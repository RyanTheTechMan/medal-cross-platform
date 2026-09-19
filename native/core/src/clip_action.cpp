#include "native_port/clip_action.hpp"

#include <charconv>
#include <set>
#include <stdexcept>
#include <string_view>

namespace native_port {
namespace {

constexpr std::string_view kClipPrefix = "clip;length=";

[[nodiscard]] const nlohmann::json& hotkey_array(const nlohmann::json& value) {
  if (value.is_array()) {
    return value;
  }
  if (value.is_object() && value.contains("hotkeys") && value.at("hotkeys").is_array()) {
    return value.at("hotkeys");
  }
  throw std::invalid_argument("Hotkeys must be the recovered array or an object containing a hotkeys array");
}

[[nodiscard]] std::chrono::seconds clip_duration(std::string_view action) {
  if (!action.starts_with(kClipPrefix)) {
    throw std::invalid_argument("clip action must use the recovered clip;length=N grammar");
  }
  const auto text = action.substr(kClipPrefix.size());
  unsigned int seconds = 0;
  const auto [end, error] = std::from_chars(text.data(), text.data() + text.size(), seconds);
  if (error != std::errc{} || end != text.data() + text.size() || seconds < 1 || seconds > 120) {
    throw std::invalid_argument("clip action length must be an integer from 1 through 120 seconds");
  }
  return std::chrono::seconds(seconds);
}

}  // namespace

std::vector<ClipHotkeyBinding> parse_clip_hotkeys(const nlohmann::json& value) {
  std::vector<ClipHotkeyBinding> result;
  std::set<std::string, std::less<>> registered_inputs;
  for (const auto& item : hotkey_array(value)) {
    if (!item.is_object() || !item.contains("action") || !item.at("action").is_string()) {
      throw std::invalid_argument("each Hotkeys entry must contain a string action");
    }
    const auto action = item.at("action").get<std::string>();
    if (!std::string_view(action).starts_with("clip;")) {
      continue;
    }
    if (item.value("device", std::string{}) != "keyboard" ||
        item.value("type", std::string{}) != "short_press" ||
        !item.contains("inputs") || !item.at("inputs").is_string()) {
      throw std::invalid_argument("clip hotkeys currently require a keyboard short_press binding");
    }
    const auto inputs = item.at("inputs").get<std::string>();
    if (inputs.empty()) {
      throw std::invalid_argument("clip hotkey inputs must not be empty");
    }
    if (!registered_inputs.insert(inputs).second) {
      throw std::invalid_argument("duplicate clip hotkey inputs are ambiguous: " + inputs);
    }
    result.push_back({.action = action, .inputs = inputs, .duration = clip_duration(action)});
  }
  return result;
}

}  // namespace native_port
