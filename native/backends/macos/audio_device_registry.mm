#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>
#include "audio_device_registry.hpp"
#include <algorithm>
#include <set>
#include <stdexcept>

namespace native_port {
namespace {
std::string string_property(AudioObjectID object, AudioObjectPropertySelector key) {
  AudioObjectPropertyAddress address{key, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  CFStringRef result = nullptr; UInt32 size = sizeof(result);
  if (AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, &result) != noErr || !result) return {};
  const char* value = ((__bridge NSString*)result).UTF8String;
  const std::string text = value ? value : ""; CFRelease(result); return text;
}
std::vector<AudioObjectID> object_list(AudioObjectID object, AudioObjectPropertySelector key,
                                       AudioObjectPropertyScope scope) {
  AudioObjectPropertyAddress address{key, scope, kAudioObjectPropertyElementMain}; UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(object, &address, 0, nullptr, &size) != noErr || size % sizeof(AudioObjectID)) return {};
  std::vector<AudioObjectID> result(size / sizeof(AudioObjectID));
  if (size && AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, result.data()) != noErr) return {};
  return result;
}
}
std::vector<MacAudioOutputDevice> mac_audio_output_snapshot() {
  @autoreleasepool {
    AudioObjectPropertyAddress address{kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID current = kAudioObjectUnknown; UInt32 size = sizeof(current);
    (void)AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, &current);
    std::vector<MacAudioOutputDevice> result;
    for (const auto object : object_list(kAudioObjectSystemObject, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)) {
      const auto streams = object_list(object, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
      if (streams.empty()) continue;
      MacAudioOutputDevice device{object, string_property(object, kAudioDevicePropertyDeviceUID),
                                string_property(object, kAudioObjectPropertyName), object == current, {}};
      for (const auto stream : streams) {
        AudioObjectPropertyAddress format_address{kAudioStreamPropertyVirtualFormat,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        AudioStreamBasicDescription format{}; size = sizeof(format);
        const auto status = AudioObjectGetPropertyData(stream, &format_address, 0, nullptr, &size, &format);
        device.stream_channels.push_back(status == noErr ? format.mChannelsPerFrame : 0);
      }
      result.push_back(std::move(device));
    }
    return result;
  }
}
std::vector<MacAudioOutputRoute> resolve_audio_output_routes(
    const std::vector<MacAudioOutputDevice>& devices, const std::vector<std::string>& selected) {
  std::vector<MacAudioOutputRoute> result;
  std::set<std::string> seen;
  for (const auto& name : selected) {
    const MacAudioOutputDevice* selected_device = nullptr;
    for (const auto& device : devices) {
      if ((name == "Auto" && device.default_output) ||
          (name != "Auto" && (name == device.uid || name == device.name))) {
        if (selected_device && selected_device->uid != device.uid)
          throw std::invalid_argument("Selected audio output name is ambiguous: " + name);
        selected_device = &device;
      }
    }
    if (!selected_device || selected_device->uid.empty())
      throw std::invalid_argument("Selected audio output is unavailable: " + name);
    if (!seen.insert(selected_device->uid).second) continue;
    if (selected_device->stream_channels.empty())
      throw std::invalid_argument("Selected audio output exposes no streams: " + name);
    for (std::uint32_t i = 0; i < selected_device->stream_channels.size(); ++i) {
      const auto channels = selected_device->stream_channels[i];
      if (channels < 1 || channels > 2)
        throw std::invalid_argument("Selected audio output stream requires an unsupported channel layout: " + name);
      result.push_back({selected_device->uid, selected_device->name, i});
    }
    if (result.size() > 14) throw std::invalid_argument("Selected audio outputs exceed bounded native source capacity");
  }
  return result;
}
} // namespace native_port
