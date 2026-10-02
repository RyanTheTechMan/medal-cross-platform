#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>
#include <libproc.h>
#include <sys/proc_info.h>

#include "audio_process_registry.hpp"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <set>

namespace native_port {
namespace {
std::string text(NSString* value) { return value.UTF8String ? value.UTF8String : ""; }
std::string lower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
  return value;
}
bool inside_bundle(const std::string& executable, const std::string& bundle) {
  return !bundle.empty() && executable.size() > bundle.size() &&
         executable.starts_with(bundle) && executable[bundle.size()] == '/';
}
template<class T> std::optional<T> scalar(AudioObjectID object, AudioObjectPropertySelector key) {
  AudioObjectPropertyAddress address{key, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  T result{}; UInt32 bytes = sizeof(result);
  if (AudioObjectGetPropertyData(object, &address, 0, nullptr, &bytes, &result) != noErr || bytes != sizeof(result)) return {};
  return result;
}
std::string string_property(AudioObjectID object, AudioObjectPropertySelector key) {
  AudioObjectPropertyAddress address{key, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  CFStringRef value = nullptr; UInt32 bytes = sizeof(value);
  if (AudioObjectGetPropertyData(object, &address, 0, nullptr, &bytes, &value) != noErr || !value) return {};
  const auto result = text((__bridge NSString*)value); CFRelease(value); return result;
}
std::vector<AudioObjectID> objects(AudioObjectID object, AudioObjectPropertySelector key,
                                   AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
  AudioObjectPropertyAddress address{key, scope, kAudioObjectPropertyElementMain};
  UInt32 bytes = 0;
  if (AudioObjectGetPropertyDataSize(object, &address, 0, nullptr, &bytes) != noErr || bytes % sizeof(AudioObjectID)) return {};
  std::vector<AudioObjectID> result(bytes / sizeof(AudioObjectID));
  if (bytes && AudioObjectGetPropertyData(object, &address, 0, nullptr, &bytes, result.data()) != noErr) return {};
  return result;
}
}

void resolve_audio_process_owners(std::vector<MacAudioProcess>& processes,
                                 const std::vector<MacApplicationIdentity>& applications) {
  for (auto& process : processes) {
    const MacApplicationIdentity* owner = nullptr;
    // Prefer a real containing outer application bundle over a nested helper.
    std::vector<const MacApplicationIdentity*> candidates;
    for (const auto& application : applications) {
      if (!inside_bundle(process.executable_path, application.bundle_path)) continue;
      if (candidates.empty() || application.bundle_path.size() < candidates[0]->bundle_path.size()) candidates.clear();
      if (candidates.empty() || application.bundle_path.size() == candidates[0]->bundle_path.size()) candidates.push_back(&application);
    }
    if (candidates.size() == 1) owner = candidates[0];
    else if (!candidates.empty()) {
      // Two live instances of one bundle are not distinguishable by path.
      // Require exact PID/ancestry evidence rather than choosing the first.
      for (const auto* candidate : candidates) if (candidate->pid == process.pid) { owner = candidate; break; }
      if (!owner) for (const auto ancestor : process.ancestors) {
        for (const auto* candidate : candidates) if (candidate->pid == ancestor) { owner = candidate; break; }
        if (owner) break;
      }
    }
    if (!owner) for (const auto& application : applications) {
      if (application.pid == process.pid) { owner = &application; break; }
    }
    if (!owner) for (const auto ancestor : process.ancestors) {
      const auto found = std::find_if(applications.begin(), applications.end(),
          [ancestor](const auto& application) { return application.pid == ancestor; });
      if (found != applications.end()) { owner = &*found; break; }
    }
    if (owner) {
      process.owner_pid = owner->pid;
      process.owner_bundle_identifier = owner->bundle_identifier;
      process.owner_bundle_path = owner->bundle_path;
      process.owner_executable_name = owner->executable_name;
      process.display_name = owner->display_name;
    } else {
      process.owner_pid = process.pid;
      process.owner_bundle_identifier = process.bundle_identifier;
      process.owner_executable_name = std::filesystem::path(process.executable_path).filename().string();
      process.display_name = process.owner_executable_name.empty() ? process.bundle_identifier : process.owner_executable_name;
    }
  }
}

std::vector<std::int64_t> resolve_audio_family(const std::vector<MacAudioProcess>& processes,
                                             const std::string& source_id,
                                             std::optional<std::int64_t> target_pid) {
  // This recovered virtual feedback source is NOT all audio from the host.
  if (source_id == "MedalEncoder.exe" || source_id == "medal-clip-sound") return {};
  auto requested = lower(source_id);
  if (requested.ends_with(".exe")) requested.resize(requested.size() - 4);
  std::set<std::int64_t> pids;
  for (const auto& process : processes) {
    if (process.pid <= 0) continue;
    const bool selected = source_id == "game-audio"
      ? target_pid && (*target_pid == process.pid || *target_pid == process.owner_pid ||
          std::find(process.ancestors.begin(), process.ancestors.end(), *target_pid) != process.ancestors.end())
      : !requested.empty() && (requested == lower(process.display_name) ||
          requested == lower(process.owner_executable_name) || requested == lower(process.owner_bundle_identifier));
    if (selected) pids.insert(process.pid);
  }
  return {pids.begin(), pids.end()};
}

std::vector<MacAudioProcess> mac_audio_process_snapshot() {
  @autoreleasepool {
    std::vector<MacApplicationIdentity> applications;
    for (NSRunningApplication* app in NSWorkspace.sharedWorkspace.runningApplications) {
      if (app.processIdentifier <= 0) continue;
      applications.push_back({app.processIdentifier, text(app.bundleIdentifier), text(app.bundleURL.path),
                             text(app.executableURL.lastPathComponent), text(app.localizedName)});
    }
    std::vector<MacAudioProcess> result;
    for (const auto object : objects(kAudioObjectSystemObject, kAudioHardwarePropertyProcessObjectList)) {
      const auto pid = scalar<pid_t>(object, kAudioProcessPropertyPID);
      if (!pid || *pid <= 0) continue;
      MacAudioProcess process;
      process.audio_object = object; process.pid = *pid;
      process.bundle_identifier = string_property(object, kAudioProcessPropertyBundleID);
      process.output_active = scalar<UInt32>(object, kAudioProcessPropertyIsRunningOutput).value_or(0) != 0;
      process.output_devices = objects(object, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput);
      char executable[PROC_PIDPATHINFO_MAXSIZE]{};
      if (proc_pidpath(*pid, executable, sizeof(executable)) > 0) process.executable_path = executable;
      pid_t cursor = *pid;
      for (int depth = 0; depth < 32; ++depth) {
        proc_bsdinfo info{};
        if (proc_pidinfo(cursor, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
            info.pbi_ppid <= 1 || info.pbi_ppid == static_cast<unsigned>(cursor) ||
            std::find(process.ancestors.begin(), process.ancestors.end(), info.pbi_ppid) != process.ancestors.end()) break;
        cursor = info.pbi_ppid; process.ancestors.push_back(cursor);
      }
      result.push_back(std::move(process));
    }
    resolve_audio_process_owners(result, applications);
    return result;
  }
}
}  // namespace native_port
