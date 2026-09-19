#include "native_port/clip_action.hpp"
#include "native_port/capture_geometry.hpp"
#include "native_port/capture_settings.hpp"
#include "native_port/json_rpc.hpp"
#include "native_port/media_time.hpp"
#include "native_port/replay_store.hpp"
#include "native_port/settings_store.hpp"
#include "native_port/video_codec.hpp"

#include <chrono>
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <functional>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {

using namespace std::chrono_literals;

class TestFailure final : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

void expect(bool condition, std::string_view message) {
  if (!condition) {
    throw TestFailure(std::string(message));
  }
}

template <typename Exception, typename Callable>
void expect_throws(Callable&& callable, std::string_view message) {
  try {
    std::invoke(std::forward<Callable>(callable));
  } catch (const Exception&) {
    return;
  }
  throw TestFailure(std::string(message));
}

std::shared_ptr<const std::vector<std::byte>> bytes(std::size_t count, unsigned char value) {
  auto storage = std::make_shared<std::vector<std::byte>>(count, static_cast<std::byte>(value));
  return storage;
}

std::shared_ptr<const native_port::EncodedPacket> packet(
    std::int64_t timestamp_ns, bool keyframe, std::uint64_t generation = 1,
    native_port::TrackKind track = native_port::TrackKind::video, std::size_t payload_bytes = 10,
    std::shared_ptr<const std::vector<std::byte>> configuration = nullptr) {
  auto value = std::make_shared<native_port::EncodedPacket>();
  value->track = track;
  value->configuration_generation = generation;
  value->monotonic_nanoseconds = timestamp_ns;
  value->pts = native_port::MediaTime{timestamp_ns, native_port::Rational{1, 1'000'000'000}};
  value->dts = value->pts;
  value->duration = native_port::MediaTime{1, native_port::Rational{1, 60}};
  value->keyframe = keyframe;
  value->depends_on_others = !keyframe;
  value->data = bytes(payload_bytes, static_cast<unsigned char>(timestamp_ns & 0xff));
  value->codec_configuration = std::move(configuration);
  return value;
}

void test_media_time() {
  const native_port::MediaTime ntsc_frame{1001, native_port::Rational{1, 30'000}};
  expect(ntsc_frame.seconds() > 0.0333L && ntsc_frame.seconds() < 0.0334L,
         "rational time conversion must preserve the time base");
  expect(native_port::rescale(ntsc_frame, native_port::Rational{1, 90'000}) == 3003,
         "timestamp rescale must preserve exact common video time bases");
  expect_throws<std::invalid_argument>([] { native_port::Rational invalid{0, 1}; },
                                       "zero time base must be rejected");
}

void test_json_rpc() {
  native_port::JsonRpcCodec codec{512};
  const auto request = codec.parse_request(
      R"({"jsonrpc":"2.0","id":"request-7","method":"UpdateSettings","params":{"Bitrate":15}})");
  expect(!request.is_notification() && request.method == "UpdateSettings", "request ID and method must parse");
  expect(std::get<std::string>(*request.id) == "request-7", "string request IDs must be preserved");
  expect(request.params.at("Bitrate") == 15, "params must be preserved without DTO invention");

  const native_port::JsonRpcRequest notification{.id = std::nullopt,
                                                  .method = "RecorderConnected",
                                                  .params = nlohmann::json::object()};
  const auto notification_json = nlohmann::json::parse(codec.serialize_request(notification));
  expect(!notification_json.contains("id"), "notifications must not acquire a synthetic ID");

  const auto success = native_port::JsonRpcCodec::medal_success({{"recording", true}});
  expect(success.at("result") == "success" && success.at("errorMessage").is_null(),
         "recovered success envelope casing must be exact");
  const auto failure = native_port::JsonRpcCodec::medal_failure("permission denied");
  expect(failure.at("result") == "fail" && failure.at("errorMessage") == "permission denied",
         "recovered failure envelope casing must be exact");

  const native_port::JsonRpcResponse response{.id = std::int64_t{9}, .result = success, .error = std::nullopt};
  const auto round_trip = codec.parse_response(codec.serialize_response(response));
  expect(std::get<std::int64_t>(round_trip.id) == 9 && round_trip.result == success,
         "responses must round-trip without changing the envelope");

  expect_throws<native_port::JsonRpcError>([&codec] { (void)codec.parse_request("not-json"); },
                                            "malformed JSON must be rejected");
  expect_throws<native_port::JsonRpcError>([&codec] {
    (void)codec.parse_request(R"({"jsonrpc":"2.0","method":"m","params":7})");
  }, "scalar params must be rejected");
  expect_throws<native_port::JsonRpcError>([&codec] {
    (void)codec.parse_response(R"({"jsonrpc":"2.0","id":1,"result":{},"error":{}})");
  }, "ambiguous response must be rejected");
  expect_throws<native_port::JsonRpcError>([&codec] {
    (void)codec.parse_request(std::string(513, 'x'));
  }, "oversized inbound frames must be rejected before parsing");
}

void test_settings() {
  native_port::SettingsStore settings;
  settings.apply({
      {.key = "Bitrate", .value = 15, .category_id = std::nullopt},
      {.key = "Resolution", .value = {{"width", 1920}, {"height", 1080}}, .category_id = std::nullopt},
      {.key = "Codec", .value = "H265", .category_id = std::nullopt},
      {.key = "GlobalSoundAlerts", .value = true, .category_id = std::nullopt},
      {.key = "ClipSavedSoundAlerts", .value = true, .category_id = std::nullopt},
      {.key = "AudioNotificationVolume", .value = 0.65, .category_id = std::nullopt},
      {.key = "ClipSound", .value = "default", .category_id = std::nullopt},
      {.key = "ClipSoundPath", .value = nullptr, .category_id = std::nullopt},
      {.key = "Hotkeys",
       .value = {{"hotkeys",
                  {{{"action", "clip;length=30"},
                    {"device", "keyboard"},
                    {"type", "short_press"},
                    {"inputs", "F8"}},
                   {{"action", "bookmark"},
                    {"device", "keyboard"},
                    {"type", "short_press"},
                    {"inputs", "F8"}}}}},
       .category_id = std::nullopt},
      {.key = "Bitrate", .value = 27.5, .category_id = "game-42"},
  });
  expect(settings.global("Bitrate") == nlohmann::json(15),
         "raw recovered bitrate number must be stored without assuming units");
  expect(settings.effective("Bitrate", "game-42") == nlohmann::json(27.5),
         "per-game value must override global value");
  expect(settings.effective("Resolution", "game-42") ==
             nlohmann::json({{"width", 1920}, {"height", 1080}}),
         "per-game reads must fall back to globals");
  expect(settings.snapshot().at("perGame").at("game-42").at("Bitrate") == 27.5,
         "settings snapshot must preserve recovered key casing");
  expect(settings.global("Codec") == nlohmann::json("H265"),
         "the recovered Medal codec value must be preserved exactly");
  expect(settings.global("AudioNotificationVolume") == nlohmann::json(0.65),
         "the traced normalized notification volume must be preserved on the recorder wire");

  settings.delete_custom_game_settings("game-42", {"Bitrate"});
  expect(settings.effective("Bitrate", "game-42") == nlohmann::json(15),
         "deleting an override must reveal the global value");
  settings.apply({{.key = "ShowCursor", .value = false, .category_id = "game-42"}});
  settings.delete_custom_game_settings(std::vector<std::string>{"game-42"});
  expect(!settings.snapshot().at("perGame").contains("game-42"), "category deletion must be complete");

  expect(native_port::SettingsStore::is_recovered_key("SelectedGPUDevice"),
         "all recovered setting keys must remain available");
  expect(!native_port::SettingsStore::is_recovered_key("selectedGpuDevice"),
         "setting names are case-sensitive");
  expect_throws<std::invalid_argument>([&settings] {
    settings.apply({{.key = "GuessedSetting", .value = true, .category_id = std::nullopt}});
  }, "unknown settings must not be guessed into the protocol");
  expect_throws<std::invalid_argument>([&settings] {
    settings.apply({{.key = "Bitrate", .value = "15 Mbps", .category_id = std::nullopt}});
  }, "bitrate must preserve the recovered numeric DTO shape");
  expect_throws<std::invalid_argument>([&settings] {
    settings.apply({{.key = "Codec", .value = "VP9", .category_id = std::nullopt}});
  }, "unknown codecs must not be accepted as successful settings");
  expect_throws<std::invalid_argument>([&settings] {
    settings.apply({{.key = "AudioNotificationVolume", .value = 65, .category_id = std::nullopt}});
  }, "the UI percentage must not be mistaken for the normalized recorder wire value");

  expect(native_port::parse_video_codec("H264") == native_port::VideoCodec::h264,
         "H264 must map from the recovered Medal spelling");
  expect(native_port::parse_video_codec("H265") == native_port::VideoCodec::hevc,
         "H265 must map to the HEVC native codec");
  expect(native_port::parse_video_codec("AV1") == native_port::VideoCodec::av1,
         "AV1 must map from the recovered Medal spelling");
}

void test_clip_action() {
  const nlohmann::json recovered = nlohmann::json::array(
      {{{"action", "clip;length=30"},
        {"device", "keyboard"},
        {"type", "short_press"},
        {"inputs", "F8"}},
       {{"action", "bookmark"},
        {"device", "keyboard"},
        {"type", "short_press"},
        {"inputs", "F8"}}});
  const auto direct = native_port::parse_clip_hotkeys(recovered);
  expect(direct.size() == 1 && direct.front().action == "clip;length=30" &&
             direct.front().inputs == "F8" && direct.front().duration == 30s,
         "the recovered clip;length=N action must parse without treating bookmark as a clip binding");
  const auto wrapped = native_port::parse_clip_hotkeys({{"hotkeys", recovered}});
  expect(wrapped.size() == 1 && wrapped.front().duration == 30s,
         "the observed settings-RPC Hotkeys wrapper must parse");
  expect_throws<std::invalid_argument>(
      [] { (void)native_port::parse_clip_hotkeys({{"hotkeys", "F8"}}); },
      "a malformed Hotkeys wrapper must be rejected");
  expect_throws<std::invalid_argument>(
      [] {
        (void)native_port::parse_clip_hotkeys(nlohmann::json::array(
            {{{"action", "clip;length=0"},
              {"device", "keyboard"},
              {"type", "short_press"},
              {"inputs", "F8"}}}));
      },
      "a clip length outside the replay capacity must be rejected");
}

void test_capture_settings() {
  native_port::SettingsStore settings;
  settings.apply({
      {.key = "Resolution", .value = {{"width", 2560}, {"height", 1440}}, .category_id = std::nullopt},
      {.key = "TargetFPS", .value = 120, .category_id = std::nullopt},
      {.key = "Bitrate", .value = 30, .category_id = std::nullopt},
      {.key = "Codec", .value = "H265", .category_id = std::nullopt},
      {.key = "ShowCursor", .value = false, .category_id = std::nullopt},
      {.key = "Bitrate", .value = 7, .category_id = "game-7"},
      {.key = "Codec", .value = "H264", .category_id = "game-7"},
  });
  const auto global = native_port::capture_configuration_from_settings(settings);
  expect(global.width == 2560 && global.height == 1440 && global.frames_per_second == 120,
         "official resolution and FPS settings must map directly to native capture");
  expect(global.bitrate_bits_per_second == 30'000'000 &&
             global.video_codec == native_port::VideoCodec::hevc && !global.show_cursor,
         "the client Mbps, H265 and cursor values must map to native encoder units");
  const auto game = native_port::capture_configuration_from_settings(settings, "game-7");
  expect(game.bitrate_bits_per_second == 7'000'000 &&
             game.video_codec == native_port::VideoCodec::h264 && game.width == 2560,
         "per-game capture settings must override globals and inherit missing values");

  struct BitrateCase final {
    double wire_value;
    std::uint64_t expected_bits_per_second;
  };
  for (const auto test : std::array{
           BitrateCase{1.0, 1'000'000}, BitrateCase{7.0, 7'000'000},
           BitrateCase{15.0, 15'000'000}, BitrateCase{27.5, 27'500'000},
           BitrateCase{100.0, 100'000'000}}) {
    native_port::SettingsStore fixed;
    fixed.apply({{.key = "Bitrate", .value = test.wire_value, .category_id = std::nullopt}});
    expect(native_port::capture_configuration_from_settings(fixed).bitrate_bits_per_second ==
               test.expected_bits_per_second,
           "pinned client/wire/recorder bitrate conversion must remain decimal Mbps to bps");
  }
}

void test_capture_geometry() {
  const auto ultrawide = native_port::fit_capture_geometry(2394, 1000, 2, 1920, 1080);
  expect(ultrawide.source_width_pixels == 4788 && ultrawide.source_height_pixels == 2000,
         "source points and ScreenCaptureKit pointPixelScale must remain independently observable");
  expect(ultrawide.requested_width == 1920 && ultrawide.requested_height == 1080 &&
             ultrawide.encoded_width == 1920 && ultrawide.encoded_height == 1080,
         "the Medal Resolution setting must describe the final encoded canvas");
  expect(ultrawide.fitted_content_width == 1920 && ultrawide.fitted_content_height == 802 &&
             ultrawide.vertical_padding == 278,
         "the observed 1920x802 dimensions must be identified as fitted source content, not output resolution");

  const auto sixteen_nine = native_port::fit_capture_geometry(1920, 1080, 1, 1280, 720);
  expect(sixteen_nine.fitted_content_width == 1280 && sixteen_nine.fitted_content_height == 720 &&
             sixteen_nine.horizontal_padding == 0 && sixteen_nine.vertical_padding == 0,
         "matching aspect ratios must require no padding");
  expect_throws<std::invalid_argument>([] {
    (void)native_port::fit_capture_geometry(1920, 1080, 1, 1919, 1080);
  }, "odd 4:2:0 encoder canvases must be rejected rather than silently rounded");
}

void test_replay_store() {
  const auto configuration = bytes(4, 0x67);
  native_port::ReplayStore store({.maximum_duration = 10s, .maximum_bytes = 1'000});
  store.push(packet(1'000'000'000, true, 1, native_port::TrackKind::video, 10, configuration));
  store.push(packet(1'500'000'000, false));
  store.push(packet(1'600'000'000, false, 1, native_port::TrackKind::mixed_audio));
  store.push(packet(2'000'000'000, true, 1, native_port::TrackKind::video, 10, configuration));
  store.push(packet(2'500'000'000, false));
  store.push(packet(2'450'000'000, false, 1, native_port::TrackKind::microphone_audio));

  const auto snapshot = store.snapshot(900ms);
  expect(snapshot.has_value(), "a replay with a retained decoder configuration must export");
  expect(snapshot->start_monotonic_nanoseconds == 1'000'000'000,
         "fast export must start at the keyframe preceding the requested interval");
  expect(snapshot->limitation == "fast export includes keyframe preroll",
         "keyframe preroll must be explicit, not silently reported as exact duration");
  expect(snapshot->packets.front()->data == store.snapshot(900ms)->packets.front()->data,
         "repeated snapshots must share encoded payload ownership instead of copying frame bytes");
  expect(std::is_sorted(snapshot->packets.begin(), snapshot->packets.end(),
                        [](const auto& left, const auto& right) {
                          return left->monotonic_nanoseconds < right->monotonic_nanoseconds;
                        }),
         "bounded cross-track callback reordering must produce a monotonic snapshot");

  native_port::ReplayStore short_store({.maximum_duration = 800ms, .maximum_bytes = 1'000});
  short_store.push(packet(0, true, 1, native_port::TrackKind::video, 10, configuration));
  short_store.push(packet(500'000'000, false));
  short_store.push(packet(1'000'000'000, true, 1, native_port::TrackKind::video, 10, configuration));
  short_store.push(packet(1'500'000'000, false));
  expect(short_store.retained_duration() == 500ms && short_store.packet_count() == 2,
         "duration eviction must realign the front to a decodable video keyframe");

  short_store.push(packet(2'000'000'000, true, 2, native_port::TrackKind::video, 10, configuration));
  short_store.push(packet(2'250'000'000, false, 2));
  const auto new_generation = short_store.snapshot(5s);
  expect(new_generation && new_generation->configuration_generation == 2 &&
             new_generation->packets.front()->configuration_generation == 2,
         "exports must not cross an encoder configuration generation boundary");

  native_port::ReplayStore byte_store({.maximum_duration = 10s, .maximum_bytes = 25});
  byte_store.push(packet(0, true, 1, native_port::TrackKind::video, 10, configuration));
  byte_store.push(packet(10, true, 1, native_port::TrackKind::video, 10, configuration));
  expect(byte_store.occupied_bytes() <= 25, "byte limit must be enforced");

  expect_throws<std::invalid_argument>([&store] { store.push(packet(100, false)); },
                                       "packets outside the bounded reorder window must be rejected");
  expect_throws<std::invalid_argument>([&store] {
    store.push(packet(3'000'000'000, true, 1, native_port::TrackKind::video, 10, nullptr));
  }, "a video keyframe without decoder configuration must be rejected");

  native_port::ReplayStore idle_store({.maximum_duration = 30s, .maximum_bytes = 1'000});
  idle_store.push(packet(0, true, 1, native_port::TrackKind::video, 10, configuration));
  idle_store.push(packet(1'000'000'000, false));
  idle_store.push(packet(2'000'000'000, true, 1, native_port::TrackKind::video, 10, configuration));
  idle_store.push(packet(3'000'000'000, false));
  idle_store.advance_clock(34'000'000'000);
  const auto idle_snapshot = idle_store.snapshot(30s);
  expect(idle_snapshot && idle_snapshot->start_monotonic_nanoseconds == 2'000'000'000,
         "an idle capture interval must retain the latest independently decodable GOP");
  expect(idle_snapshot->observed_end_monotonic_nanoseconds == 34'000'000'000 &&
             idle_snapshot->actual_duration >= 30s && idle_snapshot->actual_duration < 32s,
         "idle retention must use the capture timestamp and remain within one GOP of the request");
  expect(idle_snapshot->limitation.find("entirely idle") != std::string::npos,
         "idle replay duration extension must be reported explicitly");
}

}  // namespace

int main() {
  struct TestCase final {
    std::string_view name;
    void (*function)();
  };
  const std::vector<TestCase> tests{
      {"media_time", test_media_time},
      {"json_rpc", test_json_rpc},
      {"settings", test_settings},
      {"clip_action", test_clip_action},
      {"capture_settings", test_capture_settings},
      {"capture_geometry", test_capture_geometry},
      {"replay_store", test_replay_store},
  };

  std::size_t passed = 0;
  for (const auto& test : tests) {
    try {
      test.function();
      ++passed;
      std::cout << "PASS " << test.name << '\n';
    } catch (const std::exception& error) {
      std::cerr << "FAIL " << test.name << ": " << error.what() << '\n';
      return 1;
    }
  }
  std::cout << "PASS native_port_core_tests " << passed << "/" << tests.size() << '\n';
  return 0;
}
