#pragma once

#include "native_port/replay_store.hpp"

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace native_port {

struct Mp4AudioStreamManifest final {
  TrackKind track{TrackKind::mixed_audio};
  std::uint32_t track_id{0};
  Codec codec{Codec::aac};
  std::string logical_id;
  std::string title;
  std::uint32_t absolute_stream_index{0};
  std::uint32_t audio_ordinal{0};
  std::uint32_t sample_rate{0};
  std::uint32_t channel_count{0};
  bool default_track{false};
};

struct Mp4WriteResult final {
  std::size_t video_packets{0};
  std::size_t system_audio_packets{0};
  std::size_t microphone_packets{0};
  std::size_t bytes_written{0};
  std::chrono::nanoseconds duration{};
  std::vector<Mp4AudioStreamManifest> audio_streams;
};

[[nodiscard]] Mp4WriteResult write_mp4(const std::filesystem::path& output_path,
                                       const ReplaySnapshot& snapshot);

}  // namespace native_port
