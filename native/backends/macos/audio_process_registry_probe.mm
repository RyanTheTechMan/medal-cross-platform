#import <CoreAudio/CoreAudio.h>
#include "audio_process_registry.hpp"
#include <nlohmann/json.hpp>
#include <iostream>

// Read-only probe restricted to caller-specified synthetic fixture PIDs. Never
// prints the user's complete application/audio-client inventory.
int main(int argc, char** argv) {
  if (argc < 2 || argc > 5) return 2;
  const auto snapshot = native_port::mac_audio_process_snapshot();
  nlohmann::json result{{"snapshotCount", snapshot.size()}, {"fixtures", nlohmann::json::array()}};
  for (int argument = 1; argument < argc; ++argument) {
    const auto pid = static_cast<pid_t>(std::stol(argv[argument]));
    if (pid <= 0) return 2;
    AudioObjectID object = kAudioObjectUnknown;
    AudioObjectPropertyAddress address{kAudioHardwarePropertyTranslatePIDToProcessObject,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 bytes = sizeof(object);
    const auto status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address,
        sizeof(pid), &pid, &bytes, &object);
    nlohmann::json fixture{{"pid", pid}, {"translateStatus", status}, {"object", object}};
    for (const auto selector : {kAudioProcessPropertyIsRunning, kAudioProcessPropertyIsRunningOutput}) {
      address.mSelector = selector; UInt32 value = 0; bytes = sizeof(value);
      const auto query = AudioObjectGetPropertyData(object, &address, 0, nullptr, &bytes, &value);
      fixture[selector == kAudioProcessPropertyIsRunning ? "running" : "output"] =
          {{"status", query}, {"bytes", bytes}, {"value", value}};
    }
    for (const auto& process : snapshot) if (process.pid == pid) {
      fixture["snapshot"] = {{"active", process.output_active}, {"ownerPid", process.owner_pid},
          {"ownerName", process.display_name}, {"ownerBundle", process.owner_bundle_identifier},
          {"devices", process.output_devices.size()}};
    }
    result["fixtures"].push_back(fixture);
  }
  std::cout << result.dump(2) << '\n';
}
