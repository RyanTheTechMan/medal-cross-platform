#include "native_port/replay_store.hpp"

#include <algorithm>
#include <limits>
#include <stdexcept>

namespace native_port {

namespace {

[[nodiscard]] bool is_video(const std::shared_ptr<const EncodedPacket>& packet) noexcept {
  return packet->track == TrackKind::video;
}

[[nodiscard]] bool is_decodable_video_start(const std::shared_ptr<const EncodedPacket>& packet) noexcept {
  return is_video(packet) && packet->keyframe && !packet->depends_on_others && packet->codec_configuration &&
         !packet->codec_configuration->empty();
}

[[nodiscard]] std::int64_t packet_end_nanoseconds(const EncodedPacket& packet) {
  const auto duration = rescale(packet.duration, Rational{1, 1'000'000'000});
  return packet.monotonic_nanoseconds + std::max<std::int64_t>(0, duration);
}

}  // namespace

ReplayStore::ReplayStore(ReplayLimits limits) : limits_(limits) {
  if (limits_.maximum_duration <= std::chrono::nanoseconds::zero()) {
    throw std::invalid_argument("replay duration limit must be positive");
  }
  if (limits_.maximum_bytes == 0U) {
    throw std::invalid_argument("replay byte limit must be positive");
  }
  if (limits_.maximum_reorder_duration < std::chrono::nanoseconds::zero()) {
    throw std::invalid_argument("replay reorder duration must not be negative");
  }
}

void ReplayStore::push(std::shared_ptr<const EncodedPacket> packet) {
  if (!packet || !packet->data || packet->data->empty()) {
    throw std::invalid_argument("encoded packet and payload must be present");
  }
  if (packet->monotonic_nanoseconds < 0) {
    throw std::invalid_argument("packet monotonic timestamp must be non-negative");
  }
  if (packet->track == TrackKind::video && packet->keyframe &&
      (!packet->codec_configuration || packet->codec_configuration->empty())) {
    throw std::invalid_argument("video keyframe must carry decoder configuration");
  }

  std::scoped_lock lock(mutex_);
  if (has_timestamp_ &&
      packet->monotonic_nanoseconds <
          newest_observed_monotonic_nanoseconds_ - limits_.maximum_reorder_duration.count()) {
    throw std::invalid_argument("packet arrived outside the replay reorder window");
  }
  has_timestamp_ = true;
  newest_observed_monotonic_nanoseconds_ =
      std::max(newest_observed_monotonic_nanoseconds_, packet->monotonic_nanoseconds);
  occupied_bytes_ += packet->occupied_bytes();
  const auto insertion = std::upper_bound(
      packets_.begin(), packets_.end(), packet->monotonic_nanoseconds,
      [](std::int64_t timestamp, const std::shared_ptr<const EncodedPacket>& existing) {
        return timestamp < existing->monotonic_nanoseconds;
      });
  packets_.insert(insertion, std::move(packet));
  enforce_limits_locked();
}

void ReplayStore::advance_clock(std::int64_t monotonic_nanoseconds) {
  if (monotonic_nanoseconds < 0) {
    throw std::invalid_argument("capture clock timestamp must be non-negative");
  }
  std::scoped_lock lock(mutex_);
  has_timestamp_ = true;
  newest_observed_monotonic_nanoseconds_ =
      std::max(newest_observed_monotonic_nanoseconds_, monotonic_nanoseconds);
  enforce_limits_locked();
}

std::optional<ReplaySnapshot> ReplayStore::snapshot(std::chrono::nanoseconds requested_duration) const {
  if (requested_duration <= std::chrono::nanoseconds::zero()) {
    throw std::invalid_argument("requested replay duration must be positive");
  }

  std::scoped_lock lock(mutex_);
  if (packets_.empty()) {
    return std::nullopt;
  }

  const auto newest_generation = packets_.back()->configuration_generation;
  const auto observed_end = std::max(newest_observed_monotonic_nanoseconds_,
                                     packets_.back()->monotonic_nanoseconds);
  return snapshot_locked(requested_duration, observed_end, newest_generation, false);
}

std::optional<ReplayEndpoint> ReplayStore::pin_endpoint(std::int64_t monotonic_nanoseconds) const {
  if (monotonic_nanoseconds < 0) throw std::invalid_argument("replay endpoint must be non-negative");
  std::scoped_lock lock(mutex_);
  const auto video = std::find_if(packets_.rbegin(), packets_.rend(), [=](const auto& packet) {
    return is_video(packet) && packet->monotonic_nanoseconds < monotonic_nanoseconds;
  });
  if (video == packets_.rend()) return std::nullopt;
  ReplayEndpoint endpoint{monotonic_nanoseconds, (*video)->configuration_generation, {}};
  for (const auto& packet : packets_) {
    if (is_video(packet) || packet->configuration_generation != endpoint.configuration_generation ||
        packet->monotonic_nanoseconds >= monotonic_nanoseconds) continue;
    const ReplayAudioTrack track{packet->track, packet->track_id, packet->logical_source_id};
    if (std::find(endpoint.required_audio_tracks.begin(), endpoint.required_audio_tracks.end(), track) ==
        endpoint.required_audio_tracks.end()) endpoint.required_audio_tracks.push_back(track);
  }
  return endpoint;
}

std::optional<ReplaySnapshot> ReplayStore::snapshot_at(
    std::chrono::nanoseconds requested_duration, const ReplayEndpoint& endpoint) const {
  if (requested_duration <= std::chrono::nanoseconds::zero() || endpoint.monotonic_nanoseconds < 0)
    throw std::invalid_argument("positive replay duration and non-negative endpoint required");
  std::scoped_lock lock(mutex_);
  if (!has_timestamp_ || newest_observed_monotonic_nanoseconds_ < endpoint.monotonic_nanoseconds)
    return std::nullopt;
  for (const auto& required : endpoint.required_audio_tracks) {
    const bool covered = std::any_of(packets_.rbegin(), packets_.rend(), [&](const auto& packet) {
      return packet->configuration_generation == endpoint.configuration_generation &&
             packet->track == required.kind && packet->track_id == required.id &&
             packet->logical_source_id == required.logical_id &&
             packet->monotonic_nanoseconds < endpoint.monotonic_nanoseconds &&
             packet_end_nanoseconds(*packet) >= endpoint.monotonic_nanoseconds;
    });
    if (!covered) return std::nullopt;
  }
  return snapshot_locked(requested_duration, endpoint.monotonic_nanoseconds,
                         endpoint.configuration_generation, true);
}

std::optional<ReplaySnapshot> ReplayStore::snapshot_locked(
    std::chrono::nanoseconds requested_duration, std::int64_t observed_end,
    std::uint64_t newest_generation, bool pinned) const {
  const auto requested_count = requested_duration.count();
  const auto target = requested_count > observed_end ? 0 : observed_end - requested_count;

  std::optional<std::size_t> first_generation_index;
  std::optional<std::size_t> preceding_keyframe_index;
  std::optional<std::size_t> following_keyframe_index;
  for (std::size_t index = 0; index < packets_.size(); ++index) {
    const auto& packet = packets_[index];
    if (packet->configuration_generation != newest_generation ||
        (pinned && packet->monotonic_nanoseconds >= observed_end)) {
      continue;
    }
    if (!first_generation_index) {
      first_generation_index = index;
    }
    if (!is_decodable_video_start(packet)) {
      continue;
    }
    if (packet->monotonic_nanoseconds <= target) {
      preceding_keyframe_index = index;
    } else if (!following_keyframe_index) {
      following_keyframe_index = index;
    }
  }

  const auto start_index = preceding_keyframe_index ? preceding_keyframe_index : following_keyframe_index;
  if (!start_index || !first_generation_index) {
    return std::nullopt;
  }

  ReplaySnapshot result;
  result.requested_duration = requested_duration;
  result.configuration_generation = newest_generation;
  result.start_monotonic_nanoseconds = packets_[*start_index]->monotonic_nanoseconds;
  result.observed_end_monotonic_nanoseconds = observed_end;

  std::int64_t last_media_end = result.start_monotonic_nanoseconds;
  for (std::size_t index = *start_index; index < packets_.size(); ++index) {
    const auto& packet = packets_[index];
    if (packet->configuration_generation == newest_generation &&
        (!pinned || packet->monotonic_nanoseconds < observed_end)) {
      last_media_end = std::max(last_media_end, packet_end_nanoseconds(*packet));
    }
  }
  const bool requested_interval_is_entirely_idle = last_media_end < target;
  result.end_monotonic_nanoseconds = requested_interval_is_entirely_idle && !pinned
                                         ? last_media_end + requested_count
                                         : observed_end;
  result.actual_duration = std::chrono::nanoseconds(
      result.end_monotonic_nanoseconds - result.start_monotonic_nanoseconds);
  if (requested_interval_is_entirely_idle) {
    result.limitation = pinned
        ? "requested interval is entirely idle; fixed endpoint retains the last decodable GOP with idle preroll"
        : "requested interval is entirely idle; export extends the last encoded video sample and includes keyframe preroll";
  } else if (!preceding_keyframe_index) {
    result.limitation = "requested interval predates the first retained keyframe in the active codec generation";
  } else if (result.start_monotonic_nanoseconds < target) {
    result.limitation = "fast export includes keyframe preroll";
  }

  for (std::size_t index = *start_index; index < packets_.size(); ++index) {
    const auto& packet = packets_[index];
    if (packet->configuration_generation != newest_generation ||
        (pinned && packet->monotonic_nanoseconds >= observed_end)) {
      continue;
    }
    result.occupied_bytes += packet->occupied_bytes();
    result.packets.push_back(packet);
  }
  return result;
}

void ReplayStore::clear() {
  std::scoped_lock lock(mutex_);
  packets_.clear();
  occupied_bytes_ = 0;
  newest_observed_monotonic_nanoseconds_ = 0;
  has_timestamp_ = false;
}

std::size_t ReplayStore::occupied_bytes() const {
  std::scoped_lock lock(mutex_);
  return occupied_bytes_;
}

std::size_t ReplayStore::packet_count() const {
  std::scoped_lock lock(mutex_);
  return packets_.size();
}

std::chrono::nanoseconds ReplayStore::retained_duration() const {
  std::scoped_lock lock(mutex_);
  return retained_duration_locked();
}

void ReplayStore::enforce_limits_locked() {
  while (!packets_.empty() && occupied_bytes_ > limits_.maximum_bytes) {
    occupied_bytes_ -= packets_.front()->occupied_bytes();
    packets_.pop_front();
  }
  align_front_to_decodable_video_locked();

  if (!packets_.empty() && has_timestamp_) {
    const auto cutoff = newest_observed_monotonic_nanoseconds_ - limits_.maximum_duration.count();
    if (packets_.front()->monotonic_nanoseconds < cutoff) {
      auto selected = packets_.end();
      for (auto iterator = packets_.begin(); iterator != packets_.end(); ++iterator) {
        if (is_decodable_video_start(*iterator) && (*iterator)->monotonic_nanoseconds >= cutoff) {
          selected = iterator;
          break;
        }
      }
      if (selected == packets_.end()) {
        for (auto iterator = packets_.begin(); iterator != packets_.end(); ++iterator) {
          if (is_decodable_video_start(*iterator)) {
            selected = iterator;
          }
        }
      }
      if (selected != packets_.end()) {
        const auto keyframe_time = (*selected)->monotonic_nanoseconds;
        while (!packets_.empty() && packets_.front()->monotonic_nanoseconds < keyframe_time) {
          occupied_bytes_ -= packets_.front()->occupied_bytes();
          packets_.pop_front();
        }
      }
    }
  }
  if (packets_.empty()) {
    occupied_bytes_ = 0;
  }
}

void ReplayStore::align_front_to_decodable_video_locked() {
  const auto first_video = std::find_if(packets_.begin(), packets_.end(), is_video);
  if (first_video == packets_.end() || is_decodable_video_start(*first_video)) {
    return;
  }
  const auto first_keyframe = std::find_if(first_video, packets_.end(), is_decodable_video_start);
  if (first_keyframe == packets_.end()) {
    return;
  }
  const auto keyframe_time = (*first_keyframe)->monotonic_nanoseconds;
  while (!packets_.empty() && packets_.front()->monotonic_nanoseconds < keyframe_time) {
    occupied_bytes_ -= packets_.front()->occupied_bytes();
    packets_.pop_front();
  }
}

std::chrono::nanoseconds ReplayStore::retained_duration_locked() const {
  if (packets_.size() < 2U) {
    return std::chrono::nanoseconds::zero();
  }
  return std::chrono::nanoseconds(packets_.back()->monotonic_nanoseconds -
                                  packets_.front()->monotonic_nanoseconds);
}

}  // namespace native_port
