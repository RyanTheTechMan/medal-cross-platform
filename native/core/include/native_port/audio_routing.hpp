#pragma once

#include "native_port/settings_store.hpp"

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace native_port {

struct AudioRoutingSource final {
  std::string id;
  bool enabled{false};
  double volume_percent{100};
  double gain_linear{1.0};
};

struct AudioRoutingPlan final {
  std::string mode{"splitByProcess"};
  bool pc_audio_enabled{true};
  double pc_audio_volume_percent{100};
  double pc_audio_gain_linear{1.0};
  bool microphone_enabled{true};
  double microphone_gain_linear{0.5};
  std::optional<std::string> microphone_device_name;
  std::vector<std::string> selected_audio_devices;
  std::vector<AudioRoutingSource> sources;
  bool multiple_audio_tracks{true};
  std::uint64_t generation{0};
};

// Medal's MicSoundGain is normalized by the imported renderer before it is
// sent to the recorder (0.0..1.5). Do not guess raw percent units from a value
// outside that range. AudioModeConfig source volumes are independent percent
// values (0..150) and are converted separately.
[[nodiscard]] double normalize_microphone_gain(const nlohmann::json& value);
[[nodiscard]] double percent_to_linear_gain(const nlohmann::json& value,
                                            std::string_view field_name);

[[nodiscard]] AudioRoutingPlan audio_routing_plan_from_settings(
    const SettingsStore& settings, std::optional<std::string_view> category_id = std::nullopt,
    std::uint64_t generation = 0);

}  // namespace native_port
