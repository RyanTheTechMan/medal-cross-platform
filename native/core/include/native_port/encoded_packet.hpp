#pragma once

#include "native_port/media_time.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace native_port {

enum class Codec {
  h264,
  hevc,
  av1,
  aac,
};

enum class TrackKind {
  video,
  mixed_audio,
  game_audio,
  microphone_audio,
};

struct EncodedPacket final {
  Codec codec{Codec::h264};
  TrackKind track{TrackKind::video};
  std::uint32_t track_id{0};
  // Stable logical source identity within this media generation. This is not
  // a PID and remains valid when an application is relaunched.
  std::string logical_source_id;
  std::uint64_t configuration_generation{0};
  MediaTime pts{};
  MediaTime dts{};
  MediaTime duration{};
  std::int64_t monotonic_nanoseconds{0};
  bool keyframe{false};
  bool depends_on_others{true};
  std::uint32_t video_width{0};
  std::uint32_t video_height{0};
  std::uint32_t sample_rate{0};
  std::uint32_t channel_count{0};
  std::uint32_t bitrate_bits_per_second{0};
  std::uint32_t encoder_delay_frames{0};
  std::uint32_t discard_padding_frames{0};
  std::shared_ptr<const std::vector<std::byte>> data;
  std::shared_ptr<const std::vector<std::byte>> codec_configuration;
  std::shared_ptr<const std::vector<std::byte>> platform_codec_cookie;

  [[nodiscard]] std::size_t occupied_bytes() const noexcept {
    return (data ? data->size() : 0U) + (codec_configuration ? codec_configuration->size() : 0U) +
           (platform_codec_cookie ? platform_codec_cookie->size() : 0U);
  }
};

[[nodiscard]] constexpr std::string_view codec_name(Codec codec) noexcept {
  switch (codec) {
    case Codec::h264:
      return "h264";
    case Codec::hevc:
      return "hevc";
    case Codec::av1:
      return "av1";
    case Codec::aac:
      return "aac";
  }
  return "unknown";
}

}  // namespace native_port
