#pragma once

#import <CoreMedia/CoreMedia.h>

#include "native_port/encoded_packet.hpp"

#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace native_port {

class AacEncoder final {
 public:
  using PacketCallback = std::function<void(std::shared_ptr<const EncodedPacket>)>;

  AacEncoder(TrackKind track, std::uint32_t track_id, std::uint32_t target_bitrate,
             double gain, PacketCallback packet_callback);
  ~AacEncoder();

  AacEncoder(const AacEncoder&) = delete;
  AacEncoder& operator=(const AacEncoder&) = delete;

  [[nodiscard]] bool encode(CMSampleBufferRef sample, std::uint64_t configuration_generation,
                            std::string& error);
  void set_gain(double gain);
  void reset();

  [[nodiscard]] std::uint64_t input_sample_count() const noexcept;
  [[nodiscard]] std::uint64_t packet_count() const noexcept;
  [[nodiscard]] std::uint64_t failure_count() const noexcept;
  [[nodiscard]] std::uint64_t discontinuity_count() const noexcept;
  [[nodiscard]] std::uint32_t sample_rate() const noexcept;
  [[nodiscard]] std::uint32_t channel_count() const noexcept;
  [[nodiscard]] std::int64_t first_packet_nanoseconds() const noexcept;
  [[nodiscard]] std::int64_t last_packet_end_nanoseconds() const noexcept;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace native_port
