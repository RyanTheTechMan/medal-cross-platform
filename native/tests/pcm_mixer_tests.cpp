#include "native_port/pcm_mixer.hpp"
#include <cmath>
#include <iostream>
#include <map>
#include <stdexcept>

using namespace native_port;
void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
int main() {
  try {
    constexpr std::int64_t epoch = 12'345'000LL * 48'000;
    for (const bool stems : {false, true}) {
      std::map<std::string, std::vector<float>> result;
      std::map<std::string, std::int64_t> starts;
      PcmMixer mixer({{"pc-audio", TrackKind::mixed_audio, 2, .25},
                      {"microphone", TrackKind::microphone_audio, 3, .5}}, stems, 7,
        [&](const auto& source, auto frame, auto samples) {
          if (!starts.contains(source.logical_id)) starts[source.logical_id] = frame;
          auto& output = result[source.logical_id]; output.insert(output.end(), samples.begin(), samples.end());
        });
      const std::vector<float> pc(480 * 2, .2F), mic(480 * 2, .4F);
      for (int block = 0; block < 100; ++block) {
        // Mic starts 100 ms after PC, and reaches the worker before same-time PC.
        if (block >= 10) mixer.push("microphone", 7, epoch + block * 480, mic);
        mixer.push("pc-audio", 7, epoch + block * 480, pc);
      }
      mixer.push("pc-audio", 6, epoch, pc);
      mixer.drain(true);
      const auto& master = result.at("all-audio");
      require(result.size() == (stems ? 3U : 1U), "master-only/multiple-tracks contract");
      require(starts.at("all-audio") == epoch && master.size() == 96'000, "large host epoch and duration preserved");
      require(std::abs(master[0] - .05) < 1e-6 && std::abs(master[9600] - .25) < 1e-6, "staggered mic must join master at original timestamp");
      require(mixer.stale_blocks() == 1 && mixer.late_frames() == 0, "stale generation and reordered callbacks");
      if (stems) require(std::abs(result.at("microphone")[9600] - .2) < 1e-6, "capture gain applied once in source stem");
    }
    std::vector<float> output;
    PcmMixer gain({{"one", TrackKind::game_audio, 2, 1}, {"two", TrackKind::game_audio, 3, 1}}, false, 1,
      [&](const auto&, auto, auto samples) { output.insert(output.end(), samples.begin(), samples.end()); });
    const std::vector<float> loud(480 * 2, .8F);
    gain.push("one", 1, epoch, loud); gain.push("two", 1, epoch, loud);
    gain.set_gain("two", 0); gain.push("one", 1, epoch + 480, loud); gain.push("two", 1, epoch + 480, loud);
    gain.drain(true);
    require(output.front() <= .970001F && output[960] < .8F && output.back() > output[960], "defined limiter and gain change");
    bool rejected = false;
    try { gain.push("one", 1, epoch + 10'000'000, loud); } catch (const std::runtime_error&) { rejected = true; }
    require(rejected, "unbounded discontinuity must fail explicitly");
    std::cout << "PASS timestamped master/stems, large epoch, delayed mic, same-role identities, gains, limiting, bounded gaps and stale generations\n";
    return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
