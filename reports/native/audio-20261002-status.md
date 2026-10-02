# Native audio mixer — 2026-10-02 (live gates in progress)

Base: `0fd3698`, which contains the separately verified original editor repair.
Working source adds the real shared PCM master, Apple resampling, HAL clock/layout
repair and original settings reconciliation. No upload or publication.

## Implemented

- `PcmMixer`: worker-owned 48 kHz stereo host timeline, fifteen-source bound,
  two-second preallocated rings, 200 ms callback reorder window, missing samples
  retain time as silence, stale generations rejected. Independent capture gains
  apply once to each source; optional stems preserve those gained samples. Master
  limiting uses stereo-linked .97 peak ceiling, instantaneous attack and 50 ms
  release. Sources that never deliver PCM do not receive synthetic healthy stems.
- `AudioMixGraph`: Apple AVAudioConverter converts device PCM into the shared
  graph, then actual AudioToolbox AAC encoders encode master and optional stems.
  Mono/stereo, float planar/interleaved, signed int16 and 44.1/48/96 kHz tested.
- ScreenCaptureKit PC and microphone buses and selected process tap buses feed
  this graph. The aggregate selected-PID master is removed. Single-track mode
  retains one combined master. All PC Audio uses a separate display audio stream
  regardless of video filter. No live PCM/packets cross Electron IPC.
- Gain changes update native buses; topology/device changes drain/rebuild audio,
  retaining video capture. New media generation forces the next video keyframe.
  Old audio stream identities and pending enumeration callbacks are rejected.
- HAL taps preserve a valid capture-host timestamp in the same absolute clock as
  SCK video. No receipt-time fallback or independent zero origin. Planar and
  interleaved PCM copy into preallocated slots; a precreated dispatch signal wakes
  the worker. CoreMedia construction/AAC/mutex/string error work stays on worker.
- Strict microphone wire gain 0..1.5; missing default .5. App/PC percent gain
  retains fractions instead of rounding. The untraced legacy percent exception
  is removed. Selected unavailable microphone does not fall back silently.
- Native writer uses AVAssetWriterInputGroup so only the master is the default
  audio track. Independent ffprobe verifies [1,0,0], not merely manifest labels.

## Tests actually run

Environment: macOS 27.2 / 26B5091g, arm64 M5 Max; Xcode 27.1 / 27A9269, SDK 27.0;
Electron 43.2.0 / ABI 148. Stable development IDs/Apple Development identity kept.

- `cmake --build build-macos-20260925 -j 4`: exit 0; current
  `reports/native/audio-20261002-capture-mixer-build-r4.log`.
- `ctest --test-dir build-macos-20260925 --output-on-failure`: exit 0, 8/8;
  `reports/native/audio-20261002-capture-mixer-ctest-r4.log`.
- `python3 -m unittest -v tests/test_importer.py`: exit 0, 7/7;
  `reports/native/audio-20261002-importer-tests.log`.
- Native `audio_mix_graph_probe` generates real VideoToolbox H.264 + AudioToolbox
  AAC, ReplayStore and AVAssetWriter MP4 at a large common host epoch. PC tone
  440 Hz at .25 gain; delayed microphone 660 Hz at .5 gain. It changes PCM format
  mid-run without changing the output AAC format. Multiple and single variants
  are retained locally in `reports/audio-native-mixer-20261002-r2/`.
- `node tools/validate_native_audio_mix_fixture.cjs ... multiple .../multiple-validation-r2`
  and the equivalent single variant: exit 0. Actual AVFoundation decode, ffprobe,
  positive float PCM sample counts, correct two master tones/gains, no early
  microphone, isolated stems and actual default dispositions.
- Failed r1 default-track file is retained. It really had every audio track
  marked default. First AVFoundation commands used relative paths and were
  rejected; absolute-path retries passed. First spectral harness accidentally
  used FFmpeg's equal-power stereo downmix; corrected to inspect channel zero,
  with all failed reports preserved.
- Temporary pristine Electron extraction was cleaned outside this work. Build r1
  failed validation; re-extracted the cached archive into a fresh temporary
  directory after checking locked SHA-256
  `ad4a0ae3c37ee05aa06c7e2ed0627608389790f0505a2b0d20319efbe33ffe28`.

## Still open

Current native tests use synthetic PCM and hardware encode/mux, not permissioned
SCK/HAL routing. Original client capture/hotkey/contentCreate and live settings
must be exercised with the synthetic fixture apps. Explicit output-device taps,
application helper-family identity, Medal Clip Sound virtual bus, format/default
device listeners, microphone disconnect, sleep/wake, thirty-minute capture drift
and ten-minute preview sync remain open. Native replay defaults/labels must also
be checked through the imported client's actual probe/player and restart.
No new manual TCC interaction has occurred in this checkpoint so far.

Next runnable task: signed client on the isolated profile, interactive preflight,
controlled 440/660/880 Hz applications, normal recording/hotkey UI, exact persisted
media validation and original player restart; then complete missing routing cases.
