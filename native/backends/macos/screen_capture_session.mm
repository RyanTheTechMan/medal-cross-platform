#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>

#include "native_port/capture_session.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
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
                                        std::string& error) {
  const auto status = VTSessionSetProperty(encoder, key, value);
  if (status != noErr) {
    error = "VideoToolbox property failed with OSStatus " + std::to_string(status);
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

void append_u16(std::vector<std::byte>& target, std::size_t value) {
  target.push_back(static_cast<std::byte>((value >> 8U) & 0xffU));
  target.push_back(static_cast<std::byte>(value & 0xffU));
}

[[nodiscard]] std::shared_ptr<const std::vector<std::byte>> h264_decoder_configuration(
    CMFormatDescriptionRef description) {
  if (description == nullptr || CMFormatDescriptionGetMediaSubType(description) != kCMVideoCodecType_H264) {
    return nullptr;
  }
  const std::uint8_t* sps = nullptr;
  const std::uint8_t* pps = nullptr;
  std::size_t sps_size = 0;
  std::size_t pps_size = 0;
  std::size_t parameter_count = 0;
  int nal_length = 0;
  if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, 0, &sps, &sps_size, &parameter_count,
                                                         &nal_length) != noErr ||
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, 1, &pps, &pps_size, nullptr, nullptr) !=
          noErr ||
      sps == nullptr || pps == nullptr || sps_size < 4 || sps_size > std::numeric_limits<std::uint16_t>::max() ||
      pps_size > std::numeric_limits<std::uint16_t>::max() || nal_length < 1 || nal_length > 4) {
    return nullptr;
  }

  auto result = std::make_shared<std::vector<std::byte>>();
  result->reserve(11U + sps_size + pps_size);
  result->push_back(std::byte{1});
  result->push_back(static_cast<std::byte>(sps[1]));
  result->push_back(static_cast<std::byte>(sps[2]));
  result->push_back(static_cast<std::byte>(sps[3]));
  result->push_back(static_cast<std::byte>(0xfcU | static_cast<unsigned int>(nal_length - 1)));
  result->push_back(std::byte{0xe1});
  append_u16(*result, sps_size);
  for (std::size_t index = 0; index < sps_size; ++index) {
    result->push_back(static_cast<std::byte>(sps[index]));
  }
  result->push_back(std::byte{1});
  append_u16(*result, pps_size);
  for (std::size_t index = 0; index < pps_size; ++index) {
    result->push_back(static_cast<std::byte>(pps[index]));
  }
  return result;
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
    std::scoped_lock lock(mutex_);
    return status_locked();
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
    const void* keys[] = {kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder};
    const void* values[] = {kCFBooleanTrue};
    CFDictionaryRef specification =
        CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                           &kCFTypeDictionaryValueCallBacks);
    VTCompressionSessionRef new_encoder = nullptr;
    const auto create_status = VTCompressionSessionCreate(
        kCFAllocatorDefault, static_cast<std::int32_t>(width), static_cast<std::int32_t>(height),
        kCMVideoCodecType_H264, specification, nullptr, nullptr, &MacCaptureSession::encoder_output, this,
        &new_encoder);
    CFRelease(specification);
    if (create_status != noErr || new_encoder == nullptr) {
      error = "hardware H.264 encoder creation failed with OSStatus " + std::to_string(create_status);
      return false;
    }

    std::int32_t frame_rate = static_cast<std::int32_t>(configuration.frames_per_second);
    std::int32_t bitrate = static_cast<std::int32_t>(
        std::min<std::uint64_t>(configuration.bitrate_bits_per_second,
                                static_cast<std::uint64_t>(std::numeric_limits<std::int32_t>::max())));
    std::int32_t keyframe_seconds = 2;
    CFNumberRef frame_rate_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &frame_rate);
    CFNumberRef bitrate_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bitrate);
    CFNumberRef keyframe_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &keyframe_seconds);
    bool properties_ok = set_encoder_property(new_encoder, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, error) &&
                         set_encoder_property(new_encoder, kVTCompressionPropertyKey_AllowFrameReordering,
                                              kCFBooleanFalse, error) &&
                         set_encoder_property(new_encoder, kVTCompressionPropertyKey_ProfileLevel,
                                              kVTProfileLevel_H264_High_AutoLevel, error) &&
                         set_encoder_property(new_encoder, kVTCompressionPropertyKey_ExpectedFrameRate,
                                              frame_rate_number, error) &&
                         set_encoder_property(new_encoder, kVTCompressionPropertyKey_AverageBitRate, bitrate_number,
                                              error) &&
                         set_encoder_property(new_encoder, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                                              keyframe_number, error);
    CFRelease(frame_rate_number);
    CFRelease(bitrate_number);
    CFRelease(keyframe_number);
    if (!properties_ok) {
      VTCompressionSessionInvalidate(new_encoder);
      CFRelease(new_encoder);
      return false;
    }
    const auto prepare_status = VTCompressionSessionPrepareToEncodeFrames(new_encoder);
    if (prepare_status != noErr) {
      error = "VideoToolbox encoder preparation failed with OSStatus " + std::to_string(prepare_status);
      VTCompressionSessionInvalidate(new_encoder);
      CFRelease(new_encoder);
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
      VTCompressionSessionInvalidate(new_encoder);
      CFRelease(new_encoder);
      return false;
    }
    {
      std::scoped_lock lock(encoder_mutex_);
      encoder_ = new_encoder;
    }
    {
      std::scoped_lock lock(mutex_);
      hardware_encoder_ = true;
    }
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
    packet->codec = Codec::h264;
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
    packet->data = std::move(payload);
    if (keyframe) {
      packet->codec_configuration = h264_decoder_configuration(CMSampleBufferGetFormatDescription(sample));
      if (!packet->codec_configuration || packet->codec_configuration->empty()) {
        encode_failures_.fetch_add(1, std::memory_order_relaxed);
        return;
      }
    }
    frames_encoded_.fetch_add(1, std::memory_order_relaxed);
    packet_callback_(std::move(packet));
  }

  void finish_stop(NSError* error) {
    if (error != nil) {
      fail("capture_stop_failed", error_text(error));
      return;
    }
    destroy_encoder();
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

  [[nodiscard]] nlohmann::json status_locked() const {
    return {
        {"schemaVersion", 1},
        {"state", state_},
        {"width", capture_width_},
        {"height", capture_height_},
        {"sourceKind", source_kind_},
        {"framesPerSecond", configuration_.frames_per_second},
        {"bitrateBitsPerSecond", configuration_.bitrate_bits_per_second},
        {"hardwareEncoder", hardware_encoder_},
        {"framesReceived", frames_received_.load(std::memory_order_relaxed)},
        {"framesEncoded", frames_encoded_.load(std::memory_order_relaxed)},
        {"encodeFailures", encode_failures_.load(std::memory_order_relaxed)},
        {"idleFrames", idle_frames_.load(std::memory_order_relaxed)},
        {"inactiveFrames", inactive_frames_.load(std::memory_order_relaxed)},
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
  CaptureConfiguration configuration_;
  std::string state_{"idle"};
  std::string state_before_picker_{"idle"};
  std::string last_error_;
  std::size_t capture_width_{0};
  std::size_t capture_height_{0};
  std::string source_kind_{"none"};
  std::atomic<std::uint64_t> configuration_generation_{0};
  std::atomic<std::uint64_t> frames_received_{0};
  std::atomic<std::uint64_t> frames_encoded_{0};
  std::atomic<std::uint64_t> encode_failures_{0};
  std::atomic<std::uint64_t> idle_frames_{0};
  std::atomic<std::uint64_t> inactive_frames_{0};
  std::atomic<SCFrameStatus> last_frame_status_{SCFrameStatusStopped};
  std::string enumeration_state_{"not_requested"};
  std::string enumeration_error_;
  std::size_t display_count_{0};
  std::size_t window_count_{0};
  std::size_t application_count_{0};
  bool hardware_encoder_{false};
  SCContentSharingPicker* picker_{nil};
  NativePortCaptureDelegate* delegate_{nil};
  SCStream* stream_{nil};
  VTCompressionSessionRef encoder_{nullptr};
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
