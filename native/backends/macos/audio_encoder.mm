#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>

#include "audio_encoder.hpp"

#include "native_port/media_time.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace native_port {
namespace {

void apply_gain(std::vector<std::byte>& bytes, const AudioStreamBasicDescription& format,
                double gain) {
  if (bytes.empty() || std::abs(gain - 1.0) < 0.0001) {
    return;
  }
  if ((format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
      format.mBitsPerChannel == 32) {
    auto* samples = reinterpret_cast<float*>(bytes.data());
    const auto count = bytes.size() / sizeof(float);
    for (std::size_t index = 0; index < count; ++index) {
      samples[index] = static_cast<float>(
          std::clamp(static_cast<double>(samples[index]) * gain, -1.0, 1.0));
    }
    return;
  }
  if ((format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 &&
      format.mBitsPerChannel == 16) {
    auto* samples = reinterpret_cast<std::int16_t*>(bytes.data());
    const auto count = bytes.size() / sizeof(std::int16_t);
    for (std::size_t index = 0; index < count; ++index) {
      samples[index] = static_cast<std::int16_t>(std::clamp(
          static_cast<double>(samples[index]) * gain,
          static_cast<double>(std::numeric_limits<std::int16_t>::min()),
          static_cast<double>(std::numeric_limits<std::int16_t>::max())));
    }
  }
}

[[nodiscard]] bool same_audio_format(const AudioStreamBasicDescription& left,
                                     const AudioStreamBasicDescription& right) noexcept {
  return left.mSampleRate == right.mSampleRate && left.mFormatID == right.mFormatID &&
         left.mFormatFlags == right.mFormatFlags && left.mBytesPerPacket == right.mBytesPerPacket &&
         left.mFramesPerPacket == right.mFramesPerPacket && left.mBytesPerFrame == right.mBytesPerFrame &&
         left.mChannelsPerFrame == right.mChannelsPerFrame && left.mBitsPerChannel == right.mBitsPerChannel;
}

[[nodiscard]] std::optional<std::uint8_t> aac_sample_rate_index(double sample_rate) noexcept {
  constexpr double rates[] = {96'000, 88'200, 64'000, 48'000, 44'100, 32'000, 24'000,
                              22'050, 16'000, 12'000, 11'025, 8'000, 7'350};
  for (std::uint8_t index = 0; index < std::size(rates); ++index) {
    if (std::abs(sample_rate - rates[index]) < 0.5) {
      return index;
    }
  }
  return std::nullopt;
}

[[nodiscard]] std::shared_ptr<const std::vector<std::byte>> aac_audio_specific_config(
    const AudioStreamBasicDescription& output) {
  const auto frequency_index = aac_sample_rate_index(output.mSampleRate);
  if (!frequency_index || output.mChannelsPerFrame == 0 || output.mChannelsPerFrame > 7) {
    return nullptr;
  }
  constexpr std::uint16_t audio_object_type = 2;  // MPEG-4 AAC Low Complexity.
  const std::uint16_t bits = static_cast<std::uint16_t>((audio_object_type << 11U) |
                                                        (*frequency_index << 7U) |
                                                        (output.mChannelsPerFrame << 3U));
  auto result = std::make_shared<std::vector<std::byte>>(2);
  (*result)[0] = static_cast<std::byte>((bits >> 8U) & 0xffU);
  (*result)[1] = static_cast<std::byte>(bits & 0xffU);
  return result;
}

[[nodiscard]] MediaTime media_time(CMTime time, std::int32_t fallback_timescale,
                                   std::int64_t fallback_value) {
  if (!CMTIME_IS_NUMERIC(time) || time.timescale <= 0) {
    return MediaTime{fallback_value, Rational{1, fallback_timescale}};
  }
  return MediaTime{time.value, Rational{1, time.timescale}};
}

struct ConverterInput final {
  const std::vector<std::vector<std::byte>>* buffers{nullptr};
  const std::vector<std::uint32_t>* channel_counts{nullptr};
  std::uint32_t bytes_per_frame{0};
  std::uint32_t available_frames{0};
  std::uint32_t consumed_frames{0};
};

OSStatus provide_pcm(AudioConverterRef, UInt32* io_number_data_packets, AudioBufferList* io_data,
                     AudioStreamPacketDescription**, void* user_data) {
  auto* input = static_cast<ConverterInput*>(user_data);
  if (input == nullptr || input->buffers == nullptr || input->channel_counts == nullptr ||
      io_number_data_packets == nullptr || io_data == nullptr) {
    return paramErr;
  }
  const auto remaining = input->available_frames - input->consumed_frames;
  const auto frames = std::min<std::uint32_t>(*io_number_data_packets, remaining);
  *io_number_data_packets = frames;
  io_data->mNumberBuffers = static_cast<UInt32>(input->buffers->size());
  for (std::size_t index = 0; index < input->buffers->size(); ++index) {
    const auto byte_offset = static_cast<std::size_t>(input->consumed_frames) * input->bytes_per_frame;
    io_data->mBuffers[index].mNumberChannels = (*input->channel_counts)[index];
    io_data->mBuffers[index].mDataByteSize = frames * input->bytes_per_frame;
    io_data->mBuffers[index].mData = frames == 0
                                         ? nullptr
                                         : const_cast<std::byte*>((*input->buffers)[index].data() + byte_offset);
  }
  input->consumed_frames += frames;
  return noErr;
}

}  // namespace

struct AacEncoder::Impl final {
  Impl(TrackKind selected_track, std::uint32_t selected_track_id, std::uint32_t selected_bitrate,
       double selected_gain, PacketCallback callback)
      : track(selected_track),
        track_id(selected_track_id),
        target_bitrate(selected_bitrate),
        gain(std::clamp(selected_gain, 0.0, 1.5)),
        packet_callback(std::move(callback)) {}

  ~Impl() { dispose_converter(); }

  void dispose_converter() {
    if (converter != nullptr) {
      AudioConverterDispose(converter);
      converter = nullptr;
    }
    source = {};
    output = {};
    maximum_output_packet_bytes = 0;
    queued_frames = 0;
    fifo.clear();
    buffer_channel_counts.clear();
    queued_start_pts = kCMTimeInvalid;
    next_output_pts = kCMTimeInvalid;
    codec_configuration.reset();
    platform_codec_cookie.reset();
    first_output_packet = true;
  }

  [[nodiscard]] bool configure(const AudioStreamBasicDescription& new_source, std::string& error) {
    if (new_source.mFormatID != kAudioFormatLinearPCM || new_source.mSampleRate <= 0 ||
        new_source.mChannelsPerFrame == 0 || new_source.mBytesPerFrame == 0) {
      error = "ScreenCaptureKit audio must be linear PCM with a concrete sample rate/channel layout";
      return false;
    }
    dispose_converter();
    source = new_source;
    // ScreenCaptureKit can expose USB microphones at a device-native rate
    // such as 96 kHz even when the stream requests 48 kHz. Keep Medal's AAC
    // track at the compatibility rate and let AudioConverter resample input;
    // constructing AAC directly at some device-native rates fails with
    // kAudio_ParamError.
    output.mSampleRate = 48'000;
    output.mFormatID = kAudioFormatMPEG4AAC;
    output.mFormatFlags = kMPEG4Object_AAC_LC;
    output.mChannelsPerFrame = source.mChannelsPerFrame;
    UInt32 output_size = sizeof(output);
    auto status = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nullptr, &output_size, &output);
    if (status != noErr) {
      error = "AudioToolbox AAC output format failed with OSStatus " + std::to_string(status);
      return false;
    }
    codec_configuration = aac_audio_specific_config(output);
    if (!codec_configuration) {
      error = "AAC-LC AudioSpecificConfig does not support the captured rate/channel layout";
      return false;
    }
    status = AudioConverterNew(&source, &output, &converter);
    if (status != noErr || converter == nullptr) {
      error = "AudioToolbox AAC converter creation failed with OSStatus " + std::to_string(status);
      dispose_converter();
      return false;
    }
    UInt32 bitrate = target_bitrate;
    status = AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, sizeof(bitrate), &bitrate);
    if (status != noErr) {
      error = "AudioToolbox AAC bitrate property failed with OSStatus " + std::to_string(status);
      dispose_converter();
      return false;
    }
    UInt32 property_size = sizeof(maximum_output_packet_bytes);
    status = AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize,
                                       &property_size, &maximum_output_packet_bytes);
    if (status != noErr || maximum_output_packet_bytes == 0) {
      error = "AudioToolbox AAC maximum packet query failed with OSStatus " + std::to_string(status);
      dispose_converter();
      return false;
    }
    UInt32 cookie_size = 0;
    Boolean cookie_writable = false;
    status = AudioConverterGetPropertyInfo(converter, kAudioConverterCompressionMagicCookie,
                                           &cookie_size, &cookie_writable);
    if (status == noErr && cookie_size > 0) {
      auto cookie = std::make_shared<std::vector<std::byte>>(cookie_size);
      status = AudioConverterGetProperty(converter, kAudioConverterCompressionMagicCookie,
                                         &cookie_size, cookie->data());
      if (status != noErr) {
        error = "AudioToolbox AAC magic cookie query failed with OSStatus " + std::to_string(status);
        dispose_converter();
        return false;
      }
      cookie->resize(cookie_size);
      platform_codec_cookie = std::move(cookie);
    }
    AudioConverterPrimeInfo prime_info{};
    property_size = sizeof(prime_info);
    if (AudioConverterGetProperty(converter, kAudioConverterPrimeInfo, &property_size, &prime_info) == noErr) {
      leading_frames = prime_info.leadingFrames;
      trailing_frames = prime_info.trailingFrames;
    }
    sample_rate_value.store(static_cast<std::uint32_t>(std::llround(source.mSampleRate)),
                            std::memory_order_relaxed);
    channel_count_value.store(source.mChannelsPerFrame, std::memory_order_relaxed);
    return true;
  }

  [[nodiscard]] bool append(CMSampleBufferRef sample, std::uint64_t generation, std::string& error) {
    if (sample == nullptr || !CMSampleBufferIsValid(sample) || !CMSampleBufferDataIsReady(sample)) {
      error = "ScreenCaptureKit produced an invalid audio sample";
      return false;
    }
    auto* description = CMSampleBufferGetFormatDescription(sample);
    const auto* sample_format = description == nullptr
                                    ? nullptr
                                    : CMAudioFormatDescriptionGetStreamBasicDescription(description);
    if (sample_format == nullptr) {
      error = "ScreenCaptureKit audio sample has no AudioStreamBasicDescription";
      return false;
    }
    if (converter == nullptr || !same_audio_format(source, *sample_format)) {
      if (converter != nullptr) {
        discontinuities.fetch_add(1, std::memory_order_relaxed);
      }
      if (!configure(*sample_format, error)) {
        return false;
      }
    }

    std::size_t list_size = 0;
    auto status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sample, &list_size, nullptr, 0, nullptr, nullptr, 0, nullptr);
    if (status != noErr && status != kCMSampleBufferError_ArrayTooSmall) {
      error = "CoreMedia audio buffer sizing failed with OSStatus " + std::to_string(status);
      return false;
    }
    std::vector<std::byte> list_storage(std::max(list_size, sizeof(AudioBufferList)));
    auto* list = reinterpret_cast<AudioBufferList*>(list_storage.data());
    CMBlockBufferRef retained_block = nullptr;
    status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sample, &list_size, list, list_storage.size(), kCFAllocatorDefault, kCFAllocatorDefault,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &retained_block);
    if (status != noErr) {
      error = "CoreMedia audio buffer extraction failed with OSStatus " + std::to_string(status);
      return false;
    }

    const auto frames = static_cast<std::uint32_t>(CMSampleBufferGetNumSamples(sample));
    if (frames == 0 || list->mNumberBuffers == 0) {
      if (retained_block != nullptr) {
        CFRelease(retained_block);
      }
      return true;
    }
    if (fifo.empty()) {
      fifo.resize(list->mNumberBuffers);
      buffer_channel_counts.resize(list->mNumberBuffers);
      for (std::size_t index = 0; index < list->mNumberBuffers; ++index) {
        buffer_channel_counts[index] = list->mBuffers[index].mNumberChannels;
      }
    } else if (fifo.size() != list->mNumberBuffers) {
      if (retained_block != nullptr) {
        CFRelease(retained_block);
      }
      error = "ScreenCaptureKit audio buffer layout changed without a format change";
      return false;
    }

    const CMTime sample_pts = CMSampleBufferGetPresentationTimeStamp(sample);
    if (queued_frames > 0 && CMTIME_IS_NUMERIC(sample_pts) && CMTIME_IS_NUMERIC(queued_start_pts)) {
      const auto expected = CMTimeAdd(queued_start_pts,
                                      CMTimeMake(static_cast<std::int64_t>(queued_frames),
                                                 static_cast<std::int32_t>(std::llround(source.mSampleRate))));
      const auto difference = std::abs(CMTimeGetSeconds(CMTimeSubtract(sample_pts, expected)));
      if (std::isfinite(difference) && difference > 0.050) {
        discontinuities.fetch_add(1, std::memory_order_relaxed);
        queued_frames = 0;
        for (auto& buffer : fifo) {
          buffer.clear();
        }
        queued_start_pts = sample_pts;
        next_output_pts = sample_pts;
        AudioConverterReset(converter);
        first_output_packet = true;
      }
    }
    if (queued_frames == 0) {
      queued_start_pts = sample_pts;
      if (!CMTIME_IS_NUMERIC(next_output_pts)) {
        next_output_pts = sample_pts;
      }
    }

    const auto bytes_per_buffer_frame = source.mBytesPerFrame;
    for (std::size_t index = 0; index < fifo.size(); ++index) {
      const auto byte_count = static_cast<std::size_t>(frames) * bytes_per_buffer_frame;
      if (list->mBuffers[index].mData == nullptr || list->mBuffers[index].mDataByteSize < byte_count) {
        if (retained_block != nullptr) {
          CFRelease(retained_block);
        }
        error = "ScreenCaptureKit audio buffer is shorter than its declared frame count";
        return false;
      }
      const auto* begin = static_cast<const std::byte*>(list->mBuffers[index].mData);
      std::vector<std::byte> chunk(begin, begin + byte_count);
      apply_gain(chunk, source, gain);
      fifo[index].insert(fifo[index].end(), chunk.begin(), chunk.end());
    }
    if (retained_block != nullptr) {
      CFRelease(retained_block);
    }
    queued_frames += frames;
    input_samples.fetch_add(frames, std::memory_order_relaxed);

    const auto output_frames_per_packet = std::max<std::uint32_t>(1, output.mFramesPerPacket);
    // AudioConverterFillComplexBuffer asks the input callback for input PCM
    // packets, not output AAC packets.  When ScreenCaptureKit delivers a
    // microphone at 96 kHz and Medal's AAC track is fixed at 48 kHz, one AAC
    // packet needs roughly two source packets.  Feeding only 1024 source
    // frames (the output packet size) makes AudioToolbox consume the input
    // without producing an output packet, which used to leave the microphone
    // track empty and eventually reported “made no progress”.  Keep enough
    // source frames queued for one complete resampled output packet; the
    // exact ratio is rounded up so fractional-rate devices (44.1/48 kHz)
    // cannot starve the converter either.
    const auto source_rate = std::max(1.0, source.mSampleRate);
    const auto output_rate = std::max(1.0, output.mSampleRate);
    const auto input_frames_per_packet = std::max<std::uint32_t>(
        1, static_cast<std::uint32_t>(std::ceil(
            static_cast<double>(output_frames_per_packet) * source_rate / output_rate)));
    while (queued_frames >= input_frames_per_packet) {
      if (!encode_one(generation, 0, error)) {
        return false;
      }
    }
    return true;
  }

  [[nodiscard]] bool encode_one(std::uint64_t generation, std::uint32_t discard_padding,
                                std::string& error) {
    ConverterInput input{.buffers = &fifo,
                         .channel_counts = &buffer_channel_counts,
                         .bytes_per_frame = source.mBytesPerFrame,
                         .available_frames = static_cast<std::uint32_t>(queued_frames),
                         .consumed_frames = 0};
    auto output_bytes = std::make_shared<std::vector<std::byte>>(maximum_output_packet_bytes);
    AudioBufferList output_list{};
    output_list.mNumberBuffers = 1;
    output_list.mBuffers[0].mNumberChannels = output.mChannelsPerFrame;
    output_list.mBuffers[0].mDataByteSize = maximum_output_packet_bytes;
    output_list.mBuffers[0].mData = output_bytes->data();
    UInt32 output_packets = 1;
    AudioStreamPacketDescription packet_description{};
    const auto status = AudioConverterFillComplexBuffer(converter, &provide_pcm, &input, &output_packets,
                                                        &output_list, &packet_description);
    if (status != noErr) {
      error = "AudioToolbox AAC encode failed with OSStatus " + std::to_string(status);
      return false;
    }
    if (input.consumed_frames > queued_frames) {
      error = "AudioToolbox consumed more PCM frames than supplied";
      return false;
    }
    for (auto& buffer : fifo) {
      const auto consumed_bytes = static_cast<std::size_t>(input.consumed_frames) * source.mBytesPerFrame;
      buffer.erase(buffer.begin(), buffer.begin() + static_cast<std::ptrdiff_t>(consumed_bytes));
    }
    queued_frames -= input.consumed_frames;
    if (CMTIME_IS_NUMERIC(queued_start_pts)) {
      queued_start_pts = CMTimeAdd(queued_start_pts,
                                   CMTimeMake(input.consumed_frames,
                                              static_cast<std::int32_t>(std::llround(source.mSampleRate))));
    }
    if (output_packets == 0 || output_list.mBuffers[0].mDataByteSize == 0) {
      if (input.consumed_frames == 0) {
        error = "AudioToolbox made no progress while AAC input was available";
        return false;
      }
      return true;
    }

    output_bytes->resize(output_list.mBuffers[0].mDataByteSize);
    auto packet = std::make_shared<EncodedPacket>();
    packet->codec = Codec::aac;
    packet->track = track;
    packet->track_id = track_id;
    packet->logical_source_id = logical_source_id;
    packet->logical_source_name = logical_source_name;
    packet->configuration_generation = generation;
    packet->pts = media_time(next_output_pts, static_cast<std::int32_t>(std::llround(output.mSampleRate)), 0);
    packet->dts = packet->pts;
    packet->duration = MediaTime{static_cast<std::int64_t>(output.mFramesPerPacket),
                                 Rational{1, static_cast<std::int32_t>(std::llround(output.mSampleRate))}};
    packet->monotonic_nanoseconds =
        std::max<std::int64_t>(0, rescale(packet->pts, Rational{1, 1'000'000'000}));
    packet->keyframe = true;
    packet->depends_on_others = false;
    packet->sample_rate = static_cast<std::uint32_t>(std::llround(output.mSampleRate));
    packet->channel_count = output.mChannelsPerFrame;
    packet->bitrate_bits_per_second = target_bitrate;
    packet->data = std::move(output_bytes);
    packet->codec_configuration = codec_configuration;
    packet->platform_codec_cookie = platform_codec_cookie;
    packet->encoder_delay_frames = first_output_packet ? leading_frames : 0;
    packet->discard_padding_frames = discard_padding;
    const auto end_nanoseconds = packet->monotonic_nanoseconds +
                                 rescale(packet->duration, Rational{1, 1'000'000'000});
    if (first_output_packet) {
      first_packet_ns.store(packet->monotonic_nanoseconds, std::memory_order_relaxed);
      first_output_packet = false;
    }
    last_packet_end_ns.store(end_nanoseconds, std::memory_order_relaxed);
    packets.fetch_add(1, std::memory_order_relaxed);
    next_output_pts = CMTimeAdd(next_output_pts,
                                CMTimeMake(output.mFramesPerPacket,
                                           static_cast<std::int32_t>(std::llround(output.mSampleRate))));
    packet_callback(std::move(packet));
    return true;
  }

  TrackKind track;
  std::uint32_t track_id;
  std::uint32_t target_bitrate;
  double gain;
  std::string logical_source_id;
  std::string logical_source_name;
  PacketCallback packet_callback;
  std::mutex mutex;
  AudioConverterRef converter{nullptr};
  AudioStreamBasicDescription source{};
  AudioStreamBasicDescription output{};
  std::uint32_t maximum_output_packet_bytes{0};
  std::uint32_t leading_frames{0};
  std::uint32_t trailing_frames{0};
  std::vector<std::vector<std::byte>> fifo;
  std::vector<std::uint32_t> buffer_channel_counts;
  std::size_t queued_frames{0};
  CMTime queued_start_pts{kCMTimeInvalid};
  CMTime next_output_pts{kCMTimeInvalid};
  std::shared_ptr<const std::vector<std::byte>> codec_configuration;
  std::shared_ptr<const std::vector<std::byte>> platform_codec_cookie;
  bool first_output_packet{true};
  std::atomic<std::uint64_t> input_samples{0};
  std::atomic<std::uint64_t> packets{0};
  std::atomic<std::uint64_t> failures{0};
  std::atomic<std::uint64_t> discontinuities{0};
  std::atomic<std::uint32_t> sample_rate_value{0};
  std::atomic<std::uint32_t> channel_count_value{0};
  std::atomic<std::int64_t> first_packet_ns{-1};
  std::atomic<std::int64_t> last_packet_end_ns{-1};
};

AacEncoder::AacEncoder(TrackKind track, std::uint32_t track_id, std::uint32_t target_bitrate,
                       double gain, PacketCallback packet_callback)
    : impl_(std::make_unique<Impl>(track, track_id, target_bitrate, gain,
                                   std::move(packet_callback))) {}

AacEncoder::~AacEncoder() = default;

bool AacEncoder::encode(CMSampleBufferRef sample, std::uint64_t configuration_generation,
                        std::string& error) {
  std::scoped_lock lock(impl_->mutex);
  const bool succeeded = impl_->append(sample, configuration_generation, error);
  if (!succeeded) {
    impl_->failures.fetch_add(1, std::memory_order_relaxed);
  }
  return succeeded;
}

void AacEncoder::set_gain(double gain) {
  std::scoped_lock lock(impl_->mutex);
  impl_->gain = std::clamp(gain, 0.0, 1.5);
}

void AacEncoder::set_logical_source_id(std::string logical_source_id) {
  std::scoped_lock lock(impl_->mutex);
  impl_->logical_source_id = std::move(logical_source_id);
}

void AacEncoder::set_logical_source_name(std::string name) {
  std::scoped_lock lock(impl_->mutex);
  impl_->logical_source_name = std::move(name);
}

void AacEncoder::reset() {
  std::scoped_lock lock(impl_->mutex);
  impl_->dispose_converter();
}

std::uint64_t AacEncoder::input_sample_count() const noexcept {
  return impl_->input_samples.load(std::memory_order_relaxed);
}

std::uint64_t AacEncoder::packet_count() const noexcept {
  return impl_->packets.load(std::memory_order_relaxed);
}

std::uint64_t AacEncoder::failure_count() const noexcept {
  return impl_->failures.load(std::memory_order_relaxed);
}

std::uint64_t AacEncoder::discontinuity_count() const noexcept {
  return impl_->discontinuities.load(std::memory_order_relaxed);
}

std::uint32_t AacEncoder::sample_rate() const noexcept {
  return impl_->sample_rate_value.load(std::memory_order_relaxed);
}

std::uint32_t AacEncoder::channel_count() const noexcept {
  return impl_->channel_count_value.load(std::memory_order_relaxed);
}

std::int64_t AacEncoder::first_packet_nanoseconds() const noexcept {
  return impl_->first_packet_ns.load(std::memory_order_relaxed);
}

std::int64_t AacEncoder::last_packet_end_nanoseconds() const noexcept {
  return impl_->last_packet_end_ns.load(std::memory_order_relaxed);
}

}  // namespace native_port
