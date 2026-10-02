#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>

#include "native_port/platform_adapter.hpp"

#include <chrono>
#include <cmath>
#include <iostream>

namespace {

constexpr OSType kNativeMedalHotkeySignature = 0x4d64436cU;  // MdCl

}  // namespace

int main() {
  @autoreleasepool {
    [NSApplication sharedApplication];
    auto adapter = native_port::make_platform_adapter();
    bool triggered = false;
    const auto event_time = GetCurrentEventTime() - .25;
    const auto expected_endpoint = static_cast<std::int64_t>(std::llround(event_time * 1'000'000'000.0));
    const native_port::ClipHotkeyBinding binding{
        .action = "clip;length=5",
        .inputs = "Command+Shift+8",
        .duration = std::chrono::seconds(5),
    };
    adapter->configure_clip_hotkeys({binding}, [&](const auto& received, std::int64_t endpoint) {
      triggered = received.action == binding.action && received.inputs == binding.inputs &&
          endpoint == expected_endpoint && adapter->capture_clock_nanoseconds() - endpoint >= 250'000'000;
    });

    EventRef event = nullptr;
    const auto create_status =
        CreateEvent(nullptr, kEventClassKeyboard, kEventHotKeyPressed,
                    event_time, kEventAttributeNone, &event);
    if (create_status != noErr || event == nullptr) {
      std::cerr << "failed to create synthetic Carbon hotkey event: " << create_status << '\n';
      return 1;
    }
    const EventHotKeyID identifier{
        .signature = kNativeMedalHotkeySignature,
        .id = 1,
    };
    const auto parameter_status =
        SetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                          sizeof(identifier), &identifier);
    const auto post_status = parameter_status == noErr
                                 ? PostEventToQueue(GetMainEventQueue(), event,
                                                    kEventPriorityStandard)
                                 : parameter_status;
    ReleaseEvent(event);
    if (post_status != noErr) {
      std::cerr << "failed to queue synthetic Carbon hotkey event: " << post_status << '\n';
      return 1;
    }

    adapter->pump_events();
    const auto status = adapter->clip_hotkey_status();
    if (!triggered || status.value("triggerCount", 0U) != 1U ||
        status.value("eventPumpFailures", 1U) != 0U) {
      std::cerr << "Carbon hotkey event was not dispatched through the adapter: "
                << status.dump() << '\n';
      return 1;
    }
    std::cout << status.dump() << '\n';
    return 0;
  }
}
