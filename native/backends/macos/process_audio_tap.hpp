#pragma once

#include "audio_encoder.hpp"

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>
#include <nlohmann/json.hpp>

namespace native_port {

struct AudioTapDeviceRoute final {
  std::string uid;
  std::uint32_t stream_index{0};
  // Empty included process list is only valid for an explicitly device-bound
  // All PC Audio exclusion tap. Specific Apps always uses included families.
  bool all_processes_on_device{false};
};

// A process-private Core Audio tap backed by a HAL aggregate device.  The tap
// copies negotiated PCM into a bounded worker queue and feeds the native mix
// graph (or legacy AAC callback). No PCM crosses the client protocol boundary.
class ProcessAudioTap final {
 public:
  using PcmCallback = std::function<bool(CMSampleBufferRef, std::uint64_t, std::string&)>;
  ProcessAudioTap();
  ~ProcessAudioTap();

  ProcessAudioTap(const ProcessAudioTap&) = delete;
  ProcessAudioTap& operator=(const ProcessAudioTap&) = delete;

  [[nodiscard]] bool start(const std::vector<std::int64_t>& pids, TrackKind track,
                            std::uint32_t track_id,
                            double gain, std::uint64_t configuration_generation,
                            std::int64_t session_epoch_nanoseconds,
                            AacEncoder::PacketCallback packet_callback, std::string& error,
                            PcmCallback pcm_callback = {},
                            std::optional<AudioTapDeviceRoute> device = std::nullopt);
  void stop();
  [[nodiscard]] bool running() const noexcept;
  void set_gain(double gain);
  void set_logical_source_id(std::string logical_source_id);
  [[nodiscard]] std::uint64_t packet_count() const noexcept;
  [[nodiscard]] std::uint64_t rejected_layout_count() const noexcept;
  [[nodiscard]] std::string error() const;
  [[nodiscard]] std::string status() const;
  [[nodiscard]] nlohmann::json diagnostics() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace native_port
