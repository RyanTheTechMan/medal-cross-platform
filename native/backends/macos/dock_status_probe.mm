#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <iostream>
#include <nlohmann/json.hpp>

// Read-only shell-lifecycle evidence. No activation, capture, or other-app inventory.
int main() {
  @autoreleasepool {
    nlohmann::json hosts = nlohmann::json::array();
    for (NSRunningApplication *app in [NSRunningApplication
        runningApplicationsWithBundleIdentifier:@"com.squirrel.medal.medal"]) {
      if (![app.bundleURL.path isEqualToString:@"/Applications/Medal.app"]) continue;
      const auto policy = app.activationPolicy;
      NSUInteger visibleWindows = 0;
      NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
      for (NSDictionary *entry in windows) {
        if ([entry[(NSString *)kCGWindowOwnerPID] intValue] == app.processIdentifier &&
            [entry[(NSString *)kCGWindowLayer] intValue] == 0) ++visibleWindows;
      }
      hosts.push_back({{"pid", app.processIdentifier},
        {"activationPolicy", policy == NSApplicationActivationPolicyRegular ? "regular" :
          policy == NSApplicationActivationPolicyAccessory ? "accessory" : "prohibited"},
        {"terminated", static_cast<bool>(app.terminated)}, {"onScreenNormalWindows", visibleWindows}});
    }
    std::cout << nlohmann::json({{"schemaVersion", 1}, {"hosts", hosts}}).dump(2) << '\n';
    return hosts.size() == 1 ? 0 : 1;
  }
}
