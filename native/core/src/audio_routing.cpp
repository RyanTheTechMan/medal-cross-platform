#include "native_port/audio_routing.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace native_port {
namespace {

[[nodiscard]] std::uint32_t checked_percent(const nlohmann::json& value,
                                            std::string_view field_name) {
  if (!value.is_number()) {
    throw std::invalid_argument(std::string(field_name) + " must be numeric");
  }
  const auto percent = value.get<double>();
  if (!std::isfinite(percent) || percent < 0.0 || percent > 150.0) {
    throw std::invalid_argument(std::string(field_name) + " must be finite and between 0 and 150");
  }
  return static_cast<std::uint32_t>(std::llround(percent));
}

[[nodiscard]] bool bool_or(const std::optional<nlohmann::json>& value, bool fallback,
                           std::string_view field_name) {
  if (!value) {
    return fallback;
  }
  if (!value->is_boolean()) {
    throw std::invalid_argument(std::string(field_name) + " must be boolean");
  }
  return value->get<bool>();
}

}  // namespace

double normalize_microphone_gain(const nlohmann::json& value) {
  if (!value.is_number()) {
    throw std::invalid_argument("MicSoundGain must be numeric");
  }
  const auto raw = value.get<double>();
  if (!std::isfinite(raw) || raw < 0.0 || raw > 150.0) {
    throw std::invalid_argument("MicSoundGain must be finite and between 0 and 1.5");
  }
  // The current renderer sends a normalized scalar. Keep this branch direct;
  // the integer-percent branch is only for legacy/default profiles that were
  // persisted before the renderer normalizer ran.
  if (raw <= 1.5) {
    return raw;
  }
  return raw / 100.0;
}

double percent_to_linear_gain(const nlohmann::json& value, std::string_view field_name) {
  const auto percent = checked_percent(value, field_name);
  return static_cast<double>(percent) / 100.0;
}

AudioRoutingPlan audio_routing_plan_from_settings(const SettingsStore& settings,
                                                   std::optional<std::string_view> category_id,
                                                   std::uint64_t generation) {
  AudioRoutingPlan plan;
  plan.generation = generation;

  const auto mode = settings.effective("AudioModeConfig", category_id);
  if (mode) {
    if (!mode->is_object()) {
      throw std::invalid_argument("AudioModeConfig must be an object");
    }
    plan.mode = mode->value("type", plan.mode);
    if (plan.mode.empty()) {
      throw std::invalid_argument("AudioModeConfig.type must not be empty");
    }
    plan.pc_audio_enabled = bool_or(
        mode->contains("pcAudioEnabled") ? std::optional<nlohmann::json>(mode->at("pcAudioEnabled"))
                                          : std::nullopt,
        plan.pc_audio_enabled, "AudioModeConfig.pcAudioEnabled");
    if (mode->contains("volume")) {
      plan.pc_audio_volume_percent = checked_percent(mode->at("volume"), "AudioModeConfig.volume");
      plan.pc_audio_gain_linear = static_cast<double>(plan.pc_audio_volume_percent) / 100.0;
    }
    if (mode->contains("micEnabled")) {
      plan.microphone_enabled = bool_or(mode->at("micEnabled"), plan.microphone_enabled,
                                        "AudioModeConfig.micEnabled");
    }
    if (mode->contains("devices")) {
      if (!mode->at("devices").is_array()) {
        throw std::invalid_argument("AudioModeConfig.devices must be an array");
      }
      for (const auto& device : mode->at("devices")) {
        if (!device.is_object() || !device.contains("name") || !device.at("name").is_string()) {
          throw std::invalid_argument("AudioModeConfig device requires a name");
        }
        if (device.value("enabled", true)) {
          plan.selected_audio_devices.push_back(device.at("name").get<std::string>());
        }
      }
    }
    if (mode->contains("sources")) {
      if (!mode->at("sources").is_array()) {
        throw std::invalid_argument("AudioModeConfig.sources must be an array");
      }
      for (const auto& source : mode->at("sources")) {
        if (!source.is_object() || !source.contains("id") || !source.at("id").is_string()) {
          throw std::invalid_argument("AudioModeConfig source requires a string id");
        }
        AudioRoutingSource resolved;
        resolved.id = source.at("id").get<std::string>();
        resolved.enabled = source.value("enabled", false);
        if (!resolved.enabled) {
          resolved.volume_percent = source.contains("volume")
                                        ? checked_percent(source.at("volume"), "AudioModeConfig.source.volume")
                                        : 0;
          resolved.gain_linear = static_cast<double>(resolved.volume_percent) / 100.0;
          plan.sources.push_back(std::move(resolved));
          continue;
        }
        const auto volume = source.contains("volume") ? source.at("volume") : nlohmann::json(100);
        resolved.volume_percent = checked_percent(volume, "AudioModeConfig.source.volume");
        resolved.gain_linear = static_cast<double>(resolved.volume_percent) / 100.0;
        plan.sources.push_back(std::move(resolved));
      }
    }
  } else if (plan.mode == "splitByProcess") {
    plan.sources.push_back({"game-audio", true, 100, 1.0});
  }

  if (const auto devices = settings.effective("SelectedAudioDevices", category_id); devices) {
    if (!devices->is_array()) {
      throw std::invalid_argument("SelectedAudioDevices must be an array");
    }
    if (plan.selected_audio_devices.empty()) {
      for (const auto& device : *devices) {
        if (!device.is_string()) {
          throw std::invalid_argument("SelectedAudioDevices entries must be strings");
        }
        plan.selected_audio_devices.push_back(device.get<std::string>());
      }
    }
  }

  if (const auto multiple = settings.effective("MultipleAudioTracks", category_id); multiple) {
    if (!multiple->is_boolean()) {
      throw std::invalid_argument("MultipleAudioTracks must be boolean");
    }
    plan.multiple_audio_tracks = multiple->get<bool>();
  }
  if (const auto mic_enabled = settings.effective("MicEnabled", category_id); mic_enabled) {
    if (!mic_enabled->is_boolean()) {
      throw std::invalid_argument("MicEnabled must be boolean");
    }
    plan.microphone_enabled = plan.microphone_enabled && mic_enabled->get<bool>();
  }
  if (const auto mic_gain = settings.effective("MicSoundGain", category_id); mic_gain) {
    plan.microphone_gain_linear = normalize_microphone_gain(*mic_gain);
  }
  if (const auto mic_device = settings.effective("SelectedMicDevice", category_id); mic_device) {
    if (!mic_device->is_string()) {
      throw std::invalid_argument("SelectedMicDevice must be a string");
    }
    const auto name = mic_device->get<std::string>();
    if (!name.empty() && name != "Auto") {
      plan.microphone_device_name = name;
    }
  }
  if (const auto game_only = settings.effective("GameAudioOnly", category_id); game_only) {
    if (!game_only->is_boolean()) {
      throw std::invalid_argument("GameAudioOnly must be boolean");
    }
    if (game_only->get<bool>()) {
      plan.mode = "gameOnly";
      plan.pc_audio_enabled = false;
      for (auto& source : plan.sources) {
        source.enabled = source.id == "game-audio";
      }
    }
  }
  return plan;
}

}  // namespace native_port
