#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>

#include "native_port/platform_adapter.hpp"

#include <array>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace native_port {
namespace {

std::string cf_string_to_utf8(CFStringRef value) {
  if (value == nullptr) {
    return {};
  }
  const auto length = CFStringGetLength(value);
  const auto maximum = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
  std::vector<char> buffer(static_cast<std::size_t>(maximum));
  if (!CFStringGetCString(value, buffer.data(), maximum, kCFStringEncodingUTF8)) {
    return {};
  }
  return buffer.data();
}

std::string audio_object_name(AudioObjectID object) {
  AudioObjectPropertyAddress address{
      kAudioObjectPropertyName,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain,
  };
  CFStringRef name = nullptr;
  UInt32 size = sizeof(name);
  if (AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, &name) != noErr || name == nullptr) {
    return "Audio Device " + std::to_string(object);
  }
  const auto converted = cf_string_to_utf8(name);
  CFRelease(name);
  return converted.empty() ? "Audio Device " + std::to_string(object) : converted;
}

bool device_has_streams(AudioObjectID device, AudioObjectPropertyScope scope) {
  AudioObjectPropertyAddress address{
      kAudioDevicePropertyStreams,
      scope,
      kAudioObjectPropertyElementMain,
  };
  UInt32 size = 0;
  return AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) == noErr && size > 0;
}

std::vector<AudioObjectID> audio_devices() {
  AudioObjectPropertyAddress address{
      kAudioHardwarePropertyDevices,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain,
  };
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, nullptr, &size) != noErr) {
    throw std::runtime_error("CoreAudio device enumeration failed");
  }
  std::vector<AudioObjectID> devices(size / sizeof(AudioObjectID));
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, devices.data()) != noErr) {
    throw std::runtime_error("CoreAudio device enumeration failed");
  }
  return devices;
}

AudioObjectID default_device(AudioObjectPropertySelector selector) {
  AudioObjectPropertyAddress address{selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  AudioObjectID device = kAudioObjectUnknown;
  UInt32 size = sizeof(device);
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, &device) != noErr) {
    return kAudioObjectUnknown;
  }
  return device;
}

std::set<CMVideoCodecType> hardware_encoder_codecs() {
  CFArrayRef encoders = nullptr;
  if (VTCopyVideoEncoderList(nullptr, &encoders) != noErr || encoders == nullptr) {
    return {};
  }
  std::set<CMVideoCodecType> result;
  const auto count = CFArrayGetCount(encoders);
  for (CFIndex index = 0; index < count; ++index) {
    auto* entry = static_cast<CFDictionaryRef>(const_cast<void*>(CFArrayGetValueAtIndex(encoders, index)));
    if (CFDictionaryGetValue(entry, kVTVideoEncoderList_IsHardwareAccelerated) != kCFBooleanTrue) {
      continue;
    }
    auto* codec_number = static_cast<CFNumberRef>(
        const_cast<void*>(CFDictionaryGetValue(entry, kVTVideoEncoderList_CodecType)));
    std::int32_t codec = 0;
    if (codec_number != nullptr && CFNumberGetValue(codec_number, kCFNumberSInt32Type, &codec)) {
      result.insert(static_cast<CMVideoCodecType>(codec));
    }
  }
  CFRelease(encoders);
  return result;
}

std::string gpu_device_name() {
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil || device.name.length == 0) {
      return "Apple VideoToolbox";
    }
    const char* name = device.name.UTF8String;
    return name != nullptr ? name : "Apple VideoToolbox";
  }
}

class MacPlatformAdapter final : public PlatformAdapter {
 public:
  nlohmann::json active_displays(bool capture_screenshots) override {
    if (capture_screenshots) {
      throw std::runtime_error("display thumbnails require the permissioned ScreenCaptureKit picker");
    }
    std::array<CGDirectDisplayID, 32> displays{};
    uint32_t count = 0;
    if (CGGetActiveDisplayList(static_cast<uint32_t>(displays.size()), displays.data(), &count) !=
        kCGErrorSuccess) {
      throw std::runtime_error("CoreGraphics display enumeration failed");
    }
    nlohmann::json result = nlohmann::json::array();
    for (uint32_t index = 0; index < count; ++index) {
      const auto display = displays[index];
      const auto width = CGDisplayPixelsWide(display);
      const auto height = CGDisplayPixelsHigh(display);
      result.push_back({
          {"DeviceName", "display:" + std::to_string(display)},
          {"FriendlyName", "Display " + std::to_string(index + 1) + " (" + std::to_string(width) +
                               "x" + std::to_string(height) + ")"},
          {"CurrentScreenshot", nullptr},
          {"CurrentScreenshotFile", nullptr},
          {"IsPrimaryScreen", CGDisplayIsMain(display) != 0},
      });
    }
    return result;
  }

  std::vector<std::string> audio_output_devices() override {
    std::vector<std::string> result;
    for (const auto device : audio_devices()) {
      if (device_has_streams(device, kAudioDevicePropertyScopeOutput)) {
        result.push_back(audio_object_name(device));
      }
    }
    return result;
  }

  std::vector<std::string> microphone_devices() override {
    std::vector<std::string> result;
    for (const auto device : audio_devices()) {
      if (device_has_streams(device, kAudioDevicePropertyScopeInput)) {
        result.push_back(audio_object_name(device));
      }
    }
    return result;
  }

  nlohmann::json default_audio_devices() override {
    const auto input = default_device(kAudioHardwarePropertyDefaultInputDevice);
    const auto output = default_device(kAudioHardwarePropertyDefaultOutputDevice);
    return {
        {"input", input == kAudioObjectUnknown ? "" : audio_object_name(input)},
        {"output", output == kAudioObjectUnknown ? "" : audio_object_name(output)},
    };
  }

  nlohmann::json webcam_devices(bool include_virtual_devices) override {
    @autoreleasepool {
      AVCaptureDeviceDiscoverySession* discovery = [AVCaptureDeviceDiscoverySession
          discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera,
                                            AVCaptureDeviceTypeExternal]
                           mediaType:AVMediaTypeVideo
                            position:AVCaptureDevicePositionUnspecified];
      nlohmann::json result = nlohmann::json::array();
      for (AVCaptureDevice* device in discovery.devices) {
        const char* identifier = device.uniqueID.UTF8String;
        const char* localized_name = device.localizedName.UTF8String;
        const std::string id_value = identifier != nullptr ? identifier : "";
        const std::string label = localized_name != nullptr ? localized_name : "Camera";
        const bool virtual_device = [device.deviceType isEqualToString:AVCaptureDeviceTypeContinuityCamera];
        if (!include_virtual_devices && virtual_device) {
          continue;
        }
        result.push_back({{"id", id_value}, {"label", label}, {"value", id_value}, {"type", "camera"}});
      }
      return result;
    }
  }

  std::vector<std::string> gpu_devices() const override {
    return {gpu_device_name()};
  }

  nlohmann::json gpu_codecs() const override {
    const auto codecs = hardware_encoder_codecs();
    nlohmann::json available = nlohmann::json::array();
    if (codecs.contains(kCMVideoCodecType_H264)) {
      available.push_back("H264");
    }
    if (codecs.contains(kCMVideoCodecType_HEVC)) {
      available.push_back("H265");
    }
    if (codecs.contains(kCMVideoCodecType_AV1)) {
      available.push_back("AV1");
    }
    return {{gpu_device_name(), std::move(available)}};
  }

  std::vector<std::string> encoder_options() const override {
    return {"GPU"};
  }

  nlohmann::json capabilities() const override {
    const auto codecs = hardware_encoder_codecs();
    return {
        {"platform", "macos"},
        {"screenCaptureKit", NSClassFromString(@"SCStream") != Nil},
        {"systemAudio", true},
        {"microphone", true},
        {"processAudioTap", NSClassFromString(@"CATapDescription") != Nil},
        {"h264HardwareEncode", codecs.contains(kCMVideoCodecType_H264)},
        {"hevcHardwareEncode", codecs.contains(kCMVideoCodecType_HEVC)},
        {"av1HardwareEncode", codecs.contains(kCMVideoCodecType_AV1)},
        {"h264HardwareDecode", VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) != false},
        {"hevcHardwareDecode", VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) != false},
        {"av1HardwareDecode", VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) != false},
        {"captureState", "not_started"},
    };
  }
};

}  // namespace

std::unique_ptr<PlatformAdapter> make_platform_adapter() {
  return std::make_unique<MacPlatformAdapter>();
}

}  // namespace native_port
