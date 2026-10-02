#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace native_port {
struct MacAudioOutputDevice final {
  std::uint32_t object_id{0};
  std::string uid;
  std::string name;
  bool default_output{false};
  std::vector<std::uint32_t> stream_channels;
};
struct MacAudioOutputRoute final {
  std::string device_uid;
  std::string device_name;
  std::uint32_t stream_index{0};
  [[nodiscard]] std::string logical_id() const {
    return "pc-device:" + device_uid + ":" + std::to_string(stream_index);
  }
};
[[nodiscard]] std::vector<MacAudioOutputDevice> mac_audio_output_snapshot();
// Explicit names must resolve uniquely to connected output devices. Auto plus
// the selected current-default UID is deduplicated; there is no global fallback.
[[nodiscard]] std::vector<MacAudioOutputRoute> resolve_audio_output_routes(
    const std::vector<MacAudioOutputDevice>& devices, const std::vector<std::string>& selected);
} // namespace native_port
