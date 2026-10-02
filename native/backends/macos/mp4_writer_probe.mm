#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>

#include "audio_encoder.hpp"

#include "native_port/mp4_writer.hpp"
#include "native_port/replay_store.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <memory>
#include <mutex>
#include <numbers>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include <unistd.h>

namespace {

constexpr std::int32_t kWidth = 640;
constexpr std::int32_t kHeight = 360;
constexpr std::int32_t kFramesPerSecond = 30;
constexpr std::int32_t kVideoFrames = 60;
constexpr std::int32_t kSampleRate = 48'000;
constexpr std::uint32_t kChannels = 2;
constexpr std::uint32_t kAudioFramesPerBuffer = 480;
constexpr std::uint32_t kAudioBufferCount = 200;

[[nodiscard]] std::shared_ptr<const std::vector<std::byte>> copy_block(CMBlockBufferRef block) {
  if (block == nullptr) {
    return nullptr;
  }
  const auto size = CMBlockBufferGetDataLength(block);
  auto bytes = std::make_shared<std::vector<std::byte>>(size);
  if (CMBlockBufferCopyDataBytes(block, 0, size, bytes->data()) != kCMBlockBufferNoErr) {
    return nullptr;
  }
  return bytes;
}

[[nodiscard]] bool is_keyframe(CMSampleBufferRef sample) {
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
  if (attachments == nullptr || CFArrayGetCount(attachments) == 0) {
    return true;
  }
  auto* values = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
  return CFDictionaryGetValue(values, kCMSampleAttachmentKey_NotSync) != kCFBooleanTrue;
}

[[nodiscard]] std::shared_ptr<const std::vector<std::byte>> video_configuration(
    CMFormatDescriptionRef format) {
  auto* extensions = CMFormatDescriptionGetExtensions(format);
  if (extensions == nullptr) {
    return nullptr;
  }
  auto* atoms = static_cast<CFDictionaryRef>(
      CFDictionaryGetValue(extensions, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms));
  if (atoms == nullptr) {
    return nullptr;
  }
  auto* data = static_cast<CFDataRef>(CFDictionaryGetValue(atoms, CFSTR("avcC")));
  if (data == nullptr) {
    return nullptr;
  }
  const auto length = CFDataGetLength(data);
  auto result = std::make_shared<std::vector<std::byte>>(static_cast<std::size_t>(length));
  CFDataGetBytes(data, CFRangeMake(0, length), reinterpret_cast<UInt8*>(result->data()));
  return result;
}

struct VideoOutput final {
  std::mutex mutex;
  std::vector<std::shared_ptr<const native_port::EncodedPacket>> packets;
  std::uint32_t failures{0};
};

void video_callback(void* refcon, void*, OSStatus status, VTEncodeInfoFlags flags,
                    CMSampleBufferRef sample) {
  auto* output = static_cast<VideoOutput*>(refcon);
  if (output == nullptr) {
    return;
  }
  if (status != noErr || (flags & kVTEncodeInfo_FrameDropped) != 0 || sample == nullptr ||
      !CMSampleBufferDataIsReady(sample)) {
    std::scoped_lock lock(output->mutex);
    ++output->failures;
    return;
  }
  auto packet = std::make_shared<native_port::EncodedPacket>();
  packet->codec = native_port::Codec::h264;
  packet->track = native_port::TrackKind::video;
  packet->track_id = 0;
  packet->configuration_generation = 1;
  const auto pts = CMSampleBufferGetPresentationTimeStamp(sample);
  const auto duration = CMSampleBufferGetDuration(sample);
  packet->pts = native_port::MediaTime{pts.value, native_port::Rational{1, pts.timescale}};
  packet->dts = packet->pts;
  packet->duration = native_port::MediaTime{duration.value,
                                            native_port::Rational{1, duration.timescale}};
  packet->monotonic_nanoseconds = static_cast<std::int64_t>(
      std::llround(CMTimeGetSeconds(pts) * 1'000'000'000.0));
  packet->keyframe = is_keyframe(sample);
  packet->depends_on_others = !packet->keyframe;
  packet->video_width = kWidth;
  packet->video_height = kHeight;
  packet->bitrate_bits_per_second = 1'500'000;
  packet->data = copy_block(CMSampleBufferGetDataBuffer(sample));
  if (packet->keyframe) {
    packet->codec_configuration = video_configuration(CMSampleBufferGetFormatDescription(sample));
  }
  std::scoped_lock lock(output->mutex);
  if (!packet->data || packet->data->empty() ||
      (packet->keyframe && (!packet->codec_configuration || packet->codec_configuration->empty()))) {
    ++output->failures;
    return;
  }
  output->packets.push_back(std::move(packet));
}

[[nodiscard]] CVPixelBufferRef make_pixel_buffer() {
  const void* keys[] = {kCVPixelBufferIOSurfacePropertiesKey};
  CFDictionaryRef empty = CFDictionaryCreate(kCFAllocatorDefault, nullptr, nullptr, 0,
                                              &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
  const void* values[] = {empty};
  CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
                                                   &kCFTypeDictionaryKeyCallBacks,
                                                   &kCFTypeDictionaryValueCallBacks);
  CVPixelBufferRef pixel = nullptr;
  const auto status = CVPixelBufferCreate(kCFAllocatorDefault, kWidth, kHeight,
                                           kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           attributes, &pixel);
  CFRelease(attributes);
  CFRelease(empty);
  if (status != kCVReturnSuccess || pixel == nullptr || CVPixelBufferLockBaseAddress(pixel, 0) !=
                                                        kCVReturnSuccess) {
    if (pixel != nullptr) {
      CVPixelBufferRelease(pixel);
    }
    return nullptr;
  }
  for (std::size_t plane = 0; plane < CVPixelBufferGetPlaneCount(pixel); ++plane) {
    auto* base = static_cast<unsigned char*>(CVPixelBufferGetBaseAddressOfPlane(pixel, plane));
    const auto bytes = CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) *
                       CVPixelBufferGetHeightOfPlane(pixel, plane);
    std::memset(base, plane == 0 ? 48 : 128, bytes);
  }
  CVPixelBufferUnlockBaseAddress(pixel, 0);
  return pixel;
}

[[nodiscard]] bool encode_video(VideoOutput& output, std::string& error, std::int64_t epoch_seconds = 0) {
  const void* keys[] = {kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder};
  const void* values[] = {kCFBooleanTrue};
  CFDictionaryRef specification = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
                                                       &kCFTypeDictionaryKeyCallBacks,
                                                       &kCFTypeDictionaryValueCallBacks);
  VTCompressionSessionRef session = nullptr;
  auto status = VTCompressionSessionCreate(kCFAllocatorDefault, kWidth, kHeight, kCMVideoCodecType_H264,
                                            specification, nullptr, nullptr, &video_callback, &output,
                                            &session);
  CFRelease(specification);
  if (status != noErr || session == nullptr) {
    error = "VideoToolbox session failed with OSStatus " + std::to_string(status);
    return false;
  }
  VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
  std::int32_t bitrate = 1'500'000;
  CFNumberRef bitrate_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bitrate);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, bitrate_number);
  CFRelease(bitrate_number);
  std::int32_t interval = kFramesPerSecond;
  CFNumberRef interval_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &interval);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, interval_number);
  CFRelease(interval_number);
  status = VTCompressionSessionPrepareToEncodeFrames(session);
  CVPixelBufferRef pixel = make_pixel_buffer();
  for (std::int32_t index = 0; status == noErr && index < kVideoFrames && pixel != nullptr; ++index) {
    status = VTCompressionSessionEncodeFrame(session, pixel, CMTimeMake(epoch_seconds * kFramesPerSecond + index, kFramesPerSecond),
                                              CMTimeMake(1, kFramesPerSecond), nullptr, nullptr, nullptr);
  }
  if (pixel != nullptr) {
    CVPixelBufferRelease(pixel);
  }
  if (status == noErr) {
    status = VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
  }
  VTCompressionSessionInvalidate(session);
  CFRelease(session);
  if (status != noErr) {
    error = "VideoToolbox encode failed with OSStatus " + std::to_string(status);
    return false;
  }
  return output.failures == 0 && output.packets.size() == kVideoFrames;
}

[[nodiscard]] CMSampleBufferRef make_audio_sample(CMAudioFormatDescriptionRef format,
                                                  std::int64_t first_frame) {
  std::vector<float> samples(kAudioFramesPerBuffer * kChannels);
  for (std::uint32_t frame = 0; frame < kAudioFramesPerBuffer; ++frame) {
    const auto phase = 2.0 * std::numbers::pi * 440.0 *
                       static_cast<double>(first_frame + frame) / kSampleRate;
    const auto value = static_cast<float>(std::sin(phase) * 0.125);
    samples[frame * 2] = value;
    samples[frame * 2 + 1] = value;
  }
  const auto byte_count = samples.size() * sizeof(float);
  CMBlockBufferRef block = nullptr;
  if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, byte_count, kCFAllocatorDefault,
                                         nullptr, 0, byte_count, 0, &block) != kCMBlockBufferNoErr ||
      block == nullptr ||
      CMBlockBufferReplaceDataBytes(samples.data(), block, 0, byte_count) != kCMBlockBufferNoErr) {
    if (block != nullptr) {
      CFRelease(block);
    }
    return nullptr;
  }
  CMSampleBufferRef sample = nullptr;
  const auto status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      kCFAllocatorDefault, block, format, kAudioFramesPerBuffer,
      CMTimeMake(first_frame, kSampleRate), nullptr, &sample);
  CFRelease(block);
  return status == noErr ? sample : nullptr;
}

[[nodiscard]] bool encode_audio(
    std::vector<std::shared_ptr<const native_port::EncodedPacket>>& packets, std::string& error) {
  AudioStreamBasicDescription pcm{};
  pcm.mSampleRate = kSampleRate;
  pcm.mFormatID = kAudioFormatLinearPCM;
  pcm.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  pcm.mBytesPerPacket = sizeof(float) * kChannels;
  pcm.mFramesPerPacket = 1;
  pcm.mBytesPerFrame = sizeof(float) * kChannels;
  pcm.mChannelsPerFrame = kChannels;
  pcm.mBitsPerChannel = sizeof(float) * 8;
  CMAudioFormatDescriptionRef format = nullptr;
  if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &pcm, 0, nullptr, 0, nullptr, nullptr,
                                     &format) != noErr || format == nullptr) {
    error = "synthetic PCM format creation failed";
    return false;
  }
  native_port::AacEncoder encoder(native_port::TrackKind::game_audio, 1, 160'000, 1.0,
                                  [&](auto packet) { packets.push_back(std::move(packet)); });
  bool succeeded = true;
  for (std::uint32_t index = 0; index < kAudioBufferCount && succeeded; ++index) {
    CMSampleBufferRef sample = make_audio_sample(format,
        static_cast<std::int64_t>(index) * kAudioFramesPerBuffer);
    if (sample == nullptr) {
      error = "synthetic PCM sample creation failed";
      succeeded = false;
    } else {
      succeeded = encoder.encode(sample, 1, error);
      CFRelease(sample);
    }
  }
  CFRelease(format);
  return succeeded && encoder.failure_count() == 0 && !packets.empty();
}

[[nodiscard]] std::size_t readable_sample_count(NSURL* url, AVMediaType type) {
  AVURLAsset* asset = [AVURLAsset URLAssetWithURL:url options:nil];
  __block NSArray<AVAssetTrack*>* tracks = nil;
  dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
  [asset loadTracksWithMediaType:type completionHandler:^(NSArray<AVAssetTrack*>* result, NSError*) {
    tracks = result;
    dispatch_semaphore_signal(loaded);
  }];
  if (dispatch_semaphore_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, 2LL * NSEC_PER_SEC)) != 0) {
    return 0;
  }
  if (tracks.count != 1) {
    return 0;
  }
  NSError* error = nil;
  AVAssetReader* reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
  AVAssetReaderTrackOutput* output = [[AVAssetReaderTrackOutput alloc] initWithTrack:tracks.firstObject
                                                                      outputSettings:nil];
  if (reader == nil || ![reader canAddOutput:output]) {
    return 0;
  }
  [reader addOutput:output];
  if (![reader startReading]) {
    return 0;
  }
  std::size_t count = 0;
  while (CMSampleBufferRef sample = [output copyNextSampleBuffer]) {
    ++count;
    CFRelease(sample);
  }
  return reader.status == AVAssetReaderStatusCompleted ? count : 0;
}

}  // namespace

#ifndef NATIVE_PORT_MP4_FIXTURE_ONLY
int main() {
  @autoreleasepool {
    VideoOutput video;
    std::vector<std::shared_ptr<const native_port::EncodedPacket>> audio;
    std::string error;
    const bool video_ok = encode_video(video, error);
    const bool audio_ok = video_ok && encode_audio(audio, error);
    std::vector<std::shared_ptr<const native_port::EncodedPacket>> packets = video.packets;
    packets.insert(packets.end(), audio.begin(), audio.end());
    std::sort(packets.begin(), packets.end(), [](const auto& left, const auto& right) {
      return left->monotonic_nanoseconds < right->monotonic_nanoseconds;
    });
    native_port::ReplayStore replay({.maximum_duration = std::chrono::seconds(10),
                                     .maximum_bytes = 64U * 1024U * 1024U});
    for (const auto& packet : packets) {
      replay.push(packet);
    }
    const auto snapshot = replay.snapshot(std::chrono::seconds(5));
    const auto output_path = std::filesystem::temp_directory_path() /
                             ("native-port-mp4-writer-probe-" + std::to_string(::getpid()) + ".mp4");
    std::error_code ignored;
    std::filesystem::remove(output_path, ignored);
    native_port::Mp4WriteResult write_result;
    bool write_ok = false;
    if (audio_ok && snapshot) {
      try {
        write_result = native_port::write_mp4(output_path, *snapshot);
        write_ok = true;
      } catch (const std::exception& exception) {
        error = exception.what();
      }
    }
    NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:output_path.string().c_str()]];
    const auto readable_video = write_ok ? readable_sample_count(url, AVMediaTypeVideo) : 0;
    const auto readable_audio = write_ok ? readable_sample_count(url, AVMediaTypeAudio) : 0;
    const bool passed = write_ok && write_result.video_packets == video.packets.size() &&
                        write_result.system_audio_packets == audio.size() && readable_video > 0 &&
                        readable_audio > 0 && write_result.bytes_written > 0 &&
                        write_result.audio_streams.size() == 1 &&
                        write_result.audio_streams.front().absolute_stream_index == 1 &&
                        write_result.audio_streams.front().default_track;
    nlohmann::json manifest = nlohmann::json::array();
    for (const auto& stream : write_result.audio_streams) {
      manifest.push_back({{"index", stream.absolute_stream_index},
                          {"audioOrdinal", stream.audio_ordinal},
                          {"logicalId", stream.logical_id},
                          {"title", stream.title},
                          {"default", stream.default_track}});
    }
    nlohmann::json output = {
        {"schemaVersion", 1},
        {"probe", "VideoToolbox and AudioToolbox encoded replay to AVAssetWriter MP4"},
        {"status", passed ? "passed" : "failed"},
        {"error", error},
        {"videoPacketCount", video.packets.size()},
        {"audioPacketCount", audio.size()},
        {"writeVideoPacketCount", write_result.video_packets},
        {"writeSystemAudioPacketCount", write_result.system_audio_packets},
        {"readableVideoSampleCount", readable_video},
        {"readableAudioSampleCount", readable_audio},
        {"bytesWritten", write_result.bytes_written},
        {"audioManifest", std::move(manifest)},
        {"outputPath", output_path.string()},
    };
    std::cout << output.dump(2) << '\n';
    if (passed && std::getenv("NATIVE_PORT_KEEP_MP4_PROBE") == nullptr) {
      std::filesystem::remove(output_path, ignored);
    }
    return passed ? 0 : 1;
  }
}
#endif
