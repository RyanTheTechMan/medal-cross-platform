#pragma once
#import <CoreAudio/CoreAudio.h>
#import <CoreMedia/CoreMedia.h>
#include <string>

namespace native_port {
// Copies worker-owned PCM into a validated CoreMedia sample. Caller owns result.
CMSampleBufferRef make_pcm_sample(const AudioStreamBasicDescription& format, const AudioBufferList* buffers,
                                 std::size_t frames, CMTime host_pts, std::string& error);
// Input capture timestamp only. Receipt/now is not an alternative clock.
bool audio_capture_host_nanoseconds(const AudioTimeStamp* input, std::int64_t& output) noexcept;
}
