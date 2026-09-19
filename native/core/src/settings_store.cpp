#include "native_port/settings_store.hpp"
#include "native_port/clip_action.hpp"
#include "native_port/video_codec.hpp"

#include <algorithm>
#include <array>
#include <cmath>
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
    if (!update.value.is_number()) {
      throw std::invalid_argument("Bitrate must be a numeric Mbps value");
    }
    const auto value = update.value.get<double>();
    if (!std::isfinite(value) || value < 1.0 || value > 100.0) {
      throw std::invalid_argument("Bitrate must be between 1 and 100 Mbps");
    }
  }
  if (update.key == "Resolution") {
    if (!update.value.is_object() || !update.value.contains("width") || !update.value.contains("height") ||
        !update.value.at("width").is_number_integer() || !update.value.at("height").is_number_integer()) {
      throw std::invalid_argument("Resolution requires integer width and height");
    }
    const auto width = update.value.at("width").get<std::int64_t>();
    const auto height = update.value.at("height").get<std::int64_t>();
    if (width < 64 || width > 7680 || height < 64 || height > 4320) {
      throw std::invalid_argument("Resolution is outside the supported 64x64 through 7680x4320 range");
    }
  }
  if (update.key == "TargetFPS" &&
      (!update.value.is_number_integer() || update.value.get<std::int64_t>() < 1 ||
       update.value.get<std::int64_t>() > 240)) {
    throw std::invalid_argument("TargetFPS must be an integer from 1 through 240");
  }
  if (update.key == "ShowCursor" && !update.value.is_boolean()) {
    throw std::invalid_argument("ShowCursor must be boolean");
  }
  if ((update.key == "GlobalSoundAlerts" || update.key == "ClipSavedSoundAlerts") &&
      !update.value.is_boolean()) {
    throw std::invalid_argument(update.key + " must be boolean");
  }
  if (update.key == "AudioNotificationVolume") {
    if (!update.value.is_number()) {
      throw std::invalid_argument("AudioNotificationVolume must be the normalized numeric wire value");
    }
    const auto value = update.value.get<double>();
    if (!std::isfinite(value) || value < 0.0 || value > 1.5) {
      throw std::invalid_argument("AudioNotificationVolume must be between 0 and 1.5 on the recorder wire");
    }
  }
  if (update.key == "ClipSound" && !update.value.is_string()) {
    throw std::invalid_argument("ClipSound must be a string");
  }
  if (update.key == "ClipSoundPath" && !update.value.is_null() && !update.value.is_string()) {
    throw std::invalid_argument("ClipSoundPath must be null or a string");
  }
  if (update.key == "Codec" &&
      (!update.value.is_string() || !parse_video_codec(update.value.get<std::string>()))) {
    throw std::invalid_argument("Codec must be one of the recovered H264, H265 or AV1 values");
  }
  if (update.key == "Hotkeys") {
    (void)parse_clip_hotkeys(update.value);
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
