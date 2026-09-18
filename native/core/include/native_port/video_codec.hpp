#pragma once

#include "native_port/encoded_packet.hpp"

#include <optional>
#include <string_view>

namespace native_port {

enum class VideoCodec {
  h264,
  hevc,
  av1,
};

[[nodiscard]] constexpr std::string_view video_codec_name(VideoCodec codec) noexcept {
  switch (codec) {
    case VideoCodec::h264:
      return "h264";
    case VideoCodec::hevc:
      return "hevc";
    case VideoCodec::av1:
      return "av1";
  }
  return "unknown";
}

[[nodiscard]] constexpr std::string_view medal_video_codec_name(VideoCodec codec) noexcept {
  switch (codec) {
    case VideoCodec::h264:
      return "H264";
    case VideoCodec::hevc:
      return "H265";
    case VideoCodec::av1:
      return "AV1";
  }
  return "UNKNOWN";
}

[[nodiscard]] constexpr std::optional<VideoCodec> parse_video_codec(std::string_view value) noexcept {
  if (value == "H264" || value == "h264") {
    return VideoCodec::h264;
  }
  if (value == "H265" || value == "h265" || value == "HEVC" || value == "hevc") {
    return VideoCodec::hevc;
  }
  if (value == "AV1" || value == "av1") {
    return VideoCodec::av1;
  }
  return std::nullopt;
}

[[nodiscard]] constexpr Codec encoded_packet_codec(VideoCodec codec) noexcept {
  switch (codec) {
    case VideoCodec::h264:
      return Codec::h264;
    case VideoCodec::hevc:
      return Codec::hevc;
    case VideoCodec::av1:
      return Codec::av1;
  }
  return Codec::h264;
}

}  // namespace native_port
