#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreMedia/CoreMedia.h>
#import <mach/mach_time.h>

#include "process_audio_tap.hpp"
#include "pcm_sample.hpp"

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
             AacEncoder::PacketCallback callback, std::string& error, PcmCallback pcm,
             const std::optional<AudioTapDeviceRoute>& device) {
    stop();
    (void)session_epoch_nanoseconds; // SCK video already uses the absolute host clock.
    queue_read.store(0); queue_write.store(0);
    callback_error.store(0); dropped_buffers.store(0); rejected_layouts.store(0);
    input_frames.store(0); first_host_ns.store(-1); last_host_ns.store(-1);
    process_count = requested_pids.size();
    { std::scoped_lock lock(error_mutex); last_error.clear(); }
    if ((requested_pids.empty() && (!device || !device->all_processes_on_device)) ||
        std::any_of(requested_pids.begin(), requested_pids.end(),
                    [](const auto value) { return value <= 0; })) {
      error = "Core Audio process tap requires positive PIDs";
      return false;
    }
    if (device && device->uid.empty()) { error = "Core Audio device tap requires a stable output UID"; return false; }

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
      CATapDescription* description = nil;
      if (device) {
        NSString* uid = [NSString stringWithUTF8String:device->uid.c_str()];
        description = device->all_processes_on_device
          ? [[CATapDescription alloc] initExcludingProcesses:process_objects andDeviceUID:uid withStream:device->stream_index]
          : [[CATapDescription alloc] initWithProcesses:process_objects andDeviceUID:uid withStream:device->stream_index];
      } else description = [[CATapDescription alloc] initStereoMixdownOfProcesses:process_objects];
      if (description == nil) {
        error = "Core Audio CATapDescription creation returned nil";
        return false;
      }
      description.name = [NSString stringWithFormat:@"Medal process tap (%lu processes)",
                                                        static_cast<unsigned long>(requested_pids.size())];
      description.privateTap = YES;
      // Restoring by bundle ID without a fresh verified family snapshot could
      // acquire a different game instance. The session owns explicit rebuilds.
      description.processRestoreEnabled = NO;
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

      const bool planar = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
      if (format.mChannelsPerFrame < 1 || format.mChannelsPerFrame > 2 ||
          format.mBytesPerFrame > 8 || format.mSampleRate < 8000 || format.mSampleRate > 192000) {
        error = "Core Audio tap negotiated an unsupported PCM layout"; stop(); return false;
      }
      pcm_callback = std::move(pcm);
      if (!pcm_callback) encoder = std::make_shared<AacEncoder>(track, track_id, 96'000, gain, std::move(callback));
      configuration_generation = generation;
      buffer_count = planar ? format.mChannelsPerFrame : 1;
      channels_per_buffer = planar ? 1 : format.mChannelsPerFrame;
      dispatch_queue = dispatch_queue_create("com.squirrel.medal.medal.process-audio-tap",
                                              DISPATCH_QUEUE_SERIAL);
      worker_queue = dispatch_queue_create("com.squirrel.medal.medal.process-audio-tap-worker",
                                           DISPATCH_QUEUE_SERIAL);
      worker_signal = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, worker_queue);
      worker_cancelled = dispatch_semaphore_create(0);
      dispatch_source_set_event_handler(worker_signal, ^{ drain_owned_queue(); });
      dispatch_source_set_cancel_handler(worker_signal, ^{ dispatch_semaphore_signal(worker_cancelled); });
      dispatch_resume(worker_signal);
      for (auto& slot : owned_slots) {
        slot.bytes.resize(kMaxFramesPerCallback * format.mBytesPerFrame * buffer_count);
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
    if (worker_signal != nullptr) {
      dispatch_source_cancel(worker_signal);
      dispatch_semaphore_wait(worker_cancelled, DISPATCH_TIME_FOREVER);
      worker_signal = nullptr;
      worker_cancelled = nullptr;
    }
    if (worker_queue != nullptr) {
      dispatch_sync(worker_queue, ^{ drain_owned_queue(); });
    }
    dispatch_queue = nullptr;
    worker_queue = nullptr;
    encoder.reset();
    pcm_callback = {};
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
        input->mBuffers[0].mDataByteSize == 0) {
      return;
    }
    (void)now;
    if (input->mNumberBuffers != buffer_count) {
      rejected_layouts.fetch_add(1, std::memory_order_relaxed);
      callback_error.store(1, std::memory_order_relaxed);
      running_flag.store(false, std::memory_order_release);
      return;
    }
    const auto frames = input->mBuffers[0].mDataByteSize / format.mBytesPerFrame;
    if (frames == 0 || frames > kMaxFramesPerCallback || input->mBuffers[0].mDataByteSize % format.mBytesPerFrame) {
      dropped_buffers.fetch_add(1, std::memory_order_relaxed);
      callback_error.store(2, std::memory_order_relaxed);
      return;
    }
    std::int64_t host_nanoseconds = 0;
    if (!audio_capture_host_nanoseconds(input_time, host_nanoseconds)) {
      dropped_buffers.fetch_add(1, std::memory_order_relaxed);
      callback_error.store(3, std::memory_order_relaxed);
      return;
    }
    const auto write = queue_write.load(std::memory_order_relaxed);
    const auto read = queue_read.load(std::memory_order_acquire);
    if (write - read >= kPcmQueueCapacity) {
      dropped_buffers.fetch_add(1, std::memory_order_relaxed);
      callback_error.store(4, std::memory_order_relaxed);
      return;
    }
    auto& slot = owned_slots[write % kPcmQueueCapacity];
    for (UInt32 index = 0; index < buffer_count; ++index) {
      const auto& buffer = input->mBuffers[index];
      if (!buffer.mData || buffer.mNumberChannels != channels_per_buffer || buffer.mDataByteSize != frames * format.mBytesPerFrame) {
        rejected_layouts.fetch_add(1, std::memory_order_relaxed); callback_error.store(1, std::memory_order_relaxed); return;
      }
      std::memcpy(slot.bytes.data() + index * frames * format.mBytesPerFrame, buffer.mData, buffer.mDataByteSize);
    }
    slot.byte_count = input->mBuffers[0].mDataByteSize;
    slot.frames = frames;
    slot.host_nanoseconds = host_nanoseconds;
    auto unset = std::int64_t{-1};
    (void)first_host_ns.compare_exchange_strong(unset, host_nanoseconds, std::memory_order_relaxed);
    last_host_ns.store(host_nanoseconds + static_cast<std::int64_t>(frames * 1e9 / format.mSampleRate), std::memory_order_relaxed);
    input_frames.fetch_add(frames, std::memory_order_relaxed);
    queue_write.store(write + 1, std::memory_order_release);
    schedule_worker();
  }

  struct OwnedPcmSlot final {
    std::vector<std::uint8_t> bytes;
    std::size_t byte_count{0};
    std::size_t frames{0};
    std::int64_t host_nanoseconds{0};
  };

  void set_error(std::string value) {
    std::scoped_lock lock(error_mutex);
    if (last_error.empty()) {
      last_error = std::move(value);
    }
  }

  void schedule_worker() {
    dispatch_source_merge_data(worker_signal, 1); // Precreated signal; no per-buffer block allocation.
  }

  void drain_owned_queue() {
    for (;;) {
      const auto read = queue_read.load(std::memory_order_relaxed);
      const auto write = queue_write.load(std::memory_order_acquire);
      if (read >= write) {
        return;
      }
      auto& slot = owned_slots[read % kPcmQueueCapacity];
      struct StereoBufferList { UInt32 count; AudioBuffer buffers[2]; } storage{};
      storage.count = buffer_count;
      for (UInt32 index = 0; index < buffer_count; ++index) {
        storage.buffers[index] = {channels_per_buffer, static_cast<UInt32>(slot.byte_count),
          slot.bytes.data() + index * slot.byte_count};
      }
      std::string error;
      auto sample = make_pcm_sample(format, reinterpret_cast<AudioBufferList*>(&storage), slot.frames,
                                    CMTimeMake(slot.host_nanoseconds, 1'000'000'000), error);
      bool accepted = sample != nullptr;
      if (accepted) {
        accepted = pcm_callback ? pcm_callback(sample, configuration_generation, error)
                                : (encoder && encoder->encode(sample, configuration_generation, error));
        CFRelease(sample);
      }
      if (!accepted) {
        set_error(error.empty() ? "Core Audio tap PCM worker rejected a sample" : std::move(error));
        running_flag.store(false, std::memory_order_release);
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
  PcmCallback pcm_callback;
  UInt32 buffer_count{1}, channels_per_buffer{2};
  std::uint64_t configuration_generation{0};
  std::atomic<bool> running_flag{false};
  std::atomic<std::uint64_t> rejected_layouts{0};
  std::atomic<std::uint64_t> dropped_buffers{0};
  std::atomic<unsigned> callback_error{0};
  static constexpr std::size_t kPcmQueueCapacity = 32;
  static constexpr std::size_t kMaxFramesPerCallback = 4096;
  std::array<OwnedPcmSlot, kPcmQueueCapacity> owned_slots;
  std::atomic<std::uint64_t> queue_write{0};
  std::atomic<std::uint64_t> queue_read{0};
  dispatch_source_t worker_signal{nullptr};
  dispatch_semaphore_t worker_cancelled{nullptr};
  dispatch_queue_t worker_queue{nullptr};
  mutable std::mutex error_mutex;
  std::string last_error;
  std::string source_id;
  std::size_t process_count{0};
  std::atomic<std::uint64_t> input_frames{0};
  std::atomic<std::int64_t> first_host_ns{-1}, last_host_ns{-1};
};

ProcessAudioTap::ProcessAudioTap() : impl_(std::make_unique<Impl>()) {}
ProcessAudioTap::~ProcessAudioTap() = default;

bool ProcessAudioTap::start(const std::vector<std::int64_t>& pids, TrackKind track,
                            std::uint32_t track_id,
                            double gain, std::uint64_t generation,
                            std::int64_t session_epoch_nanoseconds,
                            AacEncoder::PacketCallback callback, std::string& error, PcmCallback pcm,
                            std::optional<AudioTapDeviceRoute> device) {
  return impl_->start(pids, track, track_id, gain, generation, session_epoch_nanoseconds,
                      std::move(callback), error, std::move(pcm), device);
}
void ProcessAudioTap::stop() { impl_->stop(); }
void ProcessAudioTap::set_gain(double gain) {
  if (impl_->encoder) {
    impl_->encoder->set_gain(gain);
  }
}
void ProcessAudioTap::set_logical_source_id(std::string logical_source_id) {
  { std::scoped_lock lock(impl_->error_mutex); impl_->source_id = logical_source_id; }
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
  if (impl_->last_error.empty()) {
    switch (impl_->callback_error.load(std::memory_order_relaxed)) {
      case 1: return "Core Audio tap delivered a malformed PCM layout";
      case 2: return "Core Audio tap callback exceeded bounded PCM slot capacity";
      case 3: return "Core Audio tap capture timestamp has no valid host-time flag";
      case 4: return "Core Audio tap PCM queue overflowed; samples were dropped";
      default: break;
    }
  }
  return impl_->last_error;
}
std::string ProcessAudioTap::status() const {
  if (!error().empty()) {
    return "error";
  }
  return running() ? "running" : "stopped";
}

nlohmann::json ProcessAudioTap::diagnostics() const {
  std::string id;
  { std::scoped_lock lock(impl_->error_mutex); id = impl_->source_id; }
  return {{"logicalSourceId", id}, {"state", status()}, {"error", error()},
    {"generation", impl_->configuration_generation}, {"processCount", impl_->process_count},
    {"sampleRate", impl_->format.mSampleRate}, {"channels", impl_->format.mChannelsPerFrame},
    {"bufferCount", impl_->buffer_count}, {"inputFrames", impl_->input_frames.load()},
    {"firstHostNanoseconds", impl_->first_host_ns.load()}, {"lastHostEndNanoseconds", impl_->last_host_ns.load()},
    {"droppedBuffers", impl_->dropped_buffers.load()}, {"rejectedLayouts", impl_->rejected_layouts.load()}};
}

}  // namespace native_port
