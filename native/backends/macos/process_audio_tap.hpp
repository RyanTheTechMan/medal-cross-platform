#pragma once

#include "audio_encoder.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace native_port {

// A process-private Core Audio tap backed by a HAL aggregate device.  The tap
// feeds already-encoded AAC packets directly into the replay store; no PCM
// crosses the Electron/WebSocket boundary.
class ProcessAudioTap final {
 public:
  ProcessAudioTap();
  ~ProcessAudioTap();

  ProcessAudioTap(const ProcessAudioTap&) = delete;
  ProcessAudioTap& operator=(const ProcessAudioTap&) = delete;

  [[nodiscard]] bool start(const std::vector<std::int64_t>& pids, TrackKind track,
                            std::uint32_t track_id,
                            double gain, std::uint64_t configuration_generation,
                            std::int64_t session_epoch_nanoseconds,
                            AacEncoder::PacketCallback packet_callback, std::string& error);
  void stop();
  [[nodiscard]] bool running() const noexcept;
  void set_gain(double gain);
  void set_logical_source_id(std::string logical_source_id);
  [[nodiscard]] std::uint64_t packet_count() const noexcept;
  [[nodiscard]] std::uint64_t rejected_layout_count() const noexcept;
  [[nodiscard]] std::string error() const;
  [[nodiscard]] std::string status() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace native_port
