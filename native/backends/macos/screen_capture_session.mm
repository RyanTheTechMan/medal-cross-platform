#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>

#include "native_port/capture_session.hpp"

#include "audio_encoder.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
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

}  // namespace

class MacCaptureSession final : public CaptureSession {
 public:
  MacCaptureSession(CaptureEventCallback event_callback, EncodedPacketCallback packet_callback)
      : event_callback_(std::move(event_callback)), packet_callback_(std::move(packet_callback)) {
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
    if (configuration.width == 0 || configuration.height == 0 || configuration.frames_per_second == 0 ||
        configuration.frames_per_second > 240 || configuration.bitrate_bits_per_second < 100'000 ||
        (configuration.preferred_source_kind != "display" && configuration.preferred_source_kind != "window" &&
         configuration.preferred_source_kind != "application")) {
      throw std::invalid_argument("invalid native capture configuration");
    }
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

  void stop() override {
    SCStream* stream = nil;
    {
      std::scoped_lock lock(mutex_);
      if (state_ == "idle" || state_ == "stopped" || state_ == "cancelled") {
        return;
      }
      state_ = "stopping";
      stream = stream_;
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

  void pump_events() override {
    @autoreleasepool {
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true);
    }
  }

  [[nodiscard]] nlohmann::json status() const override {
    std::shared_ptr<AacEncoder> system_audio;
    std::shared_ptr<AacEncoder> microphone;
    {
      std::scoped_lock audio_lock(audio_encoder_mutex_);
      system_audio = system_audio_encoder_;
      microphone = microphone_encoder_;
    }
    std::scoped_lock lock(mutex_);
    return status_locked(system_audio, microphone);
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

  void did_output_sample(CMSampleBufferRef sample, SCStreamOutputType type) {
    if (type == SCStreamOutputTypeAudio || type == SCStreamOutputTypeMicrophone) {
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
      NSNumber* status_number = dictionary[SCStreamFrameInfoStatus];
      if (status_number != nullptr) {
        frame_status = static_cast<SCFrameStatus>(status_number.integerValue);
      }
    }
    const auto previous_status = last_frame_status_.exchange(frame_status, std::memory_order_relaxed);
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
    const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
    CMTime duration = CMSampleBufferGetDuration(sample);
    if (!CMTIME_IS_VALID(duration) || duration.value <= 0) {
      duration = CMTimeMake(1, static_cast<std::int32_t>(configuration_.frames_per_second));
    }
    std::scoped_lock encoder_lock(encoder_mutex_);
    if (encoder_ == nullptr) {
      return;
    }
    CVPixelBufferRetain(image);
    const auto status = VTCompressionSessionEncodeFrame(encoder_, image, pts, duration, nullptr, image, nullptr);
    if (status != noErr) {
      CVPixelBufferRelease(image);
      encode_failures_.fetch_add(1, std::memory_order_relaxed);
      fail("encoder_failed", "VideoToolbox encode failed with OSStatus " + std::to_string(status));
    }
  }

  void stream_stopped(NSError* error) {
    fail("stream_stopped", error_text(error));
  }

  void stream_inactive() {
    publish_event("capturing", "source_inactive");
  }

  void stream_active() {
    publish_event("capturing", "source_active");
  }

 private:
  void did_output_audio(CMSampleBufferRef sample, SCStreamOutputType type) {
    std::shared_ptr<AacEncoder> audio_encoder;
    {
      std::scoped_lock lock(audio_encoder_mutex_);
      audio_encoder = type == SCStreamOutputTypeMicrophone ? microphone_encoder_ : system_audio_encoder_;
    }
    if (!audio_encoder) {
      return;
    }
    std::string error;
    if (!audio_encoder->encode(sample, configuration_generation_.load(std::memory_order_relaxed), error)) {
      fail(type == SCStreamOutputTypeMicrophone ? "microphone_encoder_failed" : "system_audio_encoder_failed",
           std::move(error));
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

  void start_stream(SCContentFilter* filter) {
    CaptureConfiguration configuration;
    {
      std::scoped_lock lock(mutex_);
      state_ = "starting";
      configuration = configuration_;
    }
    publish_event("starting", "source_selected");

    @autoreleasepool {
      const SCShareableContentInfo* info = [SCShareableContent infoForFilter:filter];
      const char* source_kind = info.style == SCShareableContentStyleDisplay
                                    ? "display"
                                    : (info.style == SCShareableContentStyleWindow
                                           ? "window"
                                           : (info.style == SCShareableContentStyleApplication ? "application" : "unknown"));
      const auto native_width = std::max(2.0, std::round(info.contentRect.size.width * info.pointPixelScale));
      const auto native_height = std::max(2.0, std::round(info.contentRect.size.height * info.pointPixelScale));
      const auto requested_width = static_cast<double>(configuration.width);
      const auto requested_height = static_cast<double>(configuration.height);
      const auto scale = std::min({1.0, requested_width / native_width, requested_height / native_height});
      auto width = static_cast<std::size_t>(std::floor(native_width * scale));
      auto height = static_cast<std::size_t>(std::floor(native_height * scale));
      width -= width % 2U;
      height -= height % 2U;
      width = std::max<std::size_t>(width, 2U);
      height = std::max<std::size_t>(height, 2U);

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
      stream_configuration.capturesAudio = configuration.capture_system_audio;
      stream_configuration.captureMicrophone = configuration.capture_microphone;
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
      if (configuration.capture_system_audio &&
          ![new_stream addStreamOutput:delegate_
                                  type:SCStreamOutputTypeAudio
                    sampleHandlerQueue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0)
                                 error:&add_error]) {
        destroy_encoder();
        destroy_audio_encoders();
        fail("system_audio_output_failed", error_text(add_error));
        return;
      }
      if (configuration.capture_microphone &&
          ![new_stream addStreamOutput:delegate_
                                  type:SCStreamOutputTypeMicrophone
                    sampleHandlerQueue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0)
                                 error:&add_error]) {
        destroy_encoder();
        destroy_audio_encoders();
        fail("microphone_output_failed", error_text(add_error));
        return;
      }
      {
        std::scoped_lock lock(mutex_);
        stream_ = new_stream;
        capture_width_ = width;
        capture_height_ = height;
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
    }
  }

  [[nodiscard]] bool create_encoder(std::size_t width, std::size_t height,
                                    const CaptureConfiguration& configuration, std::string& error) {
    destroy_encoder();
    first_video_packet_nanoseconds_.store(-1, std::memory_order_relaxed);
    last_video_packet_end_nanoseconds_.store(-1, std::memory_order_relaxed);
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
    std::scoped_lock lock(audio_encoder_mutex_);
    system_audio_encoder_.reset();
    microphone_encoder_.reset();
    if (configuration.capture_system_audio) {
      system_audio_encoder_ = std::make_shared<AacEncoder>(
          TrackKind::game_audio, 1, 160'000,
          [this](std::shared_ptr<const EncodedPacket> packet) { packet_callback_(std::move(packet)); });
    }
    if (configuration.capture_microphone) {
      microphone_encoder_ = std::make_shared<AacEncoder>(
          TrackKind::microphone_audio, 2, 96'000,
          [this](std::shared_ptr<const EncodedPacket> packet) { packet_callback_(std::move(packet)); });
    }
  }

  void destroy_audio_encoders() {
    std::shared_ptr<AacEncoder> system_audio;
    std::shared_ptr<AacEncoder> microphone;
    {
      std::scoped_lock lock(audio_encoder_mutex_);
      system_audio = system_audio_encoder_;
      microphone = microphone_encoder_;
    }
    if (system_audio) {
      system_audio->reset();
    }
    if (microphone) {
      microphone->reset();
    }
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
      state_ = "stopped";
    }
    publish_event("stopped", "requested");
  }

  void fail(std::string reason, std::string message) {
    {
      std::scoped_lock lock(mutex_);
      state_ = "failed";
      last_error_ = std::move(message);
    }
    publish_event("failed", std::move(reason));
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

  [[nodiscard]] nlohmann::json status_locked(const std::shared_ptr<AacEncoder>& system_audio,
                                              const std::shared_ptr<AacEncoder>& microphone) const {
    return {
        {"schemaVersion", 1},
        {"state", state_},
        {"width", capture_width_},
        {"height", capture_height_},
        {"sourceKind", source_kind_},
        {"framesPerSecond", configuration_.frames_per_second},
        {"bitrateBitsPerSecond", configuration_.bitrate_bits_per_second},
        {"videoCodec", medal_video_codec_name(configuration_.video_codec)},
        {"nativeVideoCodec", video_codec_name(configuration_.video_codec)},
        {"qualityPreset", quality_preset_},
        {"hardwareEncoder", hardware_encoder_},
        {"framesReceived", frames_received_.load(std::memory_order_relaxed)},
        {"framesEncoded", frames_encoded_.load(std::memory_order_relaxed)},
        {"encodeFailures", encode_failures_.load(std::memory_order_relaxed)},
        {"idleFrames", idle_frames_.load(std::memory_order_relaxed)},
        {"inactiveFrames", inactive_frames_.load(std::memory_order_relaxed)},
        {"audio",
         {{"system", audio_status(system_audio, configuration_.capture_system_audio)},
          {"microphone", audio_status(microphone, configuration_.capture_microphone)}}},
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
  mutable std::mutex mutex_;
  std::mutex encoder_mutex_;
  mutable std::mutex audio_encoder_mutex_;
  CaptureConfiguration configuration_;
  std::string state_{"idle"};
  std::string state_before_picker_{"idle"};
  std::string last_error_;
  std::size_t capture_width_{0};
  std::size_t capture_height_{0};
  std::string source_kind_{"none"};
  std::atomic<std::uint64_t> configuration_generation_{0};
  std::atomic<VideoCodec> active_video_codec_{VideoCodec::h264};
  std::atomic<std::uint64_t> frames_received_{0};
  std::atomic<std::uint64_t> frames_encoded_{0};
  std::atomic<std::uint64_t> encode_failures_{0};
  std::atomic<std::uint64_t> idle_frames_{0};
  std::atomic<std::uint64_t> inactive_frames_{0};
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
  bool hardware_encoder_{false};
  std::string quality_preset_{"not_started"};
  SCContentSharingPicker* picker_{nil};
  NativePortCaptureDelegate* delegate_{nil};
  SCStream* stream_{nil};
  VTCompressionSessionRef encoder_{nullptr};
  std::shared_ptr<AacEncoder> system_audio_encoder_;
  std::shared_ptr<AacEncoder> microphone_encoder_;
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
  (void)stream;
  if (self.owner != nullptr) {
    self.owner->did_output_sample(sampleBuffer, type);
  }
}

- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
  (void)stream;
  if (self.owner != nullptr) {
    self.owner->stream_stopped(error);
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
                                                     EncodedPacketCallback packet_callback) {
  return std::make_unique<MacCaptureSession>(std::move(event_callback), std::move(packet_callback));
}

}  // namespace native_port
