#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace native_port {

// Stable native identity used between the helper and platform adapters.  The
// Medal wire DTO is deliberately not used as the recorder's process model.
struct ProcessWindowIdentity final {
  std::uint64_t window_id{0};
  std::string title;
};

struct ProcessIdentity final {
  std::int64_t pid{0};
  std::string bundle_identifier;
  std::string executable_path;
  std::string executable_name;
  std::string application_name;
  // ScreenCaptureKit's SCRunningApplication.applicationName.  This can differ
  // from NSRunningApplication.localizedName for Java-launched games.
  std::string screen_capture_application_name;
  std::string screen_capture_application_identifier;
  std::vector<ProcessWindowIdentity> windows;
  std::vector<std::string> caption_names;
  std::vector<std::string> class_names;
};

}  // namespace native_port
