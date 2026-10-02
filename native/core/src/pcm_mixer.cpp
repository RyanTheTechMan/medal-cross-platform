#include "native_port/pcm_mixer.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <set>
#include <stdexcept>

namespace native_port {
namespace {
void validate_gain(double gain) {
  if (!std::isfinite(gain) || gain < 0 || gain > 1.5) throw std::invalid_argument("invalid PCM gain");
}
}

PcmMixer::PcmMixer(std::vector<PcmSource> sources, bool stems, std::uint64_t generation, Output output)
    : master_(block_frames * 2), stems_(stems), generation_(generation), output_(std::move(output)) {
  if (sources.size() > 15 || !output_) throw std::invalid_argument("invalid PCM source count/callback");
  std::set<std::string> ids;
  std::set<std::uint32_t> tracks;
  for (auto& source : sources) {
    validate_gain(source.gain);
    if (source.logical_id.empty() || source.logical_id == "all-audio" ||
        source.track_id < 2 || source.role == TrackKind::video ||
        !ids.insert(source.logical_id).second || !tracks.insert(source.track_id).second)
      throw std::invalid_argument("conflicting PCM source identity");
    buses_.push_back({std::move(source), std::vector<Slot>(capacity_frames), std::vector<float>(block_frames * 2)});
  }
}

void PcmMixer::set_gain(std::string_view id, double gain) {
  validate_gain(gain);
  const auto bus = std::find_if(buses_.begin(), buses_.end(), [&](const auto& item) { return item.source.logical_id == id; });
  if (bus == buses_.end()) throw std::invalid_argument("unknown PCM source");
  bus->source.gain = gain;
}

void PcmMixer::push(std::string_view id, std::uint64_t generation, std::int64_t first,
                    std::span<const float> stereo) {
  if (generation != generation_) { ++stale_blocks_; return; }
  if (first < 0 || stereo.empty() || stereo.size() % 2 != 0 || stereo.size() > capacity_frames * 2 ||
      first > std::numeric_limits<std::int64_t>::max() - static_cast<std::int64_t>(capacity_frames) ||
      !std::all_of(stereo.begin(), stereo.end(), [](float value) { return std::isfinite(value); }))
    throw std::invalid_argument("invalid PCM block");
  const auto bus = std::find_if(buses_.begin(), buses_.end(), [&](const auto& item) { return item.source.logical_id == id; });
  if (bus == buses_.end()) throw std::invalid_argument("unknown PCM source");
  if (cursor_ < 0) cursor_ = first;
  // Allow callback reordering before the first output, including a source whose
  // actual timestamp precedes the source that happened to deliver first.
  if (output_frames_ == 0 && first < cursor_ && latest_end_ - first < static_cast<std::int64_t>(capacity_frames)) cursor_ = first;
  const auto frames = stereo.size() / 2;
  const auto end = first + static_cast<std::int64_t>(frames);
  if (end - cursor_ > static_cast<std::int64_t>(capacity_frames))
    throw std::runtime_error("PCM timeline discontinuity exceeds bounded graph window");
  bus->acquired = true;
  for (std::size_t index = 0; index < frames; ++index) {
    const auto frame = first + static_cast<std::int64_t>(index);
    if (frame < cursor_) { ++late_frames_; continue; }
    auto& slot = bus->ring[static_cast<std::size_t>(frame) % capacity_frames];
    slot = {frame, static_cast<float>(std::clamp(stereo[index * 2] * bus->source.gain, -1.0, 1.0)),
                   static_cast<float>(std::clamp(stereo[index * 2 + 1] * bus->source.gain, -1.0, 1.0))};
  }
  latest_end_ = std::max(latest_end_, end);
  drain();
}

void PcmMixer::drain(bool final) {
  if (cursor_ < 0) return;
  const auto watermark = latest_end_ - (final ? 0 : reorder_frames);
  const PcmSource master{"all-audio", TrackKind::mixed_audio, 1, 1.0};
  while (cursor_ < watermark && (final || watermark - cursor_ >= static_cast<std::int64_t>(block_frames))) {
    const auto count = static_cast<std::size_t>(std::min<std::int64_t>(block_frames, watermark - cursor_));
    std::fill(master_.begin(), master_.end(), 0);
    for (auto& bus : buses_) {
      for (std::size_t index = 0; index < count; ++index) {
        const auto frame = cursor_ + static_cast<std::int64_t>(index);
        auto& slot = bus.ring[static_cast<std::size_t>(frame) % capacity_frames];
        const bool present = slot.frame == frame;
        if (!present) ++gap_frames_;
        bus.output[index * 2] = present ? slot.left : 0;
        bus.output[index * 2 + 1] = present ? slot.right : 0;
        master_[index * 2] += bus.output[index * 2];
        master_[index * 2 + 1] += bus.output[index * 2 + 1];
      }
    }
    // Stereo-linked peak limiter: instantaneous attack, 50 ms exponential
    // release, ceiling .97. No automatic normalization/boost of quiet sources.
    constexpr double release = 0.9995834201268338; // exp(-1/(48000*.05)).
    for (std::size_t index = 0; index < count; ++index) {
      const auto peak = std::max(std::abs(master_[index * 2]), std::abs(master_[index * 2 + 1]));
      const double required = peak > .97F ? .97 / peak : 1.0;
      limiter_gain_ = std::min(required, 1.0 - (1.0 - limiter_gain_) * release);
      master_[index * 2] *= static_cast<float>(limiter_gain_);
      master_[index * 2 + 1] *= static_cast<float>(limiter_gain_);
    }
    output_(master, cursor_, std::span(master_.data(), count * 2));
    if (stems_) for (const auto& bus : buses_) if (bus.acquired) output_(bus.source, cursor_, std::span(bus.output.data(), count * 2));
    cursor_ += static_cast<std::int64_t>(count);
    output_frames_ += count;
  }
}
}  // namespace native_port
