# Audio editor repair checkpoint — 2026-09-25

## Evidence correction

The `b1fa75a` progress/ledger claim that the September 20 Balatro audio edit
played after restart is withdrawn. The retained
`m3.9-audio-trim-manifest-fix-restart-final-launch.log` contains ENOENT and
DEMUXER_ERROR_COULD_NOT_OPEN; a visible thumbnail/Audio menu is not decoded
playback. The original selected row could still reference a deleted original.
All old logs and recordings are retained. Offline decode of a different edited
file does not prove that the original UI loaded that file.

## Implemented in this working checkpoint

- Native Darwin/Linux finalized-media service: authoritative library UUID and
  fresh absolute stream validation, master migration, copied AAC source stems,
  copied video, fresh output probe/manifest, unique same-volume publish.
- Original overwrite and Save Copy call a project-owned transaction through
  Medal's existing persistence IPC, verify readback, propagate failure, retain
  original files, and only then update imported caches. No automatic upload.
- Preview sidecar URLs now resolve opaque leased assets correctly. Exact main
  window/frame checks, bounded owner-private cache, range handling, no generic
  arbitrary-file/FFmpeg IPC.
- Both original popovers observe React state without rebuilding on every toggle.
  The original audio is gated independently of user mute/volume. Sidecar errors
  pause playback and stay silent with an explicit error. Source gains update in
  place; cancel uses the original state restoration.
- AVFoundation probe has an explicit audio-only mode and counts/measures decoded
  float PCM instead of confusing a successful zero-sample decode with silence.

## Actual tests so far

- `python3 research/audio-review-20260920/tests/run_reproductions.py research/extracted-macos-m0/app reports/audio-review-baseline-20260925-resume`: exit 0, 23 historical assertions (some intentionally prove bugs).
- `node client_patch/native-audio-media.test.cjs reports/audio-fixed-20260925-r5`: exit 0, 40 fixed-behavior checks. Actual FFmpeg/ffprobe, 440/660 Hz PCM measurements, positive sample counts, unchanged video and isolated AAC packet hashes, mute-both zero peak, restored unmute, export/probe/persistence failure injection, delayed sidecar offsets and Save Copy zero/full-range AAC priming. Client persistence mocked: not GUI evidence.
- `node client_patch/native-audio-preview-controller.test.cjs`: exit 0; lifecycle/gain/error/generation tests with mocked media. No audible latency claim.
- `node client_patch/native-audio-edit-manifest.test.cjs artifacts/native-client-audio-20260925/current/main.min.js`: exit 0. Actual validator plus original Windows trim-body preservation.
- Imported main/bookmarks/renderer JavaScript syntax checks: exit 0.
- Fresh Xcode 27.1 (27A9269), macOS 27.2 (26B5091g) build in `build-macos-20260925`: exit 0. `ctest --test-dir build-macos-20260925 --output-on-failure`: 6/6. Importer/security: 7/7.
- AVFoundation probe decoded input + 8 edited synthetic MP4s + 2 M4A sidecars: 11/11; actual reports in `reports/audio-fixed-20260925-r2/avfoundation.json`.
- Failed earlier commands retained: old beta compiler path and deleted managed-artifact symlink targets. New roots used; no reset or deletion of previous evidence.

## Original imported UI — actual observations, not fixture inference

Installed signed build: `2637.461.1-development-m3.5-404b6fa35c7f97e3`,
`/Applications/Medal.app`, Electron 43.2.0 / ABI 148, unchanged Apple Development
identity and bundle IDs. No new TCC interaction. One host instance only.
Authenticated isolated profile, automatic uploads disabled. Tests use only the
synthetic 3-second `reports/audio-fixed-20260925-r2/stems.mp4`; existing user
recordings were not edited. UI actions used original Import, Audio, Save Edits,
Save, Save as Copy, library and player controls.

1. Original Import created UUID `25597d46-c48d-4d9e-95d3-55b971623ddd`.
   Muted both original Audio rows; Save Edits → Save committed a new master plus
   two unchanged stems and regenerated the thumbnail. Actual library-row path
   verified by `tools/validate_audio_library_fixture.cjs`, report
   `reports/audio-ui-20260925-muted/results.json`: PASS. Positive decoded sample
   count, master peak exactly zero; stems and video retain original packet hashes.
2. Quit via Medal menu; `pgrep -fl '/Applications/Medal.app/Contents/MacOS|native_medal_recorder'`
   returned exit 1/no processes. Reopened installed app; selected the original
   synthetic clip. Actual HTML video `readyState=4`, no error, time 1.817753,
   346 decoded frames, new `-audio-4c274b58-...mp4` URL, persisted both-muted state.
3. Latest controller on that persisted muted clip measured `baselineGain=0`,
   `outputPeak=0`, both sidecars ready/playing with gains zero. Unmuted both via
   original Audio popover WITHOUT Save. A read-only 50-ms renderer meter sampled
   300 times; 144 samples had nonzero output, maximum peak 0.2929748893,
   baseline remained zero. This verifies the actual browser audio graph, not
   a physical speaker-loopback measurement or the proposed 100-ms action latency.
4. First Save as Copy exposed a real regression: passing the original UI's
   start=0/full-duration options discarded a negative AAC priming packet.
   `reports/audio-ui-20260925-copy/results.json` FAILED; failed file and UUID
   `f975a119-b306-440f-ac2f-52392e7a8c0d` retained. Fix omits redundant zero/full
   trimming; new regression exercises the exact options.
5. Retried original Save Edits → Save as Copy after installing the fixed build.
   Original UI selected new UUID `2cbef9df-63da-4764-ad22-a9e992103362`, title
   `Imported Trimmed Clip 2`, file `-audio-848a1f2b-...mp4`, original row unchanged.
   `reports/audio-ui-20260925-copy-r2/results.json`: PASS for actual persisted
   path, thumbnail, AVFoundation, ffprobe, both master tones, default dispositions
   and unchanged video/stem packet hashes.
6. Fully quit again (no host/helper processes), reopened original Clips library,
   explicitly opened the new copy. Read-only actual renderer diagnostics:
   `readyState=4`, playing at 1.909333 s, 213 decoded frames, correct
   `-audio-848a1f2b-...mp4` URL; source mute flags `[false,false]`, gains `[1,1]`,
   source times `[1.904,1.9086]`, baseline gain 0, output peak 0.2445083857.
   Closed the synthetic preview after the test. No Post/backup/upload action.

These are narrow short-fixture overwrite, unmute, Save Copy and restart results.
The reported `maximumObservedDrift=3` includes full three-second loop/seek jumps;
it is NOT evidence of the required steady-state timing bound.

## Not complete

Individual-source mute/save/restart matrix, original cancel/seek/rate/lifecycle
matrix, long-preview drift/latency and native routing tone gates remain pending.
The native All Audio path still needs a real clock-aligned PCM mixer including
microphone and independent app gains; the aggregate tap is not an acceptable
substitute. Explicit output-device routing, Medal feedback bus and sustained
capture gates remain open. No cloud milestone, upload or publication is authorized.
