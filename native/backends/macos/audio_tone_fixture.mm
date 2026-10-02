#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#include <cmath>
#include <numbers>

#ifndef NATIVE_FIXTURE_TONE
#define NATIVE_FIXTURE_TONE 440
#endif

// Test-only controllable application. Its entire window and audio are synthetic,
// so native application/tap tests need no private desktop images or user clips.
@interface MedalAudioFixtureDelegate : NSObject <NSApplicationDelegate>
@property(strong) NSWindow* window;
@property(strong) AVAudioEngine* engine;
@property(strong) AVAudioSourceNode* source;
@end
@implementation MedalAudioFixtureDelegate
- (void)applicationDidFinishLaunching:(NSNotification*)notification {
  (void)notification;
  NSString* title = [NSString stringWithFormat:@"Medal Audio Fixture %d Hz", NATIVE_FIXTURE_TONE];
  self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(160, 160, 640, 360)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
      backing:NSBackingStoreBuffered defer:NO];
  self.window.title = title;
  NSTextField* label = [NSTextField labelWithString:[title stringByAppendingString:@"\nSynthetic audio/video test only"]];
  label.font = [NSFont systemFontOfSize:28]; label.alignment = NSTextAlignmentCenter;
  label.frame = NSMakeRect(20, 120, 600, 120); label.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin | NSViewMaxYMargin;
  [self.window.contentView addSubview:label];
  [self.window makeKeyAndOrderFront:nil];
  self.engine = [[AVAudioEngine alloc] init];
  AVAudioFormat* format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
  __block std::uint64_t frame = 0;
  self.source = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:
      ^OSStatus(BOOL* silence, const AudioTimeStamp*, AVAudioFrameCount frames, AudioBufferList* output) {
        *silence = NO;
        for (AVAudioFrameCount index = 0; index < frames; ++index, ++frame) {
          const auto value = static_cast<float>(.06 * std::sin(2 * std::numbers::pi * NATIVE_FIXTURE_TONE * frame / 48000.0));
          for (UInt32 buffer = 0; buffer < output->mNumberBuffers; ++buffer) {
            auto* samples = static_cast<float*>(output->mBuffers[buffer].mData);
            for (UInt32 channel = 0; channel < output->mBuffers[buffer].mNumberChannels; ++channel)
              samples[index * output->mBuffers[buffer].mNumberChannels + channel] = value;
          }
        }
        return noErr;
      }];
  [self.engine attachNode:self.source];
  [self.engine connect:self.source to:self.engine.mainMixerNode format:format];
  NSError* error = nil;
  if (![self.engine startAndReturnError:&error]) {
    label.stringValue = [@"Audio fixture failed: " stringByAppendingString:error.localizedDescription];
  }
  [NSApp activateIgnoringOtherApps:YES];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)application { (void)application; return YES; }
- (void)applicationWillTerminate:(NSNotification*)notification { (void)notification; [self.engine stop]; }
@end
int main() {
  @autoreleasepool {
    NSApplication* app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    MedalAudioFixtureDelegate* delegate = [[MedalAudioFixtureDelegate alloc] init];
    app.delegate = delegate; [app run];
  }
}
