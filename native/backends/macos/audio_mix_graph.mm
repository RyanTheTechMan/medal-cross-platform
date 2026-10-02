#import <AVFoundation/AVFoundation.h>
#include "audio_mix_graph.hpp"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <mutex>
#include <stdexcept>

namespace native_port {
struct AudioMixGraph::Impl final {
  struct Source {
    AVAudioFormat* format{nil};
    AVAudioConverter* converter{nil};
    std::int64_t output_frame{-1};
    CMTime expected_input{kCMTimeInvalid};
  };
  Impl(std::vector<PcmSource> sources, bool stems, std::uint64_t gen, AacEncoder::PacketCallback callback)
      : generation(gen), mixer(sources, stems, gen, [this](const auto& source, auto first, auto pcm) {
          encode(source, first, pcm);
        }) {
    canonical = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:48000 channels:2 interleaved:YES];
    encoders["all-audio"] = std::make_shared<AacEncoder>(TrackKind::mixed_audio, 1, 192'000, 1, callback);
    encoders["all-audio"]->set_logical_source_id("all-audio");
    for (const auto& source : sources) {
      inputs.emplace(source.logical_id, Source{});
      if (stems) {
        auto encoder = std::make_shared<AacEncoder>(source.role, source.track_id, 160'000, 1, callback);
        encoder->set_logical_source_id(source.logical_id);
        encoder->set_logical_source_name(source.display_name);
        encoders[source.logical_id] = std::move(encoder);
      }
    }
  }
  void encode(const PcmSource& source, std::int64_t first, std::span<const float> pcm) {
    const auto bytes = pcm.size_bytes();
    CMBlockBufferRef block = nullptr;
    CMAudioFormatDescriptionRef description = nullptr;
    CMSampleBufferRef sample = nullptr;
    auto status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, bytes,
        kCFAllocatorDefault, nullptr, 0, bytes, 0, &block);
    if (status == noErr) status = CMBlockBufferReplaceDataBytes(pcm.data(), block, 0, bytes);
    if (status == noErr) status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, canonical.streamDescription,
        0, nullptr, 0, nullptr, nullptr, &description);
    if (status == noErr) status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault,
        block, description, pcm.size() / 2, CMTimeMake(first, 48000), nullptr, &sample);
    std::string message;
    const bool success = status == noErr && sample && encoders.at(source.logical_id)->encode(sample, generation, message);
    if (sample) CFRelease(sample);
    if (description) CFRelease(description);
    if (block) CFRelease(block);
    if (!success) throw std::runtime_error(message.empty() ? "PCM mixer CoreMedia output failed: " + std::to_string(status) : message);
  }
  bool consume(std::string_view id, CMSampleBufferRef sample, std::uint64_t gen, std::string& error) {
    std::scoped_lock lock(mutex);
    if (gen != generation || stopped) return true; // Superseded callback, no acquisition.
    if (!last_error.empty()) { error = last_error; return false; }
    CMBlockBufferRef retained = nullptr;
    try {
      const auto found = inputs.find(std::string(id));
      if (found == inputs.end()) return true; // Disabled source not in this generation.
      auto& source = found->second;
      if (!sample || !CMSampleBufferDataIsReady(sample)) throw std::runtime_error("PCM graph received invalid sample");
      const auto pts = CMSampleBufferGetPresentationTimeStamp(sample);
      const auto description = CMSampleBufferGetFormatDescription(sample);
      const auto* format = description ? CMAudioFormatDescriptionGetStreamBasicDescription(description) : nullptr;
      const auto frames = CMSampleBufferGetNumSamples(sample);
      if (!format || format->mFormatID != kAudioFormatLinearPCM || !CMTIME_IS_NUMERIC(pts) || pts.value < 0 ||
          frames < 1 || frames > 16'384 || format->mSampleRate < 8000 || format->mSampleRate > 192000 ||
          format->mChannelsPerFrame < 1 || format->mChannelsPerFrame > 2)
        throw std::runtime_error("PCM graph requires timestamped mono/stereo linear PCM with bounded frames/rate");
      AVAudioFormat* input_format = [[AVAudioFormat alloc] initWithStreamDescription:format];
      if (!input_format) throw std::runtime_error("PCM graph does not support the negotiated format");
      const bool gap = CMTIME_IS_NUMERIC(source.expected_input) &&
          std::abs(CMTimeGetSeconds(CMTimeSubtract(pts, source.expected_input))) > .002;
      if (source.converter == nil || ![source.format isEqual:input_format] || gap) {
        source.format = input_format;
        source.converter = [[AVAudioConverter alloc] initFromFormat:input_format toFormat:canonical];
        if (!source.converter) throw std::runtime_error("Apple PCM converter creation failed");
        source.converter.primeMethod = AVAudioConverterPrimeMethod_None;
        source.converter.sampleRateConverterQuality = AVAudioQualityMax;
        source.converter.channelMap = format->mChannelsPerFrame == 1 ? @[@0, @0] : @[@0, @1];
        source.output_frame = CMTimeConvertScale(pts, 48000, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
      }
      source.expected_input = CMTimeAdd(pts, CMTimeMake(frames, static_cast<int32_t>(std::llround(format->mSampleRate))));
      std::size_t list_size = 0;
      auto status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, &list_size, nullptr, 0, nullptr, nullptr, 0, nullptr);
      if (status != noErr && status != kCMSampleBufferError_ArrayTooSmall) throw std::runtime_error("PCM list sizing failed");
      if (list_size > sizeof(AudioBufferList) + sizeof(AudioBuffer)) throw std::runtime_error("PCM buffer list exceeds stereo bound");
      std::vector<std::byte> list_bytes(std::max(list_size, sizeof(AudioBufferList)));
      auto* list = reinterpret_cast<AudioBufferList*>(list_bytes.data());
      status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, &list_size, list, list_bytes.size(),
          kCFAllocatorDefault, kCFAllocatorDefault, kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &retained);
      if (status != noErr) throw std::runtime_error("PCM buffer extraction failed");
      AVAudioPCMBuffer* input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:input_format frameCapacity:static_cast<AVAudioFrameCount>(frames)];
      input.frameLength = static_cast<AVAudioFrameCount>(frames);
      auto* destination = input.mutableAudioBufferList;
      if (!input || destination->mNumberBuffers != list->mNumberBuffers) throw std::runtime_error("PCM layout mismatch");
      for (UInt32 index = 0; index < list->mNumberBuffers; ++index) {
        const auto& buffer = list->mBuffers[index];
        auto& target = destination->mBuffers[index];
        if (!buffer.mData || buffer.mDataByteSize != target.mDataByteSize || buffer.mNumberChannels != target.mNumberChannels)
          throw std::runtime_error("PCM frame count/layout mismatch");
        std::memcpy(target.mData, buffer.mData, buffer.mDataByteSize);
      }
      CFRelease(retained); retained = nullptr;
      __block bool supplied = false;
      const auto capacity = static_cast<AVAudioFrameCount>(std::ceil(frames * 48000.0 / format->mSampleRate) + 512);
      for (unsigned attempt = 0; attempt < 4; ++attempt) {
        AVAudioPCMBuffer* output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:canonical frameCapacity:capacity];
        NSError* conversion_error = nil;
        const auto result = [source.converter convertToBuffer:output error:&conversion_error withInputFromBlock:
            ^AVAudioBuffer*(AVAudioPacketCount, AVAudioConverterInputStatus* state) {
              if (supplied) { *state = AVAudioConverterInputStatus_NoDataNow; return nil; }
              supplied = true; *state = AVAudioConverterInputStatus_HaveData; return input;
            }];
        if (result == AVAudioConverterOutputStatus_Error) {
          const char* message = conversion_error.localizedDescription.UTF8String;
          throw std::runtime_error("Apple PCM resampling failed: " + std::string(message ? message : "unknown"));
        }
        if (output.frameLength) {
          const auto* data = static_cast<const float*>(output.audioBufferList->mBuffers[0].mData);
          mixer.push(id, generation, source.output_frame, std::span(data, output.frameLength * 2));
          source.output_frame += output.frameLength;
        }
        if (result == AVAudioConverterOutputStatus_InputRanDry || result == AVAudioConverterOutputStatus_EndOfStream || !output.frameLength) return true;
      }
      throw std::runtime_error("PCM converter exceeded bounded drain iterations");
    } catch (const std::exception& failure) {
      if (retained) CFRelease(retained);
      last_error = failure.what(); error = last_error; return false;
    }
  }
  mutable std::mutex mutex;
  std::uint64_t generation;
  PcmMixer mixer;
  AVAudioFormat* canonical{nil};
  std::map<std::string, Source> inputs;
  std::map<std::string, std::shared_ptr<AacEncoder>> encoders;
  bool stopped{false};
  std::string last_error;
};
AudioMixGraph::AudioMixGraph(std::vector<PcmSource> sources, bool stems, std::uint64_t generation,
                             AacEncoder::PacketCallback callback)
    : impl_(std::make_unique<Impl>(std::move(sources), stems, generation, std::move(callback))) {}
AudioMixGraph::~AudioMixGraph() = default;
bool AudioMixGraph::consume(std::string_view id, CMSampleBufferRef sample, std::uint64_t gen, std::string& error) {
  return impl_->consume(id, sample, gen, error);
}
void AudioMixGraph::set_gain(std::string_view id, double gain) {
  std::scoped_lock lock(impl_->mutex);
  if (impl_->inputs.contains(std::string(id))) impl_->mixer.set_gain(id, gain);
}
void AudioMixGraph::finish() {
  std::scoped_lock lock(impl_->mutex);
  if (impl_->stopped) return;
  impl_->stopped = true;
  try { impl_->mixer.drain(true); } catch (const std::exception& error) { impl_->last_error = error.what(); }
  for (const auto& [_, encoder] : impl_->encoders) encoder->reset();
}
std::shared_ptr<AacEncoder> AudioMixGraph::encoder(std::string_view id) const {
  const auto found = impl_->encoders.find(std::string(id));
  return found == impl_->encoders.end() ? nullptr : found->second;
}
std::string AudioMixGraph::error() const { std::scoped_lock lock(impl_->mutex); return impl_->last_error; }
nlohmann::json AudioMixGraph::status() const {
  std::scoped_lock lock(impl_->mutex);
  return {{"sampleRate", PcmMixer::rate}, {"sourceCount", impl_->inputs.size()},
    {"generation", impl_->generation}, {"reorderMilliseconds", 200},
    {"outputFrames", impl_->mixer.output_frames()}, {"lateSourceFrames", impl_->mixer.late_frames()},
    {"missingSourceFrames", impl_->mixer.gap_frames()}, {"staleBlocks", impl_->mixer.stale_blocks()},
    {"error", impl_->last_error}};
}
} // namespace native_port
