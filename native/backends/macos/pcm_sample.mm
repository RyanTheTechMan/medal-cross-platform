#include "pcm_sample.hpp"
#include <cmath>
#include <limits>

namespace native_port {
bool audio_capture_host_nanoseconds(const AudioTimeStamp* input, std::int64_t& output) noexcept {
  if (!input || !(input->mFlags & kAudioTimeStampHostTimeValid) || input->mHostTime == 0) return false;
  const auto converted = AudioConvertHostTimeToNanos(input->mHostTime);
  if (converted > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) return false;
  output = static_cast<std::int64_t>(converted);
  return true;
}
CMSampleBufferRef make_pcm_sample(const AudioStreamBasicDescription& format, const AudioBufferList* buffers,
                                  std::size_t frames, CMTime pts, std::string& error) {
  const bool planar = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
  const bool floating = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
  const bool integer = (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
  const auto expected_buffers = planar ? format.mChannelsPerFrame : 1;
  const auto channels_per_buffer = planar ? 1 : format.mChannelsPerFrame;
  if (!buffers || format.mFormatID != kAudioFormatLinearPCM ||
      !std::isfinite(format.mSampleRate) || format.mSampleRate < 8000 || format.mSampleRate > 192000 ||
      format.mChannelsPerFrame < 1 || format.mChannelsPerFrame > 2 ||
      !((floating && format.mBitsPerChannel == 32) || (integer && format.mBitsPerChannel == 16)) ||
      (format.mFormatFlags & kAudioFormatFlagIsBigEndian) ||
      format.mBytesPerFrame != channels_per_buffer * format.mBitsPerChannel / 8 ||
      format.mFramesPerPacket != 1 || buffers->mNumberBuffers != expected_buffers ||
      frames == 0 || frames > 16'384 || !CMTIME_IS_NUMERIC(pts) || pts.value < 0) {
    error = "Unsupported or malformed timestamped PCM format/layout"; return nullptr;
  }
  for (UInt32 index = 0; index < expected_buffers; ++index) {
    const auto& buffer = buffers->mBuffers[index];
    if (!buffer.mData || buffer.mNumberChannels != channels_per_buffer || buffer.mDataByteSize != frames * format.mBytesPerFrame) {
      error = "PCM buffer size/channels do not match declared frame count"; return nullptr;
    }
  }
  CMAudioFormatDescriptionRef description = nullptr;
  CMSampleBufferRef sample = nullptr;
  auto status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &format, 0, nullptr, 0, nullptr, nullptr, &description);
  const CMSampleTimingInfo timing{CMTimeMake(1, static_cast<int32_t>(std::llround(format.mSampleRate))), pts, kCMTimeInvalid};
  const size_t size = format.mBytesPerFrame;
  if (status == noErr) status = CMSampleBufferCreate(kCFAllocatorDefault, nullptr, false, nullptr, nullptr,
      description, static_cast<CMItemCount>(frames), 1, &timing, planar ? 0 : 1, planar ? nullptr : &size, &sample);
  if (status == noErr) status = CMSampleBufferSetDataBufferFromAudioBufferList(sample, kCFAllocatorDefault,
      kCFAllocatorDefault, kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, buffers);
  if (status == noErr) status = CMSampleBufferSetDataReady(sample);
  if (description) CFRelease(description);
  if (status != noErr) { if (sample) CFRelease(sample); error = "CoreMedia PCM construction failed: " + std::to_string(status); return nullptr; }
  return sample;
}
}
