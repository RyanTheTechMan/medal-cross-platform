#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <Carbon/Carbon.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Metal/Metal.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>

#include <iostream>

namespace {

void print_flag(const char* name, bool present, bool& first) {
  if (!first) {
    std::cout << ',';
  }
  first = false;
  std::cout << '\"' << name << "\":" << (present ? "true" : "false");
}

}  // namespace

int main() {
  @autoreleasepool {
    // Compile and link public capture, encode, audio, Metal and hot-key APIs without
    // requesting TCC consent or starting any capture session.
    const auto create_process_tap = &AudioHardwareCreateProcessTap;
    const auto destroy_process_tap = &AudioHardwareDestroyProcessTap;
    const auto create_encoder = &VTCompressionSessionCreate;
    const auto create_audio_converter = &AudioConverterNew;
    const auto register_hot_key = &RegisterEventHotKey;

    SCStreamConfiguration* stream_configuration = [[SCStreamConfiguration alloc] init];
    stream_configuration.capturesAudio = YES;
    stream_configuration.captureMicrophone = YES;
    stream_configuration.microphoneCaptureDeviceID = nil;
    stream_configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;

    SCRecordingOutputConfiguration* recording_configuration = [[SCRecordingOutputConfiguration alloc] init];
    recording_configuration.mixesAudioWithMicrophone = NO;
    SCScreenshotConfiguration* screenshot_configuration = [[SCScreenshotConfiguration alloc] init];
    screenshot_configuration.showsCursor = YES;
    SCContentSharingPickerConfiguration* picker_configuration =
        [[SCContentSharingPickerConfiguration alloc] init];
    picker_configuration.allowedPickerModes =
        SCContentSharingPickerModeSingleDisplay | SCContentSharingPickerModeSingleWindow;
    CATapDescription* tap_description =
        [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
    tap_description.privateTap = YES;
    tap_description.processRestoreEnabled = YES;

    id<MTLDevice> metal_device = MTLCreateSystemDefaultDevice();
    const bool has_h264_hardware_key = kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder != nullptr;
    const bool has_hevc_encoder = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);

    bool first = true;
    std::cout << '{';
    print_flag("ScreenCaptureKit.SCStreamConfiguration", stream_configuration != nil, first);
    print_flag("ScreenCaptureKit.captureMicrophone",
               [stream_configuration respondsToSelector:@selector(setCaptureMicrophone:)], first);
    print_flag("ScreenCaptureKit.SCRecordingOutputConfiguration", recording_configuration != nil, first);
    print_flag("ScreenCaptureKit.SCScreenshotConfiguration", screenshot_configuration != nil, first);
    print_flag("ScreenCaptureKit.SCContentSharingPickerConfiguration", picker_configuration != nil, first);
    print_flag("CoreAudio.CATapDescription", tap_description != nil, first);
    print_flag("CoreAudio.AudioHardwareCreateProcessTap", create_process_tap != nullptr, first);
    print_flag("CoreAudio.AudioHardwareDestroyProcessTap", destroy_process_tap != nullptr, first);
    print_flag("VideoToolbox.VTCompressionSessionCreate", create_encoder != nullptr, first);
    print_flag("VideoToolbox.hardwareEncoderSpecificationKey", has_h264_hardware_key, first);
    print_flag("VideoToolbox.HEVCHardwareDecode", has_hevc_encoder, first);
    print_flag("AudioToolbox.AudioConverterNew", create_audio_converter != nullptr, first);
    print_flag("Metal.defaultDevice", metal_device != nil, first);
    print_flag("Carbon.RegisterEventHotKey", register_hot_key != nullptr, first);
    std::cout << "}\n";
  }
  return 0;
}
