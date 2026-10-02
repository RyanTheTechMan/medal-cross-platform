#define NATIVE_PORT_MP4_FIXTURE_ONLY
#include "mp4_writer_probe.mm"
#include "audio_mix_graph.hpp"
#include "pcm_sample.hpp"
#include <set>

namespace {
CMSampleBufferRef tone_sample(int rate, unsigned channels, bool planar, bool integer,
                              std::int64_t frame, double hz, std::string& error) {
  const auto count = static_cast<std::size_t>(rate / 100);
  AudioStreamBasicDescription format{};
  format.mSampleRate = rate; format.mFormatID = kAudioFormatLinearPCM;
  format.mFormatFlags = kAudioFormatFlagIsPacked | (integer ? kAudioFormatFlagIsSignedInteger : kAudioFormatFlagIsFloat) |
    (planar ? kAudioFormatFlagIsNonInterleaved : 0);
  format.mChannelsPerFrame = channels; format.mBitsPerChannel = integer ? 16 : 32;
  format.mFramesPerPacket = 1;
  format.mBytesPerFrame = (planar ? 1 : channels) * format.mBitsPerChannel / 8;
  format.mBytesPerPacket = format.mBytesPerFrame;
  std::vector<std::vector<std::byte>> bytes(planar ? channels : 1,
      std::vector<std::byte>(count * format.mBytesPerFrame));
  for (std::size_t index = 0; index < count; ++index) for (unsigned channel = 0; channel < channels; ++channel) {
    const auto value = std::sin(2 * std::numbers::pi * hz * (frame + static_cast<std::int64_t>(index)) / rate) * .2;
    auto* target = bytes[planar ? channel : 0].data() + (planar ? index : index * channels + channel) * (integer ? 2 : 4);
    if (integer) { auto sample = static_cast<std::int16_t>(std::llround(value * 32767)); std::memcpy(target, &sample, 2); }
    else { auto sample = static_cast<float>(value); std::memcpy(target, &sample, 4); }
  }
  struct StereoList { UInt32 count; AudioBuffer buffers[2]; } list{};
  list.count = static_cast<UInt32>(bytes.size());
  for (unsigned index = 0; index < list.count; ++index) list.buffers[index] = {planar ? 1 : channels,
      static_cast<UInt32>(bytes[index].size()), bytes[index].data()};
  return native_port::make_pcm_sample(format, reinterpret_cast<AudioBufferList*>(&list), count, CMTimeMake(frame, rate), error);
}
}

int main(int argc, char** argv) {
  @autoreleasepool {
    const bool stems = argc < 3 || std::string(argv[2]) != "single";
    constexpr std::int64_t epoch = 12'345;
    VideoOutput video;
    std::vector<std::shared_ptr<const native_port::EncodedPacket>> audio;
    std::string error;
    bool ok = encode_video(video, error, epoch);
    native_port::AudioMixGraph graph({{"pc-audio", native_port::TrackKind::mixed_audio, 2, .25},
      {"microphone", native_port::TrackKind::microphone_audio, 3, .5}}, stems, 1,
      [&](auto packet) { audio.push_back(std::move(packet)); });
    for (int index = 0; index < 200 && ok; ++index) {
      // Alternate format halfway through: exercise mono/stereo, float planar/
      // interleaved and int16, 44.1/48/96 kHz, all on one host timeline.
      const int pc_rate = index < 100 ? 44100 : 48000;
      auto sample = tone_sample(pc_rate, 2, index < 100, false,
          epoch * pc_rate + index * pc_rate / 100, 440, error);
      if (!sample) { ok = false; break; }
      CMSampleTimingInfo timing{};
      CMSampleBufferGetSampleTimingInfo(sample, 0, &timing);
      ok = timing.duration.value == 1 && timing.duration.timescale == pc_rate &&
          graph.consume("pc-audio", sample, 1, error);
      CFRelease(sample);
      if (index >= 25 && ok) {
        sample = tone_sample(96000, 1, false, true, epoch * 96000 + index * 960, 660, error);
        if (!sample) { ok = false; break; }
        ok = graph.consume("microphone", sample, 1, error);
        CFRelease(sample);
      }
    }
    graph.finish();
    if (!graph.error().empty()) { ok = false; error = graph.error(); }
    AudioTimeStamp timestamp{};
    timestamp.mHostTime = AudioConvertNanosToHostTime(epoch * 1'000'000'000ULL);
    std::int64_t host = 0;
    ok = ok && !native_port::audio_capture_host_nanoseconds(&timestamp, host);
    timestamp.mFlags = kAudioTimeStampHostTimeValid;
    ok = ok && native_port::audio_capture_host_nanoseconds(&timestamp, host) && std::abs(host - epoch * 1'000'000'000LL) < 100;
    std::set<std::string> ids;
    for (const auto& packet : audio) {
      ids.insert(packet->logical_source_id);
      ok = ok && packet->monotonic_nanoseconds >= epoch * 1'000'000'000LL &&
        packet->configuration_generation == 1 && packet->sample_rate == 48000 && packet->channel_count == 2;
    }
    ok = ok && ids.size() == (stems ? 3U : 1U) && ids.contains("all-audio");
    auto packets = video.packets; packets.insert(packets.end(), audio.begin(), audio.end());
    std::sort(packets.begin(), packets.end(), [](const auto& a, const auto& b) { return a->monotonic_nanoseconds < b->monotonic_nanoseconds; });
    native_port::ReplayStore replay({.maximum_duration = std::chrono::seconds(10), .maximum_bytes = 64U * 1024U * 1024U});
    native_port::Mp4WriteResult result;
    const auto output = argc > 1 ? std::filesystem::path(argv[1]) : std::filesystem::temp_directory_path() /
      ("medal-audio-mixer-probe-" + std::to_string(::getpid()) + ".mp4");
    try {
      if (!ok) throw std::runtime_error(error.empty() ? "PCM or native encoder assertion failed" : error);
      for (const auto& packet : packets) replay.push(packet);
      const auto snapshot = replay.snapshot(std::chrono::seconds(5));
      if (!snapshot) throw std::runtime_error("host-clock replay snapshot missing");
      result = native_port::write_mp4(output, *snapshot);
      ok = result.audio_streams.size() == (stems ? 3U : 1U) && result.audio_streams[0].title == "All Audio" &&
           result.audio_streams[0].default_track;
    } catch (const std::exception& failure) { ok = false; error = failure.what(); }
    std::cout << nlohmann::json({{"status", ok ? "passed" : "failed"}, {"error", error}, {"stems", stems},
      {"audioPackets", audio.size()}, {"videoPackets", video.packets.size()}, {"audioStreams", result.audio_streams.size()},
      {"hostEpochSeconds", epoch}, {"outputPath", output.string()}}).dump(2) << '\n';
    if (argc < 2 && ok) std::filesystem::remove(output);
    return ok ? 0 : 1;
  }
}
