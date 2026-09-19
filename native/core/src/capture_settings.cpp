#include "native_port/capture_settings.hpp"

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
  return defaults;
}

}  // namespace native_port
