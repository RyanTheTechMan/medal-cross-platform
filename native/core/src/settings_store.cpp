#include "native_port/settings_store.hpp"

#include <algorithm>
#include <array>
#include <mutex>
#include <stdexcept>

namespace native_port {

namespace {

constexpr std::array<std::string_view, 60> kRecoveredKeys = {
    "AdvancedWindowCapture",
    "AspectRatio",
    "AudioModeConfig",
    "Bitrate",
    "ClipFolder",
    "Codec",
    "DevelopmentMode",
    "ProfileRecommendationServicesEnabled",
    "Encoder",
    "ExperimentalCapture",
    "ExternalFileSources",
    "ForceWindowCapture",
    "FpsMode",
    "FullSessionMode",
    "GameAudioOnly",
    "GameControlsCollectionEnabled",
    "ClipSavedSoundAlerts",
    "BookmarkSavedSoundAlerts",
    "SessionToggleSoundAlerts",
    "AutoClippingSoundAlerts",
    "DiskFullSoundAlerts",
    "ScreenshotSoundAlerts",
    "GlobalSoundAlerts",
    "ClipSound",
    "ClipSoundPath",
    "AudioNotificationVolume",
    "HDRCompatibility",
    "Hotkeys",
    "ICYMIEnabled",
    "ICYMIEventSettings",
    "RobloxAutoClipBlacklist",
    "MinecraftAutoClipBlacklist",
    "GTAAutoClipBlacklist",
    "InMemoryBuffer",
    "JWT",
    "MicEnabled",
    "MicNoiseGateEnabled",
    "MicNoiseGateThreshold",
    "MicNoiseSuppressionEnabled",
    "MicSoundGain",
    "MonitorDeviceName",
    "MonoMicAudio",
    "MultipleAudioTracks",
    "PassiveGameSwitchEnabled",
    "PreferGameCapture",
    "PushToTalkEnabled",
    "RecordingEnabled",
    "Resolution",
    "ScreenCaptureEnabled",
    "SDKMode",
    "SelectedAudioDevices",
    "SelectedGPUDevice",
    "SelectedMicDevice",
    "ShowCursor",
    "ShowOverlay",
    "TargetFPS",
    "VoiceClippingEnabled",
    "VoiceClippingAssistantNames",
    "VoiceCommandsActiveConfig",
    "VideoOverlayConfig",
};

void validate_setting(const SettingUpdate& update) {
  if (!SettingsStore::is_recovered_key(update.key)) {
    throw std::invalid_argument("unrecognized recorder setting: " + update.key);
  }
  if (update.category_id && update.category_id->empty()) {
    throw std::invalid_argument("categoryId must be null or a non-empty string");
  }
  if (update.key == "Bitrate") {
    // The unit remains unresolved. Preserve only; no native encoder conversion occurs here.
    if (!update.value.is_number()) {
      throw std::invalid_argument("Bitrate must remain a numeric recovered value");
    }
  }
  if (update.key == "Resolution") {
    if (!update.value.is_object() || !update.value.contains("width") || !update.value.contains("height") ||
        !update.value.at("width").is_number_integer() || !update.value.at("height").is_number_integer()) {
      throw std::invalid_argument("Resolution requires integer width and height");
    }
  }
  if (update.key == "Hotkeys" && !update.value.is_object()) {
    throw std::invalid_argument("Hotkeys must preserve its nested object shape");
  }
}

}  // namespace

SettingsStore::SettingsStore() = default;

void SettingsStore::apply(const std::vector<SettingUpdate>& updates) {
  for (const auto& update : updates) {
    validate_setting(update);
  }

  std::unique_lock lock(mutex_);
  for (const auto& update : updates) {
    if (update.category_id) {
      per_game_[*update.category_id].insert_or_assign(update.key, update.value);
    } else {
      globals_.insert_or_assign(update.key, update.value);
    }
  }
}

void SettingsStore::delete_custom_game_settings(const std::vector<std::string>& category_ids) {
  std::unique_lock lock(mutex_);
  for (const auto& category_id : category_ids) {
    if (category_id.empty()) {
      throw std::invalid_argument("category ID must not be empty");
    }
    per_game_.erase(category_id);
  }
}

void SettingsStore::delete_custom_game_settings(const std::string& category_id,
                                                 const std::vector<std::string>& keys) {
  if (category_id.empty()) {
    throw std::invalid_argument("category ID must not be empty");
  }
  for (const auto& key : keys) {
    if (!is_recovered_key(key)) {
      throw std::invalid_argument("unrecognized recorder setting: " + key);
    }
  }

  std::unique_lock lock(mutex_);
  const auto category = per_game_.find(category_id);
  if (category == per_game_.end()) {
    return;
  }
  for (const auto& key : keys) {
    category->second.erase(key);
  }
  if (category->second.empty()) {
    per_game_.erase(category);
  }
}

std::optional<nlohmann::json> SettingsStore::global(std::string_view key) const {
  std::shared_lock lock(mutex_);
  const auto found = globals_.find(key);
  if (found == globals_.end()) {
    return std::nullopt;
  }
  return found->second;
}

std::optional<nlohmann::json> SettingsStore::effective(std::string_view key,
                                                       std::optional<std::string_view> category_id) const {
  std::shared_lock lock(mutex_);
  if (category_id) {
    const auto category = per_game_.find(*category_id);
    if (category != per_game_.end()) {
      const auto override_value = category->second.find(key);
      if (override_value != category->second.end()) {
        return override_value->second;
      }
    }
  }
  const auto found = globals_.find(key);
  if (found == globals_.end()) {
    return std::nullopt;
  }
  return found->second;
}

nlohmann::json SettingsStore::snapshot() const {
  std::shared_lock lock(mutex_);
  nlohmann::json output = { { "global", nlohmann::json::object() }, { "perGame", nlohmann::json::object() } };
  for (const auto& [key, value] : globals_) {
    output["global"][key] = value;
  }
  for (const auto& [category_id, values] : per_game_) {
    for (const auto& [key, value] : values) {
      output["perGame"][category_id][key] = value;
    }
  }
  return output;
}

bool SettingsStore::is_recovered_key(std::string_view key) noexcept {
  return std::find(kRecoveredKeys.begin(), kRecoveredKeys.end(), key) != kRecoveredKeys.end();
}

}  // namespace native_port
