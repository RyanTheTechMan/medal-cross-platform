#pragma once

#include "native_port/encoded_packet.hpp"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace native_port {

struct ReplayLimits final {
  std::chrono::nanoseconds maximum_duration{std::chrono::seconds(30)};
  std::size_t maximum_bytes{128U * 1024U * 1024U};
  std::chrono::nanoseconds maximum_reorder_duration{std::chrono::seconds(2)};
};

struct ReplaySnapshot final {
  std::vector<std::shared_ptr<const EncodedPacket>> packets;
  std::chrono::nanoseconds requested_duration{};
  std::chrono::nanoseconds actual_duration{};
  std::int64_t start_monotonic_nanoseconds{0};
  std::int64_t end_monotonic_nanoseconds{0};
  std::uint64_t configuration_generation{0};
  std::size_t occupied_bytes{0};
  std::string limitation;
};

class ReplayStore final {
 public:
  explicit ReplayStore(ReplayLimits limits);

  void push(std::shared_ptr<const EncodedPacket> packet);
  [[nodiscard]] std::optional<ReplaySnapshot> snapshot(std::chrono::nanoseconds requested_duration) const;
  void clear();

  [[nodiscard]] std::size_t occupied_bytes() const;
  [[nodiscard]] std::size_t packet_count() const;
  [[nodiscard]] std::chrono::nanoseconds retained_duration() const;

 private:
  void enforce_limits_locked();
  void align_front_to_decodable_video_locked();
  [[nodiscard]] std::chrono::nanoseconds retained_duration_locked() const;

  ReplayLimits limits_;
  mutable std::mutex mutex_;
  std::deque<std::shared_ptr<const EncodedPacket>> packets_;
  std::size_t occupied_bytes_{0};
  std::int64_t newest_monotonic_nanoseconds_{0};
  bool has_timestamp_{false};
};

}  // namespace native_port
