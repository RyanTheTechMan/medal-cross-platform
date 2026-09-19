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
    while (running_.load(std::memory_order_acquire)) {
      drain_main_actions();
      adapter_->pump_events();
      capture_->pump_events();
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
        if (network_event.value("sourceKind", std::string{}) == "application" &&
            targeted_process_) {
          auto target = target_process_payload("success");
          target["captureType"] = "application";
          target["launchType"] = "manual";
          send_request("native-port:target-process:" +
                           std::to_string(++target_process_request_sequence_),
                       "targetProcess", std::move(target));
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
                           {"metadata",
                            {{"name", kScreenCaptureCategoryName},
                             {"recording", true}}}}}}});
          announced_capture_category_id_ = kScreenCaptureCategoryId;
          announced_capture_category_name_ = kScreenCaptureCategoryName;
        }
        return;
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
      }
      capture_announced_ = false;
      announced_capture_category_id_.clear();
      announced_capture_category_name_.clear();
      capture_session_id_.clear();
    });
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
        set_hotkey_result({{"action", action.action},
                           {"inputs", action.inputs},
                           {"uuid", uuid},
                           {"fileName", output.filename().string()},
                           {"state", "registration_pending"},
                           {"requestedDurationSeconds", action.duration.count()},
                           {"actualDurationNanoseconds", write_result.duration.count()},
                           {"videoPacketCount", write_result.video_packets},
                           {"systemAudioPacketCount", write_result.system_audio_packets},
                           {"microphonePacketCount", write_result.microphone_packets}});
        dispatch_to_network([this, uuid, output, now, duration_seconds] {
          (void)begin_registration(uuid, output, now, duration_seconds, std::nullopt, std::nullopt);
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
    result.capture_system_audio = params.value("captureSystemAudio", result.capture_system_audio);
    result.capture_microphone = params.value("captureMicrophone", result.capture_microphone);
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
      dispatch_to_main([this] { capture_->stop(); });
      return;
    }
    auto configuration = capture_configuration(nlohmann::json::object());
    configuration.preferred_source_kind = "display";
    const auto display_id = selected_display_id();
    dispatch_to_main([this, display_id, configuration] {
      capture_->start_display(display_id, configuration);
    });
  }

  [[nodiscard]] std::optional<native_port::ProcessIdentity> find_active_process(
      const nlohmann::json& data) const {
    const auto process_name = data.value("processName", std::string{});
    const auto requested_class_names = data.value("className", nlohmann::json::array());
    const auto requested_caption_names = data.value("captionName", nlohmann::json::array());
    const auto requested_contains = [](const nlohmann::json& values, const std::string& value) {
      if (!values.is_array() || value.empty()) {
        return false;
      }
      return std::find(values.begin(), values.end(), value) != values.end();
    };
    std::optional<native_port::ProcessIdentity> best;
    int best_score = -1;
    for (const auto& process : adapter_->process_targets()) {
      const auto wire_name = !process.application_name.empty()
                                 ? process.application_name
                                 : (!process.screen_capture_application_name.empty()
                                        ? process.screen_capture_application_name
                                        : process.executable_name);
      int score = 0;
      if (wire_name == process_name) {
        score += 4;
      }
      if (process.executable_name == process_name ||
          process.screen_capture_application_name == process_name ||
          process.bundle_identifier == process_name) {
        score += 2;
      }
      for (const auto& class_name : process.class_names) {
        if (requested_contains(requested_class_names, class_name)) {
          score += 3;
        }
      }
      for (const auto& caption_name : process.caption_names) {
        if (requested_contains(requested_caption_names, caption_name)) {
          score += 1;
        }
      }
      if (score > best_score) {
        best_score = score;
        best = process;
      }
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
      result["captionName"] = target.caption_names;
      result["className"] = target.class_names;
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
    const auto process_name = data.at("processName").get<std::string>();
    if (process_name.empty()) {
      throw std::invalid_argument("target processName must not be empty");
    }
    const auto active = find_active_process(data);
    if (!active) {
      send_request("native-port:target-process:" +
                       std::to_string(++target_process_request_sequence_),
                   "targetProcess",
                   {{"status", "failed"},
                    {"processName", process_name},
                    {"message", "the selected process is no longer running"}});
      return;
    }
    targeted_process_ = *active;
    target_game_request_id_.clear();
    auto configuration = capture_configuration(nlohmann::json::object());
    configuration.preferred_source_kind = "application";
    const auto target = *active;
    dispatch_to_main([this, target, configuration] {
      capture_->start_application(target, configuration);
    });
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
          if (packet->track == native_port::TrackKind::game_audio) {
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
                              std::string("test-game"), std::string("NativePortIsolatedTest"));
  }

  [[nodiscard]] nlohmann::json begin_registration(
      const std::string& uuid, const std::filesystem::path& clip_location,
      std::int64_t created_at, double export_duration,
      std::optional<std::string> game_category_id,
      std::optional<std::string> process_name) {
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
        {"metadata", {{"triggerType", "Manual"}, {"exportStatsDuration", export_duration}}},
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
    if (id != "native-port:handshake") {
      return true;
    }
    if (!response.result || !response.result->is_object() || response.result->value("result", "") != "success" ||
        !response.result->contains("data") || response.result->at("data").value("version", 0) != 1) {
      throw std::runtime_error("Electron handshake did not negotiate protocol version 1");
    }
    handshake_complete_ = true;
    send_request("native-port:ready", "recordingReady", nlohmann::json::object());
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
      } else if (request.method == "deleteTargetProcess") {
        const auto process_name = request.params.at("processName").get<std::string>();
        if (targeted_process_ &&
            ((!targeted_process_->application_name.empty() &&
              targeted_process_->application_name == process_name) ||
             targeted_process_->executable_name == process_name)) {
          targeted_process_.reset();
          target_game_request_id_.clear();
          dispatch_to_main([this] { capture_->stop(); });
        }
        respond(request, nullptr);
      } else if (request.method == "audioProcesses") {
        respond(request, nlohmann::json::array());
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
  bool capture_announced_{false};
  std::uint64_t capture_event_sequence_{0};
  std::uint64_t target_process_request_sequence_{0};
  std::string announced_capture_category_id_;
  std::string announced_capture_category_name_;
  std::string capture_session_id_;
  mutable std::mutex capture_event_mutex_;
  nlohmann::json last_capture_event_{{"schemaVersion", 1}, {"state", "idle"}, {"reason", "initialized"}};
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
