#pragma once

#include <nlohmann/json.hpp>

#include <chrono>
#include <string>
#include <vector>

namespace native_port {

struct ClipHotkeyBinding final {
  std::string action;
  std::string inputs;
  std::chrono::seconds duration;
};

// Accepts both the recovered persisted array and the observed settings-RPC
// wrapper {"hotkeys": [...]} without changing either outward representation.
[[nodiscard]] std::vector<ClipHotkeyBinding> parse_clip_hotkeys(const nlohmann::json& value);

}  // namespace native_port
