#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreMedia/CoreMedia.h>

#include "process_audio_tap.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <mutex>
#include <string>
#include <utility>

namespace native_port {
namespace {

std::string os_status(const char* operation, OSStatus status) {
  return std::string(operation) + " failed with OSStatus " + std::to_string(status);
}

bool property_format(AudioObjectID device, AudioStreamBasicDescription& format) {
  AudioObjectPropertyAddress address{kAudioDevicePropertyStreamFormat,
                                     kAudioObjectPropertyScopeInput,
                                     kAudioObjectPropertyElementMain};
  UInt32 size = sizeof(format);
  return AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &format) == noErr &&
         format.mFormatID == kAudioFormatLinearPCM && format.mSampleRate > 0 &&
         format.mBytesPerFrame > 0;
}

}  // namespace

struct ProcessAudioTap::Impl final {
  ~Impl() { stop(); }

  bool start(const std::vector<std::int64_t>& requested_pids, TrackKind track,
             std::uint32_t track_id, double gain,
             std::uint64_t generation, AacEncoder::PacketCallback callback, std::string& error) {
    stop();
    if (requested_pids.empty() ||
        std::any_of(requested_pids.begin(), requested_pids.end(),
                    [](const auto value) { return value <= 0; })) {
      error = "Core Audio process tap requires positive PIDs";
      return false;
    }

    AudioObjectPropertyAddress process_address{kAudioHardwarePropertyTranslatePIDToProcessObject,
                                               kAudioObjectPropertyScopeGlobal,
                                               kAudioObjectPropertyElementMain};
    NSMutableArray<NSNumber*>* process_objects = [NSMutableArray arrayWithCapacity:requested_pids.size()];
    for (const auto requested_pid : requested_pids) {
      pid = static_cast<pid_t>(requested_pid);
      AudioObjectID process_object = kAudioObjectUnknown;
      UInt32 process_size = sizeof(process_object);
      const auto process_status = AudioObjectGetPropertyData(
          kAudioObjectSystemObject, &process_address, sizeof(pid), &pid, &process_size, &process_object);
      if (process_status != noErr || process_object == kAudioObjectUnknown) {
        error = os_status("Core Audio process-object lookup", process_status);
        return false;
      }
      [process_objects addObject:@(process_object)];
    }

    @autoreleasepool {
      CATapDescription* description =
          [[CATapDescription alloc] initStereoMixdownOfProcesses:process_objects];
      if (description == nil) {
        error = "Core Audio CATapDescription creation returned nil";
        return false;
      }
      description.name = [NSString stringWithFormat:@"Medal process tap (%lu processes)",
                                                        static_cast<unsigned long>(requested_pids.size())];
      description.privateTap = YES;
      description.processRestoreEnabled = YES;
      description.muteBehavior = CATapUnmuted;
      const auto tap_status = AudioHardwareCreateProcessTap(description, &tap_id);
      if (tap_status != noErr || tap_id == kAudioObjectUnknown) {
        error = os_status("Core Audio process tap creation", tap_status);
        tap_id = kAudioObjectUnknown;
        return false;
      }

      AudioObjectPropertyAddress uid_address{kAudioTapPropertyUID,
                                             kAudioObjectPropertyScopeGlobal,
                                             kAudioObjectPropertyElementMain};
      CFStringRef tap_uid = nullptr;
      UInt32 uid_size = sizeof(tap_uid);
      auto status = AudioObjectGetPropertyData(tap_id, &uid_address, 0, nullptr, &uid_size, &tap_uid);
      if (status != noErr || tap_uid == nullptr) {
        error = os_status("Core Audio tap UID lookup", status);
        stop();
        return false;
      }

      const auto uid_text = std::string("com.squirrel.medal.medal.tap.") +
                            std::to_string(pid) + "." +
                            std::to_string(std::chrono::steady_clock::now().time_since_epoch().count());
      CFStringRef aggregate_uid =
          CFStringCreateWithCString(kCFAllocatorDefault, uid_text.c_str(), kCFStringEncodingUTF8);
      CFStringRef aggregate_name = CFSTR("Medal Native Audio Capture");
      const void* keys[] = {CFSTR(kAudioAggregateDeviceUIDKey),
                            CFSTR(kAudioAggregateDeviceNameKey),
                            CFSTR(kAudioAggregateDeviceIsPrivateKey)};
      const void* values[] = {aggregate_uid, aggregate_name, kCFBooleanTrue};
      CFDictionaryRef aggregate_description = CFDictionaryCreate(
          kCFAllocatorDefault, keys, values, 3, &kCFTypeDictionaryKeyCallBacks,
          &kCFTypeDictionaryValueCallBacks);
      status = AudioHardwareCreateAggregateDevice(aggregate_description, &aggregate_id);
      CFRelease(aggregate_description);
      CFRelease(aggregate_uid);
      if (status != noErr || aggregate_id == kAudioObjectUnknown) {
        CFRelease(tap_uid);
        error = os_status("Core Audio aggregate device creation", status);
        stop();
        return false;
      }

      // The tap UID is installed on the aggregate's tap-list property. This
      // keeps the aggregate private and avoids changing the user's default
      // output device.
      CFArrayRef tap_list = CFArrayCreate(kCFAllocatorDefault,
                                          const_cast<const void**>(
                                              reinterpret_cast<const void**>(&tap_uid)),
                                          1, &kCFTypeArrayCallBacks);
      AudioObjectPropertyAddress tap_list_address{kAudioAggregateDevicePropertyTapList,
                                                  kAudioObjectPropertyScopeGlobal,
                                                  kAudioObjectPropertyElementMain};
      const UInt32 tap_list_size = sizeof(tap_list);
      status = AudioObjectSetPropertyData(aggregate_id, &tap_list_address, 0, nullptr,
                                          tap_list_size, &tap_list);
      CFRelease(tap_list);
      CFRelease(tap_uid);
      if (status != noErr) {
        error = os_status("Core Audio aggregate tap-list configuration", status);
        stop();
        return false;
      }

      if (!property_format(aggregate_id, format)) {
        format = {};
        format.mSampleRate = 48'000;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
        format.mFramesPerPacket = 1;
        format.mChannelsPerFrame = 2;
        format.mBytesPerFrame = sizeof(float) * 2;
        format.mBytesPerPacket = format.mBytesPerFrame;
        format.mBitsPerChannel = sizeof(float) * 8;
      }

      encoder = std::make_shared<AacEncoder>(
          track, track_id, 96'000, gain, std::move(callback));
      configuration_generation = generation;
      dispatch_queue = dispatch_queue_create("com.squirrel.medal.medal.process-audio-tap",
                                              DISPATCH_QUEUE_SERIAL);
      const auto io_status = AudioDeviceCreateIOProcIDWithBlock(
          &io_proc, aggregate_id, dispatch_queue,
          ^(const AudioTimeStamp* now, const AudioBufferList* input,
            const AudioTimeStamp* input_time, AudioBufferList*, const AudioTimeStamp*) {
            (void)now;
            (void)input_time;
            on_audio(input);
          });
      if (io_status != noErr) {
        error = os_status("Core Audio process tap IOProc creation", io_status);
        stop();
        return false;
      }
      const auto start_status = AudioDeviceStart(aggregate_id, io_proc);
      if (start_status != noErr) {
        error = os_status("Core Audio process tap start", start_status);
        stop();
        return false;
      }
      running_flag.store(true, std::memory_order_release);
      return true;
    }
  }

  void stop() {
    running_flag.store(false, std::memory_order_release);
    if (aggregate_id != kAudioObjectUnknown && io_proc != nullptr) {
      AudioDeviceStop(aggregate_id, io_proc);
      AudioDeviceDestroyIOProcID(aggregate_id, io_proc);
    }
    io_proc = nullptr;
    dispatch_queue = nullptr;
    encoder.reset();
    if (aggregate_id != kAudioObjectUnknown) {
      AudioHardwareDestroyAggregateDevice(aggregate_id);
      aggregate_id = kAudioObjectUnknown;
    }
    if (tap_id != kAudioObjectUnknown) {
      AudioHardwareDestroyProcessTap(tap_id);
      tap_id = kAudioObjectUnknown;
    }
  }

  void on_audio(const AudioBufferList* input) {
    if (!running_flag.load(std::memory_order_acquire) || input == nullptr ||
        input->mNumberBuffers == 0 || input->mBuffers[0].mData == nullptr ||
        input->mBuffers[0].mDataByteSize == 0 || !encoder) {
      return;
    }
    // A stereo mixdown tap is normally one interleaved buffer. If HAL exposes
    // a non-interleaved layout, do not reinterpret it as interleaved PCM.
    if (input->mNumberBuffers != 1) {
      return;
    }
    const auto frames = input->mBuffers[0].mDataByteSize / format.mBytesPerFrame;
    if (frames == 0) {
      return;
    }
    CMBlockBufferRef block = nullptr;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr,
                                           input->mBuffers[0].mDataByteSize,
                                           kCFAllocatorDefault, nullptr, 0,
                                           input->mBuffers[0].mDataByteSize, 0,
                                           &block) != kCMBlockBufferNoErr) {
      return;
    }
    CMBlockBufferReplaceDataBytes(input->mBuffers[0].mData, block, 0,
                                  input->mBuffers[0].mDataByteSize);
    CMAudioFormatDescriptionRef format_description = nullptr;
    if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &format, 0, nullptr, 0,
                                        nullptr, nullptr, &format_description) != noErr) {
      CFRelease(block);
      return;
    }
    const auto sample_time = CMTimeMake(static_cast<std::int64_t>(sample_cursor),
                                        static_cast<int32_t>(format.mSampleRate));
    const auto duration = CMTimeMake(static_cast<std::int64_t>(frames),
                                     static_cast<int32_t>(format.mSampleRate));
    CMSampleTimingInfo timing{duration, sample_time, sample_time};
    const size_t sample_size = input->mBuffers[0].mDataByteSize;
    CMSampleBufferRef sample = nullptr;
    if (CMSampleBufferCreateReady(kCFAllocatorDefault, block, format_description, frames, 1,
                                  &timing, 1, &sample_size, &sample) == noErr &&
        sample != nullptr) {
      std::string error;
      (void)encoder->encode(sample, configuration_generation, error);
      CFRelease(sample);
    }
    CFRelease(format_description);
    CFRelease(block);
    sample_cursor += frames;
  }

  pid_t pid{0};
  AudioObjectID tap_id{kAudioObjectUnknown};
  AudioObjectID aggregate_id{kAudioObjectUnknown};
  AudioDeviceIOProcID io_proc{nullptr};
  dispatch_queue_t dispatch_queue{nullptr};
  AudioStreamBasicDescription format{};
  std::shared_ptr<AacEncoder> encoder;
  std::uint64_t configuration_generation{0};
  std::uint64_t sample_cursor{0};
  std::atomic<bool> running_flag{false};
};

ProcessAudioTap::ProcessAudioTap() : impl_(std::make_unique<Impl>()) {}
ProcessAudioTap::~ProcessAudioTap() = default;

bool ProcessAudioTap::start(const std::vector<std::int64_t>& pids, TrackKind track,
                            std::uint32_t track_id,
                            double gain, std::uint64_t generation,
                            AacEncoder::PacketCallback callback, std::string& error) {
  return impl_->start(pids, track, track_id, gain, generation, std::move(callback), error);
}
void ProcessAudioTap::stop() { impl_->stop(); }
bool ProcessAudioTap::running() const noexcept {
  return impl_->running_flag.load(std::memory_order_acquire);
}
std::uint64_t ProcessAudioTap::packet_count() const noexcept {
  return impl_->encoder ? impl_->encoder->packet_count() : 0;
}
std::string ProcessAudioTap::status() const {
  return running() ? "running" : "stopped";
}

}  // namespace native_port
