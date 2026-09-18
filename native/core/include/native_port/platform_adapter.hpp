#pragma once

#include <nlohmann/json.hpp>

#include <memory>
#include <string>
#include <vector>

namespace native_port {

class PlatformAdapter {
 public:
  virtual ~PlatformAdapter() = default;

  [[nodiscard]] virtual nlohmann::json active_displays(bool capture_screenshots) = 0;
  [[nodiscard]] virtual std::vector<std::string> audio_output_devices() = 0;
  [[nodiscard]] virtual std::vector<std::string> microphone_devices() = 0;
  [[nodiscard]] virtual nlohmann::json default_audio_devices() = 0;
  [[nodiscard]] virtual nlohmann::json webcam_devices(bool include_virtual_devices) = 0;
  [[nodiscard]] virtual std::vector<std::string> gpu_devices() const = 0;
  [[nodiscard]] virtual nlohmann::json gpu_codecs() const = 0;
  [[nodiscard]] virtual std::vector<std::string> encoder_options() const = 0;
  [[nodiscard]] virtual nlohmann::json capabilities() const = 0;
};

[[nodiscard]] std::unique_ptr<PlatformAdapter> make_platform_adapter();

}  // namespace native_port
