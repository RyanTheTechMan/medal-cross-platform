#include "native_port/json_rpc.hpp"
#include "native_port/capture_session.hpp"
#include "native_port/platform_adapter.hpp"
#include "native_port/replay_store.hpp"
#include "native_port/settings_store.hpp"

#include <boost/asio/connect.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/websocket.hpp>

#include <atomic>
#include <cerrno>
#include <charconv>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <deque>
#include <exception>
#include <functional>
#include <iostream>
#include <mutex>
#include <optional>
#include <set>
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
          std::scoped_lock lock(capture_event_mutex_);
          last_capture_event_ = std::move(event);
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
      capture_->pump_events();
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
    for (;;) {
      beast::flat_buffer buffer;
      socket.read(buffer);
      const auto message = beast::buffers_to_string(buffer.data());
      if (!handle_message(message)) {
        break;
      }
    }
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

  [[nodiscard]] native_port::CaptureConfiguration capture_configuration(const nlohmann::json& params) const {
    native_port::CaptureConfiguration result;
    result.width = params.value("width", result.width);
    result.height = params.value("height", result.height);
    result.frames_per_second = params.value("framesPerSecond", result.frames_per_second);
    result.bitrate_bits_per_second = params.value("bitrateBitsPerSecond", result.bitrate_bits_per_second);
    const auto codec = native_port::parse_video_codec(params.value("videoCodec", std::string("H264")));
    if (!codec) {
      throw std::invalid_argument("videoCodec must be H264, H265 or AV1");
    }
    result.video_codec = *codec;
    result.show_cursor = params.value("showCursor", result.show_cursor);
    result.capture_system_audio = params.value("captureSystemAudio", result.capture_system_audio);
    result.capture_microphone = params.value("captureMicrophone", result.capture_microphone);
    result.preferred_source_kind = params.value("preferredSourceKind", result.preferred_source_kind);
    return result;
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
      std::string codec = "unknown";
      for (const auto& packet : snapshot->packets) {
        if (packet->track != native_port::TrackKind::video) {
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
    return result;
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
      } else if (request.method == "nativePort.presentSourcePicker") {
        const auto configuration = capture_configuration(request.params);
        dispatch_to_main([this, configuration] { capture_->present_source_picker(configuration); });
        respond(request, {{"accepted", true}});
      } else if (request.method == "nativePort.stopCapture") {
        dispatch_to_main([this] { capture_->stop(); });
        respond(request, {{"accepted", true}});
      } else if (request.method == "nativePort.captureStatus") {
        respond(request, capture_status());
      } else if (request.method == "nativePort.videoEncoderCapabilities") {
        respond(request, {{"gpuDevices", adapter_->gpu_devices()},
                          {"gpuCodecs", adapter_->gpu_codecs()},
                          {"encoderOptions", adapter_->encoder_options()},
                          {"capabilities", adapter_->capabilities()}});
      } else if (request.method == "getTargetedProcesses" || request.method == "getActiveProcesses" ||
                 request.method == "audioProcesses") {
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
  mutable std::mutex capture_event_mutex_;
  nlohmann::json last_capture_event_{{"schemaVersion", 1}, {"state", "idle"}, {"reason", "initialized"}};
  std::mutex main_actions_mutex_;
  std::deque<std::function<void()>> main_actions_;
  std::mutex network_error_mutex_;
  std::exception_ptr network_error_;
  bool handshake_complete_{false};
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
