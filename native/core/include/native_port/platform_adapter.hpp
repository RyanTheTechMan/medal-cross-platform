#pragma once

#include "native_port/clip_action.hpp"

#include <nlohmann/json.hpp>

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace native_port {

struct ClipSavedFeedback final {
  bool play_sound{true};
  double volume{1.0};
  std::optional<std::string> sound_path;
  std::optional<std::string> icon_path;
  std::string title{"Medal"};
  std::string message{"Clip saved"};
};

class PlatformAdapter {
 public:
  using ClipHotkeyCallback = std::function<void(const ClipHotkeyBinding&)>;

  virtual ~PlatformAdapter() = default;

  [[nodiscard]] virtual nlohmann::json active_displays(bool capture_screenshots) = 0;
  [[nodiscard]] virtual nlohmann::json active_processes() = 0;
  [[nodiscard]] virtual std::vector<std::string> audio_output_devices() = 0;
  [[nodiscard]] virtual std::vector<std::string> microphone_devices() = 0;
  [[nodiscard]] virtual nlohmann::json default_audio_devices() = 0;
  [[nodiscard]] virtual nlohmann::json webcam_devices(bool include_virtual_devices) = 0;
  [[nodiscard]] virtual std::vector<std::string> gpu_devices() const = 0;
  [[nodiscard]] virtual nlohmann::json gpu_codecs() const = 0;
  [[nodiscard]] virtual std::vector<std::string> encoder_options() const = 0;
  [[nodiscard]] virtual nlohmann::json capabilities() const = 0;
  [[nodiscard]] virtual nlohmann::json interactive_session_status() const = 0;
  // The native helper owns its main loop instead of entering a framework run
  // function, so platform event delivery must be pumped explicitly.
  virtual void pump_events() = 0;
  // Called on the helper's platform/main thread only after the imported Medal
  // client acknowledges contentCreate for a physical clip action.
  virtual void present_clip_saved_feedback(const ClipSavedFeedback& feedback) = 0;
  virtual void configure_clip_hotkeys(const std::vector<ClipHotkeyBinding>& bindings,
                                      ClipHotkeyCallback callback) = 0;
  [[nodiscard]] virtual nlohmann::json clip_hotkey_status() const = 0;
};

[[nodiscard]] std::unique_ptr<PlatformAdapter> make_platform_adapter();

}  // namespace native_port
