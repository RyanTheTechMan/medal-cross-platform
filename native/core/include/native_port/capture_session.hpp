#pragma once

#include "native_port/encoded_packet.hpp"
#include "native_port/audio_routing.hpp"
#include "native_port/process_identity.hpp"
#include "native_port/video_codec.hpp"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace native_port {

struct CaptureConfiguration final {
  std::size_t width{1920};
  std::size_t height{1080};
  std::uint32_t frames_per_second{60};
  std::uint64_t bitrate_bits_per_second{20'000'000};
  VideoCodec video_codec{VideoCodec::h264};
  bool show_cursor{true};
  bool capture_system_audio{false};
  bool capture_microphone{false};
  AudioRoutingPlan audio_plan{};
  // These fields mirror the recovered Medal AudioModeConfig wire object. They
  // are intentionally native-side state; the Electron client only exchanges
  // the completed-file metadata and setting updates.
  std::string audio_mode{"splitByProcess"};
  bool pc_audio_enabled{true};
  double system_audio_volume_percent{100};
  double microphone_gain_linear{0.5};
  std::vector<std::string> selected_audio_devices{"Auto"};
  struct AudioSource final {
    std::string id;
    bool enabled{false};
    double volume_percent{100};
    double gain_linear{1.0};
  };
  std::vector<AudioSource> audio_sources;
  bool multiple_audio_tracks{true};
  std::optional<std::int64_t> target_process_id;
  // Empty selects the macOS/default input device.  When Medal's
  // SelectedMicDevice is a concrete device label, the macOS adapter resolves
  // that label to ScreenCaptureKit's device UID before starting the stream.
  std::optional<std::string> microphone_device_name;
  std::string preferred_source_kind{"display"};
};

using CaptureEventCallback = std::function<void(nlohmann::json)>;
using EncodedPacketCallback = std::function<void(std::shared_ptr<const EncodedPacket>)>;
using CaptureClockCallback = std::function<void(std::int64_t)>;

class CaptureSession {
 public:
  virtual ~CaptureSession() = default;

  virtual void enumerate_shareable_content() = 0;
  virtual void present_source_picker(const CaptureConfiguration& configuration) = 0;
  virtual void start_display(std::uint32_t display_id,
                             const CaptureConfiguration& configuration) = 0;
  virtual void start_application(const std::string& process_name,
                                 const CaptureConfiguration& configuration) = 0;
  // Native target-aware overload.  The default keeps non-macOS adapters
  // source-compatible while allowing macOS to match ScreenCaptureKit by PID.
  virtual void start_application(const ProcessIdentity& target,
                                 const CaptureConfiguration& configuration) {
    const auto& name = target.screen_capture_application_name.empty()
                           ? (target.application_name.empty() ? target.executable_name
                                                              : target.application_name)
                           : target.screen_capture_application_name;
    start_application(name, configuration);
  }
  virtual void stop() = 0;
  // Apply a fully normalized plan to an active session. Implementations may
  // update gains in place or perform an audio-only generation transition;
  // video and retained replay state must not be discarded for a gain change.
  virtual void apply_audio_plan(const AudioRoutingPlan& plan) = 0;
  virtual void pump_events() = 0;
  [[nodiscard]] virtual nlohmann::json status() const = 0;
};

[[nodiscard]] std::unique_ptr<CaptureSession> make_capture_session(CaptureEventCallback event_callback,
                                                                   EncodedPacketCallback packet_callback,
                                                                   CaptureClockCallback clock_callback);

}  // namespace native_port
