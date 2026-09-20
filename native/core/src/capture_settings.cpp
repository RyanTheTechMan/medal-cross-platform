#include "native_port/capture_settings.hpp"
#include "native_port/audio_routing.hpp"

#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>

namespace native_port {
namespace {

[[nodiscard]] std::uint64_t bitrate_bits_per_second(const nlohmann::json& value) {
  if (!value.is_number()) {
    throw std::invalid_argument("Bitrate must be a numeric Mbps value");
  }
  const auto megabits_per_second = value.get<double>();
  if (!std::isfinite(megabits_per_second) || megabits_per_second < 1.0 ||
      megabits_per_second > 100.0) {
    throw std::invalid_argument("Bitrate must be between 1 and 100 Mbps");
  }
  const auto bits = megabits_per_second * 1'000'000.0;
  if (bits > static_cast<double>(std::numeric_limits<std::uint64_t>::max())) {
    throw std::invalid_argument("Bitrate exceeds the native encoder range");
  }
  return static_cast<std::uint64_t>(std::llround(bits));
}

}  // namespace

CaptureConfiguration capture_configuration_from_settings(
    const SettingsStore& settings, std::optional<std::string_view> category_id,
    CaptureConfiguration defaults) {
  if (const auto resolution = settings.effective("Resolution", category_id); resolution) {
    const auto width = resolution->at("width").get<std::int64_t>();
    const auto height = resolution->at("height").get<std::int64_t>();
    if (width < 64 || width > 7680 || height < 64 || height > 4320 || width % 2 != 0 ||
        height % 2 != 0) {
      throw std::invalid_argument(
          "Resolution must be an even canvas inside the supported 64x64 through 7680x4320 range");
    }
    defaults.width = static_cast<std::size_t>(width);
    defaults.height = static_cast<std::size_t>(height);
  }
  if (const auto frame_rate = settings.effective("TargetFPS", category_id); frame_rate) {
    if (!frame_rate->is_number_integer()) {
      throw std::invalid_argument("TargetFPS must be an integer");
    }
    const auto value = frame_rate->get<std::int64_t>();
    if (value < 1 || value > 240) {
      throw std::invalid_argument("TargetFPS must be between 1 and 240");
    }
    defaults.frames_per_second = static_cast<std::uint32_t>(value);
  }
  if (const auto bitrate = settings.effective("Bitrate", category_id); bitrate) {
    defaults.bitrate_bits_per_second = bitrate_bits_per_second(*bitrate);
  }
  if (const auto codec = settings.effective("Codec", category_id); codec) {
    const auto parsed = parse_video_codec(codec->get<std::string>());
    if (!parsed) {
      throw std::invalid_argument("Codec must be H264, H265 or AV1");
    }
    defaults.video_codec = *parsed;
  }
  if (const auto show_cursor = settings.effective("ShowCursor", category_id); show_cursor) {
    if (!show_cursor->is_boolean()) {
      throw std::invalid_argument("ShowCursor must be boolean");
    }
    defaults.show_cursor = show_cursor->get<bool>();
  }
  defaults.audio_plan = audio_routing_plan_from_settings(settings, category_id);
  defaults.audio_mode = defaults.audio_plan.mode;
  defaults.pc_audio_enabled = defaults.audio_plan.pc_audio_enabled;
  defaults.system_audio_volume_percent = defaults.audio_plan.pc_audio_volume_percent;
  defaults.selected_audio_devices = defaults.audio_plan.selected_audio_devices;
  defaults.multiple_audio_tracks = defaults.audio_plan.multiple_audio_tracks;
  defaults.microphone_device_name = defaults.audio_plan.microphone_device_name;
  defaults.microphone_gain_linear = defaults.audio_plan.microphone_gain_linear;
  defaults.capture_microphone = defaults.audio_plan.microphone_enabled;
  defaults.audio_sources.clear();
  defaults.audio_sources.reserve(defaults.audio_plan.sources.size());
  for (const auto& source : defaults.audio_plan.sources) {
    defaults.audio_sources.push_back({source.id, source.enabled, source.volume_percent});
  }
  defaults.capture_system_audio = defaults.audio_plan.mode != "none" &&
                                  defaults.audio_plan.mode != "disabled" &&
                                  (defaults.audio_plan.mode != "allPcAudio" ||
                                   defaults.audio_plan.pc_audio_enabled);
  if (defaults.audio_plan.mode == "gameOnly") {
    defaults.capture_system_audio = true;
  }
  return defaults;
}

}  // namespace native_port
