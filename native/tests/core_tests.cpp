#include "native_port/json_rpc.hpp"
#include "native_port/media_time.hpp"
#include "native_port/replay_store.hpp"
#include "native_port/settings_store.hpp"
#include "native_port/video_codec.hpp"

#include <chrono>
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
      {.key = "Hotkeys", .value = {{"saveClip", "F8"}}, .category_id = std::nullopt},
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

  expect(native_port::parse_video_codec("H264") == native_port::VideoCodec::h264,
         "H264 must map from the recovered Medal spelling");
  expect(native_port::parse_video_codec("H265") == native_port::VideoCodec::hevc,
         "H265 must map to the HEVC native codec");
  expect(native_port::parse_video_codec("AV1") == native_port::VideoCodec::av1,
         "AV1 must map from the recovered Medal spelling");
}

void test_replay_store() {
  const auto configuration = bytes(4, 0x67);
  native_port::ReplayStore store({.maximum_duration = 10s, .maximum_bytes = 1'000});
  store.push(packet(1'000'000'000, true, 1, native_port::TrackKind::video, 10, configuration));
  store.push(packet(1'500'000'000, false));
  store.push(packet(1'600'000'000, false, 1, native_port::TrackKind::mixed_audio));
  store.push(packet(2'000'000'000, true, 1, native_port::TrackKind::video, 10, configuration));
  store.push(packet(2'500'000'000, false));

  const auto snapshot = store.snapshot(900ms);
  expect(snapshot.has_value(), "a replay with a retained decoder configuration must export");
  expect(snapshot->start_monotonic_nanoseconds == 1'000'000'000,
         "fast export must start at the keyframe preceding the requested interval");
  expect(snapshot->limitation == "fast export includes keyframe preroll",
         "keyframe preroll must be explicit, not silently reported as exact duration");
  expect(snapshot->packets.front()->data == store.snapshot(900ms)->packets.front()->data,
         "repeated snapshots must share encoded payload ownership instead of copying frame bytes");

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
                                       "out-of-order monotonic packets must be rejected");
  expect_throws<std::invalid_argument>([&store] {
    store.push(packet(3'000'000'000, true, 1, native_port::TrackKind::video, 10, nullptr));
  }, "a video keyframe without decoder configuration must be rejected");
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
