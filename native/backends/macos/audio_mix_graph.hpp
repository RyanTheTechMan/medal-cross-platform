#pragma once
#include "audio_encoder.hpp"
#include "native_port/pcm_mixer.hpp"
#include <memory>
#include <vector>
#include <nlohmann/json.hpp>

namespace native_port {
// Worker-side Apple PCM conversion + shared timeline mixer + native AAC. No HAL
// real-time callback may call this synchronous interface; ProcessAudioTap owns
// a bounded handoff queue and SCK delivers on its audio worker queue.
class AudioMixGraph final {
 public:
  AudioMixGraph(std::vector<PcmSource> sources, bool stems, std::uint64_t generation,
                AacEncoder::PacketCallback callback);
  ~AudioMixGraph();
  bool consume(std::string_view id, CMSampleBufferRef sample, std::uint64_t generation, std::string& error);
  void set_gain(std::string_view id, double gain);
  void finish();
  [[nodiscard]] std::shared_ptr<AacEncoder> encoder(std::string_view id) const;
  [[nodiscard]] std::string error() const;
  [[nodiscard]] nlohmann::json status() const;
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
} // namespace native_port
