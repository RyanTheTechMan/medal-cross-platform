#import <AVFoundation/AVFoundation.h>
#import <AVFoundation/AVMetadataIdentifiers.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>

#include "native_port/mp4_writer.hpp"

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

namespace native_port {
namespace {

template <typename T>
class CfRef final {
 public:
  CfRef() = default;
  explicit CfRef(T value) : value_(value) {}
  ~CfRef() {
    if (value_ != nullptr) {
      CFRelease(value_);
    }
  }

  CfRef(const CfRef&) = delete;
  CfRef& operator=(const CfRef&) = delete;
  CfRef(CfRef&& other) noexcept : value_(std::exchange(other.value_, nullptr)) {}
  CfRef& operator=(CfRef&& other) noexcept {
    if (this != &other) {
      if (value_ != nullptr) {
        CFRelease(value_);
      }
      value_ = std::exchange(other.value_, nullptr);
    }
    return *this;
  }

  [[nodiscard]] T get() const noexcept { return value_; }

 private:
  T value_{nullptr};
};

struct WriterTrack final {
  TrackKind track;
  Codec codec;
  AVAssetWriterInput* input;
  CfRef<CMFormatDescriptionRef> format;
  std::vector<const EncodedPacket*> packets;
};

struct FeedState final {
  void fail(std::string message) {
    std::scoped_lock lock(mutex);
    if (!error) {
      error = std::move(message);
    }
  }

  [[nodiscard]] std::optional<std::string> failure() const {
    std::scoped_lock lock(mutex);
    return error;
  }

  mutable std::mutex mutex;
  std::optional<std::string> error;
};

[[nodiscard]] std::string ns_text(NSString* value) {
  if (value == nil) {
    return "unknown Apple-framework error";
  }
  const char* utf8 = value.UTF8String;
  return utf8 == nullptr ? "unrepresentable Apple-framework error" : std::string(utf8);
}

[[nodiscard]] std::string writer_error(AVAssetWriter* writer) {
  NSError* error = writer.error;
  return error == nil ? "AVAssetWriter status " + std::to_string(writer.status)
                      : ns_text(error.localizedDescription);
}

[[nodiscard]] const EncodedPacket* first_packet(const ReplaySnapshot& snapshot, TrackKind track) {
  const auto found = std::find_if(snapshot.packets.begin(), snapshot.packets.end(),
                                  [track](const auto& packet) { return packet->track == track; });
  return found == snapshot.packets.end() ? nullptr : found->get();
}

[[nodiscard]] const EncodedPacket* configured_packet(const ReplaySnapshot& snapshot, TrackKind track) {
  const auto found = std::find_if(snapshot.packets.begin(), snapshot.packets.end(), [track](const auto& packet) {
    return packet->track == track && packet->codec_configuration && !packet->codec_configuration->empty();
  });
  return found == snapshot.packets.end() ? nullptr : found->get();
}

[[nodiscard]] CMVideoCodecType video_codec_type(Codec codec) {
  switch (codec) {
    case Codec::h264:
      return kCMVideoCodecType_H264;
    case Codec::hevc:
      return kCMVideoCodecType_HEVC;
    case Codec::av1:
      return kCMVideoCodecType_AV1;
    case Codec::aac:
      break;
  }
  throw std::invalid_argument("AAC cannot be used as an MP4 video track");
}

[[nodiscard]] NSString* video_configuration_atom(Codec codec) {
  switch (codec) {
    case Codec::h264:
      return @"avcC";
    case Codec::hevc:
      return @"hvcC";
    case Codec::av1:
      return @"av1C";
    case Codec::aac:
      break;
  }
  throw std::invalid_argument("AAC has no video decoder-configuration atom");
}

[[nodiscard]] CfRef<CMFormatDescriptionRef> video_format(const EncodedPacket& first,
                                                         const EncodedPacket& configured) {
  if (first.video_width == 0 || first.video_height == 0 || !configured.codec_configuration ||
      configured.codec_configuration->empty()) {
    throw std::runtime_error("MP4 export requires video dimensions and decoder configuration");
  }
  if (first.video_width > static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max()) ||
      first.video_height > static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max())) {
    throw std::runtime_error("MP4 video dimensions exceed CoreMedia limits");
  }
  NSData* atom = [NSData dataWithBytes:configured.codec_configuration->data()
                               length:configured.codec_configuration->size()];
  NSDictionary* atoms = @{video_configuration_atom(first.codec) : atom};
  NSDictionary* extensions = @{
    (__bridge NSString*)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms : atoms,
    (__bridge NSString*)kCMFormatDescriptionExtension_ColorPrimaries :
        (__bridge NSString*)kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
    (__bridge NSString*)kCMFormatDescriptionExtension_TransferFunction :
        (__bridge NSString*)kCMFormatDescriptionTransferFunction_ITU_R_709_2,
    (__bridge NSString*)kCMFormatDescriptionExtension_YCbCrMatrix :
        (__bridge NSString*)kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
  };
  CMFormatDescriptionRef raw = nullptr;
  const auto status = CMVideoFormatDescriptionCreate(
      kCFAllocatorDefault, video_codec_type(first.codec), static_cast<std::int32_t>(first.video_width),
      static_cast<std::int32_t>(first.video_height), (__bridge CFDictionaryRef)extensions, &raw);
  if (status != noErr || raw == nullptr) {
    throw std::runtime_error("CoreMedia video format creation failed with OSStatus " +
                             std::to_string(status));
  }
  return CfRef<CMFormatDescriptionRef>(raw);
}

[[nodiscard]] CfRef<CMFormatDescriptionRef> audio_format(const EncodedPacket& first,
                                                         const EncodedPacket& configured) {
  if (first.codec != Codec::aac || first.sample_rate == 0 || first.channel_count == 0 ||
      !configured.codec_configuration || configured.codec_configuration->empty()) {
    throw std::runtime_error("MP4 export requires AAC sample rate, channels and decoder configuration");
  }
  AudioStreamBasicDescription description{};
  description.mSampleRate = first.sample_rate;
  description.mFormatID = kAudioFormatMPEG4AAC;
  description.mFormatFlags = kMPEG4Object_AAC_LC;
  description.mFramesPerPacket = static_cast<std::uint32_t>(first.duration.value);
  description.mChannelsPerFrame = first.channel_count;
  const auto& cookie = configured.platform_codec_cookie ? configured.platform_codec_cookie
                                                        : configured.codec_configuration;
  CMFormatDescriptionRef raw = nullptr;
  const auto status = CMAudioFormatDescriptionCreate(
      kCFAllocatorDefault, &description, 0, nullptr, cookie->size(), cookie->data(), nullptr, &raw);
  if (status != noErr || raw == nullptr) {
    throw std::runtime_error("CoreMedia AAC format creation failed with OSStatus " +
                             std::to_string(status));
  }
  return CfRef<CMFormatDescriptionRef>(raw);
}

[[nodiscard]] WriterTrack make_track(AVAssetWriter* writer, const ReplaySnapshot& snapshot,
                                     TrackKind track) {
  const auto* first = first_packet(snapshot, track);
  const auto* configured = configured_packet(snapshot, track);
  if (first == nullptr || configured == nullptr) {
    throw std::runtime_error("MP4 track has no configured encoded packet");
  }
  auto format = track == TrackKind::video ? video_format(*first, *configured)
                                          : audio_format(*first, *configured);
  const AVMediaType media_type = track == TrackKind::video ? AVMediaTypeVideo : AVMediaTypeAudio;
  AVAssetWriterInput* input = [[AVAssetWriterInput alloc] initWithMediaType:media_type
                                                            outputSettings:nil
                                                         sourceFormatHint:format.get()];
  if (input == nil || ![writer canAddInput:input]) {
    throw std::runtime_error("AVAssetWriter cannot add the requested passthrough track");
  }
  // Keep the source identity in the media container. Chromium's audio-track
  // labels and the imported Medal client can use this track-level metadata;
  // without it every native track is exposed as the unhelpful "Audio Stream
  // #N". This is deliberately attached to the track, not sent through
  // Electron IPC, so the labels survive export/import and application restart.
  NSString* track_name = nil;
  switch (track) {
    case TrackKind::mixed_audio:
      track_name = @"PC Audio";
      break;
    case TrackKind::game_audio:
      track_name = @"Game Audio";
      break;
    case TrackKind::microphone_audio:
      track_name = @"Microphone";
      break;
    case TrackKind::video:
      track_name = @"Video";
      break;
  }
  AVMutableMetadataItem* track_name_item = [AVMutableMetadataItem metadataItem];
  track_name_item.identifier = AVMetadataIdentifierQuickTimeUserDataTrackName;
  track_name_item.value = track_name;
  track_name_item.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
  // The imported client's ffprobe path reads `stream.tags.title`, while
  // AVFoundation exposes the QuickTime user-data track name above.  Emit the
  // common title identifier as well so both the native probe and the original
  // client agree on the source label.
  AVMutableMetadataItem* title_item = [AVMutableMetadataItem metadataItem];
  title_item.identifier = AVMetadataIdentifierQuickTimeMetadataTitle;
  title_item.value = track_name;
  title_item.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
  AVMutableMetadataItem* common_title_item = [AVMutableMetadataItem metadataItem];
  common_title_item.identifier = AVMetadataCommonIdentifierTitle;
  common_title_item.value = track_name;
  common_title_item.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
  input.metadata = @[track_name_item, title_item, common_title_item];
  input.expectsMediaDataInRealTime = NO;
  [writer addInput:input];
  return WriterTrack{track, first->codec, input, std::move(format), {}};
}

[[nodiscard]] WriterTrack* track_for(std::vector<WriterTrack>& tracks, const EncodedPacket& packet) {
  const auto found = std::find_if(tracks.begin(), tracks.end(), [&](const auto& track) {
    return track.track == packet.track && track.codec == packet.codec;
  });
  return found == tracks.end() ? nullptr : &*found;
}

[[nodiscard]] CMTime media_time(const MediaTime& time) {
  if (time.time_base.numerator <= 0 || time.time_base.denominator <= 0) {
    return kCMTimeInvalid;
  }
  return CMTimeMakeWithEpoch(time.value * time.time_base.numerator, time.time_base.denominator, 0);
}

[[nodiscard]] CMTime relative_time(std::int64_t monotonic_nanoseconds,
                                   std::int64_t start_monotonic_nanoseconds) {
  return CMTimeMake(std::max<std::int64_t>(0, monotonic_nanoseconds - start_monotonic_nanoseconds),
                    1'000'000'000);
}

[[nodiscard]] CfRef<CMBlockBufferRef> block_buffer(const EncodedPacket& packet) {
  if (!packet.data || packet.data->empty()) {
    throw std::runtime_error("encoded packet payload is missing");
  }
  CMBlockBufferRef raw = nullptr;
  auto status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, packet.data->size(),
                                                   kCFAllocatorDefault, nullptr, 0, packet.data->size(), 0,
                                                   &raw);
  if (status != kCMBlockBufferNoErr || raw == nullptr) {
    throw std::runtime_error("CoreMedia block allocation failed with OSStatus " +
                             std::to_string(status));
  }
  CfRef<CMBlockBufferRef> result(raw);
  status = CMBlockBufferReplaceDataBytes(packet.data->data(), raw, 0, packet.data->size());
  if (status != kCMBlockBufferNoErr) {
    throw std::runtime_error("CoreMedia block copy failed with OSStatus " + std::to_string(status));
  }
  return result;
}

[[nodiscard]] CfRef<CMSampleBufferRef> sample_buffer(const EncodedPacket& packet,
                                                     CMFormatDescriptionRef format,
                                                     std::int64_t start_monotonic_nanoseconds,
                                                     std::optional<std::int64_t> end_override_nanoseconds) {
  auto data = block_buffer(packet);
  const auto presentation_time = relative_time(packet.monotonic_nanoseconds, start_monotonic_nanoseconds);
  const auto duration = end_override_nanoseconds
                            ? CMTimeMake(std::max<std::int64_t>(
                                             1, *end_override_nanoseconds - packet.monotonic_nanoseconds),
                                         1'000'000'000)
                            : media_time(packet.duration);
  CMSampleTimingInfo timing{duration, presentation_time, presentation_time};
  const auto size = packet.data->size();
  CMSampleBufferRef raw = nullptr;
  const auto status = CMSampleBufferCreateReady(kCFAllocatorDefault, data.get(), format, 1, 1, &timing,
                                                1, &size, &raw);
  if (status != noErr || raw == nullptr) {
    throw std::runtime_error("CoreMedia sample creation failed with OSStatus " +
                             std::to_string(status));
  }
  CfRef<CMSampleBufferRef> result(raw);
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(raw, true);
  if (attachments != nullptr && CFArrayGetCount(attachments) > 0) {
    auto* sample_attachments = const_cast<CFMutableDictionaryRef>(
        static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0)));
    CFDictionarySetValue(sample_attachments, kCMSampleAttachmentKey_DependsOnOthers,
                         packet.depends_on_others ? kCFBooleanTrue : kCFBooleanFalse);
    if (!packet.keyframe) {
      CFDictionarySetValue(sample_attachments, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
    }
  }
  if (packet.encoder_delay_frames > 0 && packet.sample_rate > 0) {
    const auto trim = CMTimeMake(packet.encoder_delay_frames, packet.sample_rate);
    CfRef<CFDictionaryRef> dictionary(CMTimeCopyAsDictionary(trim, kCFAllocatorDefault));
    CMSetAttachment(raw, kCMSampleBufferAttachmentKey_TrimDurationAtStart, dictionary.get(),
                    kCMAttachmentMode_ShouldPropagate);
  }
  if (packet.discard_padding_frames > 0 && packet.sample_rate > 0) {
    const auto trim = CMTimeMake(packet.discard_padding_frames, packet.sample_rate);
    CfRef<CFDictionaryRef> dictionary(CMTimeCopyAsDictionary(trim, kCFAllocatorDefault));
    CMSetAttachment(raw, kCMSampleBufferAttachmentKey_TrimDurationAtEnd, dictionary.get(),
                    kCMAttachmentMode_ShouldPropagate);
  }
  return result;
}

void append_packet(AVAssetWriter* writer, WriterTrack& track, const EncodedPacket& packet,
                   std::int64_t start_monotonic_nanoseconds,
                   std::optional<std::int64_t> end_override_nanoseconds = std::nullopt) {
  @try {
    auto sample = sample_buffer(packet, track.format.get(), start_monotonic_nanoseconds,
                                end_override_nanoseconds);
    if (![track.input appendSampleBuffer:sample.get()]) {
      throw std::runtime_error("AVAssetWriter rejected an encoded packet: " + writer_error(writer));
    }
  } @catch (NSException* exception) {
    throw std::runtime_error("AVFoundation append exception: " + ns_text(exception.reason));
  }
}

}  // namespace

Mp4WriteResult write_mp4(const std::filesystem::path& output_path, const ReplaySnapshot& snapshot) {
  @autoreleasepool {
    @try {
      if (snapshot.packets.empty()) {
        throw std::invalid_argument("cannot write an empty replay snapshot");
      }
      const auto utf8_path = output_path.string();
      NSString* path = [NSString stringWithUTF8String:utf8_path.c_str()];
      if (path == nil) {
        throw std::invalid_argument("MP4 output path is not valid UTF-8");
      }
      NSError* creation_error = nil;
      AVAssetWriter* writer = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:path]
                                                       fileType:AVFileTypeMPEG4
                                                          error:&creation_error];
      if (writer == nil) {
        throw std::runtime_error("AVAssetWriter creation failed: " +
                                 ns_text(creation_error.localizedDescription));
      }
      writer.shouldOptimizeForNetworkUse = YES;

      std::vector<WriterTrack> tracks;
      tracks.push_back(make_track(writer, snapshot, TrackKind::video));
      for (const auto track : {TrackKind::mixed_audio, TrackKind::game_audio,
                               TrackKind::microphone_audio}) {
        if (first_packet(snapshot, track) != nullptr) {
          tracks.push_back(make_track(writer, snapshot, track));
        }
      }
      for (const auto& packet : snapshot.packets) {
        auto* track = track_for(tracks, *packet);
        if (track == nullptr) {
          throw std::runtime_error("replay snapshot changed codec within one configuration generation");
        }
        track->packets.push_back(packet.get());
      }
      if (![writer startWriting]) {
        throw std::runtime_error("AVAssetWriter failed to start: " + writer_error(writer));
      }
      [writer startSessionAtSourceTime:kCMTimeZero];

      auto feed_state = std::make_shared<FeedState>();
      dispatch_group_t feeds = dispatch_group_create();
      for (auto& track : tracks) {
        auto* selected_track = &track;
        dispatch_group_enter(feeds);
        dispatch_queue_t queue = dispatch_queue_create("com.squirrel.medal.medal.recorder.mp4-track",
                                                       DISPATCH_QUEUE_SERIAL);
        __block std::size_t packet_index = 0;
        __block bool completed = false;
        [track.input requestMediaDataWhenReadyOnQueue:queue usingBlock:^{
          @autoreleasepool {
            if (completed) {
              return;
            }
            while (selected_track->input.readyForMoreMediaData) {
              if (const auto failure = feed_state->failure()) {
                [selected_track->input markAsFinished];
                completed = true;
                dispatch_group_leave(feeds);
                return;
              }
              if (packet_index >= selected_track->packets.size()) {
                [selected_track->input markAsFinished];
                completed = true;
                dispatch_group_leave(feeds);
                return;
              }
              try {
                const bool is_last_video_packet =
                    selected_track->track == TrackKind::video &&
                    packet_index + 1 == selected_track->packets.size();
                append_packet(writer, *selected_track, *selected_track->packets[packet_index],
                              snapshot.start_monotonic_nanoseconds,
                              is_last_video_packet
                                  ? std::optional<std::int64_t>(snapshot.end_monotonic_nanoseconds)
                                  : std::nullopt);
                ++packet_index;
              } catch (const std::exception& error) {
                feed_state->fail(error.what());
              }
            }
          }
        }];
      }
      if (dispatch_group_wait(feeds, dispatch_time(DISPATCH_TIME_NOW, 4LL * NSEC_PER_SEC)) != 0) {
        [writer cancelWriting];
        throw std::runtime_error("AVAssetWriter track feeds did not finish within 4 seconds");
      }
      if (const auto failure = feed_state->failure()) {
        [writer cancelWriting];
        throw std::runtime_error(*failure);
      }
      dispatch_semaphore_t completion = dispatch_semaphore_create(0);
      [writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(completion);
      }];
      if (dispatch_semaphore_wait(completion,
                                  dispatch_time(DISPATCH_TIME_NOW, 4LL * NSEC_PER_SEC)) != 0) {
        [writer cancelWriting];
        throw std::runtime_error("AVAssetWriter did not finish within 4 seconds");
      }
      if (writer.status != AVAssetWriterStatusCompleted) {
        throw std::runtime_error("AVAssetWriter failed to finish: " + writer_error(writer));
      }
      Mp4WriteResult result;
      std::error_code filesystem_error;
      result.bytes_written = std::filesystem::file_size(output_path, filesystem_error);
      if (filesystem_error) {
        throw std::system_error(filesystem_error, "stat exported MP4");
      }
      for (const auto& packet : snapshot.packets) {
        if (packet->track == TrackKind::video) {
          ++result.video_packets;
        } else if (packet->track == TrackKind::game_audio) {
          ++result.system_audio_packets;
        } else if (packet->track == TrackKind::microphone_audio) {
          ++result.microphone_packets;
        }
      }
      result.duration = snapshot.actual_duration;
      return result;
    } @catch (NSException* exception) {
      throw std::runtime_error("AVFoundation exception: " + ns_text(exception.reason));
    }
  }
}

}  // namespace native_port
