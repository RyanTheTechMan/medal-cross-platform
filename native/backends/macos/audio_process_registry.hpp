#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace native_port {

// Native identities, never the Windows-shaped process DTO. HAL is the audio
// authority; AppKit/process ancestry only supplies verifiable family ownership.
struct MacAudioProcess final {
  std::uint32_t audio_object{0};
  std::int64_t pid{0};
  std::vector<std::int64_t> ancestors;
  std::string executable_path;
  std::string bundle_identifier;
  bool output_active{false};
  std::vector<std::uint32_t> output_devices;
  std::int64_t owner_pid{0};
  std::string owner_bundle_identifier;
  std::string owner_bundle_path;
  std::string owner_executable_name;
  std::string display_name;
};

struct MacApplicationIdentity final {
  std::int64_t pid{0};
  std::string bundle_identifier;
  std::string bundle_path;
  std::string executable_name;
  std::string display_name;
};

// Pure policy, also used by the injected-identity regression test. Bundle path
// ownership uses a component boundary, not a bundle-ID/name prefix heuristic.
void resolve_audio_process_owners(std::vector<MacAudioProcess>& processes,
                                 const std::vector<MacApplicationIdentity>& applications);
[[nodiscard]] std::vector<std::int64_t> resolve_audio_family(
    const std::vector<MacAudioProcess>& processes, const std::string& source_id,
    std::optional<std::int64_t> target_pid = std::nullopt);
[[nodiscard]] std::vector<MacAudioProcess> mac_audio_process_snapshot();

}  // namespace native_port
