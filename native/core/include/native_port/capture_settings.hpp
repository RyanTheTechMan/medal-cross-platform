#pragma once

#include "native_port/capture_session.hpp"
#include "native_port/settings_store.hpp"

#include <optional>
#include <string_view>

namespace native_port {

// Maps recovered Medal recorder settings to native capture units. For the
// pinned builds, the imported client's getRecorderValueToSend default branch
// forwards Bitrate unchanged and MedalEncoder.RecordingSession::CreateConfig
// multiplies that effective value by exactly 1,000,000. See the fingerprinted
// research/evidence/bitrate_conversion.json trace; this mapping is not inferred
// from a UI label.
[[nodiscard]] CaptureConfiguration capture_configuration_from_settings(
    const SettingsStore& settings,
    std::optional<std::string_view> category_id = std::nullopt,
    CaptureConfiguration defaults = {});

}  // namespace native_port
