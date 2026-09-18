#pragma once

#include "native_port/replay_store.hpp"

#include <cstddef>
#include <filesystem>

namespace native_port {

struct Mp4WriteResult final {
  std::size_t video_packets{0};
  std::size_t system_audio_packets{0};
  std::size_t microphone_packets{0};
  std::size_t bytes_written{0};
  std::chrono::nanoseconds duration{};
};

[[nodiscard]] Mp4WriteResult write_mp4(const std::filesystem::path& output_path,
                                       const ReplaySnapshot& snapshot);

}  // namespace native_port
