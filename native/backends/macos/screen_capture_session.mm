#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <mach/mach_time.h>

#include "native_port/capture_session.hpp"

#include "audio_encoder.hpp"
#include "audio_mix_graph.hpp"
#include "process_audio_tap.hpp"
#include "native_port/capture_geometry.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cctype>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace native_port {
class MacCaptureSession;
}

@interface NativePortCaptureDelegate
    : NSObject <SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate>
@property(nonatomic, assign) native_port::MacCaptureSession* owner;
@end

namespace native_port {
namespace {

[[nodiscard]] std::string error_text(NSError* error) {
  if (error == nil) {
    return {};
  }
  const char* description = error.localizedDescription.UTF8String;
  return description != nullptr ? description : "unknown macOS capture error";
}

[[nodiscard]] std::int64_t host_time_nanoseconds() {
  mach_timebase_info_data_t timebase{};
  mach_timebase_info(&timebase);
  const auto ticks = mach_absolute_time();
  return static_cast<std::int64_t>((ticks * timebase.numer) / timebase.denom);
}

[[nodiscard]] NSString* microphone_capture_device_uid(
    const std::optional<std::string>& requested_name) {
  if (!requested_name || requested_name->empty()) {
    return nil;
  }
  NSString* requested = [NSString stringWithUTF8String:requested_name->c_str()];
  if (requested == nil || requested.length == 0) {
    return nil;
  }
  for (AVCaptureDevice* device in [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio]) {
    if ([device.localizedName caseInsensitiveCompare:requested] == NSOrderedSame ||
        [device.uniqueID caseInsensitiveCompare:requested] == NSOrderedSame) {
      return device.uniqueID;
    }
  }
  return nil;
}

[[nodiscard]] std::optional<double> frame_number(id value) {
  if (value == nil) {
    return std::nullopt;
  }
  CFTypeRef raw = (__bridge CFTypeRef)value;
  if (CFGetTypeID(raw) != CFNumberGetTypeID()) {
    return std::nullopt;
  }
  double converted = 0;
  if (!CFNumberGetValue(static_cast<CFNumberRef>(raw), kCFNumberDoubleType, &converted)) {
    return std::nullopt;
  }
  return converted;
}

[[nodiscard]] std::optional<CGRect> frame_content_rect(id value) {
  if (value == nil) {
    return std::nullopt;
  }
  if ([value isKindOfClass:[NSValue class]]) {
    return [(NSValue*)value rectValue];
  }
  CFTypeRef raw = (__bridge CFTypeRef)value;
  if (CFGetTypeID(raw) == CFDictionaryGetTypeID()) {
    CGRect converted = CGRectZero;
    if (CGRectMakeWithDictionaryRepresentation(static_cast<CFDictionaryRef>(raw), &converted)) {
      return converted;
    }
  }
  return std::nullopt;
}

[[nodiscard]] bool set_encoder_property(VTCompressionSessionRef encoder, CFStringRef key, CFTypeRef value,
                                        const char* property_name, std::string& error) {
  const auto status = VTSessionSetProperty(encoder, key, value);
  if (status != noErr) {
    error = "VideoToolbox property " + std::string(property_name) + " failed with OSStatus " +
            std::to_string(status);
    return false;
  }
  return true;
}

[[nodiscard]] std::shared_ptr<const std::vector<std::byte>> copy_block_buffer(CMBlockBufferRef block) {
  if (block == nullptr) {
    return nullptr;
  }
  const auto size = CMBlockBufferGetDataLength(block);
  auto bytes = std::make_shared<std::vector<std::byte>>(size);
  if (size > 0 && CMBlockBufferCopyDataBytes(block, 0, size, bytes->data()) != kCMBlockBufferNoErr) {
    return nullptr;
  }
  return bytes;
}

[[nodiscard]] CMVideoCodecType video_toolbox_codec_type(VideoCodec codec) {
  switch (codec) {
    case VideoCodec::h264:
      return kCMVideoCodecType_H264;
    case VideoCodec::hevc:
      return kCMVideoCodecType_HEVC;
    case VideoCodec::av1:
      return kCMVideoCodecType_AV1;
  }
  return kCMVideoCodecType_H264;
}

[[nodiscard]] CFStringRef video_profile(VideoCodec codec) {
  switch (codec) {
    case VideoCodec::h264:
      return kVTProfileLevel_H264_High_AutoLevel;
    case VideoCodec::hevc:
      return kVTProfileLevel_HEVC_Main_AutoLevel;
    case VideoCodec::av1:
      return nullptr;
  }
  return nullptr;
}

[[nodiscard]] CFStringRef codec_configuration_atom(VideoCodec codec) {
  switch (codec) {
    case VideoCodec::h264:
      return CFSTR("avcC");
    case VideoCodec::hevc:
      return CFSTR("hvcC");
    case VideoCodec::av1:
      return CFSTR("av1C");
  }
  return nullptr;
}

[[nodiscard]] std::shared_ptr<const std::vector<std::byte>> codec_configuration(
    CMFormatDescriptionRef description, VideoCodec codec) {
  if (description == nullptr || CMFormatDescriptionGetMediaSubType(description) != video_toolbox_codec_type(codec)) {
    return nullptr;
  }
  CFDictionaryRef extensions = CMFormatDescriptionGetExtensions(description);
  if (extensions == nullptr) {
    return nullptr;
  }
  auto* atoms = static_cast<CFDictionaryRef>(const_cast<void*>(
      CFDictionaryGetValue(extensions, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)));
  const auto atom_key = codec_configuration_atom(codec);
  if (atoms == nullptr || atom_key == nullptr) {
    return nullptr;
  }
  CFTypeRef value = CFDictionaryGetValue(atoms, atom_key);
  CFDataRef data = nullptr;
  if (value != nullptr && CFGetTypeID(value) == CFDataGetTypeID()) {
    data = static_cast<CFDataRef>(value);
  } else if (value != nullptr && CFGetTypeID(value) == CFArrayGetTypeID()) {
    auto* values = static_cast<CFArrayRef>(value);
    if (CFArrayGetCount(values) > 0) {
      CFTypeRef first = CFArrayGetValueAtIndex(values, 0);
      if (first != nullptr && CFGetTypeID(first) == CFDataGetTypeID()) {
        data = static_cast<CFDataRef>(first);
      }
    }
  }
  if (data == nullptr || CFDataGetLength(data) <= 0) {
    return nullptr;
  }
  const auto length = static_cast<std::size_t>(CFDataGetLength(data));
  auto result = std::make_shared<std::vector<std::byte>>(length);
  std::memcpy(result->data(), CFDataGetBytePtr(data), length);
  return result;
}

[[nodiscard]] bool supports_encoder_property(CFDictionaryRef properties, CFStringRef key) {
  return properties != nullptr && CFDictionaryContainsKey(properties, key);
}

[[nodiscard]] MediaTime media_time(CMTime time, std::int32_t fallback_timescale, std::int64_t fallback_value) {
  if (!CMTIME_IS_VALID(time) || time.timescale <= 0) {
    return MediaTime{fallback_value, Rational{1, fallback_timescale}};
  }
  return MediaTime{time.value, Rational{1, time.timescale}};
}

[[nodiscard]] bool sample_is_keyframe(CMSampleBufferRef sample) {
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
  if (attachments == nullptr || CFArrayGetCount(attachments) == 0) {
    return true;
  }
  auto* dictionary = static_cast<CFDictionaryRef>(const_cast<void*>(CFArrayGetValueAtIndex(attachments, 0)));
  return !CFDictionaryContainsKey(dictionary, kCMSampleAttachmentKey_NotSync);
}

[[nodiscard]] SCDisplay* display_for_application(SCShareableContent* content,
                                                 SCRunningApplication* application) {
  if (content == nil || application == nil || content.displays.count == 0) {
    return nil;
  }

  // An application-including filter still needs a display anchor.  Using
  // `firstObject` is wrong on multi-monitor Macs: ScreenCaptureKit then emits
  // complete frames for the selected display while the target game is on a
  // different display, yielding a black video surface with a cursor overlay.
  // Resolve the largest visible target window to the display whose global
  // bounds contain the most of that window.
  CGRect target_frame = CGRectNull;
  CGFloat target_area = 0.0;
  for (SCWindow* window in content.windows) {
    if (window.owningApplication == nil ||
        window.owningApplication.processID != application.processID || !window.isOnScreen) {
      continue;
    }
    const CGRect frame = window.frame;
    const CGFloat area = std::max<CGFloat>(0.0, CGRectGetWidth(frame)) *
                         std::max<CGFloat>(0.0, CGRectGetHeight(frame));
    if (area > target_area) {
      target_area = area;
      target_frame = frame;
    }
  }

  SCDisplay* best = content.displays.firstObject;
  CGFloat best_overlap = 0.0;
  if (!CGRectIsNull(target_frame)) {
    for (SCDisplay* display in content.displays) {
      const CGRect overlap = CGRectIntersection(CGDisplayBounds(display.displayID), target_frame);
      if (CGRectIsNull(overlap)) {
        continue;
      }
      const CGFloat area = std::max<CGFloat>(0.0, CGRectGetWidth(overlap)) *
                           std::max<CGFloat>(0.0, CGRectGetHeight(overlap));
      if (area > best_overlap) {
        best_overlap = area;
        best = display;
      }
    }
  }
  return best;
}

[[nodiscard]] SCWindow* window_for_application(SCShareableContent* content,
                                               SCRunningApplication* application) {
  if (content == nil || application == nil) {
    return nil;
  }

  // Prefer the largest visible window owned by the resolved native process.
  // `initWithDesktopIndependentWindow:` follows this window when it moves
  // between displays and excludes the rest of the desktop.  This is the
  // important distinction from an application-including display filter: the
  // latter is still anchored to one monitor and can produce a black frame with
  // only the cursor when the target is elsewhere.
  SCWindow* best = nil;
  CGFloat best_area = 0.0;
  for (SCWindow* window in content.windows) {
    if (window.owningApplication == nil ||
        window.owningApplication.processID != application.processID || !window.isOnScreen) {
      continue;
    }
    const CGRect frame = window.frame;
    const CGFloat area = std::max<CGFloat>(0.0, CGRectGetWidth(frame)) *
                         std::max<CGFloat>(0.0, CGRectGetHeight(frame));
    if (area > best_area) {
      best_area = area;
      best = window;
    }
  }
  return best;
}

}  // namespace

class MacCaptureSession final : public CaptureSession {
 public:
  MacCaptureSession(CaptureEventCallback event_callback, EncodedPacketCallback packet_callback,
                    CaptureClockCallback clock_callback)
      : event_callback_(std::move(event_callback)),
        packet_callback_(std::move(packet_callback)),
        clock_callback_(std::move(clock_callback)) {
    @autoreleasepool {
      [NSApplication sharedApplication];
      [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
      delegate_ = [[NativePortCaptureDelegate alloc] init];
      delegate_.owner = this;
      picker_ = SCContentSharingPicker.sharedPicker;
      [picker_ addObserver:delegate_];
      picker_.maximumStreamCount = @1;
    }
  }

  ~MacCaptureSession() override {
    @autoreleasepool {
      delegate_.owner = nullptr;
      [picker_ removeObserver:delegate_];
      picker_.active = NO;
      if (stream_ != nil) {
        [stream_ stopCaptureWithCompletionHandler:nil];
      }
      if (system_audio_stream_ != nil) {
        [system_audio_stream_ stopCaptureWithCompletionHandler:nil];
      }
      if (microphone_stream_ != nil) {
        [microphone_stream_ stopCaptureWithCompletionHandler:nil];
      }
      destroy_encoder();
      destroy_audio_encoders();
      stream_ = nil;
      delegate_ = nil;
    }
  }

  void enumerate_shareable_content() override {
    {
      std::scoped_lock lock(mutex_);
      enumeration_state_ = "enumerating";
      enumeration_error_.clear();
    }
    publish_event(current_state(), "source_enumeration_started");
    [SCShareableContent
        getShareableContentExcludingDesktopWindows:NO
                             onScreenWindowsOnly:NO
                                completionHandler:^(SCShareableContent* content, NSError* error) {
      if (error != nil || content == nil) {
        {
          std::scoped_lock lock(mutex_);
          enumeration_state_ = "failed";
          enumeration_error_ = error_text(error);
        }
        publish_event(current_state(), "source_enumeration_failed");
        return;
      }
      {
        std::scoped_lock lock(mutex_);
        display_count_ = content.displays.count;
        window_count_ = content.windows.count;
        application_count_ = content.applications.count;
        enumeration_state_ = "complete";
      }
      publish_event(current_state(), "sources_enumerated");
    }];
  }

  void present_source_picker(const CaptureConfiguration& configuration) override {
    validate_configuration(configuration);
    {
      std::scoped_lock lock(mutex_);
      if (state_ == "picker_presented" || state_ == "starting" || state_ == "stopping") {
        throw std::runtime_error("capture source transition is already in progress");
      }
      configuration_ = configuration;
      state_before_picker_ = state_;
      state_ = "picker_presented";
      last_error_.clear();
    }
    publish_event("picker_presented", "awaiting_user_selection");

    @autoreleasepool {
      if (!picker_.available) {
        fail("picker_unavailable", "ScreenCaptureKit reports that screen recording is unavailable");
        return;
      }
      SCContentSharingPickerConfiguration* picker_configuration =
          [[SCContentSharingPickerConfiguration alloc] init];
      picker_configuration.allowedPickerModes = SCContentSharingPickerModeSingleDisplay |
                                                  SCContentSharingPickerModeSingleWindow |
                                                  SCContentSharingPickerModeSingleApplication;
      picker_configuration.allowsChangingSelectedContent = YES;
      picker_.defaultConfiguration = picker_configuration;
      picker_.active = YES;
      [NSApp activate];
      if (stream_ != nil) {
        [picker_ setConfiguration:picker_configuration forStream:stream_];
        [picker_ presentPickerForStream:stream_];
      } else {
        const auto style = configuration.preferred_source_kind == "display"
                               ? SCShareableContentStyleDisplay
                               : (configuration.preferred_source_kind == "window" ? SCShareableContentStyleWindow
                                                                                  : SCShareableContentStyleApplication);
        [picker_ presentPickerUsingContentStyle:style];
      }
    }
  }

  void start_display(std::uint32_t display_id,
                     const CaptureConfiguration& configuration) override {
    validate_configuration(configuration);
    std::uint64_t generation = 0;
    {
      std::scoped_lock lock(mutex_);
      if (state_ == "picker_presented" || state_ == "starting" ||
          state_ == "stopping" || state_ == "capturing") {
        throw std::runtime_error("capture source transition is already in progress");
      }
      configuration_ = configuration;
      configuration_.preferred_source_kind = "display";
      state_ = "starting";
      last_error_.clear();
      generation = ++source_selection_generation_;
    }
    publish_event("starting", "resolving_display");
    [SCShareableContent
        getShareableContentExcludingDesktopWindows:NO
                             onScreenWindowsOnly:NO
                                completionHandler:^(SCShareableContent* content, NSError* error) {
      if (!source_selection_is_current(generation)) {
        return;
      }
      if (error != nil || content == nil) {
        fail("display_enumeration_failed", error_text(error));
        return;
      }
      SCDisplay* selected = nil;
      for (SCDisplay* display in content.displays) {
        if (display.displayID == display_id) {
          selected = display;
          break;
        }
      }
      if (selected == nil) {
        fail("source_disappeared", "the selected display is no longer available");
        return;
      }
      {
        std::scoped_lock lock(mutex_);
        audio_display_id_ = selected.displayID;
      }
      SCContentFilter* filter = [[SCContentFilter alloc] initWithDisplay:selected
                                                        excludingWindows:@[]];
      start_stream_if_current(filter, generation);
    }];
  }

  void start_application(const std::string& process_name,
                         const CaptureConfiguration& configuration) override {
    start_application_for_target(std::nullopt, process_name, configuration);
  }

  void start_application(const ProcessIdentity& target,
                         const CaptureConfiguration& configuration) override {
    const auto process_name = !target.screen_capture_application_name.empty()
                                  ? target.screen_capture_application_name
                                  : (!target.application_name.empty() ? target.application_name
                                                                      : target.executable_name);
    start_application_for_target(target.pid > 0 ? std::optional<std::int64_t>(target.pid)
                                               : std::nullopt,
                                 process_name, configuration);
  }

  void start_application_for_target(std::optional<std::int64_t> target_pid,
                                    const std::string& process_name,
                                    const CaptureConfiguration& configuration) {
    validate_configuration(configuration);
    if (process_name.empty()) {
      throw std::invalid_argument("process name must not be empty");
    }
    std::uint64_t generation = 0;
    {
      std::scoped_lock lock(mutex_);
      if (state_ == "picker_presented" || state_ == "starting" ||
          state_ == "stopping" || state_ == "capturing") {
        throw std::runtime_error("capture source transition is already in progress");
      }
      configuration_ = configuration;
      configuration_.preferred_source_kind = "application";
      state_ = "starting";
      last_error_.clear();
      generation = ++source_selection_generation_;
    }
    publish_event("starting", "resolving_application");
    const std::string requested_process = process_name;
    [SCShareableContent
        getShareableContentExcludingDesktopWindows:NO
                             onScreenWindowsOnly:NO
                                completionHandler:^(SCShareableContent* content, NSError* error) {
      if (!source_selection_is_current(generation)) {
        return;
      }
      if (error != nil || content == nil) {
        fail("application_enumeration_failed", error_text(error));
        return;
      }
      SCRunningApplication* selected = nil;
      NSString* requested = [NSString stringWithUTF8String:requested_process.c_str()];
      for (SCRunningApplication* application in content.applications) {
        NSRunningApplication* running =
            [NSRunningApplication runningApplicationWithProcessIdentifier:application.processID];
        NSString* executable = running.executableURL.lastPathComponent;
        const bool pid_matches = target_pid.has_value() &&
                                 static_cast<std::int64_t>(application.processID) == *target_pid;
        const bool name_matches =
            (requested.length != 0 && application.applicationName != nil &&
             [application.applicationName caseInsensitiveCompare:requested] == NSOrderedSame) ||
            (requested.length != 0 && application.bundleIdentifier != nil &&
             [application.bundleIdentifier caseInsensitiveCompare:requested] == NSOrderedSame) ||
            (requested.length != 0 && executable != nil &&
             [executable caseInsensitiveCompare:requested] == NSOrderedSame);
        const bool matches = pid_matches || name_matches;
        if (matches) {
          selected = application;
          break;
        }
      }
      // Some Unity/Java applications are present in ScreenCaptureKit's window
      // list but are omitted from the top-level applications array.  Resolve
      // the same native PID through its owning window before reporting source
      // disappearance; this keeps the typed target identity authoritative.
      if (selected == nil && target_pid.has_value()) {
        for (SCWindow* window in content.windows) {
          SCRunningApplication* owning = window.owningApplication;
          if (owning != nil && static_cast<std::int64_t>(owning.processID) == *target_pid) {
            selected = owning;
            break;
          }
        }
      }
      if (selected == nil || content.displays.count == 0) {
        const auto pid_text = target_pid.has_value() ? std::to_string(*target_pid) : "none";
        const auto detail = std::string("target application unavailable (pid=") + pid_text +
                            ", screenCaptureApplications=" + std::to_string(content.applications.count) +
                            ", screenCaptureWindows=" + std::to_string(content.windows.count) +
                            ", displays=" + std::to_string(content.displays.count) + ")";
        fail("source_disappeared", detail);
        return;
      }
      SCWindow* target_window = window_for_application(content, selected);
      SCContentFilter* filter = nil;
      if (target_window != nil) {
        filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:target_window];
      } else {
        // Some applications expose no on-screen window momentarily (for
        // example during a fullscreen transition).  Keep the display-anchored
        // application filter as a bounded fallback, but never make it the
        // normal targeted-capture path.
        SCDisplay* display = display_for_application(content, selected);
        if (display != nil) {
          filter = [[SCContentFilter alloc]
              initWithDisplay:display
           includingApplications:@[ selected ]
              exceptingWindows:@[]];
        }
      }
      if (filter == nil) {
        fail("source_disappeared", "the selected application has no capturable window or display anchor");
        return;
      }
      if (SCDisplay* audio_display = display_for_application(content, selected); audio_display != nil) {
        std::scoped_lock lock(mutex_);
        audio_display_id_ = audio_display.displayID;
      }
      start_stream_if_current(filter, generation);
    }];
  }

  void stop() override {
    SCStream* stream = nil;
    {
      std::scoped_lock lock(mutex_);
      if (state_ == "idle" || state_ == "stopped" || state_ == "cancelled") {
        return;
      }
      ++source_selection_generation_;
      state_ = "stopping";
      stream = stream_;
      if (system_audio_stream_ != nil) {
        [system_audio_stream_ stopCaptureWithCompletionHandler:nil];
      }
      if (microphone_stream_ != nil) {
        [microphone_stream_ stopCaptureWithCompletionHandler:nil];
      }
    }
    publish_event("stopping", "requested");
    if (stream == nil) {
      finish_stop(nil);
      return;
    }
    [stream stopCaptureWithCompletionHandler:^(NSError* error) {
      finish_stop(error);
    }];
  }

  void apply_audio_plan(const AudioRoutingPlan& plan) override {
    if (![NSThread isMainThread]) {
      dispatch_async(dispatch_get_main_queue(), ^{ apply_audio_plan(plan); });
      return;
    }
    bool requires_audio_rebuild = false;
    SCContentFilter* active_filter = nil;
    std::shared_ptr<AudioMixGraph> graph;
    {
      std::scoped_lock lock(mutex_);
      requires_audio_rebuild = configuration_.audio_mode != plan.mode ||
                               configuration_.capture_microphone != plan.microphone_enabled ||
                               configuration_.pc_audio_enabled != plan.pc_audio_enabled ||
                               configuration_.multiple_audio_tracks != plan.multiple_audio_tracks ||
                               configuration_.selected_audio_devices != plan.selected_audio_devices ||
                               configuration_.microphone_device_name != plan.microphone_device_name ||
                               configuration_.audio_sources.size() != plan.sources.size();
      if (!requires_audio_rebuild) {
        for (std::size_t index = 0; index < configuration_.audio_sources.size(); ++index) {
          if (configuration_.audio_sources[index].id != plan.sources[index].id ||
              configuration_.audio_sources[index].enabled != plan.sources[index].enabled) {
            requires_audio_rebuild = true;
            break;
          }
        }
      }
      active_filter = active_filter_;
      configuration_.audio_plan = plan;
      configuration_.audio_mode = plan.mode;
      configuration_.pc_audio_enabled = plan.pc_audio_enabled;
      configuration_.capture_system_audio = plan.mode == "allPcAudio" ? plan.pc_audio_enabled :
          (plan.mode == "gameOnly" || std::any_of(plan.sources.begin(), plan.sources.end(), [](const auto& source) { return source.enabled; }));
      configuration_.system_audio_volume_percent = plan.pc_audio_volume_percent;
      configuration_.microphone_gain_linear = plan.microphone_gain_linear;
      configuration_.capture_microphone = plan.microphone_enabled;
      configuration_.multiple_audio_tracks = plan.multiple_audio_tracks;
      configuration_.selected_audio_devices = plan.selected_audio_devices;
      configuration_.microphone_device_name = plan.microphone_device_name;
      configuration_.audio_sources.clear();
      for (const auto& source : plan.sources) {
        configuration_.audio_sources.push_back({source.id, source.enabled, source.volume_percent,
                                                 source.gain_linear});
      }
    }
    {
      std::scoped_lock lock(audio_encoder_mutex_);
      graph = audio_mix_graph_;
    }
    if (graph) {
      graph->set_gain("pc-audio", plan.pc_audio_gain_linear);
      graph->set_gain("microphone", plan.microphone_gain_linear);
      for (const auto& source : plan.sources) graph->set_gain(source.id, source.gain_linear);
    }
    if (requires_audio_rebuild && active_filter != nil && current_state() == "capturing") {
      // A routing/topology change is an explicit audio-generation transition.
      // Gain-only changes above stay in-place and do not interrupt video.
      rebuild_audio_only();
      return;
    }
    publish_event(current_state(), "audio_plan_applied");
  }

  void pump_events() override {
    @autoreleasepool {
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true);
    }
  }

  [[nodiscard]] nlohmann::json status() const override {
    std::shared_ptr<AacEncoder> master_audio;
    std::shared_ptr<AacEncoder> system_audio;
    std::shared_ptr<AacEncoder> microphone;
    std::shared_ptr<AudioMixGraph> graph;
    {
      std::scoped_lock audio_lock(audio_encoder_mutex_);
      master_audio = master_audio_encoder_;
      system_audio = system_audio_encoder_;
      microphone = microphone_encoder_;
      graph = audio_mix_graph_;
    }
    const auto mix_status = graph ? graph->status() : nlohmann::json(nullptr);
    std::scoped_lock lock(mutex_);
    auto result = status_locked(master_audio, system_audio, microphone);
    result["audio"]["mixGraph"] = mix_status;
    return result;
  }

  void picker_cancelled() {
    std::string next_state;
    {
      std::scoped_lock lock(mutex_);
      state_ = state_before_picker_ == "capturing" ? "capturing" : "cancelled";
      next_state = state_;
    }
    publish_event(next_state, "user_cancelled");
  }

  void picker_failed(NSError* error) {
    fail("picker_failed", error_text(error));
  }

  void picker_selected(SCContentFilter* filter, SCStream* picker_stream) {
    if (filter == nil) {
      fail("picker_failed", "system picker returned no capture filter");
      return;
    }
    if (picker_stream != nil && stream_ != nil) {
      [stream_ updateContentFilter:filter completionHandler:^(NSError* error) {
        if (error != nil) {
          fail("source_switch_failed", error_text(error));
          return;
        }
        {
          std::scoped_lock lock(mutex_);
          state_ = "capturing";
        }
        publish_event("capturing", "source_changed");
      }];
      return;
    }
    start_stream(filter);
  }

  void did_output_sample(SCStream* stream, CMSampleBufferRef sample, SCStreamOutputType type) {
    if (type == SCStreamOutputTypeAudio || type == SCStreamOutputTypeMicrophone) {
      {
        std::scoped_lock lock(mutex_);
        if ((type == SCStreamOutputTypeAudio && stream != system_audio_stream_) ||
            (type == SCStreamOutputTypeMicrophone && stream != microphone_stream_)) return;
      }
      did_output_audio(sample, type);
      return;
    }
    if (type != SCStreamOutputTypeScreen || sample == nullptr || !CMSampleBufferIsValid(sample) ||
        !CMSampleBufferDataIsReady(sample)) {
      return;
    }
    SCFrameStatus frame_status = SCFrameStatusComplete;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (attachments != nullptr && CFArrayGetCount(attachments) > 0) {
      NSDictionary* dictionary = (__bridge NSDictionary*)CFArrayGetValueAtIndex(attachments, 0);
      if (const auto status_number = frame_number(dictionary[SCStreamFrameInfoStatus]); status_number) {
        frame_status = static_cast<SCFrameStatus>(static_cast<NSInteger>(*status_number));
      }
      id content_rect_value = dictionary[SCStreamFrameInfoContentRect];
      const auto scale_factor = frame_number(dictionary[SCStreamFrameInfoScaleFactor]);
      const auto content_scale = frame_number(dictionary[SCStreamFrameInfoContentScale]);
      if (const auto frame_rect = frame_content_rect(content_rect_value); frame_rect) {
        std::scoped_lock lock(mutex_);
        last_frame_content_x_ = frame_rect->origin.x;
        last_frame_content_y_ = frame_rect->origin.y;
        last_frame_content_width_ = frame_rect->size.width;
        last_frame_content_height_ = frame_rect->size.height;
        last_frame_scale_factor_ = scale_factor.value_or(0);
        last_frame_content_scale_ = content_scale.value_or(0);
      } else if (content_rect_value != nil) {
        frame_geometry_attachment_parse_failures_.fetch_add(1, std::memory_order_relaxed);
      }
    }
    const auto previous_status = last_frame_status_.exchange(frame_status, std::memory_order_relaxed);
    const CMTime sample_pts = CMSampleBufferGetPresentationTimeStamp(sample);
    if ((frame_status == SCFrameStatusComplete || frame_status == SCFrameStatusIdle) &&
        CMTIME_IS_VALID(sample_pts) && sample_pts.timescale > 0 && clock_callback_) {
      const auto timeline_nanoseconds = rescale(
          MediaTime{sample_pts.value, Rational{1, sample_pts.timescale}}, Rational{1, 1'000'000'000});
      clock_callback_(std::max<std::int64_t>(0, timeline_nanoseconds));
    }
    if (frame_status == SCFrameStatusIdle) {
      idle_frames_.fetch_add(1, std::memory_order_relaxed);
      if (previous_status != frame_status) {
        publish_event("capturing", "source_idle");
      }
      return;
    }
    if (frame_status == SCFrameStatusBlank || frame_status == SCFrameStatusSuspended) {
      inactive_frames_.fetch_add(1, std::memory_order_relaxed);
      if (previous_status != frame_status) {
        publish_event("capturing", frame_status == SCFrameStatusBlank ? "source_blank" : "source_suspended");
      }
      return;
    }
    if (frame_status == SCFrameStatusStopped) {
      fail("source_disappeared", "ScreenCaptureKit marked the selected source as stopped");
      return;
    }
    if (previous_status != frame_status &&
        (previous_status == SCFrameStatusIdle || previous_status == SCFrameStatusBlank ||
         previous_status == SCFrameStatusSuspended)) {
      publish_event("capturing", "source_resumed");
    }
    CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
    if (image == nullptr) {
      return;
    }
    frames_received_.fetch_add(1, std::memory_order_relaxed);
    const CMTime pts = sample_pts;
    CMTime duration = CMSampleBufferGetDuration(sample);
    if (!CMTIME_IS_VALID(duration) || duration.value <= 0) {
      duration = CMTimeMake(1, static_cast<std::int32_t>(configuration_.frames_per_second));
    }
    std::scoped_lock encoder_lock(encoder_mutex_);
    if (encoder_ == nullptr) {
      return;
    }
    CVPixelBufferRetain(image);
    CFDictionaryRef frame_options = nullptr;
    if (force_next_keyframe_.exchange(false)) {
      const void* keys[] = {kVTEncodeFrameOptionKey_ForceKeyFrame}; const void* values[] = {kCFBooleanTrue};
      frame_options = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    const auto status = VTCompressionSessionEncodeFrame(encoder_, image, pts, duration, frame_options, image, nullptr);
    if (frame_options) CFRelease(frame_options);
    if (status != noErr) {
      CVPixelBufferRelease(image);
      encode_failures_.fetch_add(1, std::memory_order_relaxed);
      fail("encoder_failed", "VideoToolbox encode failed with OSStatus " + std::to_string(status));
    }
  }

  void stream_stopped(SCStream* stream, NSError* error) {
    if (stream != nil && stream == system_audio_stream_) {
      system_audio_stream_ = nil;
      return;
    }
    if (stream != nil && stream == microphone_stream_) {
      microphone_stream_ = nil;
      return;
    }
    if (stream != stream_) return; // Late callback from a drained audio generation.
    fail("stream_stopped", error_text(error));
  }

  void stream_inactive() {
    publish_event("capturing", "source_inactive");
  }

  void stream_active() {
    publish_event("capturing", "source_active");
  }

 private:
  static void validate_configuration(const CaptureConfiguration& configuration) {
    if (configuration.width == 0 || configuration.height == 0 ||
        configuration.frames_per_second == 0 || configuration.frames_per_second > 240 ||
        configuration.bitrate_bits_per_second < 100'000 ||
        (configuration.preferred_source_kind != "display" &&
         configuration.preferred_source_kind != "window" &&
         configuration.preferred_source_kind != "application")) {
      throw std::invalid_argument("invalid native capture configuration");
    }
    const auto enabled = std::count_if(configuration.audio_sources.begin(), configuration.audio_sources.end(),
                                       [](const auto& source) { return source.enabled; });
    if (enabled + (configuration.capture_microphone ? 1 : 0) > 15)
      throw std::invalid_argument("Native recording supports at most fifteen independently selected audio sources");
  }

  [[nodiscard]] bool source_selection_is_current(std::uint64_t generation) const {
    std::scoped_lock lock(mutex_);
    return generation == source_selection_generation_ && state_ == "starting";
  }

  void start_stream_if_current(SCContentFilter* filter, std::uint64_t generation) {
    if (!source_selection_is_current(generation)) {
      return;
    }
    start_stream(filter);
  }

  void did_output_audio(CMSampleBufferRef sample, SCStreamOutputType type) {
    std::shared_ptr<AudioMixGraph> graph;
    {
      std::scoped_lock lock(audio_encoder_mutex_);
      graph = audio_mix_graph_;
    }
    if (!graph) return;
    std::string error;
    if (!graph->consume(type == SCStreamOutputTypeMicrophone ? "microphone" : "pc-audio", sample,
          configuration_generation_.load(std::memory_order_relaxed), error)) fail("audio_mix_failed", std::move(error));
  }

  [[nodiscard]] std::optional<std::int64_t> pid_for_audio_source(
      const std::string& source_id, const CaptureConfiguration& configuration) const {
    if (source_id == "game-audio") {
      return configuration.target_process_id;
    }
    // MedalEncoder.exe is the original client's virtual "Medal Clip Sound"
    // label, not the Electron process.  Mapping it to the host PID captured
    // unrelated renderer/browser audio and made Specific Apps appear to work
    // while silently recording the wrong source.  Until the project-owned
    // feedback bus is present, report this source as unavailable.
    if (source_id == "MedalEncoder.exe" || source_id == "medal-clip-sound") {
      return std::nullopt;
    }
    std::string requested = source_id;
    if (requested.ends_with(".exe")) {
      requested.resize(requested.size() - 4);
    }
    const auto lower = [](std::string value) {
      std::transform(value.begin(), value.end(), value.begin(),
                     [](unsigned char character) { return static_cast<char>(std::tolower(character)); });
      return value;
    };
    requested = lower(requested);
    for (NSRunningApplication* application in NSWorkspace.sharedWorkspace.runningApplications) {
      if (application.processIdentifier <= 0) {
        continue;
      }
      const auto executable = lower(application.executableURL.lastPathComponent.UTF8String
                                        ? application.executableURL.lastPathComponent.UTF8String
                                        : "");
      const auto localized = lower(application.localizedName.UTF8String
                                       ? application.localizedName.UTF8String
                                       : "");
      const auto bundle = lower(application.bundleIdentifier.UTF8String
                                    ? application.bundleIdentifier.UTF8String
                                    : "");
      if (requested == executable || requested == localized || requested == bundle ||
          (source_id == "MedalEncoder.exe" && bundle == "com.squirrel.medal.medal")) {
        return static_cast<std::int64_t>(application.processIdentifier);
      }
    }
    return std::nullopt;
  }

  void start_process_audio_taps(const CaptureConfiguration& configuration) {
    destroy_process_audio_taps();
    if (configuration.audio_mode != "gameOnly" && configuration.audio_mode != "splitByProcess") {
      return;
    }
    struct ResolvedSource final {
      std::string id;
      std::int64_t pid{0};
      TrackKind track{TrackKind::mixed_audio};
      double gain{1.0};
    };
    std::vector<ResolvedSource> resolved;
    if (configuration.audio_mode == "gameOnly") {
      if (configuration.target_process_id) {
        resolved.push_back({"game-audio", *configuration.target_process_id,
                            TrackKind::game_audio, 1.0});
      } else {
        std::scoped_lock lock(mutex_);
        audio_tap_error_ = "Game Audio Only is enabled, but the target process has no Core Audio tap";
      }
    } else {
      for (const auto& source : configuration.audio_sources) {
        if (!source.enabled) {
          continue;
        }
        const auto pid = pid_for_audio_source(source.id, configuration);
        if (!pid) {
          std::scoped_lock lock(mutex_);
          audio_tap_error_ = "selected audio source is unavailable: " + source.id;
          continue;
        }
        resolved.push_back({source.id, *pid,
                            source.id == "game-audio" ? TrackKind::game_audio
                                                       : TrackKind::mixed_audio,
                            source.gain_linear});
      }
    }
    if (resolved.empty()) {
      return;
    }

    const auto generation = configuration_generation_.load(std::memory_order_relaxed);
    const auto callback = [this](std::shared_ptr<const EncodedPacket> packet) {
      packet_callback_(std::move(packet));
    };
    std::shared_ptr<AudioMixGraph> graph;
    { std::scoped_lock lock(audio_encoder_mutex_); graph = audio_mix_graph_; }
    std::uint32_t next_track_id = 2;
    for (const auto& source : resolved) {
      auto tap = std::make_unique<ProcessAudioTap>();
      std::string error;
      if (!tap->start({source.pid}, source.track, next_track_id++, 1.0, generation,
                      audio_session_epoch_nanoseconds_, callback, error,
                      [graph, id = source.id](CMSampleBufferRef sample, std::uint64_t gen, std::string& message) {
                        return graph && graph->consume(id, sample, gen, message);
                      })) {
        std::scoped_lock lock(mutex_);
        audio_tap_error_ = std::move(error);
        continue;
      }
      tap->set_logical_source_id(source.id);
      { std::scoped_lock lock(process_taps_mutex_); process_audio_taps_.push_back(std::move(tap)); }
    }
  }

  // `capture_system_audio` means that the selected audio configuration has at
  // least one system-side source. It does not mean that the primary
  // ScreenCaptureKit stream should always receive audio: in Specific Apps
  // mode named applications are Core Audio process taps, while only the
  // optional Game Audio source belongs to the target SCStream. Keeping this
  // distinction here prevents a Discord/Medal-only selection from being
  // silently replaced with the entire system mix.
  [[nodiscard]] bool game_audio_selected(const CaptureConfiguration& configuration) const {
    if (!configuration.capture_system_audio) {
      return false;
    }
    if (configuration.audio_mode == "allPcAudio") {
      return configuration.pc_audio_enabled;
    }
    if (configuration.audio_mode == "gameOnly") {
      // Strict game-only routing is provided by the PID-aware process tap;
      // never add a ScreenCaptureKit display mix as a fallback.
      return false;
    }
    if (configuration.audio_mode == "splitByProcess") {
      // Specific Apps and Game Audio use PID-aware Core Audio taps. A
      // display-anchored ScreenCaptureKit stream here would reintroduce the
      // whole-system fallback that the original client never requested.
      return false;
    }
    return false;
  }

  void destroy_process_audio_taps() {
    std::vector<std::unique_ptr<ProcessAudioTap>> taps;
    { std::scoped_lock lock(process_taps_mutex_); taps.swap(process_audio_taps_); }
    for (auto& tap : taps) {
      tap->stop();
    }
  }

  static void encoder_output(void* output_callback_refcon, void* source_frame_refcon, OSStatus status,
                             VTEncodeInfoFlags info_flags, CMSampleBufferRef sample_buffer) {
    auto* owner = static_cast<MacCaptureSession*>(output_callback_refcon);
    auto* retained_image = static_cast<CVImageBufferRef>(source_frame_refcon);
    if (retained_image != nullptr) {
      CVPixelBufferRelease(retained_image);
    }
    if (owner == nullptr) {
      return;
    }
    owner->did_encode(status, info_flags, sample_buffer);
  }

  void start_stream(SCContentFilter* filter, bool microphone_permission_checked = false) {
    CaptureConfiguration configuration;
    {
      std::scoped_lock lock(mutex_);
      state_ = "starting";
      configuration = configuration_;
    }
    microphone_failure_reported_.store(false, std::memory_order_relaxed);
    if (microphone_permission_checked) {
      // A denied microphone must not turn an otherwise valid display/system
      // audio recording into a black/no-output failure.  Keep the user's
      // requested setting in configuration_ for the next retry, but disable
      // only this stream and report the denial explicitly.
      configuration.capture_microphone = false;
      {
        std::scoped_lock lock(mutex_);
        last_error_ = "Microphone permission is not granted; recording continues without microphone audio until it is enabled in System Settings";
      }
      publish_event("starting", "microphone_permission_denied");
    }
    publish_event("starting", "source_selected");
    audio_session_epoch_nanoseconds_ = host_time_nanoseconds();

    // ScreenCaptureKit may still enumerate sources and transition an SCStream
    // to `capturing` when the process' own TCC grant is missing. In that
    // state macOS supplies blank frames, which would otherwise produce a
    // valid-looking but unusable black replay. The recorder has a stable
    // nested bundle identity, so check that identity before creating the
    // encoder/stream and surface the manual prerequisite to the imported UI.
    if (!CGPreflightScreenCaptureAccess()) {
      fail("screen_recording_permission_required",
           "Screen Recording permission is not granted for the signed native recorder "
           "(com.squirrel.medal.medal.recorder); approve it in System Settings > "
           "Privacy & Security > Screen & System Audio Recording, then restart capture");
      return;
    }

    // ScreenCaptureKit exposes microphone samples through the same stream, but
    // macOS still gates the input device behind the normal microphone TCC
    // decision.  Ask only after the user has enabled microphone capture in
    // Medal, and leave a precise failure in the capture state when access is
    // denied or restricted.  Never substitute system audio for a denied mic.
    if (configuration.capture_microphone) {
      const auto microphone_status =
          [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
      if (microphone_status == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                                  completionHandler:^(BOOL granted) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (granted) {
              start_stream(filter);
            } else {
              start_stream(filter, true);
            }
          });
        }];
        return;
      }
      if (microphone_status == AVAuthorizationStatusDenied ||
          microphone_status == AVAuthorizationStatusRestricted) {
        configuration.capture_microphone = false;
        {
          std::scoped_lock lock(mutex_);
          last_error_ = "Microphone permission is not granted; recording continues without microphone audio until it is enabled in System Settings";
        }
        publish_event("starting", "microphone_permission_denied");
      }
    }

    @autoreleasepool {
      const SCShareableContentInfo* info = [SCShareableContent infoForFilter:filter];
      const char* source_kind = info.style == SCShareableContentStyleDisplay
                                    ? "display"
                                    : (info.style == SCShareableContentStyleWindow
                                           ? "window"
                                           : (info.style == SCShareableContentStyleApplication ? "application" : "unknown"));
      auto geometry = fit_capture_geometry(
          info.contentRect.size.width, info.contentRect.size.height, info.pointPixelScale,
          configuration.width, configuration.height);
      // A desktop capture has a stable user-selected canvas, so its unused
      // aspect-ratio area is intentional letterbox padding.  A targeted
      // desktop-independent window is different: its native aspect ratio is
      // the content the user asked to record.  Use Medal's Resolution as a
      // maximum bound and encode the fitted window dimensions themselves;
      // otherwise ScreenCaptureKit preserves the window aspect inside a fixed
      // 1920x1080 canvas and creates synthetic black borders around the game.
      const bool window_source = info.style == SCShareableContentStyleWindow;
      if (window_source) {
        geometry.encoded_width = geometry.fitted_content_width;
        geometry.encoded_height = geometry.fitted_content_height;
        geometry.horizontal_padding = 0;
        geometry.vertical_padding = 0;
      }
      const auto width = geometry.encoded_width;
      const auto height = geometry.encoded_height;

      SCStreamConfiguration* stream_configuration = [[SCStreamConfiguration alloc] init];
      stream_configuration.width = width;
      stream_configuration.height = height;
      stream_configuration.minimumFrameInterval =
          CMTimeMake(1, static_cast<std::int32_t>(configuration.frames_per_second));
      stream_configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
      stream_configuration.queueDepth = 6;
      stream_configuration.scalesToFit = YES;
      stream_configuration.preservesAspectRatio = YES;
      stream_configuration.showsCursor = configuration.show_cursor;
      const bool game_audio_enabled = false; // Video has no audio ownership; dedicated buses below.
      stream_configuration.capturesAudio = NO;
      // Keep microphone capture on its own display-anchored SCStream.  The
      // primary application/window stream is allowed to change filters during
      // fullscreen and ScreenCaptureKit can omit microphone callbacks for a
      // desktop-independent window filter even while reporting permission as
      // authorized.  A dedicated audio-only stream makes the microphone a
      // stable independent track and avoids coupling it to the game source.
      stream_configuration.captureMicrophone = NO;
      stream_configuration.excludesCurrentProcessAudio = YES;
      stream_configuration.sampleRate = 48'000;
      stream_configuration.channelCount = 2;
      stream_configuration.captureDynamicRange = SCCaptureDynamicRangeSDR;

      std::string encoder_error;
      if (!create_encoder(width, height, configuration, encoder_error)) {
        fail("encoder_unavailable", encoder_error);
        return;
      }
      create_audio_encoders(configuration);
      start_process_audio_taps(configuration);

      SCStream* new_stream = [[SCStream alloc] initWithFilter:filter
                                                configuration:stream_configuration
                                                     delegate:delegate_];
      NSError* add_error = nil;
      if (![new_stream addStreamOutput:delegate_
                                  type:SCStreamOutputTypeScreen
                    sampleHandlerQueue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0)
                                 error:&add_error]) {
        destroy_encoder();
        fail("stream_output_failed", error_text(add_error));
        return;
      }
      if (game_audio_enabled &&
          ![new_stream addStreamOutput:delegate_
                                  type:SCStreamOutputTypeAudio
                    sampleHandlerQueue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0)
                                 error:&add_error]) {
        destroy_encoder();
        destroy_audio_encoders();
        fail("system_audio_output_failed", error_text(add_error));
        return;
      }
      // Microphone is intentionally delivered by the dedicated display-
      // anchored audio-only stream below. Adding a Microphone output to this
      // targeted video stream while captureMicrophone=NO causes a framework
      // rejection on macOS and produces the recurring generic recorder error.
      {
        std::scoped_lock lock(mutex_);
        stream_ = new_stream;
        active_filter_ = filter;
        capture_width_ = width;
        capture_height_ = height;
        source_width_points_ = geometry.source_width_points;
        source_height_points_ = geometry.source_height_points;
        source_point_pixel_scale_ = geometry.point_pixel_scale;
        source_width_pixels_ = geometry.source_width_pixels;
        source_height_pixels_ = geometry.source_height_pixels;
        fitted_content_width_ = geometry.fitted_content_width;
        fitted_content_height_ = geometry.fitted_content_height;
        horizontal_padding_ = geometry.horizontal_padding;
        vertical_padding_ = geometry.vertical_padding;
        source_kind_ = source_kind;
      }
      [new_stream startCaptureWithCompletionHandler:^(NSError* error) {
        if (error != nil) {
          destroy_encoder();
          fail("capture_start_failed", error_text(error));
          return;
        }
        {
          std::scoped_lock lock(mutex_);
          state_ = "capturing";
        }
        publish_event("capturing", "capture_started");
      }];
      if (configuration.audio_mode == "allPcAudio" && configuration.pc_audio_enabled &&
          configuration.capture_system_audio) {
        // ScreenCaptureKit scopes audio to an application/window filter. A
        // second display-anchored audio-only stream supplies the full PC mix.
        start_system_audio_stream_for_display(configuration);
      }
      if (configuration.capture_microphone) {
        start_microphone_stream_for_display(configuration);
      }
    }
  }

  void start_system_audio_stream_for_display(const CaptureConfiguration&) {
    const auto generation = audio_source_generation_.load();
    std::optional<std::uint32_t> display_id;
    {
      std::scoped_lock lock(mutex_);
      display_id = audio_display_id_;
    }
    if (!display_id) {
      return;
    }
    [SCShareableContent
        getShareableContentExcludingDesktopWindows:NO
                             onScreenWindowsOnly:NO
                                completionHandler:^(SCShareableContent* content, NSError* error) {
      if (generation != audio_source_generation_.load()) return;
      if (error != nil || content == nil) {
        std::scoped_lock lock(mutex_);
        last_error_ = "allPcAudio display stream enumeration failed: " + error_text(error);
        return;
      }
      SCDisplay* selected = nil;
      for (SCDisplay* display in content.displays) {
        if (display.displayID == *display_id) {
          selected = display;
          break;
        }
      }
      if (selected == nil) {
        std::scoped_lock lock(mutex_);
        last_error_ = "allPcAudio display stream source disappeared";
        return;
      }
      SCContentFilter* filter = [[SCContentFilter alloc] initWithDisplay:selected
                                                        excludingWindows:@[]];
      SCStreamConfiguration* audio_configuration = [[SCStreamConfiguration alloc] init];
      audio_configuration.width = 2;
      audio_configuration.height = 2;
      audio_configuration.minimumFrameInterval = CMTimeMake(1, 1);
      audio_configuration.queueDepth = 2;
      audio_configuration.capturesAudio = YES;
      audio_configuration.captureMicrophone = NO;
      // The host Electron process owns Medal's clip sound. Do not exclude the
      // helper's process here; the display mix is the user's selected PC mix.
      audio_configuration.excludesCurrentProcessAudio = NO;
      audio_configuration.sampleRate = 48'000;
      audio_configuration.channelCount = 2;
      audio_configuration.captureDynamicRange = SCCaptureDynamicRangeSDR;
      SCStream* audio_stream = [[SCStream alloc] initWithFilter:filter
                                                   configuration:audio_configuration
                                                        delegate:delegate_];
      NSError* add_error = nil;
      if (![audio_stream addStreamOutput:delegate_
                                    type:SCStreamOutputTypeAudio
                      sampleHandlerQueue:audio_worker_queue_
                                   error:&add_error]) {
        std::scoped_lock lock(mutex_);
        last_error_ = "allPcAudio stream output failed: " + error_text(add_error);
        return;
      }
      {
        std::scoped_lock lock(mutex_);
        if (generation != audio_source_generation_.load()) return;
        system_audio_stream_ = audio_stream;
      }
      [audio_stream startCaptureWithCompletionHandler:^(NSError* start_error) {
        if (start_error != nil) {
          std::scoped_lock lock(mutex_);
          last_error_ = "allPcAudio stream start failed: " + error_text(start_error);
        }
      }];
    }];
  }

  void start_microphone_stream_for_display(const CaptureConfiguration& configuration) {
    const auto generation = audio_source_generation_.load();
    if (configuration.microphone_device_name && microphone_capture_device_uid(configuration.microphone_device_name) == nil) {
      { std::scoped_lock lock(mutex_); last_error_ = "The selected microphone device is unavailable"; }
      publish_event(current_state(), "microphone_device_unavailable");
      return;
    }
    std::optional<std::uint32_t> display_id;
    {
      std::scoped_lock lock(mutex_);
      display_id = audio_display_id_;
    }
    if (!display_id) {
      std::scoped_lock lock(mutex_);
      last_error_ = "microphone stream has no display anchor";
      return;
    }
    [SCShareableContent
        getShareableContentExcludingDesktopWindows:NO
                             onScreenWindowsOnly:NO
                                completionHandler:^(SCShareableContent* content, NSError* error) {
      if (generation != audio_source_generation_.load()) return;
      if (error != nil || content == nil) {
        std::scoped_lock lock(mutex_);
        last_error_ = "microphone display stream enumeration failed: " + error_text(error);
        return;
      }
      SCDisplay* selected = nil;
      for (SCDisplay* display in content.displays) {
        if (display.displayID == *display_id) {
          selected = display;
          break;
        }
      }
      if (selected == nil) {
        std::scoped_lock lock(mutex_);
        last_error_ = "microphone display stream source disappeared";
        return;
      }
      SCContentFilter* filter = [[SCContentFilter alloc] initWithDisplay:selected
                                                        excludingWindows:@[]];
      SCStreamConfiguration* microphone_configuration = [[SCStreamConfiguration alloc] init];
      microphone_configuration.width = 2;
      microphone_configuration.height = 2;
      microphone_configuration.minimumFrameInterval = CMTimeMake(1, 1);
      microphone_configuration.queueDepth = 2;
      microphone_configuration.capturesAudio = NO;
      microphone_configuration.captureMicrophone = YES;
      if (NSString* device_uid = microphone_capture_device_uid(configuration.microphone_device_name);
          device_uid != nil) {
        microphone_configuration.microphoneCaptureDeviceID = device_uid;
      }
      microphone_configuration.excludesCurrentProcessAudio = YES;
      microphone_configuration.sampleRate = 48'000;
      microphone_configuration.channelCount = 2;
      microphone_configuration.captureDynamicRange = SCCaptureDynamicRangeSDR;
      SCStream* microphone_stream = [[SCStream alloc] initWithFilter:filter
                                                           configuration:microphone_configuration
                                                                delegate:delegate_];
      NSError* add_error = nil;
      if (![microphone_stream addStreamOutput:delegate_
                                         type:SCStreamOutputTypeMicrophone
                           sampleHandlerQueue:audio_worker_queue_
                                        error:&add_error]) {
        std::scoped_lock lock(mutex_);
        last_error_ = "microphone stream output failed: " + error_text(add_error);
        return;
      }
      {
        std::scoped_lock lock(mutex_);
        if (generation != audio_source_generation_.load()) return;
        microphone_stream_ = microphone_stream;
      }
      [microphone_stream startCaptureWithCompletionHandler:^(NSError* start_error) {
        if (start_error != nil) {
          std::scoped_lock lock(mutex_);
          last_error_ = "microphone stream start failed: " + error_text(start_error);
        }
      }];
    }];
  }

  [[nodiscard]] bool create_encoder(std::size_t width, std::size_t height,
                                    const CaptureConfiguration& configuration, std::string& error) {
    destroy_encoder();
    first_video_packet_nanoseconds_.store(-1, std::memory_order_relaxed);
    last_video_packet_end_nanoseconds_.store(-1, std::memory_order_relaxed);
    pts_dts_mismatches_.store(0, std::memory_order_relaxed);
    encoded_width_.store(static_cast<std::uint32_t>(width), std::memory_order_relaxed);
    encoded_height_.store(static_cast<std::uint32_t>(height), std::memory_order_relaxed);
    encoded_bitrate_.store(static_cast<std::uint32_t>(std::min<std::uint64_t>(
                               configuration.bitrate_bits_per_second,
                               std::numeric_limits<std::uint32_t>::max())),
                           std::memory_order_relaxed);
    const auto codec_type = video_toolbox_codec_type(configuration.video_codec);
    const auto medal_codec = std::string(medal_video_codec_name(configuration.video_codec));
    const void* keys[] = {kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder};
    const void* values[] = {kCFBooleanTrue};
    CFDictionaryRef specification =
        CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                           &kCFTypeDictionaryValueCallBacks);
    VTCompressionSessionRef new_encoder = nullptr;
    const auto create_status = VTCompressionSessionCreate(
        kCFAllocatorDefault, static_cast<std::int32_t>(width), static_cast<std::int32_t>(height),
        codec_type, specification, nullptr, nullptr, &MacCaptureSession::encoder_output, this,
        &new_encoder);
    CFRelease(specification);
    if (create_status != noErr || new_encoder == nullptr) {
      error = "hardware " + medal_codec + " encoder creation failed with OSStatus " +
              std::to_string(create_status);
      return false;
    }

    const auto discard_encoder = [&] {
      VTCompressionSessionInvalidate(new_encoder);
      CFRelease(new_encoder);
    };
    CFDictionaryRef supported_properties = nullptr;
    const auto supported_status = VTSessionCopySupportedPropertyDictionary(new_encoder, &supported_properties);
    if (supported_status != noErr || supported_properties == nullptr) {
      error = "VideoToolbox supported-property query failed with OSStatus " + std::to_string(supported_status);
      discard_encoder();
      return false;
    }

    const std::string quality_preset = "realtime_quality_priority";

    std::int32_t frame_rate = static_cast<std::int32_t>(configuration.frames_per_second);
    std::int32_t bitrate = static_cast<std::int32_t>(
        std::min<std::uint64_t>(configuration.bitrate_bits_per_second,
                                static_cast<std::uint64_t>(std::numeric_limits<std::int32_t>::max())));
    std::int32_t keyframe_seconds = 2;
    CFNumberRef frame_rate_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &frame_rate);
    CFNumberRef bitrate_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bitrate);
    CFNumberRef keyframe_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &keyframe_seconds);
    const auto set_required = [&](CFStringRef key, CFTypeRef value, const char* property_name) {
      if (!supports_encoder_property(supported_properties, key)) {
        error = "VideoToolbox " + medal_codec + " encoder lacks required property " + property_name;
        return false;
      }
      return set_encoder_property(new_encoder, key, value, property_name, error);
    };
    bool properties_ok =
        set_required(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, "RealTime") &&
        set_required(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse,
                     "AllowFrameReordering");
    const auto profile = video_profile(configuration.video_codec);
    if (properties_ok && profile != nullptr) {
      properties_ok = set_required(kVTCompressionPropertyKey_ProfileLevel, profile, "ProfileLevel");
    }
    properties_ok = properties_ok &&
                    set_required(kVTCompressionPropertyKey_ExpectedFrameRate, frame_rate_number,
                                 "ExpectedFrameRate") &&
                    set_required(kVTCompressionPropertyKey_AverageBitRate, bitrate_number,
                                 "AverageBitRate") &&
                    set_required(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                                 keyframe_number, "MaxKeyFrameIntervalDuration");
    if (properties_ok &&
        supports_encoder_property(supported_properties,
                                  kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality)) {
      properties_ok = set_encoder_property(new_encoder,
                                           kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                                           kCFBooleanFalse, "PrioritizeEncodingSpeedOverQuality", error);
    }
    CFRelease(frame_rate_number);
    CFRelease(bitrate_number);
    CFRelease(keyframe_number);
    CFRelease(supported_properties);
    if (!properties_ok) {
      discard_encoder();
      return false;
    }
    const auto prepare_status = VTCompressionSessionPrepareToEncodeFrames(new_encoder);
    if (prepare_status != noErr) {
      error = "VideoToolbox encoder preparation failed with OSStatus " + std::to_string(prepare_status);
      discard_encoder();
      return false;
    }
    CFTypeRef hardware_value = nullptr;
    const auto property_status = VTSessionCopyProperty(
        new_encoder, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, kCFAllocatorDefault,
        &hardware_value);
    const bool hardware_encoder = property_status == noErr && hardware_value == kCFBooleanTrue;
    if (hardware_value != nullptr) {
      CFRelease(hardware_value);
    }
    if (!hardware_encoder) {
      error = "VideoToolbox did not confirm hardware encoder use";
      discard_encoder();
      return false;
    }
    {
      std::scoped_lock lock(encoder_mutex_);
      encoder_ = new_encoder;
    }
    {
      std::scoped_lock lock(mutex_);
      hardware_encoder_ = true;
      quality_preset_ = quality_preset;
    }
    active_video_codec_.store(configuration.video_codec, std::memory_order_relaxed);
    configuration_generation_.fetch_add(1, std::memory_order_relaxed);
    return true;
  }

  void destroy_encoder() {
    VTCompressionSessionRef encoder = nullptr;
    {
      std::scoped_lock lock(encoder_mutex_);
      encoder = encoder_;
      encoder_ = nullptr;
    }
    if (encoder != nullptr) {
      VTCompressionSessionCompleteFrames(encoder, kCMTimeInvalid);
      VTCompressionSessionInvalidate(encoder);
      CFRelease(encoder);
    }
    {
      std::scoped_lock lock(mutex_);
      hardware_encoder_ = false;
    }
  }

  void create_audio_encoders(const CaptureConfiguration& configuration) {
    audio_source_generation_.fetch_add(1);
    std::scoped_lock lock(audio_encoder_mutex_);
    master_audio_encoder_.reset();
    system_audio_encoder_.reset();
    microphone_encoder_.reset();
    std::vector<PcmSource> sources;
    std::uint32_t next_id = 2;
    if (game_audio_selected(configuration)) sources.push_back({"pc-audio", TrackKind::mixed_audio, next_id++, configuration.audio_plan.pc_audio_gain_linear});
    else if (configuration.audio_mode == "gameOnly" && configuration.target_process_id) {
      auto gain = 1.0;
      for (const auto& source : configuration.audio_sources) if (source.id == "game-audio") gain = source.gain_linear;
      sources.push_back({"game-audio", TrackKind::game_audio, next_id++, gain});
    } else if (configuration.audio_mode == "splitByProcess") {
      for (const auto& source : configuration.audio_sources) if (source.enabled && pid_for_audio_source(source.id, configuration))
        sources.push_back({source.id, source.id == "game-audio" ? TrackKind::game_audio : TrackKind::mixed_audio, next_id++, source.gain_linear});
    }
    if (configuration.capture_microphone) sources.push_back({"microphone", TrackKind::microphone_audio, next_id++, configuration.microphone_gain_linear});
    audio_mix_graph_ = std::make_shared<AudioMixGraph>(std::move(sources), configuration.multiple_audio_tracks,
      configuration_generation_.load(), [this](auto packet) { packet_callback_(std::move(packet)); });
    master_audio_encoder_ = audio_mix_graph_->encoder("all-audio");
    system_audio_encoder_ = audio_mix_graph_->encoder("pc-audio");
    microphone_encoder_ = audio_mix_graph_->encoder("microphone");
  }

  void destroy_audio_encoders() {
    audio_source_generation_.fetch_add(1);
    destroy_process_audio_taps();
    std::shared_ptr<AudioMixGraph> graph;
    { std::scoped_lock lock(audio_encoder_mutex_); graph = std::exchange(audio_mix_graph_, nullptr); }
    if (graph) graph->finish();
    std::shared_ptr<AacEncoder> master_audio;
    std::shared_ptr<AacEncoder> system_audio;
    std::shared_ptr<AacEncoder> microphone;
    {
      std::scoped_lock lock(audio_encoder_mutex_);
      master_audio = master_audio_encoder_;
      system_audio = system_audio_encoder_;
      microphone = microphone_encoder_;
    }
    if (master_audio) {
      master_audio->reset();
    }
    if (system_audio) {
      system_audio->reset();
    }
    if (microphone) {
      microphone->reset();
    }
  }

  void rebuild_audio_only() {
    SCStream* system = nil;
    SCStream* microphone = nil;
    {
      std::scoped_lock lock(mutex_);
      // A second settings batch updates configuration_ while the existing
      // drain completes. The completion always builds the latest full plan.
      if (audio_rebuild_in_flight_) return;
      audio_rebuild_in_flight_ = true;
      system = system_audio_stream_; system_audio_stream_ = nil;
      microphone = microphone_stream_; microphone_stream_ = nil;
      audio_source_generation_.fetch_add(1);
    }
    publish_event("capturing", "audio_plan_rebuilding");
    dispatch_group_t stopped = dispatch_group_create();
    SCStream* audio_streams[] = {system, microphone};
    for (SCStream* audio_stream : audio_streams) {
      if (audio_stream == nil) continue;
      dispatch_group_enter(stopped);
      [audio_stream stopCaptureWithCompletionHandler:^(NSError* error) {
        if (error) { std::scoped_lock lock(mutex_); last_error_ = "audio-only drain failed: " + error_text(error); }
        dispatch_group_leave(stopped);
      }];
    }
    dispatch_group_notify(stopped, dispatch_get_main_queue(), ^{
      CaptureConfiguration configuration;
      {
        std::scoped_lock lock(mutex_);
        audio_rebuild_in_flight_ = false;
        if (state_ != "capturing") return;
        configuration = configuration_;
      }
      destroy_audio_encoders();
      configuration_generation_.fetch_add(1);
      force_next_keyframe_.store(true);
      if (configuration.capture_microphone && [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized) {
        configuration.capture_microphone = false;
        { std::scoped_lock lock(mutex_); last_error_ = "Microphone permission is required for the selected audio plan"; }
        publish_event("capturing", "microphone_permission_required");
      }
      try {
        create_audio_encoders(configuration);
        start_process_audio_taps(configuration);
        if (game_audio_selected(configuration)) start_system_audio_stream_for_display(configuration);
        if (configuration.capture_microphone) start_microphone_stream_for_display(configuration);
        publish_event("capturing", "audio_plan_applied");
      } catch (const std::exception& error) {
        { std::scoped_lock lock(mutex_); last_error_ = error.what(); }
        publish_event("capturing", "audio_plan_failed");
      }
    });
  }

  void did_encode(OSStatus status, VTEncodeInfoFlags info_flags, CMSampleBufferRef sample) {
    if (status != noErr || (info_flags & kVTEncodeInfo_FrameDropped) != 0 || sample == nullptr ||
        !CMSampleBufferDataIsReady(sample)) {
      encode_failures_.fetch_add(1, std::memory_order_relaxed);
      if (status != noErr) {
        fail("encoder_callback_failed", "VideoToolbox callback failed with OSStatus " + std::to_string(status));
      }
      return;
    }
    const bool keyframe = sample_is_keyframe(sample);
    auto payload = copy_block_buffer(CMSampleBufferGetDataBuffer(sample));
    if (!payload || payload->empty()) {
      encode_failures_.fetch_add(1, std::memory_order_relaxed);
      return;
    }
    auto packet = std::make_shared<EncodedPacket>();
    const auto video_codec = active_video_codec_.load(std::memory_order_relaxed);
    packet->codec = encoded_packet_codec(video_codec);
    packet->track = TrackKind::video;
    packet->track_id = 1;
    packet->configuration_generation = configuration_generation_.load(std::memory_order_relaxed);
    packet->pts = media_time(CMSampleBufferGetPresentationTimeStamp(sample), 1'000'000'000, 0);
    packet->dts = media_time(CMSampleBufferGetDecodeTimeStamp(sample), packet->pts.time_base.denominator,
                             packet->pts.value);
    if (rescale(packet->pts, Rational{1, 1'000'000'000}) !=
        rescale(packet->dts, Rational{1, 1'000'000'000})) {
      pts_dts_mismatches_.fetch_add(1, std::memory_order_relaxed);
    }
    packet->duration = media_time(CMSampleBufferGetDuration(sample),
                                  static_cast<std::int32_t>(configuration_.frames_per_second), 1);
    const auto monotonic = rescale(packet->pts, Rational{1, 1'000'000'000});
    packet->monotonic_nanoseconds = std::max<std::int64_t>(0, monotonic);
    packet->keyframe = keyframe;
    packet->depends_on_others = !keyframe;
    packet->video_width = encoded_width_.load(std::memory_order_relaxed);
    packet->video_height = encoded_height_.load(std::memory_order_relaxed);
    packet->bitrate_bits_per_second = encoded_bitrate_.load(std::memory_order_relaxed);
    packet->data = std::move(payload);
    if (keyframe) {
      packet->codec_configuration = codec_configuration(CMSampleBufferGetFormatDescription(sample), video_codec);
      if (!packet->codec_configuration || packet->codec_configuration->empty()) {
        encode_failures_.fetch_add(1, std::memory_order_relaxed);
        return;
      }
    }
    frames_encoded_.fetch_add(1, std::memory_order_relaxed);
    const auto packet_end = packet->monotonic_nanoseconds +
                            rescale(packet->duration, Rational{1, 1'000'000'000});
    std::int64_t unset = -1;
    first_video_packet_nanoseconds_.compare_exchange_strong(
        unset, packet->monotonic_nanoseconds, std::memory_order_relaxed);
    last_video_packet_end_nanoseconds_.store(packet_end, std::memory_order_relaxed);
    packet_callback_(std::move(packet));
  }

  void finish_stop(NSError* error) {
    if (error != nil) {
      fail("capture_stop_failed", error_text(error));
      return;
    }
    destroy_encoder();
    destroy_audio_encoders();
    {
      std::scoped_lock lock(mutex_);
      stream_ = nil;
      active_filter_ = nil;
      system_audio_stream_ = nil;
      microphone_stream_ = nil;
      state_ = "stopped";
    }
    publish_event("stopped", "requested");
  }

  void fail(std::string reason, std::string message) {
    bool transitioned = false;
    {
      std::scoped_lock lock(mutex_);
      if (state_ == "failed") {
        return;
      }
      state_ = "failed";
      last_error_ = std::move(message);
      transitioned = true;
    }
    if (transitioned) {
      publish_event("failed", std::move(reason));
    }
  }

  void publish_event(std::string state, std::string reason) const {
    auto value = status();
    value["schemaVersion"] = 1;
    value["state"] = std::move(state);
    value["reason"] = std::move(reason);
    event_callback_(std::move(value));
  }

  [[nodiscard]] std::string current_state() const {
    std::scoped_lock lock(mutex_);
    return state_;
  }

  [[nodiscard]] nlohmann::json audio_status(const std::shared_ptr<AacEncoder>& encoder,
                                            bool enabled) const {
    nlohmann::json result = {
        {"enabled", enabled},
        {"inputSampleCount", encoder ? encoder->input_sample_count() : 0},
        {"packetsEncoded", encoder ? encoder->packet_count() : 0},
        {"encodeFailures", encoder ? encoder->failure_count() : 0},
        {"discontinuities", encoder ? encoder->discontinuity_count() : 0},
        {"sampleRate", encoder ? encoder->sample_rate() : 0},
        {"channelCount", encoder ? encoder->channel_count() : 0},
        {"firstPacketNanoseconds", encoder ? encoder->first_packet_nanoseconds() : -1},
        {"lastPacketEndNanoseconds", encoder ? encoder->last_packet_end_nanoseconds() : -1},
    };
    const auto video_end = last_video_packet_end_nanoseconds_.load(std::memory_order_relaxed);
    const auto audio_end = encoder ? encoder->last_packet_end_nanoseconds() : -1;
    result["endToVideoDriftNanoseconds"] =
        video_end >= 0 && audio_end >= 0 ? nlohmann::json(audio_end - video_end) : nlohmann::json(nullptr);
    const auto video_start = first_video_packet_nanoseconds_.load(std::memory_order_relaxed);
    const auto audio_start = encoder ? encoder->first_packet_nanoseconds() : -1;
    result["startToVideoOffsetNanoseconds"] =
        video_start >= 0 && audio_start >= 0 ? nlohmann::json(audio_start - video_start) : nlohmann::json(nullptr);
    return result;
  }

  [[nodiscard]] nlohmann::json status_locked(const std::shared_ptr<AacEncoder>& master_audio,
                                              const std::shared_ptr<AacEncoder>& system_audio,
                                              const std::shared_ptr<AacEncoder>& microphone) const {
    return {
        {"schemaVersion", 1},
        {"state", state_},
        {"screenCaptureAccess", CGPreflightScreenCaptureAccess() != false},
        {"microphonePermission", [&] {
          switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) {
            case AVAuthorizationStatusAuthorized: return std::string("authorized");
            case AVAuthorizationStatusDenied: return std::string("denied");
            case AVAuthorizationStatusRestricted: return std::string("restricted");
            case AVAuthorizationStatusNotDetermined: return std::string("not_determined");
          }
          return std::string("unknown");
        }()},
        {"width", capture_width_},
        {"height", capture_height_},
        {"geometry",
         {{"aspectPolicy", source_kind_ == "window" ? "fit_source_bounded" : "fit_letterbox"},
          {"sourceContentRectPoints",
           {{"width", source_width_points_}, {"height", source_height_points_}}},
          {"pointPixelScale", source_point_pixel_scale_},
          {"sourcePixels", {{"width", source_width_pixels_}, {"height", source_height_pixels_}}},
          {"requestedMedalResolution",
           {{"width", configuration_.width}, {"height", configuration_.height}}},
          {"fittedContentPixels",
           {{"width", fitted_content_width_}, {"height", fitted_content_height_}}},
          {"paddingPixels",
           {{"horizontalTotal", horizontal_padding_}, {"verticalTotal", vertical_padding_}}},
          {"finalEncodedPixels", {{"width", capture_width_}, {"height", capture_height_}}},
          {"lastFrameAttachments",
           {{"contentRect",
             {{"x", last_frame_content_x_},
              {"y", last_frame_content_y_},
              {"width", last_frame_content_width_},
              {"height", last_frame_content_height_}}},
            {"scaleFactor", last_frame_scale_factor_},
            {"contentScale", last_frame_content_scale_},
            {"parseFailures",
             frame_geometry_attachment_parse_failures_.load(std::memory_order_relaxed)}}}}},
        {"sourceKind", source_kind_},
        {"framesPerSecond", configuration_.frames_per_second},
        {"bitrateBitsPerSecond", configuration_.bitrate_bits_per_second},
        {"videoCodec", medal_video_codec_name(configuration_.video_codec)},
        {"nativeVideoCodec", video_codec_name(configuration_.video_codec)},
        {"qualityPreset", quality_preset_},
        {"hardwareEncoder", hardware_encoder_},
        {"gop",
         {{"allowFrameReordering", false},
          {"maximumKeyframeIntervalDurationSeconds", 2},
          {"ptsDtsMismatchCount", pts_dts_mismatches_.load(std::memory_order_relaxed)}}},
        {"framesReceived", frames_received_.load(std::memory_order_relaxed)},
        {"framesEncoded", frames_encoded_.load(std::memory_order_relaxed)},
        {"encodeFailures", encode_failures_.load(std::memory_order_relaxed)},
        {"idleFrames", idle_frames_.load(std::memory_order_relaxed)},
        {"inactiveFrames", inactive_frames_.load(std::memory_order_relaxed)},
        {"lastFrameStatusCode", static_cast<int>(last_frame_status_.load(std::memory_order_relaxed))},
        {"audio",
         {{"mode", configuration_.audio_mode},
          {"pcAudioEnabled", configuration_.pc_audio_enabled},
          {"master", audio_status(master_audio, configuration_.multiple_audio_tracks)},
          {"system", audio_status(system_audio, configuration_.capture_system_audio)},
          {"microphone", audio_status(microphone, configuration_.capture_microphone)},
          {"selectedOutputDevices", configuration_.selected_audio_devices},
          {"multipleTracks", configuration_.multiple_audio_tracks},
          {"processTaps", [&] { std::scoped_lock lock(process_taps_mutex_); return process_audio_taps_.size(); }()},
          {"processTapRejectedLayouts", [&] {
             std::uint64_t rejected = 0;
             std::scoped_lock lock(process_taps_mutex_);
             for (const auto& tap : process_audio_taps_) {
               rejected += tap->rejected_layout_count();
             }
             return rejected;
           }()},
          {"processTapErrors", [&] {
             nlohmann::json errors = nlohmann::json::array();
             std::scoped_lock lock(process_taps_mutex_);
             for (const auto& tap : process_audio_taps_) {
               if (!tap->error().empty()) {
                 errors.push_back(tap->error());
               }
             }
             return errors;
           }()},
          {"processTapError", audio_tap_error_}}},
        {"sourceEnumeration",
         {{"state", enumeration_state_},
          {"displayCount", display_count_},
          {"windowCount", window_count_},
          {"applicationCount", application_count_},
          {"lastError", enumeration_error_}}},
        {"lastError", last_error_},
    };
  }

  CaptureEventCallback event_callback_;
  EncodedPacketCallback packet_callback_;
  CaptureClockCallback clock_callback_;
  mutable std::mutex mutex_;
  std::mutex encoder_mutex_;
  mutable std::mutex audio_encoder_mutex_;
  CaptureConfiguration configuration_;
  std::string state_{"idle"};
  std::string state_before_picker_{"idle"};
  std::string last_error_;
  std::size_t capture_width_{0};
  std::size_t capture_height_{0};
  double source_width_points_{0};
  double source_height_points_{0};
  double source_point_pixel_scale_{0};
  std::size_t source_width_pixels_{0};
  std::size_t source_height_pixels_{0};
  std::size_t fitted_content_width_{0};
  std::size_t fitted_content_height_{0};
  std::size_t horizontal_padding_{0};
  std::size_t vertical_padding_{0};
  double last_frame_content_x_{0};
  double last_frame_content_y_{0};
  double last_frame_content_width_{0};
  double last_frame_content_height_{0};
  double last_frame_scale_factor_{0};
  double last_frame_content_scale_{0};
  std::string source_kind_{"none"};
  std::atomic<std::uint64_t> configuration_generation_{0};
  std::atomic<bool> force_next_keyframe_{false};
  std::atomic<std::uint64_t> audio_source_generation_{0};
  bool audio_rebuild_in_flight_{false};
  std::int64_t audio_session_epoch_nanoseconds_{0};
  std::atomic<VideoCodec> active_video_codec_{VideoCodec::h264};
  std::atomic<std::uint64_t> frames_received_{0};
  std::atomic<std::uint64_t> frames_encoded_{0};
  std::atomic<std::uint64_t> encode_failures_{0};
  std::atomic<std::uint64_t> pts_dts_mismatches_{0};
  std::atomic<std::uint64_t> idle_frames_{0};
  std::atomic<std::uint64_t> inactive_frames_{0};
  std::atomic<std::uint64_t> frame_geometry_attachment_parse_failures_{0};
  std::atomic<std::int64_t> first_video_packet_nanoseconds_{-1};
  std::atomic<std::int64_t> last_video_packet_end_nanoseconds_{-1};
  std::atomic<std::uint32_t> encoded_width_{0};
  std::atomic<std::uint32_t> encoded_height_{0};
  std::atomic<std::uint32_t> encoded_bitrate_{0};
  std::atomic<SCFrameStatus> last_frame_status_{SCFrameStatusStopped};
  std::string enumeration_state_{"not_requested"};
  std::string enumeration_error_;
  std::size_t display_count_{0};
  std::size_t window_count_{0};
  std::size_t application_count_{0};
  std::uint64_t source_selection_generation_{0};
  bool hardware_encoder_{false};
  std::string quality_preset_{"not_started"};
  SCContentSharingPicker* picker_{nil};
  NativePortCaptureDelegate* delegate_{nil};
  SCStream* stream_{nil};
  SCContentFilter* active_filter_{nil};
  VTCompressionSessionRef encoder_{nullptr};
  std::optional<std::uint32_t> audio_display_id_;
  SCStream* system_audio_stream_{nil};
  SCStream* microphone_stream_{nil};
  std::shared_ptr<AacEncoder> system_audio_encoder_;
  std::shared_ptr<AacEncoder> master_audio_encoder_;
  std::shared_ptr<AacEncoder> microphone_encoder_;
  std::shared_ptr<AudioMixGraph> audio_mix_graph_;
  std::vector<std::unique_ptr<ProcessAudioTap>> process_audio_taps_;
  mutable std::mutex process_taps_mutex_;
  dispatch_queue_t audio_worker_queue_{dispatch_queue_create("com.squirrel.medal.medal.audio-samples", DISPATCH_QUEUE_SERIAL)};
  std::string audio_tap_error_;
  std::atomic<bool> microphone_failure_reported_{false};
};

}  // namespace native_port

@implementation NativePortCaptureDelegate

- (void)contentSharingPicker:(SCContentSharingPicker*)picker didCancelForStream:(SCStream*)stream {
  (void)picker;
  (void)stream;
  if (self.owner != nullptr) {
    self.owner->picker_cancelled();
  }
}

- (void)contentSharingPicker:(SCContentSharingPicker*)picker
         didUpdateWithFilter:(SCContentFilter*)filter
                   forStream:(SCStream*)stream {
  (void)picker;
  if (self.owner != nullptr) {
    self.owner->picker_selected(filter, stream);
  }
}

- (void)contentSharingPickerStartDidFailWithError:(NSError*)error {
  if (self.owner != nullptr) {
    self.owner->picker_failed(error);
  }
}

- (void)stream:(SCStream*)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
  if (self.owner != nullptr) {
    self.owner->did_output_sample(stream, sampleBuffer, type);
  }
}

- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
  if (self.owner != nullptr) {
    self.owner->stream_stopped(stream, error);
  }
}

- (void)streamDidBecomeActive:(SCStream*)stream {
  (void)stream;
  if (self.owner != nullptr) {
    self.owner->stream_active();
  }
}

- (void)streamDidBecomeInactive:(SCStream*)stream {
  (void)stream;
  if (self.owner != nullptr) {
    self.owner->stream_inactive();
  }
}

@end

namespace native_port {
std::unique_ptr<CaptureSession> make_capture_session(CaptureEventCallback event_callback,
                                                     EncodedPacketCallback packet_callback,
                                                     CaptureClockCallback clock_callback) {
  return std::make_unique<MacCaptureSession>(std::move(event_callback), std::move(packet_callback),
                                             std::move(clock_callback));
}

}  // namespace native_port
