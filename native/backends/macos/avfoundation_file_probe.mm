#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <cmath>
#include <cstdint>
#include <filesystem>
#include <iostream>
#include <string>
#include <utility>

#include <nlohmann/json.hpp>

namespace {

[[nodiscard]] std::string fourcc(std::uint32_t value) {
  char text[5] = {
      static_cast<char>((value >> 24U) & 0xffU),
      static_cast<char>((value >> 16U) & 0xffU),
      static_cast<char>((value >> 8U) & 0xffU),
      static_cast<char>(value & 0xffU),
      '\0',
  };
  for (std::size_t index = 0; index < 4; ++index) {
    if (text[index] < 0x20 || text[index] > 0x7e) {
      text[index] = '?';
    }
  }
  return text;
}

[[nodiscard]] bool is_sync_sample(CMSampleBufferRef sample) {
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
  if (attachments == nullptr || CFArrayGetCount(attachments) == 0) {
    return true;
  }
  auto* values = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
  return CFDictionaryGetValue(values, kCMSampleAttachmentKey_NotSync) != kCFBooleanTrue;
}

[[nodiscard]] double seconds(CMTime value) {
  if (!CMTIME_IS_VALID(value) || !CMTIME_IS_NUMERIC(value)) {
    return 0.0;
  }
  return CMTimeGetSeconds(value);
}

[[nodiscard]] nlohmann::json compressed_track_probe(AVAsset* asset, AVAssetTrack* track,
                                                     bool is_video) {
  NSError* error = nil;
  AVAssetReader* reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
  nlohmann::json result = {
      {"readerCreated", reader != nil},
      {"readerStarted", false},
      {"readerCompleted", false},
      {"sampleBufferCount", 0},
      {"sampleCount", 0},
      {"emptySampleBufferCount", 0},
      {"nonMonotonicPtsCount", 0},
      {"ptsDtsMismatchCount", 0},
      {"firstSampleIsSync", nullptr},
      {"codec", ""},
  };
  if (reader == nil) {
    result["error"] = error == nil ? "AVAssetReader creation failed" : error.localizedDescription.UTF8String;
    return result;
  }
  AVAssetReaderTrackOutput* output =
      [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil];
  output.alwaysCopiesSampleData = NO;
  if (![reader canAddOutput:output]) {
    result["error"] = "AVAssetReader rejected compressed track output";
    return result;
  }
  [reader addOutput:output];
  if (![reader startReading]) {
    result["error"] = reader.error == nil ? "AVAssetReader failed to start" : reader.error.localizedDescription.UTF8String;
    return result;
  }
  result["readerStarted"] = true;
  CMTime previous_pts = kCMTimeInvalid;
  bool first = true;
  while (CMSampleBufferRef sample = [output copyNextSampleBuffer]) {
    result["sampleBufferCount"] = result["sampleBufferCount"].get<std::uint64_t>() + 1;
    const auto samples_in_buffer = CMSampleBufferGetNumSamples(sample);
    result["sampleCount"] = result["sampleCount"].get<std::uint64_t>() +
                            static_cast<std::uint64_t>(samples_in_buffer);
    if (samples_in_buffer == 0) {
      result["emptySampleBufferCount"] =
          result["emptySampleBufferCount"].get<std::uint64_t>() + 1;
      CFRelease(sample);
      continue;
    }
    const auto pts = CMSampleBufferGetPresentationTimeStamp(sample);
    const auto dts = CMSampleBufferGetDecodeTimeStamp(sample);
    if (CMTIME_IS_NUMERIC(previous_pts) && CMTIME_IS_NUMERIC(pts) && CMTimeCompare(pts, previous_pts) < 0) {
      result["nonMonotonicPtsCount"] = result["nonMonotonicPtsCount"].get<std::uint64_t>() + 1;
    }
    if (CMTIME_IS_NUMERIC(pts) && CMTIME_IS_NUMERIC(dts) && CMTimeCompare(pts, dts) != 0) {
      result["ptsDtsMismatchCount"] = result["ptsDtsMismatchCount"].get<std::uint64_t>() + 1;
    }
    if (result["codec"].get<std::string>().empty()) {
      if (const auto format = CMSampleBufferGetFormatDescription(sample); format != nullptr) {
        result["codec"] = fourcc(CMFormatDescriptionGetMediaSubType(format));
        if (is_video) {
          const auto dimensions = CMVideoFormatDescriptionGetDimensions(format);
          result["width"] = dimensions.width;
          result["height"] = dimensions.height;
        } else if (const auto* audio = CMAudioFormatDescriptionGetStreamBasicDescription(format);
                   audio != nullptr) {
          result["sampleRate"] = audio->mSampleRate;
          result["channelCount"] = audio->mChannelsPerFrame;
        }
      }
    }
    if (first) {
      result["firstPtsSeconds"] = seconds(pts);
      if (is_video) {
        result["firstSampleIsSync"] = is_sync_sample(sample);
      }
      first = false;
    }
    previous_pts = pts;
    CFRelease(sample);
  }
  result["readerStatus"] = static_cast<std::int64_t>(reader.status);
  result["readerCompleted"] = reader.status == AVAssetReaderStatusCompleted;
  if (reader.error != nil) {
    result["error"] = reader.error.localizedDescription.UTF8String;
  }
  return result;
}

[[nodiscard]] nlohmann::json decoded_track_probe(AVAsset* asset, AVAssetTrack* track,
                                                  bool is_video) {
  NSError* error = nil;
  AVAssetReader* reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
  nlohmann::json result = {
      {"readerCreated", reader != nil},
      {"readerStarted", false},
      {"readerCompleted", false},
      {"decodedSampleCount", 0},
      {"missingDecodedBufferCount", 0},
  };
  if (reader == nil) {
    result["error"] = error == nil ? "AVAssetReader creation failed" : error.localizedDescription.UTF8String;
    return result;
  }
  NSDictionary* settings = is_video
      ? @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)}
      : @{
          AVFormatIDKey : @(kAudioFormatLinearPCM),
          AVLinearPCMBitDepthKey : @32,
          AVLinearPCMIsFloatKey : @YES,
          AVLinearPCMIsNonInterleaved : @NO,
        };
  AVAssetReaderTrackOutput* output =
      [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
  output.alwaysCopiesSampleData = NO;
  if (![reader canAddOutput:output]) {
    result["error"] = "AVAssetReader rejected decoded track output";
    return result;
  }
  [reader addOutput:output];
  if (![reader startReading]) {
    result["error"] = reader.error == nil ? "AVAssetReader failed to start" : reader.error.localizedDescription.UTF8String;
    return result;
  }
  result["readerStarted"] = true;
  while (CMSampleBufferRef sample = [output copyNextSampleBuffer]) {
    const bool decoded_buffer_present = is_video
        ? CMSampleBufferGetImageBuffer(sample) != nullptr
        : CMSampleBufferGetDataBuffer(sample) != nullptr;
    if (!decoded_buffer_present) {
      result["missingDecodedBufferCount"] =
          result["missingDecodedBufferCount"].get<std::uint64_t>() + 1;
    }
    result["decodedSampleCount"] = result["decodedSampleCount"].get<std::uint64_t>() + 1;
    CFRelease(sample);
  }
  result["readerStatus"] = static_cast<std::int64_t>(reader.status);
  result["readerCompleted"] = reader.status == AVAssetReaderStatusCompleted;
  if (reader.error != nil) {
    result["error"] = reader.error.localizedDescription.UTF8String;
  }
  return result;
}

[[nodiscard]] bool track_passed(const nlohmann::json& compressed,
                                const nlohmann::json& decoded, bool video) {
  return compressed.value("readerCompleted", false) && decoded.value("readerCompleted", false) &&
         compressed.value("sampleCount", 0U) > 0 && decoded.value("decodedSampleCount", 0U) > 0 &&
         compressed.value("nonMonotonicPtsCount", 1U) == 0 &&
         decoded.value("missingDecodedBufferCount", 1U) == 0 &&
         (!video || compressed.value("firstSampleIsSync", false));
}

[[nodiscard]] NSArray<AVAssetTrack*>* load_tracks(AVAsset* asset, AVMediaType type,
                                                  std::string& error) {
  __block NSArray<AVAssetTrack*>* tracks = nil;
  __block std::string load_error;
  dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
  [asset loadTracksWithMediaType:type completionHandler:^(NSArray<AVAssetTrack*>* result,
                                                          NSError* result_error) {
    tracks = result;
    if (result_error != nil) {
      load_error = result_error.localizedDescription.UTF8String;
    }
    dispatch_semaphore_signal(loaded);
  }];
  if (dispatch_semaphore_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) != 0) {
    error = "AVFoundation track loading timed out";
    return nil;
  }
  if (!load_error.empty()) {
    error = std::move(load_error);
    return nil;
  }
  return tracks;
}

}  // namespace

int main(int argc, char** argv) {
  @autoreleasepool {
    nlohmann::json report = {
        {"schemaVersion", 1},
        {"status", "failed"},
        {"probe", "AVFoundation AVAssetReader compressed and decoded sample validation"},
    };
    if (argc != 2) {
      report["error"] = "usage: native_port_macos_avfoundation_file_probe /absolute/path/to/file.mp4";
      std::cout << report.dump(2) << '\n';
      return 2;
    }
    const std::filesystem::path path(argv[1]);
    report["fileName"] = path.filename().string();
    if (!path.is_absolute() || !std::filesystem::is_regular_file(path)) {
      report["error"] = "input must be an existing absolute regular file";
      std::cout << report.dump(2) << '\n';
      return 2;
    }

    NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:url options:nil];
    __block bool load_succeeded = true;
    __block std::string load_error;
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    NSArray<NSString*>* keys = @[@"duration", @"playable", @"tracks"];
    [asset loadValuesAsynchronouslyForKeys:keys completionHandler:^{
      for (NSString* key in keys) {
        NSError* error = nil;
        if ([asset statusOfValueForKey:key error:&error] != AVKeyValueStatusLoaded) {
          load_succeeded = false;
          load_error = error == nil ? "asset key failed to load" : error.localizedDescription.UTF8String;
          break;
        }
      }
      dispatch_semaphore_signal(loaded);
    }];
    if (dispatch_semaphore_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) != 0) {
      report["error"] = "AVFoundation asset loading timed out";
      std::cout << report.dump(2) << '\n';
      return 1;
    }
    if (!load_succeeded) {
      report["error"] = load_error;
      std::cout << report.dump(2) << '\n';
      return 1;
    }

    std::string track_load_error;
    NSArray<AVAssetTrack*>* video_tracks = load_tracks(asset, AVMediaTypeVideo, track_load_error);
    NSArray<AVAssetTrack*>* audio_tracks = load_tracks(asset, AVMediaTypeAudio, track_load_error);
    report["playable"] = asset.playable;
    report["durationSeconds"] = seconds(asset.duration);
    report["videoTrackCount"] = video_tracks.count;
    report["audioTrackCount"] = audio_tracks.count;
    if (!track_load_error.empty()) {
      report["error"] = track_load_error;
      std::cout << report.dump(2) << '\n';
      return 1;
    }
    if (!asset.playable || video_tracks.count != 1 || audio_tracks.count != 1 ||
        !std::isfinite(seconds(asset.duration)) || seconds(asset.duration) <= 0.0) {
      report["error"] = "asset did not expose one playable video track and one playable audio track";
      std::cout << report.dump(2) << '\n';
      return 1;
    }

    report["video"] = {
        {"compressed", compressed_track_probe(asset, video_tracks.firstObject, true)},
        {"decoded", decoded_track_probe(asset, video_tracks.firstObject, true)},
    };
    report["audio"] = {
        {"compressed", compressed_track_probe(asset, audio_tracks.firstObject, false)},
        {"decoded", decoded_track_probe(asset, audio_tracks.firstObject, false)},
    };
    const bool passed = track_passed(report["video"]["compressed"], report["video"]["decoded"], true) &&
                        track_passed(report["audio"]["compressed"], report["audio"]["decoded"], false) &&
                        report["video"]["compressed"].value("codec", "") == "avc1" &&
                        report["audio"]["compressed"].value("codec", "") == "aac ";
    report["status"] = passed ? "passed" : "failed";
    if (!passed) {
      report["error"] = "one or more AVFoundation compressed/decode validations failed";
    }
    std::cout << report.dump(2) << '\n';
    return passed ? 0 : 1;
  }
}
