# Original live audio routing — 2026-10-02 (in progress)

Base `dd66b00`, no reset/upload/publication/library DB writes. Existing recordings
and failed evidence preserved. This report does not claim audio completion.

## Preconditions and first actual round trip

- Installed Apple Development build `2637.461.1-development-m3.5-84f35d9a5ac0c845`;
  exactly one host PID 79632 and recorder PID 79645. Same deterministic IDs/team.
- Read-only original IPC preflight: interactive/onConsole/GUI/loginDone true,
  screenLockedHint false, three displays. Existing recorder Screen Recording and
  microphone grants authorized; camera not requested. No new TCC interaction.
- Original Uploads page: Never selected, free-up-after-upload OFF.
- Own 440/660/880 Hz AVAudioEngine fixture windows started through normal app UI.
  Original Audio: All PC audio, Auto output, gain 100%, Separate Tracks ON,
  microphone OFF (privacy prerequisite; no private microphone audio acquired).
- Original capture selector Game → process fixture 440 → Continue → focus fixture
  reached native SCK window capture. This is normal targeting, not a capture demo
  or private save command. Synthetic fixture has no invented game/category.
- User physically pressed F8 and replied “Pressed”; original existing action
  `clip;length=30` dispatched once. Read-only status: triggerCount=1,
  feedbackCount=1, lastClipAction=acknowledged. UUID:
  `cb6890f5-472b-4e76-b6fb-0b8ff7cf1402`.
- Original contentCreate/probe/library generated a visible 31-second card and
  synthetic thumbnail. Double-click original card opened its player. Read-only
  HTMLVideoElement: readyState=4, no error, 1762×1080, time=15.476637, playing,
  decoded frames=822. File location is authoritative library path, not guessed.
- `node tools/validate_live_audio_routing.cjs <isolated-DB> <UUID> <expected> reports/audio-live-allpc-20261002-r1`
  exit 0. Full argv/library/probes/hashes/positive decoded PCM/spectral segments in
  that directory's `results.json`. Master/stem 440/660/880 amplitudes ~0.05984 /
  0.05963 / 0.05932 for 0.06 input; all-PC capture is independent of video target.
  AAC48k stereo; only master default; AVFoundation and independent ffprobe pass.
  These do not prove microphone, app isolation or drift.
- Original modal close (without Save) then Medal menu Quit; verified no host or
  helper remains. This is clean shutdown, not yet post-restart playback.

## Actual failed mute gate and source diagnosis

Original Audio popover exposes only PC Audio. Toggle muted it and showed Save
Edits, but read-only controller snapshot still reported ready/buses=2,
baselineGain=0, outputPeak=0.17693741619586945, muted=[false,true], gains=[1,0].
Thus a hidden master SIDE CAR was playing; baseline suppression alone was not
enough. No Save was used to paper over the failure.

Pinned original main `wi` stores JSON text in each returned row's metadata;
original preload `getContents -> y` parses it for renderer callers. Our main
service called `wi` directly and read `content.metadata.audioStreams` as if it
were an object. Native AVAssetWriter's uiso/titl title is not ffprobe's title tag,
so fallback could not recover the master identity. Existing FFmpeg-edited
fixtures have handler_name=All Audio and therefore concealed this boundary bug.

Fix: parse/bound/validate trusted library metadata at the service boundary for
both preview and edit. Reject malformed metadata. Controller independently
rejects master-plus-stem prepared manifests and mutes buses absent from original
controls. Actual UI retry on rebuilt signed app remains pending.

New tests: 45 real FFmpeg media checks in
`reports/audio-fixed-20261002-main-metadata-r1/results.json` (exit 0), including
main JSON text preview/edit/mute/invalid shapes. Controller ownership regression
and capture-header tests exit 0; native build exit 0; CTest 9/9 exit 0.
Logs: `audio-20261002-{preview-hidden-master-test,capture-label-test,live-metadata-build,live-metadata-ctest}.log`.

## Other observed failures / open gates

- User observed normal target modal “Clipping: <app>” while header said Waiting
  For Game. Original header is category-driven. Added namespaced read-only native
  captureActivity and original React header fallback for actually capturing
  uncategorized applications; category/error/disabled states keep precedence.
  No fake game category or successful unsupported original RPC introduced.
  Built/tested; actual header test after new package remains pending.
- Both actual AAC tracks end 228.333 ms before video. This is a missing replay
  tail, not an audible long-run drift pass. Mixer buffers 200 ms and snapshot
  does not wait for its fixed press endpoint. Preserve this file and fix/test
  press-anchored scheduling; delaying latest snapshot would shift the moment.
- First direct SQLite query used nonexistent `uuid`/`audio_streams` columns and
  failed read-only. Corrected to actual local_content_id/JSONB metadata fields;
  no data mutation or failed evidence replacement.

## Rebuilt actual-client retry and All PC Save/restart — passed narrow gate

Signed build `2637.461.1-development-m3.5-0ab219782f8c066e` installed atomically;
prepared client `2637.461.1-native-port-m3.5-f22cd77d94c6`. Original routing build
retained at `/Applications/Medal.app.previous-audio-routing-20261002`. Strict/deep
signatures verified before/after activation. Same host/recorder IDs/team/TCC
grants; no permission prompt/reset. Import/build/install commands and exit status
are in `audio-20261002-live-metadata-{import,app-build,install}.log`.

Fresh original player for UUID cb6890f5 now has exactly one PC stem bus, not a
hidden master; baseline gain 0. Original PC mute during playback: gain/outputPeak
0. Normal Save Edits → Save committed a new audio-edited path for the same UUID,
fresh thumbnail and manifest; original recording retained. Independent post-save
validator exits 0 (`reports/audio-live-allpc-20261002-muted-r1/results.json`):
master decoded floats are all zero, PC stem retains all three .06 input tones.
FFmpeg packet payload hashes of video and PC source stream are unchanged.

Original menu Quit exited host and helper. Fresh exact `/Applications/Medal.app`
launch reopened the same current UUID/file/thumbnail. Read-only original-player
snapshot: readyState 4, decoded video 182, controller ready/one bus,
muted=[true], gain/outputPeak 0 while playing. Original unmute without Save
restored outputPeak 0.1769106686115265. Closed without saving audition changes.
This is short functional silence/persistence, not physical latency or ten-minute
preview timing evidence. Loop/seek-inclusive maxObservedDrift is not a drift gate.

## Specific Apps actual isolation/mute/Save/restart — passed narrow gate

Old tone engines were actually stopped (HAL IsRunning/IsRunningOutput 0, device
count 0), though their windows remained. Do not attribute this to Medal discovery;
the underlying old engine stop cause is not proven. Read-only registry probe
records only explicit fixture PIDs. Old fixture Cmd-Q was ineffective because no
menu existed: verified fixture PIDs alone were SIGTERM'd, with no recording
deleted. Added health/Start/Stop/Quit controls, rebuilt and launched fresh three
fixtures; all showed tone playing. Probe/fixture builds exit 0, logs retained.

Original Audio settings: Specific Apps, Game Audio ON, fixture 660 ON, fixture
880 OFF, duplicate game fixture 440 OFF, microphone/Clip Sound/Discord OFF;
gains 100%, Separate Tracks ON. Normal native window target fixture 440 reached
capture. Header now actually shows Clipping: Medal Audio Fixture 440, matching
the original target modal. Native status: splitByProcess, two taps, no tap errors,
48k graph/sourceCount 2. Startup missingSourceFrames 5547 (~115 ms) retained;
late/stale frames 0 at snapshot, not sustained timing evidence.

User physically pressed F8 and replied “pressed”; trigger/feedback count 1,
acknowledged UUID `2e5756c8-e327-4a87-ae2f-f5fd0fc217ce`. Manifest: index 1 All
Audio/default; index 2 Medal Audio Fixture 660; index 3 Game Audio. All logical
IDs/ordinals/defaults verified against original library metadata. Live validator
exit 0 (`reports/audio-live-specific-20261002-r1/results.json`): master 440+660,
app stem only 660, game stem only 440; 880 absent in all three spectral segments.
Positive native decoded video/PCM, H.264/AAC48k stereo, ffprobe and AVFoundation
pass. Actual audio tail delta -211.666 ms, not passed as timing.

Original library has real synthetic thumbnail/card; actual original player
readyState 4, error null, 1762×1080, playing at 11.754667, decoded frames 651.
Controller two source buses, baseline 0, gain [1,1], outputPeak .1185071915.
Original named controls mute both: during playing at .808046, decoded 3368,
muted=[true,true], gains [0,0], outputPeak exactly 0 (not just paused).
Normal Save Edits → Save commits current edited path/new thumbnail. Post-save
validator exit 0 (`reports/audio-live-specific-20261002-muted-r1/results.json`):
master digital zero, both independent source tones retained, 880 absent, probes
pass. Original recordings are intact.

Original menu Quit verified no host/helper. Exact app relaunched once; startup
nonessential suggestion dialog dismissed without account changes. Same clip's
post-restart player: readyState 4, error null, decoded 770, playing at 14.037333;
controller ready, two buses, muted=[true,true], gain/outputPeak 0. Original Game
Audio unmute alone restored outputPeak .0600171201, gains [0,1]; selected-app
unmute alone restored .0600127839, gains [1,0]. Closed without Save to cancel
audition changes. Fixture Cmd-Q now exits all three; verified no fixture process.
Single installed host PID 6102/helper 6129 remained, no active capture.

Next: press-anchored replay tail fix; 25/50/150% live gain matrix; output devices,
microphone/listeners/feedback and sustained/failure gates. Neither audio completion
nor Linux handoff is ready. No uploads/publications.

## Final checkpoint verification

macOS 27.2 (26B5091g), Apple M5 Max/arm64; installed Xcode 27.1 (27A9269), SDK
27.0/Apple clang 21; Electron 43.2.0/ABI148/Node24.18.0. All commands executed
from `/Users/ryan/Developer/medal-cross-platform`; final logs named
`audio-20261002-live-final-*` under this directory:

- `cmake --build build-macos-20260925 -j4`: exit 0.
- `ctest --test-dir build-macos-20260925 --output-on-failure`: exit 0, 9/9.
- `python3 -m unittest tests.test_importer -v`: exit 0, 7/7.
- `node client_patch/native-audio-preview-controller.test.cjs`: exit 0.
- `node client_patch/native-capture-status.test.cjs`: exit 0.
- `python3 validate_pack.py`: exit 0, document consistency only, not capture.
- `git diff --check`: exit 0.

Exact media-validator tool arguments, library metadata, file/thumbnail hashes,
probe reports and positive decoded sample/spectral evidence are recorded in the
four new `reports/audio-live-*-20261002*-r1/results.json` files. No media binaries
or private screen images are added to the repository. A read-only comparison
ran `/opt/homebrew/bin/ffmpeg -v error -i <authoritative-path> -map <stream> -c copy
-f data -`, SHA256 of packet payloads before/after Save: All PC video
`3b0b7ca52b55600e7b5f4eb03706d6abdbe6c772e0434c2511d9a5fab1259996`, PC source
`f80dc5c81a8c2a083c9d4851a0694e0deadf414072d598f1115b2c9cc358f01a`; Specific
video `30489fc61c3e91d32709426dd0cdfb7aa97c2abede0be956572770c480dd36b0`, app
`a530edeb9dbdd3f7ba29a362689d339c94d934ec93c66ec9218bbf62f3a3b04f`, game
`80b6f2e321033433e07359f3aecdd34269d689986496967e69dad5af80dfe78a`. All equal
before/after: no video/source retranscode. Read-only exact-UUID DB query after
restart gives identical saved paths/file hashes: All PC
`67a2069ec5f89fcdfb7ff46bc29c45a3d30092cc58a7a83ae1022603600f6be2`, Specific
`fd89ea68930bcd5edc1ec6ce40be704ce16fcd488a2d47eec2d63049666e465e`.
