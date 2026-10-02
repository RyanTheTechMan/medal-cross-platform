#pragma once

#include "native_port/encoded_packet.hpp"

#include <functional>
#include <span>
#include <vector>

namespace native_port {

struct PcmSource final {
  std::string logical_id;
  TrackKind role{TrackKind::mixed_audio};
  std::uint32_t track_id{2};
  double gain{1.0};
};

// Serialized worker-owned graph. All positions are ABSOLUTE host time expressed
// in 48 kHz frames, never a per-device zero origin. Adapters resample into this
// format. PCM never crosses the client protocol boundary.
class PcmMixer final {
 public:
  static constexpr std::int32_t rate = 48'000;
  static constexpr std::size_t block_frames = 480;
  static constexpr std::size_t capacity_frames = 96'000;
  static constexpr std::int64_t reorder_frames = 9'600; // 200 ms.
  using Output = std::function<void(const PcmSource&, std::int64_t, std::span<const float>)>;
  PcmMixer(std::vector<PcmSource> sources, bool stems, std::uint64_t generation, Output output);
  // Only future acquired samples receive a new gain. Stems carry capture gain;
  // the editor must not apply it a second time. Topology is immutable per graph.
  void set_gain(std::string_view id, double gain);
  void push(std::string_view id, std::uint64_t generation, std::int64_t first_frame,
            std::span<const float> stereo);
  void drain(bool final = false);
  [[nodiscard]] std::uint64_t late_frames() const noexcept { return late_frames_; }
  [[nodiscard]] std::uint64_t stale_blocks() const noexcept { return stale_blocks_; }
  [[nodiscard]] std::uint64_t gap_frames() const noexcept { return gap_frames_; }
  [[nodiscard]] std::uint64_t output_frames() const noexcept { return output_frames_; }

 private:
  struct Slot { std::int64_t frame{-1}; float left{0}, right{0}; };
  struct Bus { PcmSource source; std::vector<Slot> ring; std::vector<float> output; bool acquired{false}; };
  std::vector<Bus> buses_;
  std::vector<float> master_;
  bool stems_;
  std::uint64_t generation_;
  Output output_;
  std::int64_t cursor_{-1}, latest_end_{-1};
  double limiter_gain_{1.0};
  std::uint64_t late_frames_{0}, stale_blocks_{0}, gap_frames_{0}, output_frames_{0};
};

}  // namespace native_port
