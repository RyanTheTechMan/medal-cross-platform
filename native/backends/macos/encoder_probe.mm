#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#include <nlohmann/json.hpp>

namespace {

constexpr std::int32_t kWidth = 1280;
constexpr std::int32_t kHeight = 720;

struct CodecDefinition final {
  const char* name;
  CMVideoCodecType type;
  const char* configuration_atom;
};

struct EncodeObservation final {
  std::atomic<bool> callback_received{false};
  std::atomic<std::uint32_t> callback_count{0};
  std::atomic<std::uint32_t> callback_failure_count{0};
  std::atomic<std::uint32_t> dropped_frame_count{0};
  std::atomic<std::uint32_t> ready_sample_count{0};
  std::atomic<std::uint32_t> codec_mismatch_count{0};
  std::atomic<OSStatus> callback_status{noErr};
  std::atomic<bool> frame_dropped{false};
  std::atomic<bool> sample_ready{false};
  std::atomic<std::uint32_t> sample_codec{0};
  std::atomic<std::size_t> sample_bytes{0};
  std::atomic<bool> configuration_present{false};
  std::uint32_t expected_codec{0};
  const char* configuration_atom{nullptr};
};

[[nodiscard]] std::string cf_string(CFStringRef value) {
  if (value == nullptr) {
    return {};
  }
  const auto length = CFStringGetLength(value);
  const auto maximum = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
  std::vector<char> buffer(static_cast<std::size_t>(std::max<CFIndex>(maximum, 1)));
  if (!CFStringGetCString(value, buffer.data(), static_cast<CFIndex>(buffer.size()), kCFStringEncodingUTF8)) {
    return {};
  }
  return buffer.data();
}

[[nodiscard]] std::string fourcc(std::uint32_t value) {
  char text[5] = {
      static_cast<char>((value >> 24U) & 0xffU),
      static_cast<char>((value >> 16U) & 0xffU),
      static_cast<char>((value >> 8U) & 0xffU),
      static_cast<char>(value & 0xffU),
      '\0',
  };
  for (std::size_t index = 0; index < 4; ++index) {
    if (text[index] < 0x20 || text[index] > 0x7e) {
      text[index] = '?';
    }
  }
  return text;
}

[[nodiscard]] bool dictionary_boolean(CFDictionaryRef dictionary, CFStringRef key) {
  return dictionary != nullptr && CFDictionaryGetValue(dictionary, key) == kCFBooleanTrue;
}

void encoder_output(void* output_callback_refcon, void*, OSStatus status, VTEncodeInfoFlags info_flags,
                    CMSampleBufferRef sample) {
  auto* observation = static_cast<EncodeObservation*>(output_callback_refcon);
  if (observation == nullptr) {
    return;
  }
  observation->callback_status.store(status, std::memory_order_relaxed);
  if (status != noErr) {
    observation->callback_failure_count.fetch_add(1, std::memory_order_relaxed);
  }
  const bool frame_dropped = (info_flags & kVTEncodeInfo_FrameDropped) != 0;
  if (frame_dropped) {
    observation->dropped_frame_count.fetch_add(1, std::memory_order_relaxed);
    observation->frame_dropped.store(true, std::memory_order_relaxed);
  }
  if (sample != nullptr) {
    const bool sample_ready = CMSampleBufferDataIsReady(sample);
    observation->sample_ready.store(sample_ready, std::memory_order_relaxed);
    if (sample_ready) {
      observation->ready_sample_count.fetch_add(1, std::memory_order_relaxed);
    }
    if (const auto* description = CMSampleBufferGetFormatDescription(sample); description != nullptr) {
      const auto sample_codec = CMFormatDescriptionGetMediaSubType(description);
      observation->sample_codec.store(sample_codec, std::memory_order_relaxed);
      if (sample_codec != observation->expected_codec) {
        observation->codec_mismatch_count.fetch_add(1, std::memory_order_relaxed);
      }
      if (const auto* extensions = CMFormatDescriptionGetExtensions(description); extensions != nullptr) {
        auto* atoms = static_cast<CFDictionaryRef>(
            CFDictionaryGetValue(extensions, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms));
        if (atoms != nullptr && observation->configuration_atom != nullptr) {
          CFStringRef atom = CFStringCreateWithCString(kCFAllocatorDefault, observation->configuration_atom,
                                                       kCFStringEncodingASCII);
          if (CFDictionaryContainsKey(atoms, atom)) {
            observation->configuration_present.store(true, std::memory_order_relaxed);
          }
          CFRelease(atom);
        }
      }
    }
    if (auto block = CMSampleBufferGetDataBuffer(sample); block != nullptr) {
      observation->sample_bytes.fetch_add(CMBlockBufferGetDataLength(block), std::memory_order_relaxed);
    }
  }
  observation->callback_received.store(true, std::memory_order_release);
  observation->callback_count.fetch_add(1, std::memory_order_release);
}

[[nodiscard]] CVPixelBufferRef make_black_pixel_buffer() {
  const void* attribute_keys[] = {kCVPixelBufferIOSurfacePropertiesKey, kCVPixelBufferMetalCompatibilityKey};
  CFDictionaryRef empty = CFDictionaryCreate(kCFAllocatorDefault, nullptr, nullptr, 0,
                                              &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  const void* attribute_values[] = {empty, kCFBooleanTrue};
  CFDictionaryRef attributes =
      CFDictionaryCreate(kCFAllocatorDefault, attribute_keys, attribute_values, 2,
                         &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CVPixelBufferRef pixel_buffer = nullptr;
  const auto create_status = CVPixelBufferCreate(kCFAllocatorDefault, kWidth, kHeight,
                                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes,
                                                  &pixel_buffer);
  CFRelease(attributes);
  CFRelease(empty);
  if (create_status != kCVReturnSuccess || pixel_buffer == nullptr) {
    return nullptr;
  }
  if (CVPixelBufferLockBaseAddress(pixel_buffer, 0) != kCVReturnSuccess) {
    CVPixelBufferRelease(pixel_buffer);
    return nullptr;
  }
  for (std::size_t plane = 0; plane < CVPixelBufferGetPlaneCount(pixel_buffer); ++plane) {
    auto* base = static_cast<unsigned char*>(CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, plane));
    const auto bytes = CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, plane) *
                       CVPixelBufferGetHeightOfPlane(pixel_buffer, plane);
    std::memset(base, plane == 0 ? 16 : 128, bytes);
  }
  CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);
  return pixel_buffer;
}

[[nodiscard]] nlohmann::json listed_encoders(CMVideoCodecType codec, CFArrayRef encoders) {
  auto result = nlohmann::json::array();
  if (encoders == nullptr) {
    return result;
  }
  const auto count = CFArrayGetCount(encoders);
  for (CFIndex index = 0; index < count; ++index) {
    auto* entry = static_cast<CFDictionaryRef>(const_cast<void*>(CFArrayGetValueAtIndex(encoders, index)));
    auto* codec_number = static_cast<CFNumberRef>(const_cast<void*>(
        CFDictionaryGetValue(entry, kVTVideoEncoderList_CodecType)));
    std::int32_t listed_codec = 0;
    if (codec_number == nullptr ||
        !CFNumberGetValue(codec_number, kCFNumberSInt32Type, &listed_codec) ||
        static_cast<CMVideoCodecType>(listed_codec) != codec) {
      continue;
    }
    auto* identifier = static_cast<CFStringRef>(const_cast<void*>(
        CFDictionaryGetValue(entry, kVTVideoEncoderList_EncoderID)));
    auto* name = static_cast<CFStringRef>(const_cast<void*>(
        CFDictionaryGetValue(entry, kVTVideoEncoderList_EncoderName)));
    result.push_back({
        {"encoderId", cf_string(identifier)},
        {"encoderName", cf_string(name)},
        {"hardwareAccelerated", dictionary_boolean(entry, kVTVideoEncoderList_IsHardwareAccelerated)},
    });
  }
  return result;
}

[[nodiscard]] nlohmann::json probe_codec(const CodecDefinition& codec, CFArrayRef encoders) {
  nlohmann::json result = {
      {"codec", codec.name},
      {"fourcc", fourcc(codec.type)},
      {"registeredEncoders", listed_encoders(codec.type, encoders)},
      {"sessionCreateStatus", nullptr},
      {"prepareStatus", nullptr},
      {"highQualityPresetAdvertised", false},
      {"realTimeStatus", nullptr},
      {"allowFrameReorderingStatus", nullptr},
      {"qualityPriorityStatus", nullptr},
      {"encodeStatus", nullptr},
      {"callbacksBeforeComplete", 0},
      {"completeStatus", nullptr},
      {"hardwareConfirmed", false},
      {"callbackReceived", false},
      {"callbackFailureCount", 0},
      {"droppedFrameCount", 0},
      {"readySampleCount", 0},
      {"codecMismatchCount", 0},
      {"callbackStatus", nullptr},
      {"frameDropped", false},
      {"sampleReady", false},
      {"sampleCodec", ""},
      {"sampleBytes", 0},
      {"configurationAtom", codec.configuration_atom},
      {"configurationPresent", false},
      {"supported", false},
      {"recordingReady", false},
  };

  const void* specification_keys[] = {kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder};
  const void* specification_values[] = {kCFBooleanTrue};
  CFDictionaryRef specification =
      CFDictionaryCreate(kCFAllocatorDefault, specification_keys, specification_values, 1,
                         &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  EncodeObservation observation;
  observation.configuration_atom = codec.configuration_atom;
  observation.expected_codec = codec.type;
  VTCompressionSessionRef session = nullptr;
  const auto create_status = VTCompressionSessionCreate(kCFAllocatorDefault, kWidth, kHeight, codec.type,
                                                         specification, nullptr, nullptr, &encoder_output,
                                                         &observation, &session);
  CFRelease(specification);
  result["sessionCreateStatus"] = create_status;
  if (create_status != noErr || session == nullptr) {
    return result;
  }

  CFDictionaryRef supported_properties = nullptr;
  const auto supported_status = VTSessionCopySupportedPropertyDictionary(session, &supported_properties);
  result["supportedPropertyStatus"] = supported_status;

  CFTypeRef presets_value = nullptr;
  if (supported_properties != nullptr &&
      CFDictionaryContainsKey(supported_properties, kVTCompressionPropertyKey_SupportedPresetDictionaries)) {
    const auto preset_copy_status = VTSessionCopyProperty(
        session, kVTCompressionPropertyKey_SupportedPresetDictionaries, kCFAllocatorDefault, &presets_value);
    result["presetCopyStatus"] = preset_copy_status;
    if (preset_copy_status == noErr && presets_value != nullptr &&
        CFGetTypeID(presets_value) == CFDictionaryGetTypeID()) {
      auto* presets = static_cast<CFDictionaryRef>(presets_value);
      CFTypeRef high_quality = CFDictionaryGetValue(presets, kVTCompressionPreset_HighQuality);
      if (high_quality != nullptr && CFGetTypeID(high_quality) == CFDictionaryGetTypeID()) {
        result["highQualityPresetAdvertised"] = true;
      }
    }
  }

  result["realTimeStatus"] =
      VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
  result["allowFrameReorderingStatus"] =
      VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
  if (supported_properties != nullptr && CFDictionaryContainsKey(
          supported_properties, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality)) {
    result["qualityPriorityStatus"] = VTSessionSetProperty(
        session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanFalse);
  }
  if (presets_value != nullptr) {
    CFRelease(presets_value);
  }
  if (supported_properties != nullptr) {
    CFRelease(supported_properties);
  }
  const auto prepare_status = VTCompressionSessionPrepareToEncodeFrames(session);
  result["prepareStatus"] = prepare_status;

  CFTypeRef hardware_value = nullptr;
  const auto hardware_status = VTSessionCopyProperty(
      session, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, kCFAllocatorDefault,
      &hardware_value);
  const bool hardware_confirmed = hardware_status == noErr && hardware_value == kCFBooleanTrue;
  result["hardwarePropertyStatus"] = hardware_status;
  result["hardwareConfirmed"] = hardware_confirmed;
  if (hardware_value != nullptr) {
    CFRelease(hardware_value);
  }

  if (prepare_status == noErr) {
    CVPixelBufferRef pixel_buffer = make_black_pixel_buffer();
    if (pixel_buffer == nullptr) {
      result["pixelBufferError"] = "creation_failed";
    } else {
      OSStatus encode_status = noErr;
      for (std::int64_t frame = 0; frame < 4 && encode_status == noErr; ++frame) {
        encode_status = VTCompressionSessionEncodeFrame(
            session, pixel_buffer, CMTimeMake(frame, 60), CMTimeMake(1, 60), nullptr, nullptr, nullptr);
      }
      result["encodeStatus"] = encode_status;
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
      result["callbacksBeforeComplete"] = observation.callback_count.load(std::memory_order_acquire);
      const auto complete_status = VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
      result["completeStatus"] = complete_status;
      CVPixelBufferRelease(pixel_buffer);
    }
  }

  result["callbackReceived"] = observation.callback_received.load(std::memory_order_acquire);
  result["callbackCount"] = observation.callback_count.load(std::memory_order_acquire);
  result["callbackFailureCount"] =
      observation.callback_failure_count.load(std::memory_order_relaxed);
  result["droppedFrameCount"] = observation.dropped_frame_count.load(std::memory_order_relaxed);
  result["readySampleCount"] = observation.ready_sample_count.load(std::memory_order_relaxed);
  result["codecMismatchCount"] = observation.codec_mismatch_count.load(std::memory_order_relaxed);
  if (observation.callback_received.load(std::memory_order_acquire)) {
    result["callbackStatus"] = observation.callback_status.load(std::memory_order_relaxed);
  }
  result["frameDropped"] = observation.frame_dropped.load(std::memory_order_relaxed);
  result["sampleReady"] = observation.sample_ready.load(std::memory_order_relaxed);
  result["sampleCodec"] = fourcc(observation.sample_codec.load(std::memory_order_relaxed));
  result["sampleBytes"] = observation.sample_bytes.load(std::memory_order_relaxed);
  result["configurationPresent"] = observation.configuration_present.load(std::memory_order_relaxed);
  result["lowLatencySettingsAccepted"] = result["realTimeStatus"] == noErr &&
                                         result["allowFrameReorderingStatus"] == noErr &&
                                         result["qualityPriorityStatus"] == noErr;
  result["boundedFrameDelayObserved"] = result["callbacksBeforeComplete"].get<std::uint32_t>() >= 3;
  result["supported"] = hardware_confirmed && result["encodeStatus"] == noErr &&
                        observation.callback_count.load(std::memory_order_acquire) == 4 &&
                        observation.callback_failure_count.load(std::memory_order_relaxed) == 0 &&
                        observation.dropped_frame_count.load(std::memory_order_relaxed) == 0 &&
                        observation.ready_sample_count.load(std::memory_order_relaxed) == 4 &&
                        observation.codec_mismatch_count.load(std::memory_order_relaxed) == 0 &&
                        observation.callback_received.load(std::memory_order_acquire) &&
                        observation.callback_status.load(std::memory_order_relaxed) == noErr &&
                        !observation.frame_dropped.load(std::memory_order_relaxed) &&
                        observation.sample_ready.load(std::memory_order_relaxed) &&
                        observation.sample_codec.load(std::memory_order_relaxed) == codec.type &&
                        observation.sample_bytes.load(std::memory_order_relaxed) > 0 &&
                        observation.configuration_present.load(std::memory_order_relaxed);
  result["recordingReady"] = result["supported"].get<bool>() &&
                             result["lowLatencySettingsAccepted"].get<bool>() &&
                             result["boundedFrameDelayObserved"].get<bool>();

  VTCompressionSessionInvalidate(session);
  CFRelease(session);
  return result;
}

}  // namespace

int main() {
  @autoreleasepool {
    CFArrayRef encoders = nullptr;
    const auto list_status = VTCopyVideoEncoderList(nullptr, &encoders);
    const CodecDefinition codecs[] = {
        {"h264", kCMVideoCodecType_H264, "avcC"},
        {"hevc", kCMVideoCodecType_HEVC, "hvcC"},
        {"av1", kCMVideoCodecType_AV1, "av1C"},
    };
    nlohmann::json output = {
        {"schemaVersion", 2},
        {"probe", "VideoToolbox hardware-required four-frame real-time encode"},
        {"width", kWidth},
        {"height", kHeight},
        {"encoderListStatus", list_status},
        {"codecs", nlohmann::json::array()},
    };
    for (const auto& codec : codecs) {
      output["codecs"].push_back(probe_codec(codec, encoders));
    }
    if (encoders != nullptr) {
      CFRelease(encoders);
    }
    std::cout << output.dump(2) << '\n';
    return list_status == noErr ? 0 : 1;
  }
}
