#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>

#include "native_port/platform_adapter.hpp"
#include "audio_process_registry.hpp"

#include <array>
#include <algorithm>
#include <chrono>
#include <cctype>
#include <cmath>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace native_port {
namespace {

constexpr auto kScreenshotTimeout = std::chrono::seconds(8);

struct ScreenshotResults final {
  std::mutex mutex;
  std::map<CGDirectDisplayID, std::string> data_urls;
};

[[nodiscard]] std::string jpeg_data_url(CGImageRef image) {
  if (image == nullptr) {
    return {};
  }
  @autoreleasepool {
    NSMutableData* data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)data, CFSTR("public.jpeg"), 1, nullptr);
    if (destination == nullptr) {
      return {};
    }
    NSDictionary* properties = @{(__bridge NSString*)kCGImageDestinationLossyCompressionQuality : @0.72};
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)properties);
    const bool finalized = CGImageDestinationFinalize(destination) != false;
    CFRelease(destination);
    if (!finalized || data.length == 0) {
      return {};
    }
    NSString* encoded = [data base64EncodedStringWithOptions:0];
    if (encoded.length == 0) {
      return {};
    }
    return "data:image/jpeg;base64," + std::string(encoded.UTF8String);
  }
}

[[nodiscard]] std::map<CGDirectDisplayID, std::string> display_screenshots() {
  @autoreleasepool {
    dispatch_semaphore_t content_ready = dispatch_semaphore_create(0);
    __block SCShareableContent* content = nil;
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                               onScreenWindowsOnly:YES
                                                  completionHandler:^(SCShareableContent* shareable,
                                                                      NSError*) {
      content = shareable;
      dispatch_semaphore_signal(content_ready);
    }];
    const auto deadline = dispatch_time(DISPATCH_TIME_NOW,
                                        static_cast<int64_t>(kScreenshotTimeout.count()) * NSEC_PER_SEC);
    if (dispatch_semaphore_wait(content_ready, deadline) != 0 || content == nil) {
      return {};
    }

    auto results = std::make_shared<ScreenshotResults>();
    dispatch_group_t captures = dispatch_group_create();
    for (SCDisplay* display in content.displays) {
      SCContentFilter* filter = [[SCContentFilter alloc] initWithDisplay:display
                                                        excludingWindows:@[]];
      SCStreamConfiguration* configuration = [[SCStreamConfiguration alloc] init];
      const double scale = std::min(1.0, 640.0 / std::max(1.0, static_cast<double>(display.width)));
      configuration.width = static_cast<size_t>(std::max(2.0, std::floor(display.width * scale / 2.0) * 2.0));
      configuration.height = static_cast<size_t>(std::max(2.0, std::floor(display.height * scale / 2.0) * 2.0));
      configuration.scalesToFit = YES;
      configuration.preservesAspectRatio = YES;
      configuration.showsCursor = NO;
      const auto display_id = display.displayID;
      dispatch_group_enter(captures);
      [SCScreenshotManager captureImageWithFilter:filter
                                     configuration:configuration
                                 completionHandler:^(CGImageRef image, NSError*) {
        auto data_url = jpeg_data_url(image);
        if (!data_url.empty()) {
          std::scoped_lock lock(results->mutex);
          results->data_urls.emplace(display_id, std::move(data_url));
        }
        dispatch_group_leave(captures);
      }];
    }
    if (dispatch_group_wait(captures, deadline) != 0) {
      return {};
    }
    std::scoped_lock lock(results->mutex);
    return results->data_urls;
  }
}

std::string cf_string_to_utf8(CFStringRef value) {
  if (value == nullptr) {
    return {};
  }
  const auto length = CFStringGetLength(value);
  const auto maximum = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
  std::vector<char> buffer(static_cast<std::size_t>(maximum));
  if (!CFStringGetCString(value, buffer.data(), maximum, kCFStringEncodingUTF8)) {
    return {};
  }
  return buffer.data();
}

std::string audio_object_name(AudioObjectID object) {
  AudioObjectPropertyAddress address{
      kAudioObjectPropertyName,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain,
  };
  CFStringRef name = nullptr;
  UInt32 size = sizeof(name);
  if (AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, &name) != noErr || name == nullptr) {
    return "Audio Device " + std::to_string(object);
  }
  const auto converted = cf_string_to_utf8(name);
  CFRelease(name);
  return converted.empty() ? "Audio Device " + std::to_string(object) : converted;
}

bool device_has_streams(AudioObjectID device, AudioObjectPropertyScope scope) {
  AudioObjectPropertyAddress address{
      kAudioDevicePropertyStreams,
      scope,
      kAudioObjectPropertyElementMain,
  };
  UInt32 size = 0;
  return AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) == noErr && size > 0;
}

std::vector<AudioObjectID> audio_devices() {
  AudioObjectPropertyAddress address{
      kAudioHardwarePropertyDevices,
      kAudioObjectPropertyScopeGlobal,
      kAudioObjectPropertyElementMain,
  };
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, nullptr, &size) != noErr) {
    throw std::runtime_error("CoreAudio device enumeration failed");
  }
  std::vector<AudioObjectID> devices(size / sizeof(AudioObjectID));
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, devices.data()) != noErr) {
    throw std::runtime_error("CoreAudio device enumeration failed");
  }
  return devices;
}

AudioObjectID default_device(AudioObjectPropertySelector selector) {
  AudioObjectPropertyAddress address{selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  AudioObjectID device = kAudioObjectUnknown;
  UInt32 size = sizeof(device);
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, &device) != noErr) {
    return kAudioObjectUnknown;
  }
  return device;
}

std::set<CMVideoCodecType> hardware_encoder_codecs() {
  CFArrayRef encoders = nullptr;
  if (VTCopyVideoEncoderList(nullptr, &encoders) != noErr || encoders == nullptr) {
    return {};
  }
  std::set<CMVideoCodecType> result;
  const auto count = CFArrayGetCount(encoders);
  for (CFIndex index = 0; index < count; ++index) {
    auto* entry = static_cast<CFDictionaryRef>(const_cast<void*>(CFArrayGetValueAtIndex(encoders, index)));
    if (CFDictionaryGetValue(entry, kVTVideoEncoderList_IsHardwareAccelerated) != kCFBooleanTrue) {
      continue;
    }
    auto* codec_number = static_cast<CFNumberRef>(
        const_cast<void*>(CFDictionaryGetValue(entry, kVTVideoEncoderList_CodecType)));
    std::int32_t codec = 0;
    if (codec_number != nullptr && CFNumberGetValue(codec_number, kCFNumberSInt32Type, &codec)) {
      result.insert(static_cast<CMVideoCodecType>(codec));
    }
  }
  CFRelease(encoders);
  return result;
}

std::string gpu_device_name() {
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil || device.name.length == 0) {
      return "Apple VideoToolbox";
    }
    const char* name = device.name.UTF8String;
    return name != nullptr ? name : "Apple VideoToolbox";
  }
}

[[nodiscard]] std::string uppercase_trimmed(std::string value) {
  const auto first = std::find_if_not(value.begin(), value.end(), [](unsigned char character) {
    return std::isspace(character) != 0;
  });
  const auto last = std::find_if_not(value.rbegin(), value.rend(), [](unsigned char character) {
    return std::isspace(character) != 0;
  }).base();
  if (first >= last) {
    return {};
  }
  std::string result(first, last);
  std::transform(result.begin(), result.end(), result.begin(), [](unsigned char character) {
    return static_cast<char>(std::toupper(character));
  });
  return result;
}

struct CarbonKey final {
  UInt32 key_code{0};
  UInt32 modifiers{0};
};

[[nodiscard]] std::optional<UInt32> carbon_key_code(std::string_view key) {
  static const std::map<std::string_view, UInt32, std::less<>> keys = {
      {"A", kVK_ANSI_A}, {"B", kVK_ANSI_B}, {"C", kVK_ANSI_C}, {"D", kVK_ANSI_D},
      {"E", kVK_ANSI_E}, {"F", kVK_ANSI_F}, {"G", kVK_ANSI_G}, {"H", kVK_ANSI_H},
      {"I", kVK_ANSI_I}, {"J", kVK_ANSI_J}, {"K", kVK_ANSI_K}, {"L", kVK_ANSI_L},
      {"M", kVK_ANSI_M}, {"N", kVK_ANSI_N}, {"O", kVK_ANSI_O}, {"P", kVK_ANSI_P},
      {"Q", kVK_ANSI_Q}, {"R", kVK_ANSI_R}, {"S", kVK_ANSI_S}, {"T", kVK_ANSI_T},
      {"U", kVK_ANSI_U}, {"V", kVK_ANSI_V}, {"W", kVK_ANSI_W}, {"X", kVK_ANSI_X},
      {"Y", kVK_ANSI_Y}, {"Z", kVK_ANSI_Z}, {"0", kVK_ANSI_0}, {"1", kVK_ANSI_1},
      {"2", kVK_ANSI_2}, {"3", kVK_ANSI_3}, {"4", kVK_ANSI_4}, {"5", kVK_ANSI_5},
      {"6", kVK_ANSI_6}, {"7", kVK_ANSI_7}, {"8", kVK_ANSI_8}, {"9", kVK_ANSI_9},
      {"F1", kVK_F1}, {"F2", kVK_F2}, {"F3", kVK_F3}, {"F4", kVK_F4},
      {"F5", kVK_F5}, {"F6", kVK_F6}, {"F7", kVK_F7}, {"F8", kVK_F8},
      {"F9", kVK_F9}, {"F10", kVK_F10}, {"F11", kVK_F11}, {"F12", kVK_F12},
      {"F13", kVK_F13}, {"F14", kVK_F14}, {"F15", kVK_F15}, {"F16", kVK_F16},
      {"F17", kVK_F17}, {"F18", kVK_F18}, {"F19", kVK_F19}, {"F20", kVK_F20},
      {"SPACE", kVK_Space}, {"TAB", kVK_Tab}, {"RETURN", kVK_Return}, {"ENTER", kVK_Return},
      {"ESC", kVK_Escape}, {"ESCAPE", kVK_Escape}, {"BACKSPACE", kVK_Delete},
      {"DELETE", kVK_ForwardDelete}, {"LEFT", kVK_LeftArrow}, {"RIGHT", kVK_RightArrow},
      {"UP", kVK_UpArrow}, {"DOWN", kVK_DownArrow}, {"HOME", kVK_Home}, {"END", kVK_End},
      {"PAGEUP", kVK_PageUp}, {"PAGEDOWN", kVK_PageDown},
  };
  const auto found = keys.find(key);
  return found == keys.end() ? std::nullopt : std::optional<UInt32>(found->second);
}

[[nodiscard]] CarbonKey parse_carbon_key(std::string_view inputs) {
  CarbonKey result;
  bool has_key = false;
  std::size_t start = 0;
  while (start <= inputs.size()) {
    const auto separator = inputs.find('+', start);
    const auto end = separator == std::string_view::npos ? inputs.size() : separator;
    const auto token = uppercase_trimmed(std::string(inputs.substr(start, end - start)));
    if (token == "ALT" || token == "OPTION") {
      result.modifiers |= optionKey;
    } else if (token == "CTRL" || token == "CONTROL") {
      result.modifiers |= controlKey;
    } else if (token == "SHIFT") {
      result.modifiers |= shiftKey;
    } else if (token == "CMD" || token == "COMMAND" || token == "META") {
      result.modifiers |= cmdKey;
    } else if (const auto key = carbon_key_code(token); key && !has_key) {
      result.key_code = *key;
      has_key = true;
    } else {
      throw std::invalid_argument("unsupported or ambiguous macOS hotkey token: " + token);
    }
    if (separator == std::string_view::npos) {
      break;
    }
    start = separator + 1;
  }
  if (!has_key) {
    throw std::invalid_argument("macOS hotkey has no supported non-modifier key");
  }
  return result;
}

class MacPlatformAdapter final : public PlatformAdapter {
 public:
  MacPlatformAdapter()
      : hardware_codecs_(hardware_encoder_codecs()),
        gpu_device_name_(gpu_device_name()),
        h264_hardware_decode_(VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) != false),
        hevc_hardware_decode_(VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) != false),
        av1_hardware_decode_(VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) != false) {}
  ~MacPlatformAdapter() override { clear_hotkeys(); }

  std::int64_t capture_clock_nanoseconds() const override {
    const auto now = CMClockGetTime(CMClockGetHostTimeClock());
    if (!CMTIME_IS_NUMERIC(now) || now.value < 0)
      throw std::runtime_error("CoreMedia host capture clock is unavailable");
    return CMTimeConvertScale(now, 1'000'000'000, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
  }

  nlohmann::json active_displays(bool capture_screenshots) override {
    std::array<CGDirectDisplayID, 32> displays{};
    uint32_t count = 0;
    if (CGGetActiveDisplayList(static_cast<uint32_t>(displays.size()), displays.data(), &count) !=
        kCGErrorSuccess) {
      throw std::runtime_error("CoreGraphics display enumeration failed");
    }
    std::map<CGDirectDisplayID, std::string> screenshots;
    if (capture_screenshots) {
      const auto now = std::chrono::steady_clock::now();
      bool cache_complete = true;
      {
        std::scoped_lock lock(preview_cache_mutex_);
        for (uint32_t index = 0; index < count; ++index) {
          const auto display = displays[index];
          const auto width = CGDisplayPixelsWide(display);
          const auto height = CGDisplayPixelsHigh(display);
          const auto found = preview_cache_.find(display);
          if (found == preview_cache_.end() || found->second.width != width ||
              found->second.height != height || now - found->second.created_at > preview_cache_ttl_) {
            cache_complete = false;
            continue;
          }
          screenshots.emplace(display, found->second.data_url);
        }
      }
      if (!cache_complete) {
        const auto fresh = display_screenshots();
        std::scoped_lock lock(preview_cache_mutex_);
        for (uint32_t index = 0; index < count; ++index) {
          const auto display = displays[index];
          const auto found = fresh.find(display);
          if (found == fresh.end()) {
            continue;
          }
          preview_cache_[display] = PreviewCacheEntry{
              .data_url = found->second,
              .width = static_cast<std::uint32_t>(CGDisplayPixelsWide(display)),
              .height = static_cast<std::uint32_t>(CGDisplayPixelsHigh(display)),
              .created_at = now,
          };
          screenshots[display] = found->second;
        }
      }
    }
    nlohmann::json result = nlohmann::json::array();
    for (uint32_t index = 0; index < count; ++index) {
      const auto display = displays[index];
      const auto width = CGDisplayPixelsWide(display);
      const auto height = CGDisplayPixelsHigh(display);
      const auto screenshot = screenshots.find(display);
      result.push_back({
          {"DeviceName", "display:" + std::to_string(display)},
          {"FriendlyName", "Display " + std::to_string(index + 1) + " (" + std::to_string(width) +
                               "x" + std::to_string(height) + ")"},
          {"CurrentScreenshot", screenshot == screenshots.end()
                                    ? nlohmann::json(nullptr)
                                    : nlohmann::json(screenshot->second)},
          {"CurrentScreenshotFile", nullptr},
          {"IsPrimaryScreen", CGDisplayIsMain(display) != 0},
      });
    }
    return result;
  }

  std::vector<ProcessIdentity> process_targets() override {
    @autoreleasepool {
      std::map<pid_t, std::vector<ProcessWindowIdentity>> windows_by_pid;
      CFArrayRef window_info = CGWindowListCopyWindowInfo(
          kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
          kCGNullWindowID);
      if (window_info != nullptr) {
        for (NSDictionary* window in (__bridge NSArray*)window_info) {
          NSNumber* owner_pid = window[(id)kCGWindowOwnerPID];
          NSNumber* layer = window[(id)kCGWindowLayer];
          NSString* title = window[(id)kCGWindowName];
          NSNumber* window_number = window[(id)kCGWindowNumber];
          if (owner_pid == nil || window_number == nil || layer.integerValue != 0) {
            continue;
          }
          ProcessWindowIdentity identity;
          identity.window_id = window_number.unsignedLongLongValue;
          if (title.length != 0 && title.UTF8String != nullptr) {
            identity.title = title.UTF8String;
          }
          auto& windows = windows_by_pid[owner_pid.intValue];
          const auto duplicate = std::find_if(
              windows.begin(), windows.end(), [&](const auto& existing) {
                return existing.window_id == identity.window_id;
              });
          if (duplicate == windows.end()) {
            windows.push_back(std::move(identity));
          }
        }
        CFRelease(window_info);
      }

      // ScreenCaptureKit is the authoritative source for capture identities.
      // Keep the lookup bounded so a locked/non-interactive session cannot
      // leave the Game chooser waiting forever.
      std::map<pid_t, std::pair<std::string, std::string>> shareable_apps;
      std::map<pid_t, std::vector<ProcessWindowIdentity>> shareable_windows;
      dispatch_semaphore_t content_ready = dispatch_semaphore_create(0);
      __block SCShareableContent* shareable = nil;
      [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                                   onScreenWindowsOnly:NO
                                                      completionHandler:^(SCShareableContent* content,
                                                                          NSError*) {
        shareable = content;
        dispatch_semaphore_signal(content_ready);
      }];
      const auto deadline = dispatch_time(DISPATCH_TIME_NOW,
                                          static_cast<int64_t>(kScreenshotTimeout.count()) * NSEC_PER_SEC);
      if (dispatch_semaphore_wait(content_ready, deadline) == 0 && shareable != nil) {
        for (SCRunningApplication* application in shareable.applications) {
          const auto pid = static_cast<pid_t>(application.processID);
          const auto app_name = application.applicationName.UTF8String != nullptr
                                    ? std::string(application.applicationName.UTF8String)
                                    : std::string{};
          const auto bundle = application.bundleIdentifier.UTF8String != nullptr
                                  ? std::string(application.bundleIdentifier.UTF8String)
                                  : std::string{};
          shareable_apps[pid] = {app_name, bundle};
        }
        for (SCWindow* window in shareable.windows) {
          if (window.owningApplication == nil) {
            continue;
          }
          ProcessWindowIdentity identity;
          identity.window_id = window.windowID;
          if (window.title.UTF8String != nullptr) {
            identity.title = window.title.UTF8String;
          }
          auto& windows = shareable_windows[static_cast<pid_t>(window.owningApplication.processID)];
          const auto duplicate = std::find_if(
              windows.begin(), windows.end(), [&](const auto& existing) {
                return existing.window_id == identity.window_id;
              });
          if (duplicate == windows.end()) {
            windows.push_back(std::move(identity));
          }
        }
      }

      std::vector<ProcessIdentity> result;
      std::set<pid_t> seen;
      const auto contains_case_insensitive = [](std::string value, std::string needle) {
        std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
          return static_cast<char>(std::tolower(character));
        });
        std::transform(needle.begin(), needle.end(), needle.begin(), [](unsigned char character) {
          return static_cast<char>(std::tolower(character));
        });
        return value.find(needle) != std::string::npos;
      };
      for (NSRunningApplication* application in NSWorkspace.sharedWorkspace.runningApplications) {
        if (application.terminated) {
          continue;
        }
        const auto pid = application.processIdentifier;
        const auto has_shareable_identity = shareable_apps.contains(pid);
        const auto has_windows = windows_by_pid.contains(pid) || shareable_windows.contains(pid);
        // Accessory applications (notably Java-launched games) are valid
        // ScreenCaptureKit targets when they own a visible capture surface.
        if (application.activationPolicy == NSApplicationActivationPolicyProhibited &&
            !has_shareable_identity && !has_windows) {
          continue;
        }
        ProcessIdentity identity;
        identity.pid = pid;
        identity.bundle_identifier = application.bundleIdentifier.UTF8String != nullptr
                                         ? std::string(application.bundleIdentifier.UTF8String)
                                         : std::string{};
        identity.executable_path = application.executableURL.path.UTF8String != nullptr
                                        ? std::string(application.executableURL.path.UTF8String)
                                        : std::string{};
        identity.executable_name = application.executableURL.lastPathComponent.UTF8String != nullptr
                                       ? std::string(application.executableURL.lastPathComponent.UTF8String)
                                       : std::string{};
        identity.application_name = application.localizedName.UTF8String != nullptr
                                        ? std::string(application.localizedName.UTF8String)
                                        : std::string{};
        if (const auto found = shareable_apps.find(pid); found != shareable_apps.end()) {
          identity.screen_capture_application_name = found->second.first;
          identity.screen_capture_application_identifier = found->second.second;
          if (identity.application_name.empty()) {
            identity.application_name = identity.screen_capture_application_name;
          }
          if (identity.bundle_identifier.empty()) {
            identity.bundle_identifier = identity.screen_capture_application_identifier;
          }
        }
        if (const auto found = windows_by_pid.find(pid); found != windows_by_pid.end()) {
          identity.windows = found->second;
        }
        if (const auto found = shareable_windows.find(pid); found != shareable_windows.end()) {
          for (const auto& window : found->second) {
            const auto duplicate = std::find_if(
                identity.windows.begin(), identity.windows.end(), [&](const auto& existing) {
                  return existing.window_id == window.window_id;
                });
            if (duplicate == identity.windows.end()) {
              identity.windows.push_back(window);
            }
          }
        }
        for (const auto& window : identity.windows) {
          if (!window.title.empty() && std::find(identity.caption_names.begin(),
                                                 identity.caption_names.end(), window.title) ==
                                           identity.caption_names.end()) {
            identity.caption_names.push_back(window.title);
          }
        }
        // Minecraft's native launcher commonly leaves the game process
        // named "java".  Use its visible window title as the user-facing
        // target name while retaining the executable/PID as the stable native
        // identity used for capture.
        if (contains_case_insensitive(identity.executable_name, "java")) {
          const auto minecraft_window = std::find_if(
              identity.windows.begin(), identity.windows.end(), [&](const auto& window) {
                return contains_case_insensitive(window.title, "minecraft");
              });
          if (minecraft_window != identity.windows.end()) {
            identity.application_name = "Minecraft";
          }
        }
        if (!identity.bundle_identifier.empty()) {
          identity.class_names.push_back(identity.bundle_identifier);
        }
        if (identity.application_name.empty()) {
          identity.application_name = identity.executable_name;
        }
        if (identity.application_name.empty()) {
          identity.application_name = identity.screen_capture_application_name;
        }
        if (identity.application_name.empty()) {
          continue;
        }
        // Regular AppKit applications normally have a Dock identity.  Do not
        // expose every accessory/prohibited process merely because it owns a
        // transient helper window: that admits Dock, AutoFill, WindowManager,
        // accessibility agents and Electron helpers into Medal's manual
        // chooser.  Java-launched Minecraft is the intentional non-Dock
        // exception; its stable game process owns the visible game window.
        const auto executable_is_java = identity.executable_name == "java" ||
                                        identity.executable_name == "javaw";
        const auto is_minecraft = contains_case_insensitive(identity.application_name, "minecraft") ||
                                  contains_case_insensitive(identity.screen_capture_application_name,
                                                            "minecraft");
        const auto is_adofai = identity.bundle_identifier == "com.7thbeat.adofai" ||
                               contains_case_insensitive(identity.application_name,
                                                         "a dance of fire and ice");
        identity.manual_selectable =
            application.activationPolicy == NSApplicationActivationPolicyRegular ||
            (has_windows && (executable_is_java || is_minecraft || is_adofai));
        result.push_back(std::move(identity));
        seen.insert(pid);
      }

      // Include ScreenCaptureKit applications that are not surfaced by
      // NSWorkspace (a common case for game launchers and Java processes).
      for (const auto& [pid, app] : shareable_apps) {
        if (seen.contains(pid) || app.first.empty()) {
          continue;
        }
        ProcessIdentity identity;
        identity.pid = pid;
        identity.application_name = app.first;
        identity.screen_capture_application_name = app.first;
        identity.bundle_identifier = app.second;
        identity.screen_capture_application_identifier = app.second;
        identity.windows = shareable_windows[pid];
        for (const auto& window : identity.windows) {
          if (!window.title.empty()) {
            identity.caption_names.push_back(window.title);
          }
        }
        if (!identity.bundle_identifier.empty()) {
          identity.class_names.push_back(identity.bundle_identifier);
        }
        const auto executable_is_java = identity.executable_name == "java" ||
                                        identity.executable_name == "javaw";
        const auto is_minecraft = contains_case_insensitive(identity.application_name, "minecraft");
        const auto is_adofai = identity.bundle_identifier == "com.7thbeat.adofai" ||
                               contains_case_insensitive(identity.application_name,
                                                         "a dance of fire and ice");
        identity.manual_selectable = !identity.windows.empty() &&
                                     (executable_is_java || is_minecraft || is_adofai);
        result.push_back(std::move(identity));
      }
      std::sort(result.begin(), result.end(), [](const auto& left, const auto& right) {
        const auto left_name = left.application_name.empty() ? left.executable_name : left.application_name;
        const auto right_name = right.application_name.empty() ? right.executable_name : right.application_name;
        if (left_name != right_name) {
          return left_name < right_name;
        }
        return left.pid < right.pid;
      });
      return result;
    }
  }

  nlohmann::json active_processes() override {
    const auto targets = process_targets();
    nlohmann::json result = nlohmann::json::array();
    for (const auto& target : targets) {
      if (!target.manual_selectable) {
        continue;
      }
      const auto process_name = !target.application_name.empty()
                                    ? target.application_name
                                    : (!target.screen_capture_application_name.empty()
                                           ? target.screen_capture_application_name
                                           : target.executable_name);
      result.push_back({{"processName", process_name},
                        {"captionName", target.caption_names},
                        {"className", target.class_names}});
    }
    return result;
  }

  nlohmann::json audio_processes() override {
    @autoreleasepool {
      nlohmann::json result = nlohmann::json::array();
      std::map<std::int64_t, nlohmann::json> families;
      for (const auto& process : mac_audio_process_snapshot()) {
        if (!process.output_active || process.display_name.empty()) {
          continue;
        }
        auto [entry, inserted] = families.try_emplace(process.owner_pid, nlohmann::json{
          {"pid", process.owner_pid}, {"bundleIdentifier", process.owner_bundle_identifier},
          {"processName", process.display_name}, {"displayName", process.display_name},
          {"outputActive", true}, {"devices", nlohmann::json::array()}});
        (void)inserted;
        auto& devices = entry->second["devices"];
        for (const auto device : process.output_devices) {
          if (std::none_of(devices.begin(), devices.end(), [device](const auto& item) {
                return item.at("id") == device;
              })) devices.push_back({{"id", device}, {"name", audio_object_name(device)}});
        }
      }
      for (auto& [pid, family] : families) { (void)pid; result.push_back(std::move(family)); }
      std::sort(result.begin(), result.end(), [](const auto& left, const auto& right) {
        return left.value("displayName", std::string{}) < right.value("displayName", std::string{});
      });
      return result;
    }
  }

  std::vector<std::string> audio_output_devices() override {
    std::vector<std::string> result;
    for (const auto device : audio_devices()) {
      if (device_has_streams(device, kAudioDevicePropertyScopeOutput)) {
        result.push_back(audio_object_name(device));
      }
    }
    return result;
  }

  std::vector<std::string> microphone_devices() override {
    std::vector<std::string> result;
    for (const auto device : audio_devices()) {
      if (device_has_streams(device, kAudioDevicePropertyScopeInput)) {
        result.push_back(audio_object_name(device));
      }
    }
    return result;
  }

  nlohmann::json default_audio_devices() override {
    const auto input = default_device(kAudioHardwarePropertyDefaultInputDevice);
    const auto output = default_device(kAudioHardwarePropertyDefaultOutputDevice);
    return {
        {"input", input == kAudioObjectUnknown ? "" : audio_object_name(input)},
        {"output", output == kAudioObjectUnknown ? "" : audio_object_name(output)},
    };
  }

  nlohmann::json webcam_devices(bool include_virtual_devices) override {
    @autoreleasepool {
      AVCaptureDeviceDiscoverySession* discovery = [AVCaptureDeviceDiscoverySession
          discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera,
                                            AVCaptureDeviceTypeExternal]
                           mediaType:AVMediaTypeVideo
                            position:AVCaptureDevicePositionUnspecified];
      nlohmann::json result = nlohmann::json::array();
      for (AVCaptureDevice* device in discovery.devices) {
        const char* identifier = device.uniqueID.UTF8String;
        const char* localized_name = device.localizedName.UTF8String;
        const std::string id_value = identifier != nullptr ? identifier : "";
        const std::string label = localized_name != nullptr ? localized_name : "Camera";
        const bool virtual_device = [device.deviceType isEqualToString:AVCaptureDeviceTypeContinuityCamera];
        if (!include_virtual_devices && virtual_device) {
          continue;
        }
        result.push_back({{"id", id_value}, {"label", label}, {"value", id_value}, {"type", "camera"}});
      }
      return result;
    }
  }

  std::vector<std::string> gpu_devices() const override {
    return {gpu_device_name_};
  }

  nlohmann::json gpu_codecs() const override {
    nlohmann::json available = nlohmann::json::array();
    if (hardware_codecs_.contains(kCMVideoCodecType_H264)) {
      available.push_back("H264");
    }
    if (hardware_codecs_.contains(kCMVideoCodecType_HEVC)) {
      available.push_back("H265");
    }
    if (hardware_codecs_.contains(kCMVideoCodecType_AV1)) {
      available.push_back("AV1");
    }
    return {{gpu_device_name_, std::move(available)}};
  }

  std::vector<std::string> encoder_options() const override {
    return {"GPU"};
  }

  nlohmann::json capabilities() const override {
    return {
        {"platform", "macos"},
        {"screenCaptureKit", NSClassFromString(@"SCStream") != Nil},
        {"systemAudio", true},
        {"microphone", true},
        {"processAudioTap", NSClassFromString(@"CATapDescription") != Nil},
        {"h264HardwareEncode", hardware_codecs_.contains(kCMVideoCodecType_H264)},
        {"hevcHardwareEncode", hardware_codecs_.contains(kCMVideoCodecType_HEVC)},
        {"av1HardwareEncode", hardware_codecs_.contains(kCMVideoCodecType_AV1)},
        {"h264HardwareDecode", h264_hardware_decode_},
        {"hevcHardwareDecode", hevc_hardware_decode_},
        {"av1HardwareDecode", av1_hardware_decode_},
        {"captureState", "not_started"},
        {"globalClipHotkeys", true},
    };
  }

  nlohmann::json interactive_session_status() const override {
    @autoreleasepool {
      CFDictionaryRef session = CGSessionCopyCurrentDictionary();
      bool on_console = false;
      bool login_done = false;
      bool screen_locked = false;
      if (session != nullptr) {
        on_console = CFDictionaryGetValue(session, kCGSessionOnConsoleKey) == kCFBooleanTrue;
        login_done = CFDictionaryGetValue(session, kCGSessionLoginDoneKey) == kCFBooleanTrue;
        // WindowServer includes this value in the returned session dictionary,
        // although the SDK has no public constant for it. It is a conservative
        // test-harness hint; the public session/display checks below remain the
        // authoritative non-interactive reasons.
        const auto locked_key = CFSTR("CGSSessionScreenIsLocked");
        screen_locked = CFDictionaryGetValue(session, locked_key) == kCFBooleanTrue;
        CFRelease(session);
      }
      std::array<CGDirectDisplayID, 32> displays{};
      uint32_t display_count = 0;
      const auto display_status = CGGetActiveDisplayList(
          static_cast<uint32_t>(displays.size()), displays.data(), &display_count);
      const bool has_gui_session = session != nullptr;
      const bool interactive = has_gui_session && on_console && login_done && !screen_locked &&
                               display_status == kCGErrorSuccess && display_count > 0;
      std::string reason = "interactive";
      if (!has_gui_session) {
        reason = "no_quartz_gui_session";
      } else if (!on_console) {
        reason = "not_console_session";
      } else if (!login_done) {
        reason = "login_incomplete";
      } else if (screen_locked) {
        reason = "screen_locked";
      } else if (display_status != kCGErrorSuccess) {
        reason = "display_query_failed";
      } else if (display_count == 0) {
        reason = "no_active_displays";
      }
      return {{"schemaVersion", 1},
              {"interactive", interactive},
              {"reason", reason},
              {"hasGuiSession", has_gui_session},
              {"onConsole", on_console},
              {"loginDone", login_done},
              {"screenLockedHint", screen_locked},
              {"activeDisplayCount", display_count},
              {"displayQueryStatus", display_status}};
    }
  }

  nlohmann::json permission_status() const override {
    @autoreleasepool {
      const auto microphone = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
      const auto microphone_name = [&] {
        switch (microphone) {
          case AVAuthorizationStatusAuthorized: return std::string("authorized");
          case AVAuthorizationStatusDenied: return std::string("denied");
          case AVAuthorizationStatusRestricted: return std::string("restricted");
          case AVAuthorizationStatusNotDetermined: return std::string("not_determined");
        }
        return std::string("unknown");
      }();
      return {
          {"screenRecording", {{"granted", CGPreflightScreenCaptureAccess()},
                                {"bundleIdentifier", "com.squirrel.medal.medal.recorder"}}},
          {"microphone", {{"status", microphone_name},
                           {"granted", microphone == AVAuthorizationStatusAuthorized},
                           {"bundleIdentifier", "com.squirrel.medal.medal.recorder"}}},
          {"camera", {{"status", "not_requested"},
                        {"granted", false},
                        {"bundleIdentifier", "com.squirrel.medal.medal.recorder"}}},
          {"remediation", "Approve the signed Medal host/helper entries in System Settings > Privacy & Security, then restart capture."},
      };
    }
  }

  void request_permissions() override {
    @autoreleasepool {
      // These are the normal macOS TCC prompts.  We never alter the TCC
      // database or treat a denial as success.  Camera remains opt-in and is
      // requested only when a camera overlay is enabled.
      if (!CGPreflightScreenCaptureAccess()) {
        CGRequestScreenCaptureAccess();
      }
      if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] ==
          AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL) {}];
      }
    }
  }

  void open_permission_settings() override {
    @autoreleasepool {
      // Use the documented System Settings deep link.  This does not reset or
      // modify TCC; the user still has to enable the signed host/helper rows.
      NSURL* url = [NSURL URLWithString:
          @"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"];
      [[NSWorkspace sharedWorkspace] openURL:url];
    }
  }

  void pump_events() override {
    constexpr std::size_t kMaximumEventsPerPump = 32;
    const EventTypeSpec hotkey_event_type{
        .eventClass = kEventClassKeyboard,
        .eventKind = kEventHotKeyPressed,
    };
    for (std::size_t index = 0; index < kMaximumEventsPerPump; ++index) {
      EventRef event = nullptr;
      const auto receive_status = ReceiveNextEvent(
          1, &hotkey_event_type, 0.0, true, &event);
      if (receive_status == eventLoopTimedOutErr) {
        return;
      }
      if (receive_status != noErr || event == nullptr) {
        std::scoped_lock lock(hotkey_mutex_);
        last_event_pump_status_ = receive_status;
        ++event_pump_failures_;
        return;
      }
      const auto dispatch_status =
          SendEventToEventTarget(event, GetEventDispatcherTarget());
      ReleaseEvent(event);
      if (dispatch_status != noErr) {
        std::scoped_lock lock(hotkey_mutex_);
        last_event_pump_status_ = dispatch_status;
        ++event_pump_failures_;
      }
    }
  }

  void present_clip_saved_feedback(const ClipSavedFeedback& feedback) override {
    @autoreleasepool {
      bool sound_played = false;
      std::string sound_state = feedback.play_sound ? "unavailable" : "disabled_by_settings";
      if (feedback.play_sound && feedback.sound_path && !feedback.sound_path->empty()) {
        NSString* path = [NSString stringWithUTF8String:feedback.sound_path->c_str()];
        NSSound* sound = path != nil
                             ? [[NSSound alloc] initWithContentsOfFile:path byReference:NO]
                             : nil;
        if (sound != nil) {
          sound.volume = static_cast<float>(std::clamp(feedback.volume, 0.0, 1.5));
          active_feedback_sound_ = sound;
          sound_played = [sound play] == YES;
          sound_state = sound_played ? "playing" : "play_rejected";
        }
      }

      constexpr CGFloat kWidth = 330.0;
      constexpr CGFloat kHeight = 82.0;
      if (feedback_panel_ != nil) {
        [feedback_panel_ orderOut:nil];
      }
      NSPanel* panel = [[NSPanel alloc]
          initWithContentRect:NSMakeRect(0.0, 0.0, kWidth, kHeight)
                    styleMask:NSWindowStyleMaskBorderless
                      backing:NSBackingStoreBuffered
                        defer:NO];
      panel.opaque = NO;
      panel.backgroundColor = [NSColor colorWithCalibratedWhite:0.08 alpha:0.96];
      panel.hasShadow = YES;
      panel.level = NSStatusWindowLevel;
      panel.alphaValue = 1.0;
      panel.releasedWhenClosed = NO;
      panel.ignoresMouseEvents = YES;
      panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                 NSWindowCollectionBehaviorFullScreenAuxiliary;
      panel.accessibilityTitle = @"Medal clip saved";

      NSView* content = [[NSView alloc] initWithFrame:NSMakeRect(0.0, 0.0, kWidth, kHeight)];
      content.wantsLayer = YES;
      content.layer.cornerRadius = 14.0;
      content.layer.masksToBounds = YES;
      panel.contentView = content;

      if (feedback.icon_path && !feedback.icon_path->empty()) {
        NSString* icon_path = [NSString stringWithUTF8String:feedback.icon_path->c_str()];
        NSImage* icon = icon_path != nil ? [[NSImage alloc] initWithContentsOfFile:icon_path] : nil;
        if (icon != nil) {
          NSImageView* image = [[NSImageView alloc] initWithFrame:NSMakeRect(16.0, 17.0, 48.0, 48.0)];
          image.image = icon;
          image.imageScaling = NSImageScaleProportionallyUpOrDown;
          [content addSubview:image];
        }
      }

      NSString* title_text = [NSString stringWithUTF8String:feedback.title.c_str()];
      NSTextField* title = [NSTextField labelWithString:title_text != nil ? title_text : @"Medal"];
      title.frame = NSMakeRect(78.0, 43.0, 232.0, 24.0);
      title.font = [NSFont systemFontOfSize:15.0 weight:NSFontWeightSemibold];
      title.textColor = NSColor.whiteColor;
      [content addSubview:title];

      NSString* message_text = [NSString stringWithUTF8String:feedback.message.c_str()];
      NSTextField* message =
          [NSTextField labelWithString:message_text != nil ? message_text : @"Clip saved"];
      message.frame = NSMakeRect(78.0, 18.0, 232.0, 22.0);
      message.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightRegular];
      message.textColor = [NSColor colorWithCalibratedWhite:0.82 alpha:1.0];
      [content addSubview:message];

      // Place the HUD on the display where the user is currently working.  A
      // helper process has no key window of its own, so NSScreen.mainScreen
      // can otherwise resolve to an unrelated monitor and make a successful
      // toast appear to be missing.
      const NSPoint mouse_location = [NSEvent mouseLocation];
      NSScreen* screen = nil;
      for (NSScreen* candidate in NSScreen.screens) {
        if (NSPointInRect(mouse_location, candidate.frame)) {
          screen = candidate;
          break;
        }
      }
      if (screen == nil) {
        screen = NSScreen.mainScreen != nil ? NSScreen.mainScreen : NSScreen.screens.firstObject;
      }
      if (screen != nil) {
        const NSRect visible = screen.visibleFrame;
        [panel setFrameOrigin:NSMakePoint(NSMaxX(visible) - kWidth - 24.0,
                                           NSMaxY(visible) - kHeight - 24.0)];
      }
      [panel orderFrontRegardless];
      feedback_panel_ = panel;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(3.0 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
        [panel orderOut:nil];
      });

      std::scoped_lock lock(hotkey_mutex_);
      ++feedback_count_;
      last_feedback_ = {
          {"hudShown", true},
          {"soundRequested", feedback.play_sound},
          {"soundPlayed", sound_played},
          {"soundState", sound_state},
          {"volume", std::clamp(feedback.volume, 0.0, 1.5)},
      };
    }
  }

  void configure_clip_hotkeys(const std::vector<ClipHotkeyBinding>& bindings,
                              ClipHotkeyCallback callback) override {
    std::scoped_lock lock(hotkey_mutex_);
    clear_hotkeys_unlocked();
    callback_ = std::move(callback);
    if (bindings.empty()) {
      return;
    }
    EventTypeSpec event_type{.eventClass = kEventClassKeyboard, .eventKind = kEventHotKeyPressed};
    const auto handler_status = InstallApplicationEventHandler(
        &MacPlatformAdapter::hotkey_event, 1, &event_type, this, &event_handler_);
    if (handler_status != noErr || event_handler_ == nullptr) {
      callback_ = {};
      throw std::runtime_error("Carbon hotkey event handler failed with OSStatus " +
                               std::to_string(handler_status));
    }
    try {
      for (const auto& binding : bindings) {
        const auto key = parse_carbon_key(binding.inputs);
        const auto identifier = static_cast<UInt32>(registered_hotkeys_.size() + 1);
        const EventHotKeyID hotkey_id{.signature = 0x4d64436cU, .id = identifier};  // MdCl
        EventHotKeyRef reference = nullptr;
        const auto status = RegisterEventHotKey(key.key_code, key.modifiers, hotkey_id,
                                                GetApplicationEventTarget(), 0, &reference);
        if (status != noErr || reference == nullptr) {
          throw std::runtime_error("Carbon hotkey registration failed for " + binding.inputs +
                                   " with OSStatus " + std::to_string(status));
        }
        registered_hotkeys_.push_back({.reference = reference, .identifier = identifier, .binding = binding});
      }
    } catch (...) {
      clear_hotkeys_unlocked();
      throw;
    }
  }

  nlohmann::json clip_hotkey_status() const override {
    std::scoped_lock lock(hotkey_mutex_);
    nlohmann::json bindings = nlohmann::json::array();
    for (const auto& registration : registered_hotkeys_) {
      bindings.push_back({{"action", registration.binding.action},
                          {"inputs", registration.binding.inputs},
                          {"durationSeconds", registration.binding.duration.count()}});
    }
    return {{"backend", "Carbon.RegisterEventHotKey"},
            {"permissionRequired", false},
            {"triggerCount", hotkey_trigger_count_},
            {"eventPumpFailures", event_pump_failures_},
            {"lastEventPumpOSStatus", last_event_pump_status_},
            {"feedbackCount", feedback_count_},
            {"lastFeedback", last_feedback_},
            {"registered", std::move(bindings)}};
  }

 private:
  struct PreviewCacheEntry final {
    std::string data_url;
    std::uint32_t width{0};
    std::uint32_t height{0};
    std::chrono::steady_clock::time_point created_at{};
  };

  struct RegisteredHotkey final {
    EventHotKeyRef reference{nullptr};
    UInt32 identifier{0};
    ClipHotkeyBinding binding;
  };

  static OSStatus hotkey_event(EventHandlerCallRef, EventRef event, void* context) noexcept {
    auto* owner = static_cast<MacPlatformAdapter*>(context);
    if (owner == nullptr || event == nullptr) {
      return eventNotHandledErr;
    }
    EventHotKeyID identifier{};
    const auto status = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                                          nullptr, sizeof(identifier), nullptr, &identifier);
    if (status != noErr || identifier.signature != 0x4d64436cU) {
      return eventNotHandledErr;
    }
    ClipHotkeyBinding binding;
    ClipHotkeyCallback callback;
    {
      std::scoped_lock lock(owner->hotkey_mutex_);
      const auto found = std::find_if(owner->registered_hotkeys_.begin(), owner->registered_hotkeys_.end(),
                                      [&](const auto& registration) {
                                        return registration.identifier == identifier.id;
                                      });
      if (found == owner->registered_hotkeys_.end() || !owner->callback_) {
        return eventNotHandledErr;
      }
      binding = found->binding;
      callback = owner->callback_;
      ++owner->hotkey_trigger_count_;
    }
    try {
      // SDK CarbonEventsCore.h: EventTime is seconds since system startup.
      // API probe verifies Carbon/CoreMedia/CoreAudio share the host epoch.
      const auto event_time = GetEventTime(event);
      if (!std::isfinite(event_time) || event_time < 0 || event_time >
          static_cast<double>(std::numeric_limits<std::int64_t>::max()) / 1'000'000'000.0)
        return eventNotHandledErr;
      callback(binding, static_cast<std::int64_t>(std::llround(event_time * 1'000'000'000.0)));
      return noErr;
    } catch (...) {
      return eventNotHandledErr;
    }
  }

  void clear_hotkeys() noexcept {
    std::scoped_lock lock(hotkey_mutex_);
    clear_hotkeys_unlocked();
  }

  void clear_hotkeys_unlocked() noexcept {
    for (auto& registration : registered_hotkeys_) {
      if (registration.reference != nullptr) {
        UnregisterEventHotKey(registration.reference);
      }
    }
    registered_hotkeys_.clear();
    if (event_handler_ != nullptr) {
      RemoveEventHandler(event_handler_);
      event_handler_ = nullptr;
    }
    callback_ = {};
  }

  std::vector<RegisteredHotkey> registered_hotkeys_;
  const std::set<CMVideoCodecType> hardware_codecs_;
  const std::string gpu_device_name_;
  const bool h264_hardware_decode_;
  const bool hevc_hardware_decode_;
  const bool av1_hardware_decode_;
  EventHandlerRef event_handler_{nullptr};
  ClipHotkeyCallback callback_;
  std::uint64_t hotkey_trigger_count_{0};
  std::uint64_t event_pump_failures_{0};
  std::uint64_t feedback_count_{0};
  OSStatus last_event_pump_status_{noErr};
  nlohmann::json last_feedback_{{"state", "not_presented"}};
  NSSound* active_feedback_sound_{nil};
  NSPanel* feedback_panel_{nil};
  mutable std::mutex hotkey_mutex_;
  mutable std::mutex preview_cache_mutex_;
  std::map<CGDirectDisplayID, PreviewCacheEntry> preview_cache_;
  static constexpr auto preview_cache_ttl_ = std::chrono::milliseconds(900);
};

}  // namespace

std::unique_ptr<PlatformAdapter> make_platform_adapter() {
  return std::make_unique<MacPlatformAdapter>();
}

}  // namespace native_port
