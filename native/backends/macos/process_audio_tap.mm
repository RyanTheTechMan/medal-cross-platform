#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreMedia/CoreMedia.h>
#import <mach/mach_time.h>

#include "process_audio_tap.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace native_port {
namespace {

std::string os_status(const char* operation, OSStatus status) {
  return std::string(operation) + " failed with OSStatus " + std::to_string(status);
}

bool property_format(AudioObjectID object, AudioObjectPropertySelector selector,
                     AudioStreamBasicDescription& format) {
  AudioObjectPropertyAddress address{selector,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
  UInt32 size = sizeof(format);
  return AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, &format) == noErr &&
         format.mFormatID == kAudioFormatLinearPCM && format.mSampleRate > 0 &&
         format.mBytesPerFrame > 0;
}

}  // namespace

struct ProcessAudioTap::Impl final {
  ~Impl() { stop(); }

  bool start(const std::vector<std::int64_t>& requested_pids, TrackKind track,
             std::uint32_t track_id, double gain,
             std::uint64_t generation, std::int64_t session_epoch_nanoseconds,
             AacEncoder::PacketCallback callback, std::string& error) {
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

      if (!property_format(tap_id, kAudioTapPropertyFormat, format) &&
          !property_format(aggregate_id, kAudioDevicePropertyStreamFormat, format)) {
        error = "Core Audio process tap did not expose a negotiated PCM format";
        stop();
        return false;
      }

      encoder = std::make_shared<AacEncoder>(
          track, track_id, 96'000, gain, std::move(callback));
      configuration_generation = generation;
      this->session_epoch_nanoseconds = session_epoch_nanoseconds;
      sample_cursor = 0;
      dispatch_queue = dispatch_queue_create("com.squirrel.medal.medal.process-audio-tap",
                                              DISPATCH_QUEUE_SERIAL);
      worker_queue = dispatch_queue_create("com.squirrel.medal.medal.process-audio-tap-worker",
                                           DISPATCH_QUEUE_SERIAL);
      for (auto& slot : owned_slots) {
        slot.bytes.resize(kMaxFramesPerCallback * format.mBytesPerFrame);
      }
      const auto io_status = AudioDeviceCreateIOProcIDWithBlock(
          &io_proc, aggregate_id, dispatch_queue,
          ^(const AudioTimeStamp* now, const AudioBufferList* input,
            const AudioTimeStamp* input_time, AudioBufferList*, const AudioTimeStamp*) {
            (void)now;
            (void)input_time;
            on_audio(now, input, input_time);
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
    if (worker_queue != nullptr) {
      dispatch_sync(worker_queue, ^{ drain_owned_queue(); });
    }
    dispatch_queue = nullptr;
    worker_queue = nullptr;
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

  void on_audio(const AudioTimeStamp* now, const AudioBufferList* input,
                const AudioTimeStamp* input_time) {
    if (!running_flag.load(std::memory_order_acquire) || input == nullptr ||
        input->mNumberBuffers == 0 || input->mBuffers[0].mData == nullptr ||
        input->mBuffers[0].mDataByteSize == 0 || !encoder) {
      return;
    }
    // A stereo mixdown tap is normally one interleaved buffer. If HAL exposes
    // a non-interleaved layout, do not reinterpret it as interleaved PCM.
    if (input->mNumberBuffers != 1) {
      rejected_layouts.fetch_add(1, std::memory_order_relaxed);
      set_error("Core Audio process tap delivered a non-interleaved layout; source was stopped");
      running_flag.store(false, std::memory_order_release);
      return;
    }
    const auto frames = input->mBuffers[0].mDataByteSize / format.mBytesPerFrame;
    if (frames == 0 || frames > kMaxFramesPerCallback) {
      dropped_buffers.fetch_add(1, std::memory_order_relaxed);
      set_error("Core Audio process tap callback exceeded the bounded PCM queue capacity");
      return;
    }
    const auto* timestamp = input_time != nullptr && input_time->mHostTime != 0 ? input_time : now;
    if (timestamp == nullptr || timestamp->mHostTime == 0) {
      dropped_buffers.fetch_add(1, std::memory_order_relaxed);
      set_error("Core Audio process tap callback had no host timestamp");
      return;
    }
    const auto host_nanoseconds =
        static_cast<std::int64_t>(AudioConvertHostTimeToNanos(timestamp->mHostTime));
    const auto relative_nanoseconds = std::max<std::int64_t>(
        0, host_nanoseconds - session_epoch_nanoseconds);
    const auto write = queue_write.load(std::memory_order_relaxed);
    const auto read = queue_read.load(std::memory_order_acquire);
    if (write - read >= kPcmQueueCapacity) {
      dropped_buffers.fetch_add(1, std::memory_order_relaxed);
      set_error("Core Audio process tap PCM queue overflowed; samples were dropped");
      return;
    }
    auto& slot = owned_slots[write % kPcmQueueCapacity];
    std::memcpy(slot.bytes.data(), input->mBuffers[0].mData, input->mBuffers[0].mDataByteSize);
    slot.byte_count = input->mBuffers[0].mDataByteSize;
    slot.frames = frames;
    slot.relative_nanoseconds = relative_nanoseconds;
    queue_write.store(write + 1, std::memory_order_release);
    schedule_worker();
  }

  struct OwnedPcmSlot final {
    std::vector<std::uint8_t> bytes;
    std::size_t byte_count{0};
    std::size_t frames{0};
    std::int64_t relative_nanoseconds{0};
  };

  void set_error(std::string value) {
    std::scoped_lock lock(error_mutex);
    if (last_error.empty()) {
      last_error = std::move(value);
    }
  }

  void schedule_worker() {
    bool expected = false;
    if (worker_scheduled.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
      dispatch_async(worker_queue, ^{
        drain_owned_queue();
        worker_scheduled.store(false, std::memory_order_release);
        if (queue_read.load(std::memory_order_acquire) < queue_write.load(std::memory_order_acquire)) {
          schedule_worker();
        }
      });
    }
  }

  void drain_owned_queue() {
    for (;;) {
      const auto read = queue_read.load(std::memory_order_relaxed);
      const auto write = queue_write.load(std::memory_order_acquire);
      if (read >= write) {
        return;
      }
      auto& slot = owned_slots[read % kPcmQueueCapacity];
      auto current_encoder = encoder;
      if (current_encoder != nullptr && slot.byte_count > 0) {
        CMBlockBufferRef block = nullptr;
        const auto block_status = CMBlockBufferCreateWithMemoryBlock(
            kCFAllocatorDefault, nullptr, slot.byte_count, kCFAllocatorDefault, nullptr, 0,
            slot.byte_count, 0, &block);
        if (block_status == kCMBlockBufferNoErr && block != nullptr &&
            CMBlockBufferReplaceDataBytes(slot.bytes.data(), block, 0, slot.byte_count) == noErr) {
          CMAudioFormatDescriptionRef format_description = nullptr;
          if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &format, 0, nullptr, 0,
                                              nullptr, nullptr, &format_description) == noErr &&
              format_description != nullptr) {
            const auto sample_time = CMTimeMake(slot.relative_nanoseconds, 1'000'000'000);
            const auto duration =
                CMTimeMake(1, static_cast<int32_t>(std::llround(format.mSampleRate)));
            CMSampleTimingInfo timing{duration, sample_time, sample_time};
            const size_t sample_size = format.mBytesPerFrame;
            CMSampleBufferRef sample = nullptr;
            if (CMSampleBufferCreateReady(kCFAllocatorDefault, block, format_description,
                                          slot.frames, 1, &timing, 1, &sample_size,
                                          &sample) == noErr && sample != nullptr) {
              std::string error;
              if (!current_encoder->encode(sample, configuration_generation, error) && !error.empty()) {
                set_error(std::move(error));
              }
              CFRelease(sample);
            }
            CFRelease(format_description);
          }
          CFRelease(block);
        } else if (block != nullptr) {
          CFRelease(block);
        }
      }
      queue_read.store(read + 1, std::memory_order_release);
    }
  }

  pid_t pid{0};
  AudioObjectID tap_id{kAudioObjectUnknown};
  AudioObjectID aggregate_id{kAudioObjectUnknown};
  AudioDeviceIOProcID io_proc{nullptr};
  dispatch_queue_t dispatch_queue{nullptr};
  AudioStreamBasicDescription format{};
  std::shared_ptr<AacEncoder> encoder;
  std::uint64_t configuration_generation{0};
  std::int64_t session_epoch_nanoseconds{0};
  std::uint64_t sample_cursor{0};
  std::atomic<bool> running_flag{false};
  std::atomic<std::uint64_t> rejected_layouts{0};
  std::atomic<std::uint64_t> dropped_buffers{0};
  static constexpr std::size_t kPcmQueueCapacity = 32;
  static constexpr std::size_t kMaxFramesPerCallback = 4096;
  std::array<OwnedPcmSlot, kPcmQueueCapacity> owned_slots;
  std::atomic<std::uint64_t> queue_write{0};
  std::atomic<std::uint64_t> queue_read{0};
  std::atomic<bool> worker_scheduled{false};
  dispatch_queue_t worker_queue{nullptr};
  mutable std::mutex error_mutex;
  std::string last_error;
};

ProcessAudioTap::ProcessAudioTap() : impl_(std::make_unique<Impl>()) {}
ProcessAudioTap::~ProcessAudioTap() = default;

bool ProcessAudioTap::start(const std::vector<std::int64_t>& pids, TrackKind track,
                            std::uint32_t track_id,
                            double gain, std::uint64_t generation,
                            std::int64_t session_epoch_nanoseconds,
                            AacEncoder::PacketCallback callback, std::string& error) {
  return impl_->start(pids, track, track_id, gain, generation, session_epoch_nanoseconds,
                      std::move(callback), error);
}
void ProcessAudioTap::stop() { impl_->stop(); }
void ProcessAudioTap::set_gain(double gain) {
  if (impl_->encoder) {
    impl_->encoder->set_gain(gain);
  }
}
void ProcessAudioTap::set_logical_source_id(std::string logical_source_id) {
  if (impl_->encoder) {
    impl_->encoder->set_logical_source_id(std::move(logical_source_id));
  }
}
bool ProcessAudioTap::running() const noexcept {
  return impl_->running_flag.load(std::memory_order_acquire);
}
std::uint64_t ProcessAudioTap::packet_count() const noexcept {
  return impl_->encoder ? impl_->encoder->packet_count() : 0;
}
std::uint64_t ProcessAudioTap::rejected_layout_count() const noexcept {
  return impl_->rejected_layouts.load(std::memory_order_relaxed);
}
std::string ProcessAudioTap::error() const {
  std::scoped_lock lock(impl_->error_mutex);
  return impl_->last_error;
}
std::string ProcessAudioTap::status() const {
  if (!error().empty()) {
    return "error";
  }
  return running() ? "running" : "stopped";
}

}  // namespace native_port
