# Press-anchored native replay endpoint — 2026-10-02

Base `7e319cd` is the known-good original native All PC/Specific Apps isolation,
mute/Save/restart checkpoint. No reset, uploads, private capture or library writes.

## Corrected measurement and retained failures

Earlier live reports calculated audio endpoints as ffprobe stream start_time +
duration. MP4 edit-list stream durations are not always relative to start_time.
Independent packet PTS + duration on the retained original recordings gives
All PC delta **-243.667 ms**, Specific Apps **-221.001 ms**, not the previous
container-derived -228.333/-211.666 ms. The actual tail defect is still real.
Both old reports/files remain intact; do not treat those numbers as exact packet
or audible drift evidence.

`reports/audio-native-endpoint-20261002-r1/results.json` failed the one-AAC-packet
tail condition using the wrong container expression. Correct packet-based r2
passes the same bound (not a relaxed tolerance). Manual first AVFoundation CLI
invocation supplied a relative path and was rejected; the validator's absolute
path probe passes. A second CTest attempt failed AVAssetWriter Cannot Save when
the constant fixture filename already existed. Retained it; changed CTest to a
unique PID-named temporary output, preserving failed artifacts instead of
overwriting/deleting them. No failed evidence was relabeled.

## Implementation

- Platform shortcut callback now carries the OS event timestamp in capture
  nanoseconds, not dispatch or export time. Installed Carbon SDK explicitly
  defines EventTime in startup-relative seconds. Native API probe brackets both
  Carbon/CoreMedia clocks against Core Audio host nanoseconds on this Mac.
  Platform media-clock accessor is an explicit contract, not std::steady_clock.
- Shared ReplayEndpoint pins the generation and acquired audio track identities
  at the event. snapshot_at waits for every required AAC track to cover it,
  preserves decoder configuration/keyframe boundaries and shares packet bytes.
  Export excludes PTS >= endpoint and all other generations. It never substitutes
  the newest snapshot. Idle clock still controls duration; idle GOP preroll is
  explicitly reported. Very long all-idle preroll remains an optimization gate.
- Native main-loop queue (max eight) retries without blocking capture/UI, with a
  three-second deadline. Failure is journaled and sent through the existing
  recorderError/fallback handler, not a false success. Target category/name are
  pinned before the wait. Success records fixed endpoint, generation, required
  audio count and wait milliseconds. Raw frames/packets remain native.
- Actual VT H.264/AAC mixer probe deliberately withholds late audio, verifies
  premature finalization is rejected, then exports the original 1.5-second
  endpoint after arrival. Independent packet timelines end within one 1024/48k
  AAC packet: master/PC +13.333 ms, microphone +10.666 ms. AVFoundation duration
  is exactly 1.5 s, independently decoded frames/PCM are positive, spectra/source
  gains and no-B-frame PTS/DTS/keyframe checks pass. This is synthetic hardware
  evidence, not ScreenCaptureKit/physical hotkey or long-run drift evidence.

## Commands/environment/results

Same macOS 27.2/26B5091g arm64 M5 Max, Xcode 27.1/27A9269/SDK27.0, Electron
43.2.0/ABI148/Node24.18.0. Workspace cwd `/Users/ryan/Developer/medal-cross-platform`.

- `cmake --build build-macos-20260925 -j4`: exit 0, build r1–r4 logs retained.
- `ctest --test-dir build-macos-20260925 --output-on-failure`: r1 exit 0/10 of 10;
  r2 exit 8/9 of 10 (existing filename); r3 exit 0/10 of 10. Exact logs
  `audio-20261002-endpoint-ctest-r*.log`.
- `node tools/validate_native_audio_mix_fixture.cjs build-macos-20260925/native/backends/macos/audio-replay-endpoint-test.mp4 multiple reports/audio-native-endpoint-20261002-r2 1.5`:
  exit 0, real media/AVFoundation/ffprobe/PCM/packet timelines in results.json.
- `python3 -m unittest tests.test_importer -v`: exit 0, 7/7;
  `audio-20261002-endpoint-importer-tests-r1.log`.
- Import/build commands match the prior live-routing report, with the current
  helper. Import/build logs `audio-20261002-endpoint-{import,app-build}-r1.log`.
  Prepared client `2637.461.1-native-port-m3.5-0396a759169f`; signed app
  `2637.461.1-development-m3.5-e78f3ce58a85e573`.
- Clean Medal menu Quit, no host/helper; ditto stage, strict/deep signatures,
  Darwin renamex_np RENAME_SWAP atomic activation, verify installed, retain prior
  bundle at `/Applications/Medal.app.previous-audio-roundtrip-20261002`.
  Install log `audio-20261002-endpoint-install-r1.log`. Same deterministic
  host/helper IDs, development team/certificate/TCC; no new consent/reset.

## Current live prerequisite

Exact installed app launched once: host PID 19915/helper 19929. Original read-only
interactiveSessionPreflight: interactive/GUI/onConsole/loginDone true, three
displays, screenLockedHint false. Fresh synthetic fixture 440/660/880 apps each
show tone playing. Original missed-game process selector → fixture 440 → Continue
→ focus reaches Clipping, not a self-test. Original Specific Apps settings retain
game + fixture 660 only, mic/feedback/Discord/880 OFF, separate tracks ON.
Game slider adjusted through actual keyboard UI to 25%; selected app to 50%.
Capture status: capturing, lastError empty, original `clip;length=30` F8 registered,
trigger/feedback count 0. Physical F8 requested; no live endpoint/gain pass claimed
until its actual finalized file, original probe/thumbnail/player and restart are
checked. Automatic uploads remain Never. Further device/mic/listener/feedback/
sustained timing and Linux gates remain open.

## Physical original-client endpoint/gain/restart gate — passed

The user physically pressed F8 and replied “done.” Original clip action dispatched
once, feedback count 1, contentCreate acknowledged UUID
`31bdef5a-5619-4048-9b19-6a0d8dc9f4b2`. Event endpoint 557896461231375 ns,
configuration generation 1, required AAC tracks 3, wait 208 ms. Reported replay
duration 31.043979542 s for requested 30 s (independently decodable GOP preroll).
No private save command used; native frames/packets stay outside Electron.

`node tools/validate_live_audio_routing.cjs <isolated-DB> <UUID> <expected-JSON> reports/audio-live-endpoint-20261002-r1 --require-endpoint-coverage`
exits 0; exact invocation and tool argv in results.json. All three native AAC48k
stereo tracks have positive decoded PCM (1,489,920 mono inspection samples each),
correct manifests/defaults and expected spectra in start/middle/end segments:
master 440 ~.01495 / 660 ~.02980, selected-app stem only 660 ~.02980, game stem
only 440 ~.01496. The unselected 880 Hz amplitude is below .000011 everywhere.
Thus real original UI 25%/50% capture gains are applied once, not only at preview.
Live 150% and real microphone remain separate gates.

Independent packet timeline: video 1568 packets, first PTS/DTS 0 and keyframe;
all packets PTS=DTS/monotonic, last video end 31.045 s after MP4 time-base
quantization. All three AAC endpoints also 31.045 s (delta floating rounding
~-3.6e-15 s), no missing audio tail. The bound remains one indivisible AAC packet,
not exact unquantized MP4 duration. Native AVFoundation decode and independent
ffprobe pass, plus original Medal contentCreate/probe and actual thumbnail/card.

Original Medal player matches expected UUID, readyState 4/error null, playing at
5.528271, decoded 1859; two source preview buses ready/gains 1, baseline 0,
outputPeak .0446591. Original menu Quit exited both processes. Fresh single exact
app launch reopened the same clip through its card: expected UUID true,
readyState 4/error null, playing at 13.727965, decoded 706; source buses ready,
outputPeak .0437371. This is short playback, not sustained/physical timing proof;
maxObservedDrift includes startup and loops/seeks and remains unsuitable for that
gate. Exact post-restart library path/file hash unchanged:
`9dc81cef84a4ab21a9055d5c780d562433843a7ebc73638589c8223f19a98a8b`.

Original game/selected-app sliders restored to pre-test 100%. Fixture Cmd-Q exits
all three; verified no fixture process remains. Single host 25380/helper 25393
remain at `/Applications/Medal.app`, no active capture after restart. New original
audio recordings, their edits and all failed evidence remain intact. No uploads.
Next runnable gates: live 150% gain/microphone/input/output devices, process/
default-device/format lifecycle and project-owned Clip Sound PCM; sustained
preview/routing drift/latency/failure matrix. Linux handoff not ready.

Final verification after live gate: `cmake --build build-macos-20260925 -j4`
exit 0; `ctest --test-dir build-macos-20260925 --output-on-failure` exit 0/10 of
10; both validator `node --check` commands exit 0; `python3 validate_pack.py`
exit 0 (document consistency only); `git diff --check` exit 0. Logs named
`audio-20261002-endpoint-final-*.log`. Shared-interface revision/build identity
also recorded in DEPENDENCIES.lock.json; no release/notarization claim.
