#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>

#include "audio_encoder.hpp"

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <numbers>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace {

constexpr std::int32_t kSampleRate = 48'000;
constexpr std::uint32_t kChannels = 2;
constexpr std::uint32_t kFramesPerBuffer = 480;
constexpr std::uint32_t kBufferCount = 100;

[[nodiscard]] CMSampleBufferRef make_sample(CMAudioFormatDescriptionRef format,
                                            std::int64_t first_frame) {
  std::vector<float> samples(kFramesPerBuffer * kChannels);
  for (std::uint32_t frame = 0; frame < kFramesPerBuffer; ++frame) {
    const auto phase = 2.0 * std::numbers::pi * 1'000.0 *
                       static_cast<double>(first_frame + frame) / kSampleRate;
    const auto value = static_cast<float>(std::sin(phase) * 0.25);
    samples[frame * 2] = value;
    samples[frame * 2 + 1] = value;
  }
  const auto byte_count = samples.size() * sizeof(float);
  CMBlockBufferRef block = nullptr;
  if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, byte_count, kCFAllocatorDefault,
                                         nullptr, 0, byte_count, 0, &block) != kCMBlockBufferNoErr ||
      block == nullptr) {
    return nullptr;
  }
  if (CMBlockBufferReplaceDataBytes(samples.data(), block, 0, byte_count) != kCMBlockBufferNoErr) {
    CFRelease(block);
    return nullptr;
  }
  CMSampleBufferRef sample = nullptr;
  const auto status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      kCFAllocatorDefault, block, format, kFramesPerBuffer, CMTimeMake(first_frame, kSampleRate), nullptr,
      &sample);
  CFRelease(block);
  return status == noErr ? sample : nullptr;
}

}  // namespace

int main() {
  @autoreleasepool {
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
    const auto format_status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &pcm, 0, nullptr, 0,
                                                               nullptr, nullptr, &format);
    std::vector<std::shared_ptr<const native_port::EncodedPacket>> packets;
    native_port::AacEncoder encoder(native_port::TrackKind::game_audio, 1, 160'000, 1.0,
                                    [&](std::shared_ptr<const native_port::EncodedPacket> packet) {
                                      packets.push_back(std::move(packet));
                                    });
    std::string error;
    bool encode_succeeded = format_status == noErr && format != nullptr;
    for (std::uint32_t index = 0; index < kBufferCount && encode_succeeded; ++index) {
      CMSampleBufferRef sample = make_sample(format, static_cast<std::int64_t>(index) * kFramesPerBuffer);
      if (sample == nullptr) {
        error = "synthetic PCM sample creation failed";
        encode_succeeded = false;
        break;
      }
      encode_succeeded = encoder.encode(sample, 7, error);
      CFRelease(sample);
    }
    if (format != nullptr) {
      CFRelease(format);
    }

    std::size_t payload_bytes = 0;
    bool packets_valid = !packets.empty();
    std::int64_t previous_timestamp = -1;
    for (const auto& packet : packets) {
      payload_bytes += packet->data ? packet->data->size() : 0;
      packets_valid = packets_valid && packet->codec == native_port::Codec::aac &&
                      packet->track == native_port::TrackKind::game_audio && packet->track_id == 1 &&
                      packet->configuration_generation == 7 && packet->data && !packet->data->empty() &&
                      packet->codec_configuration && packet->codec_configuration->size() == 2 &&
                      packet->monotonic_nanoseconds >= previous_timestamp;
      previous_timestamp = packet->monotonic_nanoseconds;
    }
    const bool audio_specific_config_valid = !packets.empty() &&
                                             static_cast<unsigned char>((*packets.front()->codec_configuration)[0]) ==
                                                 0x11 &&
                                             static_cast<unsigned char>((*packets.front()->codec_configuration)[1]) ==
                                                 0x90;
    const bool passed = encode_succeeded && packets_valid && audio_specific_config_valid &&
                        encoder.input_sample_count() == kFramesPerBuffer * kBufferCount &&
                        encoder.packet_count() == packets.size() && encoder.failure_count() == 0 &&
                        encoder.sample_rate() == kSampleRate && encoder.channel_count() == kChannels;
    nlohmann::json output = {
        {"schemaVersion", 1},
        {"probe", "AudioToolbox AAC-LC synthetic PCM encode"},
        {"status", passed ? "passed" : "failed"},
        {"formatCreateStatus", format_status},
        {"encodeSucceeded", encode_succeeded},
        {"error", error},
        {"sampleRate", encoder.sample_rate()},
        {"channelCount", encoder.channel_count()},
        {"inputSampleCount", encoder.input_sample_count()},
        {"packetCount", encoder.packet_count()},
        {"payloadBytes", payload_bytes},
        {"failureCount", encoder.failure_count()},
        {"discontinuityCount", encoder.discontinuity_count()},
        {"audioSpecificConfig", audio_specific_config_valid ? "1190" : "invalid"},
        {"firstPacketNanoseconds", encoder.first_packet_nanoseconds()},
        {"lastPacketEndNanoseconds", encoder.last_packet_end_nanoseconds()},
    };
    std::cout << output.dump(2) << '\n';
    return passed ? 0 : 1;
  }
}
