#include "native_port/json_rpc.hpp"
#include "native_port/capture_session.hpp"
#include "native_port/capture_settings.hpp"
#include "native_port/mp4_writer.hpp"
#include "native_port/platform_adapter.hpp"
#include "native_port/replay_store.hpp"
#include "native_port/settings_store.hpp"

#include <boost/asio/connect.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/steady_timer.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/websocket.hpp>

#include <atomic>
#include <algorithm>
#include <array>
#include <cerrno>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cctype>
#include <csignal>
#include <cstdlib>
#include <deque>
#include <exception>
#include <fstream>
#include <functional>
#include <filesystem>
#include <iostream>
#include <iomanip>
#include <map>
#include <mutex>
#include <optional>
#include <random>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include <sys/types.h>
#include <unistd.h>

namespace {

namespace asio = boost::asio;
namespace beast = boost::beast;
namespace websocket = beast::websocket;
using tcp = asio::ip::tcp;

constexpr std::size_t kMaximumFrameBytes = 1024U * 1024U;
constexpr const char* kScreenCaptureCategoryId = "1b7CpvXVSuB";
constexpr const char* kScreenCaptureCategoryName = "Screen Capture";

[[nodiscard]] bool is_uuid(std::string_view value) noexcept {
  if (value.size() != 36) {
    return false;
  }
  for (std::size_t index = 0; index < value.size(); ++index) {
    if (index == 8 || index == 13 || index == 18 || index == 23) {
      if (value[index] != '-') {
        return false;
      }
      continue;
    }
    const char character = value[index];
    const bool hexadecimal = (character >= '0' && character <= '9') ||
                             (character >= 'a' && character <= 'f') ||
                             (character >= 'A' && character <= 'F');
    if (!hexadecimal) {
      return false;
    }
  }
  return true;
}

[[nodiscard]] std::string make_uuid() {
  std::array<unsigned char, 16> bytes{};
  std::random_device random;
  for (auto& byte : bytes) {
    byte = static_cast<unsigned char>(random());
  }
  bytes[6] = static_cast<unsigned char>((bytes[6] & 0x0fU) | 0x40U);
  bytes[8] = static_cast<unsigned char>((bytes[8] & 0x3fU) | 0x80U);
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (std::size_t index = 0; index < bytes.size(); ++index) {
    if (index == 4 || index == 6 || index == 8 || index == 10) {
      output << '-';
    }
    output << std::setw(2) << static_cast<unsigned int>(bytes[index]);
  }
  return output.str();
}

// Medal's recovered target-process notification base64-encodes processName
// at the renderer boundary.  Keep the wire contract intact while decoding it
// before matching native PID/bundle identities.  Plain legacy names are left
// unchanged.
[[nodiscard]] std::string decode_wire_process_name(const std::string& value) {
  if (value.empty() || value.size() % 4 != 0) {
    return value;
  }
  constexpr std::string_view alphabet =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string decoded;
  decoded.reserve((value.size() / 4) * 3);
  int accumulator = 0;
  int bits = -8;
  for (const auto character : value) {
    if (character == '=') {
      break;
    }
    const auto position = alphabet.find(character);
    if (position == std::string_view::npos) {
      return value;
    }
    accumulator = (accumulator << 6) | static_cast<int>(position);
    bits += 6;
    if (bits >= 0) {
      decoded.push_back(static_cast<char>((accumulator >> bits) & 0xff));
      bits -= 8;
    }
  }
  if (decoded.empty() || std::any_of(decoded.begin(), decoded.end(), [](unsigned char character) {
        return character < 0x20 || character > 0x7e;
      })) {
    return value;
  }
  return decoded;
}

struct Options final {
  std::uint16_t electron_port{0};
  pid_t parent_pid{0};
  std::string environment;
};

Options parse_options(int argc, char** argv) {
  Options options;
  for (int index = 1; index < argc; ++index) {
    const std::string_view argument(argv[index]);
    const auto value = [&]() -> std::string_view {
      if (index + 1 >= argc) {
        throw std::invalid_argument("missing value for " + std::string(argument));
      }
      return argv[++index];
    };
    if (argument == "--electronPort") {
      const auto text = value();
      unsigned int parsed = 0;
      const auto [end, error] = std::from_chars(text.data(), text.data() + text.size(), parsed);
      if (error != std::errc{} || end != text.data() + text.size() || parsed == 0 || parsed > 65535) {
        throw std::invalid_argument("invalid --electronPort");
      }
      options.electron_port = static_cast<std::uint16_t>(parsed);
    } else if (argument == "--parentPid") {
      const auto text = value();
      int parsed = 0;
      const auto [end, error] = std::from_chars(text.data(), text.data() + text.size(), parsed);
      if (error != std::errc{} || end != text.data() + text.size() || parsed <= 1) {
        throw std::invalid_argument("invalid --parentPid");
      }
      options.parent_pid = static_cast<pid_t>(parsed);
    } else if (argument == "--environment") {
      options.environment = value();
    } else if (argument == "--wsComms") {
      continue;
    } else {
      throw std::invalid_argument("unknown command-line argument: " + std::string(argument));
    }
  }
  if (options.electron_port == 0 || options.parent_pid <= 1 || options.environment.empty()) {
    throw std::invalid_argument("--electronPort, --parentPid and --environment are required");
  }
  return options;
}

nlohmann::json id_json(const native_port::JsonRpcId& id) {
  return std::visit([](const auto& value) { return nlohmann::json(value); }, id);
}

class HelperSession final {
 public:
  explicit HelperSession(Options options)
      : options_(std::move(options)),
        adapter_(native_port::make_platform_adapter()),
        codec_(kMaximumFrameBytes),
        replay_(native_port::ReplayLimits{.maximum_duration = std::chrono::seconds(120),
                                         .maximum_bytes = 512U * 1024U * 1024U}) {
    capture_ = native_port::make_capture_session(
        [this](nlohmann::json event) {
          handle_capture_event(std::move(event));
        },
        [this](std::shared_ptr<const native_port::EncodedPacket> packet) {
          try {
            replay_.push(std::move(packet));
          } catch (const std::exception& error) {
            std::scoped_lock lock(capture_event_mutex_);
            last_capture_event_ = {{"schemaVersion", 1},
                                   {"state", "failed"},
                                   {"reason", "replay_buffer_rejected_packet"},
                                   {"lastError", error.what()}};
          }
        },
        [this](std::int64_t monotonic_nanoseconds) {
          replay_.advance_clock(monotonic_nanoseconds);
        });
  }

  int run() {
    std::jthread network([this] {
      try {
        network_run();
      } catch (...) {
        {
          std::scoped_lock lock(network_error_mutex_);
          network_error_ = std::current_exception();
        }
        running_.store(false, std::memory_order_release);
      }
    });
    auto next_auto_detection = std::chrono::steady_clock::now();
    while (running_.load(std::memory_order_acquire)) {
      drain_main_actions();
      adapter_->pump_events();
      capture_->pump_events();
      if (handshake_complete_ && std::chrono::steady_clock::now() >= next_auto_detection) {
        auto_detect_running_game();
        next_auto_detection = std::chrono::steady_clock::now() + std::chrono::seconds(1);
      }
      drain_clip_actions();
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    drain_main_actions();
    network.join();
    std::exception_ptr error;
    {
      std::scoped_lock lock(network_error_mutex_);
      error = network_error_;
    }
    if (error) {
      std::rethrow_exception(error);
    }
    return 0;
  }

 private:
  struct ClipRegistration final {
    std::string uuid;
    std::string request_id;
    std::filesystem::path clip_location;
    std::filesystem::path journal_path;
    std::int64_t created_at_milliseconds{0};
    double export_duration_seconds{0};
    std::string state{"pending"};
    std::string error;
    nlohmann::json content_id{nullptr};
  };

  void network_run() {
    const char* secret = std::getenv("NATIVE_PORT_SESSION_SECRET");
    if (secret == nullptr || std::string_view(secret).size() < 32U) {
      throw std::runtime_error("missing per-launch native port session secret");
    }

    std::jthread parent_monitor([this](std::stop_token stop) {
      while (!stop.stop_requested()) {
        if (::getppid() != options_.parent_pid && ::kill(options_.parent_pid, 0) != 0 && errno == ESRCH) {
          std::raise(SIGTERM);
          return;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
      }
    });

    asio::io_context context;
    tcp::resolver resolver(context);
    websocket::stream<tcp::socket> socket(context);
    socket.read_message_max(kMaximumFrameBytes);
    socket.set_option(websocket::stream_base::timeout::suggested(beast::role_type::client));
    socket.set_option(websocket::stream_base::decorator([secret = std::string(secret)](websocket::request_type& request) {
      request.set("x-native-port-secret", secret);
      request.set(beast::http::field::user_agent, "native-medal-recorder/0.1");
    }));

    const auto host = std::string("127.0.0.1");
    const auto port = std::to_string(options_.electron_port);
    const auto endpoints = resolver.resolve(host, port);
    asio::connect(socket.next_layer(), endpoints);
    socket.handshake(host + ":" + port, "/");
    socket_ = &socket;

    send_request("native-port:handshake", "handshake", {{"supportedVersions", {1}}, {"preferredVersion", 1}});

    // Do not gate WebSocket reads on tcp::socket::available(). Beast may read
    // more than one frame from TCP and retain the next frame in its own input
    // buffer. Polling only the underlying socket can therefore strand a valid
    // adjacent RPC until unrelated traffic arrives.
    beast::flat_buffer buffer;
    asio::steady_timer action_timer(context);
    std::function<void()> begin_read;
    std::function<void()> schedule_action_drain;
    begin_read = [&] {
      socket.async_read(buffer, [&](const boost::system::error_code& error, std::size_t) {
        if (error == websocket::error::closed) {
          context.stop();
          return;
        }
        if (error) {
          throw boost::system::system_error(error);
        }
        const auto message = beast::buffers_to_string(buffer.data());
        buffer.consume(buffer.size());
        if (!handle_message(message)) {
          context.stop();
          return;
        }
        begin_read();
      });
    };
    schedule_action_drain = [&] {
      drain_network_actions();
      action_timer.expires_after(std::chrono::milliseconds(5));
      action_timer.async_wait([&](const boost::system::error_code& error) {
        if (!error) {
          schedule_action_drain();
        } else if (error != asio::error::operation_aborted) {
          throw boost::system::system_error(error);
        }
      });
    };
    begin_read();
    schedule_action_drain();
    context.run();
    parent_monitor.request_stop();
    socket_ = nullptr;
    running_.store(false, std::memory_order_release);
  }

  void dispatch_to_main(std::function<void()> action) {
    std::scoped_lock lock(main_actions_mutex_);
    main_actions_.push_back(std::move(action));
  }

  void drain_main_actions() {
    std::deque<std::function<void()>> actions;
    {
      std::scoped_lock lock(main_actions_mutex_);
      actions.swap(main_actions_);
    }
    for (auto& action : actions) {
      try {
        action();
      } catch (const std::exception& error) {
        std::scoped_lock lock(capture_event_mutex_);
        last_capture_event_ = {{"schemaVersion", 1},
                               {"state", "failed"},
                               {"reason", "main_thread_capture_action_failed"},
                               {"lastError", error.what()}};
      }
    }
  }

  void dispatch_to_network(std::function<void()> action) {
    std::scoped_lock lock(network_actions_mutex_);
    network_actions_.push_back(std::move(action));
  }

  void handle_capture_event(nlohmann::json event) {
    const auto network_event = event;
    {
      std::scoped_lock lock(capture_event_mutex_);
      last_capture_event_ = std::move(event);
    }
    dispatch_to_network([this, network_event] {
      const auto state = network_event.value("state", std::string{});
      const auto reason = network_event.value("reason", std::string{});
      if (state == "capturing" && reason == "capture_started") {
        if (capture_announced_) {
          return;
        }
        capture_announced_ = true;
        // ScreenCaptureKit can report the style of an application-including
        // filter as display. The pending target flag is authoritative for
        // the original Medal target-process route.
        if (target_capture_pending_ && targeted_process_) {
          auto target = target_process_payload("success");
          send_request("native-port:target-process:" +
                           std::to_string(++target_process_request_sequence_),
                       "targetProcess", std::move(target));
          target_capture_pending_ = false;
          announce_target_capture_category();
        } else {
          capture_session_id_ = make_uuid();
          send_request("native-port:capture-started:" +
                           std::to_string(++capture_event_sequence_),
                       "captureStarted",
                       {{"categoryId", kScreenCaptureCategoryId},
                        {"categoryName", kScreenCaptureCategoryName}});
          send_request("native-port:game-state:" +
                           std::to_string(++capture_event_sequence_),
                       "gameState",
                       {{"sessionId", capture_session_id_},
                        {"contexts",
                         {{{"type", "CATEGORY"},
                           {"externalId", kScreenCaptureCategoryId},
                           {"members", nlohmann::json::array()},
                           {"metadata",
                            {{"name", kScreenCaptureCategoryName},
                             {"recording", true}}}}}}});
          announced_capture_category_id_ = kScreenCaptureCategoryId;
          announced_capture_category_name_ = kScreenCaptureCategoryName;
        }
        return;
      }
      if (state == "starting" && reason == "microphone_permission_denied") {
        send_request("native-port:recorder-error:" + std::to_string(++capture_event_sequence_),
                     "recorderError",
                     {{"type", "audio-device-access-denied"},
                      {"params", {{"deviceName", "Microphone"}, {"deviceType", "capture"}}}});
        return;
      }
      if (state == "capturing" && reason == "microphone_encoder_failed") {
        send_request("native-port:recorder-error:" + std::to_string(++capture_event_sequence_),
                     "recorderError",
                     {{"type", "audio-device-access-denied"},
                      {"params", {{"deviceName", "Microphone"}, {"deviceType", "capture"}}},
                      {"fallback", network_event.value("lastError", "Microphone AAC encoder failed")}});
        return;
      }
      if (state == "failed") {
        const auto failure = network_event.value("lastError", reason);
        nlohmann::json notification = {{"type", "recorder-failure"},
                                       {"fallback", failure}};
        if (reason == "microphone_permission_required") {
          notification = {{"type", "audio-device-access-denied"},
                          {"params", {{"deviceName", "Microphone"}, {"deviceType", "capture"}}},
                          {"fallback", failure}};
        } else if (reason == "screen_recording_permission_required") {
          notification = {{"type", "screen-recording-permission-required"},
                          {"fallback", failure}};
        }
        send_request("native-port:recorder-error:" + std::to_string(++capture_event_sequence_),
                     "recorderError", std::move(notification));
      }
      if (state != "stopped" && state != "failed" && state != "cancelled") {
        return;
      }
      if (capture_announced_ && !announced_capture_category_id_.empty()) {
        send_request("native-port:game-state:" +
                         std::to_string(++capture_event_sequence_),
                     "gameState",
                     {{"sessionId", capture_session_id_},
                      {"contexts", nlohmann::json::array()}});
        send_request("native-port:capture-stopped:" +
                         std::to_string(++capture_event_sequence_),
                     "captureStopped",
                     {{"categoryId", announced_capture_category_id_},
                      {"categoryName", announced_capture_category_name_}});
      }
      if (state == "failed" && targeted_process_) {
        auto target = target_process_payload("failed", network_event.value("lastError", reason));
        send_request("native-port:target-process:" +
                         std::to_string(++target_process_request_sequence_),
                       "targetProcess", std::move(target));
        target_capture_pending_ = false;
        // Do not keep a dead target latched after ScreenCaptureKit reports
        // source disappearance.  The next automatic scan may select a
        // different running game, while the failed target remains visible in
        // the client as an honest failure transition.
        targeted_process_.reset();
        target_game_request_id_.clear();
      }
      capture_announced_ = false;
      announced_capture_category_id_.clear();
      announced_capture_category_name_.clear();
      capture_session_id_.clear();
      target_game_category_id_.clear();
      target_game_category_name_.clear();
    });
  }

  void announce_target_capture_category() {
    if (!targeted_process_ || target_game_category_id_.empty() ||
        target_game_category_name_.empty() || !announced_capture_category_id_.empty()) {
      return;
    }
    capture_session_id_ = make_uuid();
    announced_capture_category_id_ = target_game_category_id_;
    announced_capture_category_name_ = target_game_category_name_;
    const nlohmann::json category = {
        {"categoryId", announced_capture_category_id_},
        {"categoryName", announced_capture_category_name_},
    };
    send_request("native-port:game-started:" + std::to_string(++capture_event_sequence_),
                 "gameStarted",
                 { {"categoryId", announced_capture_category_id_},
                   {"categoryName", announced_capture_category_name_},
                   {"overlayInjectedMode", false} });
    send_request("native-port:capture-started:" + std::to_string(++capture_event_sequence_),
                 "captureStarted", category);
    send_request("native-port:game-state:" + std::to_string(++capture_event_sequence_),
                 "gameState",
                 { {"sessionId", capture_session_id_},
                   {"contexts", {{{"type", "CATEGORY"},
                                  {"externalId", announced_capture_category_id_},
                                  {"members", nlohmann::json::array()},
                                  {"metadata", {{"name", announced_capture_category_name_},
                                                  {"recording", true}}}}}} });
  }

  void drain_network_actions() {
    std::deque<std::function<void()>> actions;
    {
      std::scoped_lock lock(network_actions_mutex_);
      actions.swap(network_actions_);
    }
    for (auto& action : actions) {
      action();
    }
  }

  void enqueue_clip_action(const native_port::ClipHotkeyBinding& binding) {
    std::scoped_lock lock(clip_actions_mutex_);
    clip_actions_.push_back(binding);
  }

  void set_hotkey_result(nlohmann::json result) {
    std::scoped_lock lock(hotkey_result_mutex_);
    last_hotkey_result_ = std::move(result);
  }

  void drain_clip_actions() {
    std::deque<native_port::ClipHotkeyBinding> actions;
    {
      std::scoped_lock lock(clip_actions_mutex_);
      actions.swap(clip_actions_);
    }
    for (const auto& action : actions) {
      try {
        const auto snapshot = replay_.snapshot(action.duration);
        if (!snapshot) {
          throw std::runtime_error("no decodable replay snapshot is available for the clip hotkey");
        }
        const auto uuid = make_uuid();
        const auto output_directory = profile_root() / "Clips";
        std::filesystem::create_directories(output_directory);
        std::filesystem::permissions(output_directory, std::filesystem::perms::owner_all,
                                     std::filesystem::perm_options::replace);
        const auto output = output_directory / (uuid + ".mp4");
        const auto temporary = output.string() + ".partial-" + std::to_string(::getpid());
        const auto write_result = native_port::write_mp4(temporary, *snapshot);
        std::filesystem::rename(temporary, output);
        const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(
                             std::chrono::system_clock::now().time_since_epoch())
                             .count();
        const auto duration_seconds =
            static_cast<double>(write_result.duration.count()) / 1'000'000'000.0;
        auto capture_diagnostics = capture_->status();
        capture_diagnostics["routing"] = {
            {"targetCapturePending", target_capture_pending_},
            {"captureAnnounced", capture_announced_},
        };
        if (targeted_process_) {
          capture_diagnostics["nativeTarget"] = {
              {"pid", targeted_process_->pid},
              {"applicationName", targeted_process_->application_name},
              {"executableName", targeted_process_->executable_name},
              {"bundleIdentifier", targeted_process_->bundle_identifier},
              {"screenCaptureApplicationName", targeted_process_->screen_capture_application_name},
              {"windowIds", [&] {
                 nlohmann::json ids = nlohmann::json::array();
                 for (const auto& window : targeted_process_->windows) {
                   ids.push_back(window.window_id);
                 }
                 return ids;
               }()},
          };
        } else {
          capture_diagnostics["nativeTarget"] = nullptr;
        }
        const auto hotkey_result = nlohmann::json{
            {"action", action.action},
            {"inputs", action.inputs},
            {"uuid", uuid},
            {"fileName", output.filename().string()},
            {"state", "registration_pending"},
            {"requestedDurationSeconds", action.duration.count()},
            {"actualDurationNanoseconds", write_result.duration.count()},
            {"videoPacketCount", write_result.video_packets},
            {"systemAudioPacketCount", write_result.system_audio_packets},
            {"microphonePacketCount", write_result.microphone_packets},
            {"captureDiagnostics", capture_diagnostics},
        };
        set_hotkey_result(hotkey_result);
        persist_hotkey_diagnostics(uuid, hotkey_result);
        // The imported client already resolved the running target through its
        // authenticated game-request/category path.  Carry that same category
        // into contentCreate; otherwise the original library quite correctly
        // files the clip under Discover even though the active-session UI said
        // Minecraft.  Snapshot the identity before handing the request to the
        // network queue because source-disappearance cleanup clears these
        // members asynchronously.
        const auto category_id = !target_game_category_id_.empty()
                                     ? std::optional<std::string>(target_game_category_id_)
                                     : (!announced_capture_category_id_.empty()
                                            ? std::optional<std::string>(announced_capture_category_id_)
                                            : std::nullopt);
        const auto process_name = targeted_process_
                                      ? std::optional<std::string>(
                                            !targeted_process_->application_name.empty()
                                                ? targeted_process_->application_name
                                                : targeted_process_->executable_name)
                                      : std::nullopt;
        nlohmann::json audio_streams = nlohmann::json::array();
        // Medal's edit path passes these values back to ffmpeg as absolute
        // stream indexes (`0:<index>`), not indexes within the audio-only
        // array.  The MP4 writer always emits video first, then audio tracks
        // in mixed/game/microphone order, so preserve that exact container
        // ordering here.  Sending 0,1 for a video+PC+mic file accidentally
        // filtered the video stream and left the original PC audio audible.
        std::size_t next_audio_stream_index = 1;  // stream 0 is the video track
        const auto append_audio_stream = [&](native_port::TrackKind track, std::string title) {
          const auto found = std::find_if(snapshot->packets.begin(), snapshot->packets.end(),
                                          [track](const auto& packet) { return packet->track == track; });
          if (found != snapshot->packets.end()) {
            audio_streams.push_back({{"index", next_audio_stream_index++}, {"title", std::move(title)}});
          }
        };
        // These are the source names the imported Medal client uses when it
        // builds `metadata.audioStreams` from ffprobe.  Keeping them in the
        // contentCreate metadata makes its normal Audio menu useful instead
        // of falling back to “Audio Stream #N”.
        append_audio_stream(native_port::TrackKind::mixed_audio, "PC Audio");
        append_audio_stream(native_port::TrackKind::game_audio, "Game Audio");
        append_audio_stream(native_port::TrackKind::microphone_audio, "Microphone");
        dispatch_to_network([this, uuid, output, now, duration_seconds, category_id, process_name,
                             audio_streams = std::move(audio_streams)] {
          (void)begin_registration(uuid, output, now, duration_seconds, category_id, process_name,
                                   audio_streams);
        });
      } catch (const std::exception& error) {
        set_hotkey_result({{"action", action.action},
                           {"inputs", action.inputs},
                           {"state", "failed"},
                           {"error", error.what()}});
      }
    }
  }

  [[nodiscard]] native_port::CaptureConfiguration capture_configuration(const nlohmann::json& params) const {
    std::optional<std::string> category;
    if (params.contains("categoryId") && !params.at("categoryId").is_null()) {
      category = params.at("categoryId").get<std::string>();
      if (category->empty()) {
        throw std::invalid_argument("categoryId must be null or a non-empty string");
      }
    }
    auto result = native_port::capture_configuration_from_settings(
        settings_, category ? std::optional<std::string_view>(*category) : std::nullopt);
    result.width = params.value("width", result.width);
    result.height = params.value("height", result.height);
    result.frames_per_second = params.value("framesPerSecond", result.frames_per_second);
    result.bitrate_bits_per_second = params.value("bitrateBitsPerSecond", result.bitrate_bits_per_second);
    if (params.contains("videoCodec")) {
      const auto codec = native_port::parse_video_codec(params.at("videoCodec").get<std::string>());
      if (!codec) {
        throw std::invalid_argument("videoCodec must be H264, H265 or AV1");
      }
      result.video_codec = *codec;
    }
    result.show_cursor = params.value("showCursor", result.show_cursor);
    // The imported client sends the recovered recorder settings on its normal
    // Desktop/Game start route; the explicit capture* fields are only present
    // in our namespaced capture self-test.  Resolve the production route from
    // those settings instead of silently falling back to video-only capture.
    // The renderer normalizes the recovered setting before it reaches this
    // helper: `allPcAudio` carries only selected output-device names and
    // `splitByProcess` carries source ids/volumes. Keep that wire shape intact
    // instead of inferring a mode from the UI label.
    const auto audio_mode = settings_.effective("AudioModeConfig", category);
    if (audio_mode && audio_mode->is_object()) {
      result.audio_mode = audio_mode->value("type", std::string{"splitByProcess"});
      result.pc_audio_enabled = audio_mode->value("pcAudioEnabled", true);
      result.system_audio_volume_percent = static_cast<std::uint32_t>(std::clamp(
          audio_mode->value("volume", 100), 0, 150));
      if (audio_mode->contains("devices") && audio_mode->at("devices").is_array()) {
        for (const auto& device : audio_mode->at("devices")) {
          if (device.is_object() && device.value("enabled", true) && device.contains("name") &&
              device.at("name").is_string()) {
            result.selected_audio_devices.push_back(device.at("name").get<std::string>());
          }
        }
      }
      if (audio_mode->contains("sources") && audio_mode->at("sources").is_array()) {
        for (const auto& source : audio_mode->at("sources")) {
          if (!source.is_object() || !source.contains("id") || !source.at("id").is_string()) {
            continue;
          }
          result.audio_sources.push_back({source.at("id").get<std::string>(),
                                         source.value("enabled", false),
                                         static_cast<std::uint32_t>(std::clamp(
                                             source.value("volume", 100), 0, 150))});
        }
      }
    }
    const auto multiple_audio_tracks = settings_.effective("MultipleAudioTracks", category);
    if (multiple_audio_tracks && multiple_audio_tracks->is_boolean()) {
      result.multiple_audio_tracks = multiple_audio_tracks->get<bool>();
    }
    const auto mic_gain = settings_.effective("MicSoundGain", category);
    if (mic_gain && mic_gain->is_number()) {
      result.microphone_volume_percent = static_cast<std::uint32_t>(std::clamp(
          mic_gain->get<double>(), 0.0, 150.0));
    }
    if (params.contains("captureSystemAudio")) {
      result.capture_system_audio = params.at("captureSystemAudio").get<bool>();
    } else {
      const auto game_audio_only = settings_.effective("GameAudioOnly", category);
      const bool game_only = game_audio_only && game_audio_only->is_boolean() &&
                             game_audio_only->get<bool>();
      bool configured_system_audio = true;
      if (audio_mode && audio_mode->is_object()) {
        const auto type = audio_mode->value("type", std::string{});
          configured_system_audio = type != "none" && type != "disabled" &&
                                  (type != "allPcAudio" || result.pc_audio_enabled);
          if (audio_mode->contains("sources") && audio_mode->at("sources").is_array()) {
            if (type == "splitByProcess") {
            // In Specific Apps mode every enabled source is meaningful. The
            // game source is supplied by the target ScreenCaptureKit stream;
            // named applications are supplied by Core Audio process taps.
            // Keep the aggregate flag true for either case so the native
            // adapter can route each source independently. It must not turn a
            // Discord/Medal-only selection into a whole-PC mix.
            configured_system_audio = std::any_of(
                audio_mode->at("sources").begin(), audio_mode->at("sources").end(),
                [](const nlohmann::json& source) {
                  return source.is_object() && source.value("enabled", true);
                });
          } else {
            configured_system_audio = std::any_of(
                audio_mode->at("sources").begin(), audio_mode->at("sources").end(),
                [](const nlohmann::json& source) {
                  return source.is_object() && source.value("enabled", true);
                });
          }
        }
      }
      // `GameAudioOnly` remains a strict process-isolation request. The
      // ScreenCaptureKit system stream is never substituted for it. For the
      // normal split-by-process route the application filter supplies the game
      // stream; all-PC mode is handled by a separate display-anchored audio
      // stream when video is targeted at a window.
      result.capture_system_audio = configured_system_audio && !game_only;
      if (game_only) {
        result.audio_mode = "gameOnly";
      }
    }
    if (params.contains("captureMicrophone")) {
      result.capture_microphone = params.at("captureMicrophone").get<bool>();
    } else {
      const auto microphone = settings_.effective("MicEnabled", category);
      // Medal's recovered default is MicEnabled=true.  The imported client
      // does not always include an unchanged default in its initial settings
      // envelope, so absence must not silently turn the native microphone
      // track off.  An explicit false (global or per-game) still wins.
      result.capture_microphone = microphone && microphone->is_boolean()
                                      ? microphone->get<bool>()
                                      : true;
    }
    if (result.capture_microphone) {
      const auto selected_microphone = settings_.effective("SelectedMicDevice", category);
      if (selected_microphone && selected_microphone->is_string()) {
        const auto name = selected_microphone->get<std::string>();
        if (!name.empty() && name != "Auto") {
          result.microphone_device_name = name;
        }
      }
    }
    result.preferred_source_kind = params.value("preferredSourceKind", result.preferred_source_kind);
    return result;
  }

  [[nodiscard]] std::uint32_t selected_display_id() const {
    std::string device_name;
    if (const auto configured = settings_.global("MonitorDeviceName");
        configured && configured->is_string()) {
      device_name = configured->get<std::string>();
    }
    if (device_name.empty()) {
      const auto displays = adapter_->active_displays(false);
      if (!displays.is_array() || displays.empty()) {
        throw std::runtime_error("no active display is available");
      }
      const auto primary = std::find_if(displays.begin(), displays.end(), [](const auto& display) {
        return display.value("IsPrimaryScreen", false);
      });
      device_name = (primary != displays.end() ? *primary : displays.front())
                        .value("DeviceName", std::string{});
    }
    constexpr std::string_view prefix = "display:";
    if (!device_name.starts_with(prefix)) {
      throw std::invalid_argument("MonitorDeviceName is not a native macOS display identifier");
    }
    std::uint32_t display_id = 0;
    const auto text = std::string_view(device_name).substr(prefix.size());
    const auto [end, error] =
        std::from_chars(text.data(), text.data() + text.size(), display_id);
    if (error != std::errc{} || end != text.data() + text.size() || display_id == 0) {
      throw std::invalid_argument("MonitorDeviceName contains an invalid display identifier");
    }
    return display_id;
  }

  void apply_screen_capture_setting(const std::vector<native_port::SettingUpdate>& updates) {
    const auto changed = std::find_if(updates.rbegin(), updates.rend(), [](const auto& update) {
      return update.key == "ScreenCaptureEnabled" && !update.category_id.has_value();
    });
    if (changed == updates.rend()) {
      return;
    }
    if (!changed->value.is_boolean()) {
      throw std::invalid_argument("ScreenCaptureEnabled must be boolean");
    }
    if (!changed->value.get<bool>()) {
      target_capture_pending_ = false;
      screen_capture_enable_pending_ = false;
      dispatch_to_main([this] { capture_->stop(); });
      return;
    }
    // The original client sends the enable flag and the recorder settings as
    // separate startup messages.  Do not start with the native default while
    // the authoritative recordingSettings response is still in flight.
    if (!recording_settings_synced_) {
      screen_capture_enable_pending_ = true;
      std::scoped_lock lock(capture_event_mutex_);
      last_capture_event_ = {{"schemaVersion", 1},
                             {"state", "waiting_for_settings"},
                             {"reason", "recording_settings_not_yet_applied"}};
      return;
    }
    target_capture_pending_ = false;
    start_configured_display_capture();
  }

  void start_configured_display_capture() {
    auto configuration = capture_configuration(nlohmann::json::object());
    configuration.preferred_source_kind = "display";
    const auto display_id = selected_display_id();
    dispatch_to_main([this, display_id, configuration] {
      capture_->start_display(display_id, configuration);
    });
  }

  [[nodiscard]] std::optional<native_port::ProcessIdentity> find_active_process(
      const nlohmann::json& data, std::string* diagnostic = nullptr) const {
    const auto process_name = data.value("processName", std::string{});
    const auto requested_class_names = data.value("className", nlohmann::json::array());
    const auto requested_caption_names = data.value("captionName", nlohmann::json::array());
    const auto canonical = [](std::string value) {
      std::string result;
      result.reserve(value.size());
      for (const auto character : value) {
        const auto unsigned_character = static_cast<unsigned char>(character);
        if (std::isalnum(unsigned_character) != 0) {
          result.push_back(static_cast<char>(std::tolower(unsigned_character)));
        }
      }
      return result;
    };
    const auto canonical_process_name = canonical(process_name);
    const auto requested_contains = [](const nlohmann::json& values, const std::string& value) {
      if (!values.is_array() || value.empty()) {
        return false;
      }
      return std::find(values.begin(), values.end(), value) != values.end();
    };
    std::optional<native_port::ProcessIdentity> best;
    int best_score = -1;
    const auto processes = adapter_->process_targets();
    for (const auto& process : processes) {
      const auto wire_name = !process.application_name.empty()
                                 ? process.application_name
                                 : (!process.screen_capture_application_name.empty()
                                        ? process.screen_capture_application_name
                                        : process.executable_name);
      int score = 0;
      if (wire_name == process_name ||
          (!canonical_process_name.empty() && canonical(wire_name) == canonical_process_name)) {
        score += 4;
      }
      if (process.executable_name == process_name ||
          process.screen_capture_application_name == process_name ||
          process.bundle_identifier == process_name ||
          (!canonical_process_name.empty() &&
           (canonical(process.executable_name) == canonical_process_name ||
            canonical(process.screen_capture_application_name) == canonical_process_name ||
            canonical(process.bundle_identifier) == canonical_process_name))) {
        score += 2;
      }
      for (const auto& class_name : process.class_names) {
        if (requested_contains(requested_class_names, class_name) ||
            std::any_of(requested_class_names.begin(), requested_class_names.end(), [&](const auto& requested) {
              return requested.is_string() &&
                     canonical(requested.template get<std::string>()) == canonical(class_name);
            })) {
          score += 3;
        }
      }
      for (const auto& caption_name : process.caption_names) {
        if (requested_contains(requested_caption_names, caption_name) ||
            std::any_of(requested_caption_names.begin(), requested_caption_names.end(), [&](const auto& requested) {
              return requested.is_string() &&
                     canonical(requested.template get<std::string>()) == canonical(caption_name);
            })) {
          score += 1;
        }
      }
      if (score > best_score) {
        best_score = score;
        best = process;
      }
    }
    if (diagnostic != nullptr) {
      *diagnostic = best_score >= 2 ? "native target matched" : "no matching native target";
    }
    return best_score >= 2 ? best : std::nullopt;
  }

  [[nodiscard]] nlohmann::json target_process_payload(const std::string& status,
                                                       const std::string& message = {}) const {
    nlohmann::json result = {
        {"status", status},
        {"gameID", ""},
        {"processName", ""},
        {"captionName", nlohmann::json::array()},
        {"className", nlohmann::json::array()},
        {"gameRequestId", target_game_request_id_},
    };
    if (targeted_process_) {
      const auto& target = *targeted_process_;
      result["processName"] = !target.application_name.empty()
                                   ? target.application_name
                                   : (!target.screen_capture_application_name.empty()
                                          ? target.screen_capture_application_name
                                          : target.executable_name);
      // The recovered targetProcess response uses scalar class/caption
      // fields, even though getActiveProcesses exposes arrays. Keep the
      // typed vectors native-side and flatten only at this protocol boundary.
      result["captionName"] = target.caption_names.empty() ? std::string{}
                                                              : target.caption_names.front();
      result["className"] = target.class_names.empty() ? std::string{}
                                                         : target.class_names.front();
      // The recovered Windows recorder declares CaptureType and
      // LaunchTypeCode as integer enums (WindowCapture=5 and
      // ProcessClassCaption=3).  The imported renderer forwards these
      // values unchanged to /games/requests; sending enum names produces
      // the server's errorId=21 "unexpected format" response.
      result["captureType"] = 5;
      result["launchType"] = 3;
      // These are additive diagnostic fields.  The imported client ignores
      // them, while the native helper retains PID/bundle/window identity.
      result["nativeIdentity"] = {
          {"pid", target.pid},
          {"bundleIdentifier", target.bundle_identifier},
          {"executablePath", target.executable_path},
          {"executableName", target.executable_name},
          {"screenCaptureApplicationName", target.screen_capture_application_name},
          {"windowIds", [&target] {
             nlohmann::json ids = nlohmann::json::array();
             for (const auto& window : target.windows) {
               ids.push_back(window.window_id);
             }
             return ids;
           }()},
      };
    }
    if (!message.empty()) {
      result["message"] = message;
    }
    return result;
  }

  void set_target_process(const nlohmann::json& params) {
    const auto& data = params.at("data");
    const auto process_name = decode_wire_process_name(data.at("processName").get<std::string>());
    if (process_name.empty()) {
      throw std::invalid_argument("target processName must not be empty");
    }
    std::string match_diagnostic;
    auto match_data = data;
    match_data["processName"] = process_name;
    const auto active = find_active_process(match_data, &match_diagnostic);
    if (!active) {
      send_request("native-port:target-process:" +
                       std::to_string(++target_process_request_sequence_),
                   "targetProcess",
                   {{"status", "failed"},
                    {"processName", process_name},
                    {"message", "the selected process is no longer running (" + match_diagnostic + ")"}});
      return;
    }
    targeted_process_ = *active;
    target_game_request_id_.clear();
    target_game_category_id_.clear();
    target_game_category_name_.clear();
    target_capture_pending_ = true;
    auto configuration = capture_configuration(nlohmann::json::object());
    configuration.preferred_source_kind = "application";
    configuration.target_process_id = active->pid;
    const auto target = *active;
    request_application_capture(target, configuration);
  }

  void request_application_capture(const native_port::ProcessIdentity& target,
                                   const native_port::CaptureConfiguration& configuration) {
    const auto state = capture_->status().value("state", std::string{});
    if (state == "capturing" || state == "starting" || state == "stopping" ||
        state == "picker_presented") {
      // The imported client may have started its configured display before the
      // native process scan resolves a game. Drain that stream first; the next
      // automatic-detection tick starts the application filter after the
      // ScreenCaptureKit source transition is complete.
      if (!capture_cleanup_requested_.exchange(true, std::memory_order_acq_rel)) {
        dispatch_to_main([this] { capture_->stop(); });
      }
      return;
    }
    capture_cleanup_requested_.store(false, std::memory_order_release);
    dispatch_to_main([this, target, configuration] {
      capture_->start_application(target, configuration);
    });
  }

  [[nodiscard]] static bool is_native_game_candidate(const native_port::ProcessIdentity& process) {
    // This is a native launch-origin filter, not a replacement for Medal's
    // game database. The imported client still resolves the candidate through
    // its authenticated /games/requests and category-search calls, which
    // return the real Medal gameRequestId/category metadata. Steam (and the
    // other supported game-launcher roots) provide a stable cross-title signal
    // without inventing a local game list; ordinary apps such as Terminal and
    // Discord remain visible to the manual chooser but are not auto-targeted.
    const auto lowercase = [](std::string value) {
      std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
      });
      return value;
    };
    const auto bundle = lowercase(process.bundle_identifier);
    const auto executable = lowercase(process.executable_name);
    const auto application = lowercase(process.application_name);
    const auto path = lowercase(process.executable_path);
    const auto has_visible_window = !process.windows.empty();
    const auto launched_from_game_store =
        path.find("/steam/steamapps/common/") != std::string::npos ||
        path.find("/steamapps/common/") != std::string::npos ||
        path.find("/epic games/") != std::string::npos ||
        path.find("/gog games/") != std::string::npos ||
        path.find("/riot games/") != std::string::npos ||
        path.find("/battle.net/") != std::string::npos;
    if (has_visible_window && launched_from_game_store) {
      return true;
    }
    if (bundle == "com.7thbeat.adofai" || executable == "adanceoffireandice" ||
        application == "a dance of fire and ice") {
      return true;
    }
    if (application == "minecraft" &&
        (executable == "java" || bundle == "com.mojang.minecraftlauncher")) {
      return true;
    }
    return false;
  }

  void auto_detect_running_game() {
    const auto capture_state = capture_->status().value("state", std::string{});
    nlohmann::json detection = {
        {"schemaVersion", 1},
        {"handshakeComplete", handshake_complete_},
        {"captureState", capture_state},
        {"captureSourceKind", capture_->status().value("sourceKind", std::string{})},
        {"captureLastError", capture_->status().value("lastError", std::string{})},
        {"captureAnnounced", capture_announced_},
        {"targetCapturePending", target_capture_pending_},
        {"targetPid", targeted_process_ ? nlohmann::json(targeted_process_->pid) : nlohmann::json(nullptr)},
    };
    if (!recording_settings_synced_) {
      detection["decision"] = "waiting_for_recording_settings";
      persist_auto_detection(detection);
      return;
    }
    if (capture_state == "failed") {
      // A source-disappearance callback can arrive while the old SCStream is
      // still attached.  Stop and drain that stream before selecting another
      // running game; otherwise two delegate streams can race and the second
      // target would not have an unambiguous lifecycle.
      if (!capture_cleanup_requested_.exchange(true, std::memory_order_acq_rel)) {
        dispatch_to_main([this] { capture_->stop(); });
      }
      detection["decision"] = "waiting_for_failed_stream_to_stop";
      persist_auto_detection(detection);
      return;
    }
    if (target_capture_pending_ && targeted_process_) {
      if (capture_state == "idle" || capture_state == "stopped" || capture_state == "cancelled") {
        auto configuration = capture_configuration(nlohmann::json::object());
        configuration.preferred_source_kind = "application";
        configuration.target_process_id = targeted_process_->pid;
        const auto target = *targeted_process_;
        request_application_capture(target, configuration);
      }
      detection["decision"] = "target_capture_pending";
      persist_auto_detection(detection);
      return;
    }
    capture_cleanup_requested_.store(false, std::memory_order_release);
    const auto source_kind = capture_->status().value("sourceKind", std::string{});
    const auto prefer_game_capture = settings_.effective("PreferGameCapture", std::nullopt);
    // The imported client does not persist its recovered default when the
    // setting has never been changed.  Medal's actual default is true, so an
    // absent wire value must not disable automatic game capture.
    const bool game_capture_preferred =
        !prefer_game_capture.has_value() ||
        (prefer_game_capture->is_boolean() && prefer_game_capture->get<bool>());
    // The normal client starts its configured display stream as soon as
    // ScreenCaptureEnabled is applied.  With Medal's default PreferGameCapture
    // setting, that display stream is a provisional fallback: replace it with
    // the native application filter as soon as a running game is resolved.
    const bool provisional_display = capture_announced_ && capture_state == "capturing" &&
                                     source_kind == "display" && game_capture_preferred;
    if (targeted_process_ || (capture_announced_ && !provisional_display)) {
      return;
    }
    const auto candidates = adapter_->process_targets();
    detection["candidateCount"] = candidates.size();
    detection["candidates"] = [&] {
      nlohmann::json result = nlohmann::json::array();
      for (const auto& process : candidates) {
        result.push_back({{"pid", process.pid},
                          {"applicationName", process.application_name},
                          {"executableName", process.executable_name},
                          {"bundleIdentifier", process.bundle_identifier},
                          {"windowCount", process.windows.size()}});
      }
      return result;
    }();
    const auto candidate = std::find_if(candidates.begin(), candidates.end(), [](const auto& process) {
      return is_native_game_candidate(process);
    });
    if (candidate == candidates.end()) {
      detection["decision"] = "no_supported_candidate";
      persist_auto_detection(detection);
      return;
    }
    targeted_process_ = *candidate;
    target_game_request_id_.clear();
    target_game_category_id_.clear();
    target_game_category_name_.clear();
    target_capture_pending_ = true;
    auto configuration = capture_configuration(nlohmann::json::object());
    configuration.preferred_source_kind = "application";
    const auto target = *candidate;
    detection["decision"] = "request_application_capture";
    detection["selectedTarget"] = { {"pid", target.pid},
                                     {"applicationName", target.application_name},
                                     {"executableName", target.executable_name},
                                     {"bundleIdentifier", target.bundle_identifier},
                                     {"windowCount", target.windows.size()} };
    persist_auto_detection(detection);
    request_application_capture(target, configuration);
  }

  void persist_auto_detection(const nlohmann::json& value) const {
    try {
      const auto directory = profile_root() / "native-port";
      std::filesystem::create_directories(directory);
      std::filesystem::permissions(directory, std::filesystem::perms::owner_all,
                                   std::filesystem::perm_options::replace);
      const auto destination = directory / "auto-detection.json";
      const auto temporary = destination.string() + ".partial-" + std::to_string(::getpid());
      std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
      stream << value.dump(2) << '\n';
      stream.flush();
      stream.close();
      std::filesystem::permissions(temporary,
                                   std::filesystem::perms::owner_read |
                                       std::filesystem::perms::owner_write,
                                   std::filesystem::perm_options::replace);
      std::filesystem::rename(temporary, destination);
    } catch (...) {
      // Diagnostics must never change the capture state.
    }
  }

  void persist_settings_sync(const nlohmann::json& value) const {
    try {
      const auto directory = profile_root() / "native-port";
      std::filesystem::create_directories(directory);
      std::filesystem::permissions(directory, std::filesystem::perms::owner_all,
                                   std::filesystem::perm_options::replace);
      const auto destination = directory / "settings-sync.json";
      const auto temporary = destination.string() + ".partial-" + std::to_string(::getpid());
      std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
      stream << value.dump(2) << '\n';
      stream.flush();
      stream.close();
      std::filesystem::permissions(temporary,
                                   std::filesystem::perms::owner_read |
                                       std::filesystem::perms::owner_write,
                                   std::filesystem::perm_options::replace);
      std::filesystem::rename(temporary, destination);
    } catch (...) {
      // Diagnostics must never change the capture state.
    }
  }

  [[nodiscard]] nlohmann::json effective_capture_configuration(const nlohmann::json& params) const {
    const auto configuration = capture_configuration(params);
    return {
        {"width", configuration.width},
        {"height", configuration.height},
        {"framesPerSecond", configuration.frames_per_second},
        {"bitrateBitsPerSecond", configuration.bitrate_bits_per_second},
        {"videoCodec", native_port::medal_video_codec_name(configuration.video_codec)},
        {"showCursor", configuration.show_cursor},
        {"captureSystemAudio", configuration.capture_system_audio},
        {"captureMicrophone", configuration.capture_microphone},
        {"audioMode", configuration.audio_mode},
        {"pcAudioEnabled", configuration.pc_audio_enabled},
        {"systemAudioVolumePercent", configuration.system_audio_volume_percent},
        {"microphoneVolumePercent", configuration.microphone_volume_percent},
        {"selectedAudioDevices", configuration.selected_audio_devices},
        {"multipleAudioTracks", configuration.multiple_audio_tracks},
        {"microphoneDeviceName", configuration.microphone_device_name
                                      ? nlohmann::json(*configuration.microphone_device_name)
                                      : nlohmann::json(nullptr)},
        {"preferredSourceKind", configuration.preferred_source_kind},
    };
  }

  [[nodiscard]] nlohmann::json capture_status() const {
    auto result = capture_->status();
    result["replay"] = {{"packetCount", replay_.packet_count()},
                        {"occupiedBytes", replay_.occupied_bytes()},
                        {"retainedNanoseconds", replay_.retained_duration().count()}};
    if (const auto snapshot = replay_.snapshot(std::chrono::seconds(120)); snapshot) {
      std::size_t video_packets = 0;
      std::size_t keyframes = 0;
      std::size_t configured_keyframes = 0;
      std::size_t system_audio_packets = 0;
      std::size_t microphone_packets = 0;
      std::size_t configured_audio_packets = 0;
      std::uint64_t audio_encoder_delay_frames = 0;
      std::uint64_t audio_discard_padding_frames = 0;
      std::string codec = "unknown";
      for (const auto& packet : snapshot->packets) {
        if (packet->track != native_port::TrackKind::video) {
          if (packet->track == native_port::TrackKind::game_audio ||
              packet->track == native_port::TrackKind::mixed_audio) {
            ++system_audio_packets;
          } else if (packet->track == native_port::TrackKind::microphone_audio) {
            ++microphone_packets;
          }
          if (packet->codec == native_port::Codec::aac && packet->codec_configuration &&
              !packet->codec_configuration->empty()) {
            ++configured_audio_packets;
          }
          audio_encoder_delay_frames += packet->encoder_delay_frames;
          audio_discard_padding_frames += packet->discard_padding_frames;
          continue;
        }
        ++video_packets;
        codec = native_port::codec_name(packet->codec);
        if (packet->keyframe) {
          ++keyframes;
          if (packet->codec_configuration && !packet->codec_configuration->empty()) {
            ++configured_keyframes;
          }
        }
      }
      result["replay"]["decodableSnapshot"] = {
          {"available", true},
          {"codec", codec},
          {"packetCount", snapshot->packets.size()},
          {"videoPacketCount", video_packets},
          {"keyframeCount", keyframes},
          {"configuredKeyframeCount", configured_keyframes},
          {"systemAudioPacketCount", system_audio_packets},
          {"microphonePacketCount", microphone_packets},
          {"configuredAudioPacketCount", configured_audio_packets},
          {"audioEncoderDelayFrames", audio_encoder_delay_frames},
          {"audioDiscardPaddingFrames", audio_discard_padding_frames},
          {"configurationGeneration", snapshot->configuration_generation},
          {"startMonotonicNanoseconds", snapshot->start_monotonic_nanoseconds},
          {"endMonotonicNanoseconds", snapshot->end_monotonic_nanoseconds},
          {"limitation", snapshot->limitation},
      };
    } else {
      result["replay"]["decodableSnapshot"] = {{"available", false}};
    }
    {
      std::scoped_lock lock(capture_event_mutex_);
      result["lastEvent"] = last_capture_event_;
    }
    result["hotkeys"] = adapter_->clip_hotkey_status();
    {
      std::scoped_lock lock(settings_sync_mutex_);
      result["settingsSync"] = settings_sync_;
    }
    {
      std::scoped_lock lock(hotkey_result_mutex_);
      result["lastClipAction"] = last_hotkey_result_;
    }
    return result;
  }

  [[nodiscard]] std::filesystem::path validated_test_export_path(const nlohmann::json& params) const {
    const auto requested_text = params.value("outputPath", std::string{});
    const char* profile_text = std::getenv("NATIVE_PORT_PROFILE_DIR");
    if (requested_text.empty() || profile_text == nullptr) {
      throw std::invalid_argument("test export requires an isolated profile and outputPath");
    }
    const std::filesystem::path requested(requested_text);
    const std::filesystem::path profile(profile_text);
    if (!requested.is_absolute() || requested.extension() != ".mp4") {
      throw std::invalid_argument("test export path must be an absolute MP4 path");
    }
    const auto profile_root = std::filesystem::weakly_canonical(profile);
    const auto output_parent = std::filesystem::weakly_canonical(requested.parent_path());
    auto profile_iterator = profile_root.begin();
    auto output_iterator = output_parent.begin();
    while (profile_iterator != profile_root.end() && output_iterator != output_parent.end() &&
           *profile_iterator == *output_iterator) {
      ++profile_iterator;
      ++output_iterator;
    }
    if (profile_iterator != profile_root.end()) {
      throw std::invalid_argument("test export path must stay inside the isolated profile");
    }
    if (std::filesystem::exists(requested)) {
      throw std::invalid_argument("test export refuses to overwrite an existing file");
    }
    return requested;
  }

  [[nodiscard]] nlohmann::json save_test_replay(const nlohmann::json& params) {
    const auto duration_seconds = params.value("durationSeconds", 30);
    if (duration_seconds < 1 || duration_seconds > 120) {
      throw std::invalid_argument("durationSeconds must be between 1 and 120");
    }
    const auto output = validated_test_export_path(params);
    const auto snapshot = replay_.snapshot(std::chrono::seconds(duration_seconds));
    if (!snapshot) {
      throw std::runtime_error("no decodable replay snapshot is available");
    }
    const auto temporary = output.string() + ".partial-" + std::to_string(::getpid());
    std::error_code cleanup_error;
    std::filesystem::remove(temporary, cleanup_error);
    try {
      const auto result = native_port::write_mp4(temporary, *snapshot);
      std::filesystem::rename(temporary, output);
      return {
          {"saved", true},
          {"fileName", output.filename().string()},
          {"bytesWritten", result.bytes_written},
          {"durationNanoseconds", result.duration.count()},
          {"videoPacketCount", result.video_packets},
          {"systemAudioPacketCount", result.system_audio_packets},
          {"microphonePacketCount", result.microphone_packets},
      };
    } catch (...) {
      std::filesystem::remove(temporary, cleanup_error);
      throw;
    }
  }

  [[nodiscard]] std::filesystem::path profile_root() const {
    const char* profile_text = std::getenv("NATIVE_PORT_PROFILE_DIR");
    if (profile_text == nullptr || std::string_view(profile_text).empty()) {
      throw std::runtime_error("native recorder requires an isolated profile path");
    }
    const std::filesystem::path profile(profile_text);
    if (!profile.is_absolute()) {
      throw std::runtime_error("native recorder profile path must be absolute");
    }
    return std::filesystem::weakly_canonical(profile);
  }

  void persist_hotkey_diagnostics(const std::string& uuid, const nlohmann::json& value) const {
    const auto directory = profile_root() / "native-port" / "hotkey-diagnostics";
    std::filesystem::create_directories(directory);
    std::filesystem::permissions(directory, std::filesystem::perms::owner_all,
                                 std::filesystem::perm_options::replace);
    const auto destination = directory / (uuid + ".json");
    const auto temporary = destination.string() + ".partial-" + std::to_string(::getpid());
    {
      std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
      if (!stream) {
        throw std::runtime_error("failed to create hotkey diagnostics journal");
      }
      stream << value.dump(2) << '\n';
      stream.flush();
      if (!stream) {
        throw std::runtime_error("failed to write hotkey diagnostics journal");
      }
    }
    std::filesystem::permissions(temporary,
                                 std::filesystem::perms::owner_read |
                                     std::filesystem::perms::owner_write,
                                 std::filesystem::perm_options::replace);
    std::filesystem::rename(temporary, destination);
  }

  [[nodiscard]] std::filesystem::path existing_profile_mp4(const nlohmann::json& params) const {
    const auto requested_text = params.value("clipLocation", std::string{});
    if (requested_text.empty()) {
      throw std::invalid_argument("clipLocation is required");
    }
    const std::filesystem::path requested(requested_text);
    if (!requested.is_absolute() || requested.extension() != ".mp4" ||
        !std::filesystem::is_regular_file(requested)) {
      throw std::invalid_argument("clipLocation must be an existing absolute MP4 file");
    }
    const auto canonical = std::filesystem::weakly_canonical(requested);
    const auto profile = profile_root();
    auto profile_iterator = profile.begin();
    auto clip_iterator = canonical.begin();
    while (profile_iterator != profile.end() && clip_iterator != canonical.end() &&
           *profile_iterator == *clip_iterator) {
      ++profile_iterator;
      ++clip_iterator;
    }
    if (profile_iterator != profile.end()) {
      throw std::invalid_argument("isolated contentCreate test clip must stay inside its profile");
    }
    return canonical;
  }

  void persist_registration(const ClipRegistration& registration) const {
    const nlohmann::json value = {
        {"schemaVersion", 1},
        {"uuid", registration.uuid},
        {"requestId", registration.request_id},
        {"clipLocation", registration.clip_location.string()},
        {"createdAt", registration.created_at_milliseconds},
        {"exportStatsDuration", registration.export_duration_seconds},
        {"state", registration.state},
        {"error", registration.error.empty() ? nlohmann::json(nullptr)
                                               : nlohmann::json(registration.error)},
        {"contentId", registration.content_id},
    };
    std::filesystem::create_directories(registration.journal_path.parent_path());
    std::filesystem::permissions(
        registration.journal_path.parent_path(),
        std::filesystem::perms::owner_all,
        std::filesystem::perm_options::replace);
    const auto temporary = registration.journal_path.string() + ".partial-" +
                           std::to_string(::getpid());
    {
      std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
      if (!stream) {
        throw std::runtime_error("failed to create content registration journal");
      }
      stream << value.dump(2) << '\n';
      stream.flush();
      if (!stream) {
        throw std::runtime_error("failed to write content registration journal");
      }
    }
    std::filesystem::permissions(
        temporary,
        std::filesystem::perms::owner_read | std::filesystem::perms::owner_write,
        std::filesystem::perm_options::replace);
    std::filesystem::rename(temporary, registration.journal_path);
  }

  [[nodiscard]] nlohmann::json registration_json(const ClipRegistration& registration) const {
    return {
        {"found", true},
        {"uuid", registration.uuid},
        {"fileName", registration.clip_location.filename().string()},
        {"state", registration.state},
        {"error", registration.error.empty() ? nlohmann::json(nullptr)
                                               : nlohmann::json(registration.error)},
        {"contentId", registration.content_id},
    };
  }

  [[nodiscard]] nlohmann::json register_test_replay(const nlohmann::json& params) {
    const auto uuid = params.value("uuid", std::string{});
    if (!is_uuid(uuid)) {
      throw std::invalid_argument("uuid must be a canonical hexadecimal UUID");
    }
    if (registrations_.contains(uuid)) {
      return registration_json(registrations_.at(uuid));
    }
    const auto clip_location = existing_profile_mp4(params);
    const auto created_at = params.value("createdAt", std::int64_t{0});
    const auto export_duration = params.value("exportStatsDuration", 0.0);
    if (created_at <= 0 || !std::isfinite(export_duration) || export_duration <= 0.0 ||
        export_duration > 125.0) {
      throw std::invalid_argument("createdAt and a bounded positive exportStatsDuration are required");
    }
    return begin_registration(uuid, clip_location, created_at, export_duration,
                              std::string("test-game"), std::string("NativePortIsolatedTest"),
                              nlohmann::json::array({{{"index", 0}, {"title", "PC Audio"}}}));
  }

  [[nodiscard]] nlohmann::json begin_registration(
      const std::string& uuid, const std::filesystem::path& clip_location,
      std::int64_t created_at, double export_duration,
      std::optional<std::string> game_category_id,
      std::optional<std::string> process_name,
      nlohmann::json audio_streams = nlohmann::json::array()) {
    if (registrations_.contains(uuid)) {
      return registration_json(registrations_.at(uuid));
    }
    ClipRegistration registration{
        .uuid = uuid,
        .request_id = "native-port:content:" + uuid,
        .clip_location = clip_location,
        .journal_path = profile_root() / "native-port" / "content-outbox" / (uuid + ".json"),
        .created_at_milliseconds = created_at,
        .export_duration_seconds = export_duration,
    };
    persist_registration(registration);
    registrations_.insert_or_assign(uuid, registration);
    registration_request_ids_.insert_or_assign(registration.request_id, uuid);
    nlohmann::json content = {
        {"uuid", uuid},
        {"createdAt", created_at},
        {"clipLocation", clip_location.string()},
        {"gameCategoryId", game_category_id ? nlohmann::json(*game_category_id)
                                             : nlohmann::json(nullptr)},
        {"clipType", "clip"},
        {"captureType", "screen"},
        {"metadata", {{"triggerType", "Manual"},
                       {"exportStatsDuration", export_duration},
                       {"audioStreams", std::move(audio_streams)}}},
    };
    if (process_name) {
      content["processName"] = *process_name;
    }
    send_request(registration.request_id, "contentCreate", std::move(content));
    return registration_json(registrations_.at(uuid));
  }

  [[nodiscard]] nlohmann::json registration_status(const nlohmann::json& params) const {
    const auto uuid = params.value("uuid", std::string{});
    const auto found = registrations_.find(uuid);
    if (found == registrations_.end()) {
      return {{"found", false}, {"uuid", uuid}};
    }
    return registration_json(found->second);
  }

  [[nodiscard]] native_port::ClipSavedFeedback clip_saved_feedback() const {
    const auto boolean_setting = [this](std::string_view key, bool fallback) {
      const auto value = settings_.global(key);
      return value && value->is_boolean() ? value->get<bool>() : fallback;
    };
    const bool sound_enabled = boolean_setting("GlobalSoundAlerts", true) &&
                               boolean_setting("ClipSavedSoundAlerts", true);
    double volume = 1.0;
    if (const auto configured = settings_.global("AudioNotificationVolume");
        configured && configured->is_number()) {
      volume = std::clamp(configured->get<double>(), 0.0, 1.5);
    }
    std::optional<std::string> sound_path;
    if (const auto configured = settings_.global("ClipSoundPath");
        configured && configured->is_string()) {
      const auto candidate = configured->get<std::string>();
      if (!candidate.empty() && candidate != "default") {
        sound_path = candidate;
      }
    }
    if (!sound_path) {
      if (const char* official_default = std::getenv("NATIVE_PORT_DEFAULT_CLIP_SOUND");
          official_default != nullptr && official_default[0] == '/') {
        sound_path = official_default;
      }
    }
    std::optional<std::string> icon_path;
    if (const char* icon = std::getenv("NATIVE_PORT_MEDAL_ICON");
        icon != nullptr && icon[0] == '/') {
      icon_path = icon;
    }
    return native_port::ClipSavedFeedback{
        .play_sound = sound_enabled && volume > 0.0,
        .volume = volume,
        .sound_path = std::move(sound_path),
        .icon_path = std::move(icon_path),
        .title = "Medal",
        .message = "Clip saved",
    };
  }

  void complete_registration(const std::string& request_id,
                             const native_port::JsonRpcResponse& response) {
    const auto request = registration_request_ids_.find(request_id);
    if (request == registration_request_ids_.end()) {
      return;
    }
    auto registration = registrations_.find(request->second);
    if (registration == registrations_.end()) {
      registration_request_ids_.erase(request);
      return;
    }
    if (response.error) {
      registration->second.state = "failed";
      registration->second.error = response.error->value("message", "contentCreate returned a wire error");
    } else if (!response.result || !response.result->is_object() ||
               response.result->value("result", std::string{}) != "success" ||
               !response.result->contains("data") || !response.result->at("data").is_object() ||
               response.result->at("data").value("uuid", std::string{}) != registration->second.uuid) {
      registration->second.state = "failed";
      registration->second.error = "contentCreate returned an invalid or unsuccessful Medal envelope";
    } else {
      registration->second.state = "acknowledged";
      registration->second.error.clear();
      registration->second.content_id = response.result->at("data").value("contentId", nlohmann::json(nullptr));
    }
    persist_registration(registration->second);
    bool acknowledged_hotkey = false;
    {
      std::scoped_lock lock(hotkey_result_mutex_);
      if (last_hotkey_result_.value("uuid", std::string{}) == registration->second.uuid) {
        last_hotkey_result_["state"] = registration->second.state;
        last_hotkey_result_["error"] = registration->second.error.empty()
                                                ? nlohmann::json(nullptr)
                                                : nlohmann::json(registration->second.error);
        last_hotkey_result_["contentId"] = registration->second.content_id;
        acknowledged_hotkey = registration->second.state == "acknowledged";
      }
    }
    if (acknowledged_hotkey) {
      auto feedback = clip_saved_feedback();
      dispatch_to_main([this, feedback = std::move(feedback)] {
        adapter_->present_clip_saved_feedback(feedback);
      });
    }
    registration_request_ids_.erase(request);
  }

  void send_json(const nlohmann::json& value) {
    const auto encoded = value.dump();
    if (encoded.size() > kMaximumFrameBytes) {
      throw std::length_error("outbound JSON-RPC frame exceeds limit");
    }
    socket_->write(asio::buffer(encoded));
  }

  void send_request(std::string id, std::string method, nlohmann::json params) {
    send_json({{"jsonrpc", "2.0"}, {"id", std::move(id)}, {"method", std::move(method)}, {"params", std::move(params)}});
  }

  void send_response(const native_port::JsonRpcId& id, nlohmann::json result) {
    send_json({{"jsonrpc", "2.0"}, {"id", id_json(id)}, {"result", std::move(result)}});
  }

  void send_error(const native_port::JsonRpcId& id, int code, std::string message,
                  std::optional<nlohmann::json> data = std::nullopt) {
    send_json({{"jsonrpc", "2.0"},
               {"id", id_json(id)},
               {"error", native_port::JsonRpcCodec::error_object(code, std::move(message), std::move(data))}});
  }

  bool handle_message(std::string_view payload) {
    nlohmann::json value = nlohmann::json::parse(payload, nullptr, false);
    if (value.is_discarded() || !value.is_object() || value.value("jsonrpc", "") != "2.0") {
      send_json({{"jsonrpc", "2.0"}, {"id", nullptr}, {"error", {{"code", -32700}, {"message", "Parse error"}}}});
      return true;
    }
    if (value.contains("method")) {
      return handle_request(codec_.parse_request(payload));
    }
    const auto response = codec_.parse_response(payload);
    return handle_response(response);
  }

  bool handle_response(const native_port::JsonRpcResponse& response) {
    if (!std::holds_alternative<std::string>(response.id)) {
      return true;
    }
    const auto& id = std::get<std::string>(response.id);
    if (id.starts_with("native-port:content:")) {
      complete_registration(id, response);
      return true;
    }
    if (id == "native-port:recording-settings") {
      // `recordingSettings` is the original Medal startup request.  The
      // imported client returns its normalized recorder wire array inside the
      // usual {result:"success",data:[...]} envelope.  Applying this response
      // here keeps the native helper on the real client path; a stale or
      // missing Electron-side settings notification must not silently leave
      // the helper on its split-by-process default.
      if (response.error) {
        const auto error_message = response.error->is_object()
                                       ? response.error->value("message", "recordingSettings failed")
                                       : std::string{"recordingSettings returned a malformed error"};
        const auto sync = nlohmann::json{{"schemaVersion", 1},
                                         {"state", "failed"},
                                         {"reason", "recording_settings_request_failed"},
                                         {"lastError", error_message}};
        {
          std::scoped_lock lock(settings_sync_mutex_);
          settings_sync_ = sync;
        }
        persist_settings_sync(sync);
        std::scoped_lock lock(capture_event_mutex_);
        last_capture_event_ = {{"schemaVersion", 1},
                               {"state", "settings_sync_failed"},
                               {"reason", "recording_settings_request_failed"},
                               {"lastError", response.error->value("message", "recordingSettings failed")}};
        return true;
      }
      try {
        if (!response.result) {
          throw std::runtime_error("recordingSettings returned no result");
        }
        const auto& envelope = *response.result;
        const nlohmann::json* data = &envelope;
        if (envelope.is_object() && envelope.contains("data")) {
          data = &envelope.at("data");
        }
        if (data->is_object() && data->contains("settings")) {
          data = &data->at("settings");
        }
        if (!data->is_array()) {
          throw std::runtime_error("recordingSettings returned a non-array data payload");
        }
        const bool had_pending_display_start = screen_capture_enable_pending_;
        const bool settings_include_screen_capture = std::any_of(
            data->begin(), data->end(), [](const auto& item) {
              return item.is_object() && item.value("key", std::string{}) == "ScreenCaptureEnabled";
            });
        recording_settings_synced_ = true;
        screen_capture_enable_pending_ = false;
        apply_settings({{"settings", *data}});
        if (had_pending_display_start && !settings_include_screen_capture) {
          start_configured_display_capture();
        }
        const auto audio_mode = settings_.global("AudioModeConfig");
        const auto audio_mode_type = audio_mode && audio_mode->is_object()
                                         ? audio_mode->value("type", std::string{"missing"})
                                         : std::string{"missing"};
        const auto pc_audio_enabled = audio_mode && audio_mode->is_object() &&
                                      audio_mode->contains("pcAudioEnabled") &&
                                      audio_mode->at("pcAudioEnabled").is_boolean()
                                          ? audio_mode->at("pcAudioEnabled").get<bool>()
                                          : false;
        const auto sync = nlohmann::json{{"schemaVersion", 1},
                                         {"state", "applied"},
                                         {"reason", "recording_settings_applied"},
                                         {"settingCount", data->size()},
                                         {"audioMode", audio_mode_type},
                                         {"pcAudioEnabled", pc_audio_enabled}};
        {
          std::scoped_lock lock(settings_sync_mutex_);
          settings_sync_ = sync;
        }
        persist_settings_sync(sync);
        {
          std::scoped_lock lock(capture_event_mutex_);
          last_capture_event_ = {{"schemaVersion", 1},
                                 {"state", "settings_synced"},
                                 {"reason", "recording_settings_applied"},
                                 {"settingCount", data->size()}};
        }
      } catch (const std::exception& error) {
        const auto sync = nlohmann::json{{"schemaVersion", 1},
                                         {"state", "failed"},
                                         {"reason", "recording_settings_invalid"},
                                         {"lastError", error.what()}};
        {
          std::scoped_lock lock(settings_sync_mutex_);
          settings_sync_ = sync;
        }
        persist_settings_sync(sync);
        std::scoped_lock lock(capture_event_mutex_);
        last_capture_event_ = {{"schemaVersion", 1},
                               {"state", "settings_sync_failed"},
                               {"reason", "recording_settings_invalid"},
                               {"lastError", error.what()}};
      }
      return true;
    }
    if (id != "native-port:handshake") {
      return true;
    }
    if (!response.result || !response.result->is_object() || response.result->value("result", "") != "success" ||
        !response.result->contains("data") || response.result->at("data").value("version", 0) != 1) {
      throw std::runtime_error("Electron handshake did not negotiate protocol version 1");
    }
    handshake_complete_ = true;
    send_request("native-port:ready", "recordingReady", nlohmann::json::object());
    // Request the exact normalized settings array used by Medal's original
    // recorder startup flow.  This is intentionally a request (rather than a
    // private notification) so a missing/failed response remains observable.
    send_request("native-port:recording-settings", "recordingSettings", nlohmann::json::object());
    send_request("native-port:displays", "setKV", {{"key", "activeDisplays"}, {"value", adapter_->active_displays(false)}});
    send_request("native-port:mics", "setKV", {{"key", "micDevices"}, {"value", adapter_->microphone_devices()}});
    send_request("native-port:audio", "setKV", {{"key", "gameDevices"}, {"value", adapter_->audio_output_devices()}});
    send_request("native-port:gpu-devices", "setKV",
                 {{"key", "gpuDevices"}, {"value", adapter_->gpu_devices()}});
    send_request("native-port:gpu-codecs", "setKV",
                 {{"key", "gpuCodecs"}, {"value", adapter_->gpu_codecs()}});
    send_request("native-port:encoder-options", "setKV",
                 {{"key", "encoderOptions"}, {"value", adapter_->encoder_options()}});
    send_request("native-port:capabilities", "setKV",
                 {{"key", "nativePort.capabilities"}, {"value", adapter_->capabilities()}});
    send_request("native-port:permissions", "setKV",
                 {{"key", "nativePort.permissions"}, {"value", adapter_->permission_status()}});
    return true;
  }

  bool handle_request(const native_port::JsonRpcRequest& request) {
    if (!handshake_complete_ && request.method != "ping" && request.method != "settings" &&
        request.method != "shutdown") {
      respond_error(request, -32001, "native port handshake is not complete");
      return true;
    }
    try {
      if (request.method == "ping") {
        respond(request, nullptr);
      } else if (request.method == "settings") {
        apply_settings(request.params);
        respond(request, nullptr);
      } else if (request.method == "deleteAllCustomGameSettings") {
        settings_.delete_custom_game_settings(request.params.at("categoryIds").get<std::vector<std::string>>());
        respond(request, nullptr);
      } else if (request.method == "deleteCustomGameSettings") {
        for (const auto& item : request.params.at("customGameSettings")) {
          settings_.delete_custom_game_settings(item.at("categoryId").get<std::string>(),
                                                item.at("settingKeys").get<std::vector<std::string>>());
        }
        respond(request, nullptr);
      } else if (request.method == "activeDisplays") {
        respond(request, adapter_->active_displays(request.params.value("captureScreenshots", false)));
      } else if (request.method == "availableAudioDevices" || request.method == "gameSoundAudioDevice") {
        respond(request, adapter_->audio_output_devices());
      } else if (request.method == "availableMicDevices") {
        respond(request, adapter_->microphone_devices());
      } else if (request.method == "getDefaultAudioDevices") {
        respond(request, adapter_->default_audio_devices());
      } else if (request.method == "micAudioDevice") {
        const auto defaults = adapter_->default_audio_devices();
        respond(request, defaults.value("input", ""));
      } else if (request.method == "webcamDevices") {
        respond(request, adapter_->webcam_devices(request.params.value("includeVirtualDevices", false)));
      } else if (request.method == "nativePort.enumerateSources") {
        dispatch_to_main([this] { capture_->enumerate_shareable_content(); });
        respond(request, {{"accepted", true}});
      } else if (request.method == "nativePort.interactiveSessionPreflight") {
        respond(request, adapter_->interactive_session_status());
      } else if (request.method == "nativePort.permissionStatus") {
        respond(request, adapter_->permission_status());
      } else if (request.method == "nativePort.requestPermissions") {
        dispatch_to_main([this] { adapter_->request_permissions(); });
        respond(request, {{"accepted", true}, {"status", adapter_->permission_status()}});
      } else if (request.method == "nativePort.openPermissionSettings") {
        dispatch_to_main([this] { adapter_->open_permission_settings(); });
        respond(request, {{"accepted", true}});
      } else if (request.method == "nativePort.presentSourcePicker") {
        const auto configuration = capture_configuration(request.params);
        dispatch_to_main([this, configuration] { capture_->present_source_picker(configuration); });
        respond(request, {{"accepted", true}});
      } else if (request.method == "nativePort.stopCapture") {
        dispatch_to_main([this] { capture_->stop(); });
        respond(request, {{"accepted", true}});
      } else if (request.method == "nativePort.captureStatus") {
        respond(request, capture_status());
      } else if (request.method == "nativePort.effectiveCaptureConfiguration") {
        respond(request, effective_capture_configuration(request.params));
      } else if (request.method == "nativePort.saveReplay") {
        respond(request, save_test_replay(request.params));
      } else if (request.method == "nativePort.registerExportedReplay") {
        respond(request, register_test_replay(request.params));
      } else if (request.method == "nativePort.registrationStatus") {
        respond(request, registration_status(request.params));
      } else if (request.method == "nativePort.videoEncoderCapabilities") {
        respond(request, {{"gpuDevices", adapter_->gpu_devices()},
                          {"gpuCodecs", adapter_->gpu_codecs()},
                          {"encoderOptions", adapter_->encoder_options()},
                          {"capabilities", adapter_->capabilities()}});
      } else if (request.method == "getActiveProcesses") {
        respond(request, adapter_->active_processes());
      } else if (request.method == "getTargetedProcesses") {
        auto result = nlohmann::json::array();
        if (targeted_process_) {
          result.push_back(target_process_payload("success"));
        }
        respond(request, std::move(result));
      } else if (request.method == "setTargetProcess") {
        set_target_process(request.params);
        respond(request, nullptr);
      } else if (request.method == "setGameRequestId") {
        const auto& data = request.params.at("data");
        if (targeted_process_) {
          const auto wire_name = !targeted_process_->application_name.empty()
                                     ? targeted_process_->application_name
                                     : targeted_process_->executable_name;
          if (wire_name == data.value("processName", std::string{})) {
            target_game_request_id_ = data.value("gameRequestId", std::string{});
          }
        }
        respond(request, nullptr);
      } else if (request.method == "nativePort.gameClassification") {
        const auto& data = request.params.contains("data") ? request.params.at("data") : request.params;
        const auto category_id = data.value("categoryId", std::string{});
        const auto category_name = data.value("categoryName", std::string{});
        if (category_id.empty() || category_name.empty()) {
          throw std::invalid_argument("nativePort.gameClassification requires categoryId and categoryName");
        }
        target_game_category_id_ = category_id;
        target_game_category_name_ = category_name;
        if (capture_announced_) {
          announce_target_capture_category();
        }
        respond(request, nullptr);
      } else if (request.method == "deleteTargetProcess") {
        const auto process_name =
            decode_wire_process_name(request.params.at("processName").get<std::string>());
        if (targeted_process_ &&
            ((!targeted_process_->application_name.empty() &&
              targeted_process_->application_name == process_name) ||
             targeted_process_->executable_name == process_name)) {
          targeted_process_.reset();
          target_game_request_id_.clear();
          target_game_category_id_.clear();
          target_game_category_name_.clear();
          target_capture_pending_ = false;
          dispatch_to_main([this] { capture_->stop(); });
        }
        respond(request, nullptr);
      } else if (request.method == "audioProcesses") {
        // The original renderer expects the Windows-shaped fields
        // processName/displayName/icon, but the adapter keeps the native PID
        // and bundle identity authoritative. This list is intentionally
        // limited to user-selectable applications; internal helpers and Dock
        // are filtered by the macOS process model.
        auto processes = adapter_->active_processes();
        if (processes.is_array()) {
          for (auto& process : processes) {
            if (process.is_object() && process.contains("processName")) {
              process["displayName"] = process.value("processName", "");
            }
          }
        }
        respond(request, std::move(processes));
      } else if (request.method == "shutdown") {
        dispatch_to_main([this] { capture_->stop(); });
        respond(request, nullptr);
        websocket::close_reason reason(websocket::close_code::normal);
        reason.reason = "shutdown";
        socket_->close(reason);
        return false;
      } else {
        respond_error(request, -32601,
                      "Method unavailable in the current native macOS implementation: " + request.method,
                      nlohmann::json{{"platform", "macos"}, {"method", request.method}});
      }
    } catch (const nlohmann::json::exception& error) {
      respond_error(request, -32602, std::string("Invalid params: ") + error.what());
    } catch (const std::invalid_argument& error) {
      respond_error(request, -32602, std::string("Invalid params: ") + error.what());
    } catch (const std::exception& error) {
      respond_error(request, -32020, error.what());
    }
    return true;
  }

  void apply_settings(const nlohmann::json& params) {
    std::vector<native_port::SettingUpdate> updates;
    for (const auto& item : params.at("settings")) {
      native_port::SettingUpdate update{
          .key = item.at("key").get<std::string>(),
          .value = item.at("value"),
          .category_id = std::nullopt,
      };
      if (item.contains("categoryId") && !item.at("categoryId").is_null()) {
        update.category_id = item.at("categoryId").get<std::string>();
      }
      updates.push_back(std::move(update));
    }
    settings_.apply(updates);
    apply_screen_capture_setting(updates);
    const bool global_hotkeys_changed = std::any_of(
        updates.begin(), updates.end(), [](const auto& update) {
          return update.key == "Hotkeys" && !update.category_id.has_value();
        });
    if (global_hotkeys_changed) {
      const auto hotkeys = settings_.global("Hotkeys");
      const auto bindings = hotkeys ? native_port::parse_clip_hotkeys(*hotkeys)
                                    : std::vector<native_port::ClipHotkeyBinding>{};
      adapter_->configure_clip_hotkeys(
          bindings, [this](const native_port::ClipHotkeyBinding& binding) {
            enqueue_clip_action(binding);
          });
    }
  }

  void respond(const native_port::JsonRpcRequest& request, nlohmann::json value) {
    if (request.id) {
      send_response(*request.id, std::move(value));
    }
  }

  void respond_error(const native_port::JsonRpcRequest& request, int code, std::string message,
                     std::optional<nlohmann::json> data = std::nullopt) {
    if (request.id) {
      send_error(*request.id, code, std::move(message), std::move(data));
    }
  }

  Options options_;
  std::unique_ptr<native_port::PlatformAdapter> adapter_;
  native_port::SettingsStore settings_;
  native_port::JsonRpcCodec codec_;
  native_port::ReplayStore replay_;
  std::unique_ptr<native_port::CaptureSession> capture_;
  websocket::stream<tcp::socket>* socket_{nullptr};
  std::atomic<bool> running_{true};
  std::optional<native_port::ProcessIdentity> targeted_process_;
  std::string target_game_request_id_;
  std::string target_game_category_id_;
  std::string target_game_category_name_;
  bool target_capture_pending_{false};
  std::atomic<bool> capture_cleanup_requested_{false};
  bool capture_announced_{false};
  std::uint64_t capture_event_sequence_{0};
  std::uint64_t target_process_request_sequence_{0};
  std::string announced_capture_category_id_;
  std::string announced_capture_category_name_;
  std::string capture_session_id_;
  mutable std::mutex capture_event_mutex_;
  nlohmann::json last_capture_event_{{"schemaVersion", 1}, {"state", "idle"}, {"reason", "initialized"}};
  mutable std::mutex settings_sync_mutex_;
  nlohmann::json settings_sync_{{"schemaVersion", 1}, {"state", "not_requested"}};
  std::mutex main_actions_mutex_;
  std::deque<std::function<void()>> main_actions_;
  std::mutex network_actions_mutex_;
  std::deque<std::function<void()>> network_actions_;
  std::mutex clip_actions_mutex_;
  std::deque<native_port::ClipHotkeyBinding> clip_actions_;
  mutable std::mutex hotkey_result_mutex_;
  nlohmann::json last_hotkey_result_{{"state", "not_triggered"}};
  std::mutex network_error_mutex_;
  std::exception_ptr network_error_;
  bool handshake_complete_{false};
  bool recording_settings_synced_{false};
  bool screen_capture_enable_pending_{false};
  std::map<std::string, ClipRegistration, std::less<>> registrations_;
  std::map<std::string, std::string, std::less<>> registration_request_ids_;
};

}  // namespace

int main(int argc, char** argv) {
  try {
    return HelperSession(parse_options(argc, argv)).run();
  } catch (const std::exception& error) {
    std::cerr << "native recorder fatal: " << error.what() << '\n';
    return 1;
  }
}
