# Native audio routing continuation — 2026-10-02

Base: `3a0f3f7`, preserving editor checkpoint `0fd3698` and all unrelated work.
No reset, upload, publication or direct library DB write. Existing recordings
and failed evidence are retained. This is NOT an audio-complete claim.

## Implemented and built

- Native HAL audio identities retain audio-object/PID, executable/bundle,
  bounded parent ancestry, output activity/devices and application-family owner.
  `audioProcesses` gets its Windows-shaped DTO only at the wire boundary. Helpers
  belong to a verified enclosing bundle/component boundary or PID ancestry, not
  a name/bundle-ID prefix. Two instances require PID/ancestry evidence. Selected
  families have separate gains; overlapping aliases are not captured twice.
- Explicit PC output selection resolves connected device UIDs/stream indexes.
  Device-bound CATapDescription exclusion taps feed native PCM; Auto-only keeps
  the dedicated SCK stream. Auto plus the same explicit default UID deduplicates.
  Missing/ambiguous devices or unsupported layouts report unavailability, with
  no whole-PC fallback. Current device adapters require negotiated mono/stereo;
  multichannel support remains open.
- Hash-pinned original `H4` emits only selected `AudioModeConfig.devices`.
  Explicit empty devices now means no outputs, not fallback to stale legacy
  `SelectedAudioDevices:["Auto"]`. Only absent selection defaults to Auto.
  Verified main SHA-256:
  `5a2a6dd5d1370a15577b0c09bc2d021059e2f9e7dba6a2e40cc41b4685e0c8ff`.
- Strict normalization rejects empty/reserved/duplicate/oversized IDs, unknown
  modes and excessive live sources before async graph construction. Silent/
  closed selected descriptors emit no fake healthy stems before actual PCM.
- Shared packet source names are separate from stable IDs and survive native
  AAC/replay/writer manifests. Device stems read `PC Audio — <device> (stream N)`.
  Master remains All Audio/default. HAL diagnostics expose bounded counts,
  generation, format and host timestamps, never raw PCM. Single-track master
  status no longer incorrectly reports disabled.
- Bundle-ID automatic restoration is disabled pending verified lifecycle
  listeners. Process/default-device/format listeners, relaunch and sleep/wake
  still remain open. Game-only and Specific Apps never substitute whole-PC audio.

Primary API evidence: Apple's [CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription)
and [device-bound exclusion initializer](https://developer.apple.com/documentation/coreaudio/catapdescription/initexcludingprocesses%3Aanddeviceuid%3Awithstream%3A?language=objc),
plus installed SDK headers. No third-party tap implementation was imported.

## Tests actually run

macOS 27.2/26B5091g, arm64 M5 Max; Xcode 27.1/27A9269, SDK 27.0, Apple clang
21.0.0; Electron 43.2.0/ABI 148. Same Apple Development IDs/team XDB9K8JX58.

- `cmake --build build-macos-20260925 -j 4`: exit 0;
  `reports/native/audio-20261002-device-build-r2.log`.
- `ctest --test-dir build-macos-20260925 --output-on-failure`: exit 0, 9/9;
  `reports/native/audio-20261002-device-ctest-r2.log`. New injected identity tests:
  helper/ancestor ownership, false path-prefix rejection, two instances, exact
  families, missing/virtual sources, PID/UID/default dedup, stream identity and
  missing/ambiguous/invalid devices. These are NOT permissioned capture tests.
- `python3 -m unittest -v tests/test_importer.py`: exit 0, 7/7;
  `reports/native/audio-20261002-routing-importer-tests.log`.
- `native_port_macos_audio_mix_graph_probe <absolute-output> multiple|single`:
  both exit 0; files in `reports/audio-native-routing-20261002-r1/`.
  `node tools/validate_native_audio_mix_fixture.cjs <file> <mode> <new-directory>`:
  both exit 0. Actual H.264/AAC master/source gains, delayed mic, isolated stems,
  positive PCM samples/default dispositions, AVFoundation decode and ffprobe.
  Writer additionally verifies source-name preservation. Exact argv/results are
  in each validation `results.json`. These are synthetic native media, not
  imported Medal probe/player evidence.

## Original UI — partial, then blocked

Mixer build `2637.461.1-development-m3.5-62bdb9e5d75925f2` ran as exactly one
host/helper pair on the existing isolated authenticated profile.

1. Original read-only `MedalIPC` preflight: displays=3, GUI/onConsole/loginDone/
   interactive=true, screenLockedHint=false. No picker launched.
2. Original Uploads selected Never; free-up-after-upload OFF.
3. Original Hotkeys showed F8 conflict (Clip/Bookmark). Rebind attempts failed;
   console explicitly reported unavailable/rejected `startHotkeyListening`.
   Original Unset Hotkey removed Bookmark/conflict. Clip stayed F8, length=30.
4. Own native 440/660/880 Hz fixture apps launched. Original Audio listed all
   three. Selected All PC audio/Auto/Separate Tracks ON and microphone OFF.
   Original Game selector → fixture 440 → Continue → focus synthetic window
   reached Clipping/native capturing. This is normal targeting, not a self-test.
   Header still said Waiting For Game: synthetic non-game classification is not
   a game/category pass. No category was invented/private desktop captured.
5. Native 48 kHz stereo PCM/AAC acquisition: zero observed encode failures/
   discontinuities. One snapshot: 23,888,640 mixer frames, 28,423 video frames;
   zero late/missing/stale frames, generation=1, sources=1. Earlier audio/video
   endpoint differences +481.106375/-241.389208 ms include startup/200 ms reorder
   buffering; NOT an audible A/V-drift measurement/pass.
6. CUA F8 did not reach Carbon: triggerCount=0, lastClipAction=not_triggered.
   Physical F8 prerequisite requested. No native replay/contentCreate/thumbnail/
   new player/restart pass is inferred.
7. Later UI observation: Mac locked; manual unlock required. No further UI,
   picker, unlock/security/TCC-reset attempts. GUI/hotkey/isolation/restart gates
   blocked. Freshly verified test host/fixture PIDs stopped by SIGTERM; subsequent
   pgrep found no host/helper/fixtures. This is cleanup/parent-death stop, not a
   clean-menu restart gate. No new manual TCC interaction occurred.

Two RSS samples: helper 74,048 KiB at 11:38 process elapsed, 77,104 at 28:07;
host 228,272/235,024 KiB. Two points only; required 30-minute drift/memory test
has NOT passed.

Replay-tail gate remains open: the mixer intentionally buffers 200 ms for source
reordering, while the synthetic probe calls finish/drain before muxing. Therefore
its complete audio tail does not prove a running hotkey snapshot has equivalent
tail coverage. Validate the actual finalized hotkey file against the original
press endpoint; distinguish acquisition latency from audible timestamp offset,
and repair endpoint scheduling/coverage if needed without shifting the requested
moment or compressing time.

## Packaging and next gate

Import/build/install exit 0; source reports:
`audio-20261002-routing-import.log`, `audio-20261002-routing-app-build.log`,
`audio-20261002-routing-install.log` under `reports/native/`.
Prepared client `2637.461.1-native-port-m3.5-449de189f1a6`; new installed app
`2637.461.1-development-m3.5-84f35d9a5ac0c845` at `/Applications/Medal.app`.
It is NOT launched while locked. Stage/installed strict/deep signatures passed.
Atomic Darwin renamex_np/RENAME_SWAP activation (SDK sys/stdio.h flag 0x2)
retained the old mixer at `/Applications/Medal.app.previous-audio-mixer-20261002`.
Earlier editor backup remains. Failed verification would atomically swap back;
no application/recording was deleted. Development only, not notarized/released.

Two patch-tool attempts were rejected before changes: duplicate target operations,
then a missing documentation anchor. Corrected/retried; no failed test evidence
was rewritten.

Next: manual unlock; open exactly installed Medal; preflight/Never uploads; own
tones; normal target/Desktop UI → physical clip hotkey → replay/contentCreate →
exact current-file AVFoundation/ffprobe/original Medal probe/thumbnail/player →
full restart. Then Specific Apps 440 game + 660 selected/880 excluded, gains,
explicit device selection, microphone and lifecycle/long-run gates. Do not count
this family/device build as live isolation. Clip Sound PCM, PTT/noise processing
and full audio matrix remain open. Linux transfer is not ready.
