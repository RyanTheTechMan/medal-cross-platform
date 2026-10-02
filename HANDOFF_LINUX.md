# Actual macOS → Linux handoff

Status: **usable as a Linux development baseline; macOS completion/M7 remains open**.
This is a development handoff, not a release-completion claim.

## Current development baseline — 2026-10-02

Start exploratory Linux work from `0405d68` or the subsequent Dock-lifecycle
checkpoint, not a historical September audio build. Core native H.264/AAC window
capture, original hotkey replay/contentCreate/thumbnail/library/player/full
restart and original All PC/Specific Apps mute/Save/restart now have actual Mac
evidence. Ten native CTests pass. See `reports/native/audio-20261002-endpoint.md`
and `reports/native/audio-20261002-live-routing.md` for exact scope and failures.

This is enough evidence to reuse the control/settings/replay/audio-edit contracts
while implementing Linux adapters. It does NOT satisfy all macOS M4–M6 gates.
Microphone/device lifecycle, PTT, feedback PCM, sessions/recovery/storage failure,
camera/HDR, authorized upload, clean-user release packaging and sustained
timing/performance remain open. Keep the Mac regression route and ledger intact.

Current actual toolchain: macOS 27.2 (26B5091g), Apple M5 Max arm64, installed
Xcode 27.1 (27A9269), macOS SDK 27.0; Electron 43.2.0, ABI 148. Do not use the
removed Xcode-beta paths in historical commands below.

First Linux task, on a real Linux machine: read `LINUX_CONTINUATION_PROMPT.md`,
run `python3 validate_pack.py`, configure/build/test the shared core using
`cmake -S . -B build-linux -G Ninja -DBUILD_TESTING=ON`,
`cmake --build build-linux`, `ctest --test-dir build-linux --output-on-failure`.
Record missing dependencies/actual Linux compile failures, then implement native
Electron/addon packaging and portal/PipeWire/hardware encoder adapters. Native
Wayland selection requires consent; process discovery is not capture permission.
No Linux build, capture, GPU or desktop test is claimed by this Mac handoff.

Latest installed build is `2637.461.1-development-m3.5-bb19f77a1f0a4d20`, prepared
`2637.461.1-native-port-m3.5-274e0bc38555`: Darwin left-click now opens Medal,
right-click retains the dynamic original tray menu. Other platforms unchanged.
12 JS/7 importer tests pass; physical status-icon confirmation pending.
See `reports/native/tray-20261002.md`. Previous Dock gate below remains valid.

Latest lifecycle change: main-window hide removes the macOS Dock identity;
original menu-bar Show/activate/second-instance reopening restores it. The new
adapter is Darwin-only, not a Linux app-lifecycle implementation. Its final
installed build is `2637.461.1-development-m3.5-948e030ef3a56181`, prepared client
`2637.461.1-native-port-m3.5-3ab9354a0e3e`. Native red-X, same-instance Finder
reopen and minimize pass; the menu-bar Show handler is unchanged but not separately
clicked in this run. Tests are recorded in `reports/native/dock-20261002.md`.

### Historical continuation notes (superseded where stated above)

New endpoint continuation from known-good original audio checkpoint `7e319cd`:
shared ReplayEndpoint/snapshot_at pins OS event time, codec generation and audio
track identities; waits for AAC coverage without shifting the interval; excludes
post-press packets. Platform shortcut callback now receives capture nanoseconds
as its second argument. Linux must convert its own shortcut/portal clock into
the same native media epoch, not blindly use std::steady_clock. Native hardware
fixture/10 CTests and real physical original-client endpoint/25%/50% isolated gain/
probe/thumbnail/player/full restart gates pass. Installed
build `2637.461.1-development-m3.5-e78f3ce58a85e573`; exact failures/commands in
`reports/native/audio-20261002-endpoint.md`. Actual prior AAC packet tails were
-221.001/-243.667 ms, not the historical container-derived values below.

Latest 2026-10-02 original native audio gates: All PC and Specific Apps synthetic
normal targeting/physical F8/replay/contentCreate/probe/thumbnail/player pass,
including original mute/Save/full restart and independently decodable preserved
stems. Installed signed build `2637.461.1-development-m3.5-0ab219782f8c066e`;
prepared client `2637.461.1-native-port-m3.5-f22cd77d94c6`. Original main library
metadata is JSON text; parse/validate it in the shared native media service.
New namespaced read-only `nativePort.captureActivity` schema 1 exposes real state
and targeted app name only; it does not replace game classification. Retain these
contracts on Linux. Exact tests/failures are in
`reports/native/audio-20261002-live-routing.md`. Actual replay AAC tails remain
211.666–228.333 ms short; device/mic/listener/feedback/sustained timing gates open.
No Linux capture, release or cloud claim.

2026-10-02 continuation: native HAL helper-family ownership and UID/stream taps
are build/model-tested; 9 CTests and native single/multiple media validations pass.
Shared `EncodedPacket.logical_source_name`/`PcmSource.display_name` separate source
identity from manifest labels. Explicit empty AudioModeConfig.devices means no
outputs, only absent selection defaults to Auto; Linux must retain this policy.
GUI/isolation/restart gates blocked when Mac locked. Current installed development
build: `2637.461.1-development-m3.5-84f35d9a5ac0c845`, not launched while locked.
Exact commands/rollback/open gates: `reports/native/audio-20261002-routing-status.md`.
No Linux capture/release claim.

2026-10-02: shared `PcmMixer` adds canonical 48 kHz float stereo, absolute host
frame positions, fifteen-source/two-second ring bounds, a 200 ms reorder window,
independent capture gains, master limiting and optional stems. macOS adapters
resample and encode with Apple frameworks. Native build/8 CTests, actual
single/multiple MP4 decode/spectral/default-track tests pass; live routing is
still in progress. PC/app percentage fields are now doubles; microphone wire gain
is strictly 0..1.5, with traced default .5. Linux must preserve these semantics,
map PipeWire clocks/formats into this core and retain native client media patches.
See `reports/native/audio-20261002-status.md` for exact evidence and next commands.

2026-09-25 correction: current base is `b1fa75a`, not the stale pre-amendment
`590e471` below. The September 20 audio-edit playback/restart claims are withdrawn
because the retained launch log contains missing-file/decoder failures. Shared
JS native editing and preview repairs now pass short synthetic original-UI
overwrite/unmute/Save Copy/restart checks on the exact persisted paths; see
`reports/native/audio-20260925-status.md`. Xcode 27.1 (27A9269), macOS 27.2
(26B5091g), `build-macos-20260925`: fresh build/6 CTests pass. The user's isolated
profile is authenticated; no further login is needed. No uploads are authorized.
Installed development build: `2637.461.1-development-m3.5-404b6fa35c7f97e3`.
The historical sections below describe earlier gates; they do not supersede the
September 25 audio report. Native PCM mixing/routing remains incomplete.

## Build identity

- Commit / dirty-tree changes: checkpoint `590e471` and its parents cover M0, shared core/M1, authenticated actual-client/helper M2, deterministic signing, real H.264/HEVC capture, native AAC/MP4 export, typed audio routing, HAL process discovery, bounded process-tap handoff, the secure original-client sidecar audition path, and the original trim absolute-index/output-manifest fix. The current macOS evidence is not yet a Linux handoff because Save Copy/unmute rollback, microphone capture, per-app isolation and long-duration drift gates remain open.
- Input hashes: installer `e6477e89f968593fe4b8335f09fc25f81889dd412c28ff85522a0a37415decdb`; recorder ZIP `d33c6e3c0506c1f6b71e6158716fda3a9866bfacc41060f2ec29c4d792ca1312`.
- macOS / chip: macOS 27.2 build 26B5086k; arm64 Apple M5 Max.
- Toolchain: stable Xcode 27 unavailable; Xcode 27.2 beta build 27B5019j with SDK 27.2 and Apple clang 21.0.0 is used for development only.
- Electron/addon/signing/package: actual Electron 43.2.0 / ABI 148 and locally built better-sqlite3 12.12.0 run arm64-native. `Medal.app` uses recovered upstream ID `com.squirrel.medal.medal` and the imported Medal icon; its `.recorder` helper has a separate fixed identity. Both are Apple-Development signed for repeatable local TCC tests. There is no Developer-ID/notarized/release package.
- Dependency lock / protocol: `DEPENDENCIES.lock.json`; recovered protocol version 1 unchanged.

## What actually works

- Pinned read-only extraction and 12/12 inherited isolated protocol/library tests pass on this Mac.
- The actual imported native Electron client and actual C++ helper complete authenticated version-1 WebSocket handshake/readiness, device/settings queries and clean shutdown on the selected loopback port.
- Shared C++ JSON-RPC, settings/timestamp/replay data structures and the macOS platform-adapter interface compile/test. CoreGraphics/CoreAudio/AVFoundation enumeration is active.
- ScreenCaptureKit display/window capture crosses real TCC/picker interaction and feeds frames directly into hardware-required VideoToolbox; H.264 and HEVC short runs pass on this host. AV1 remains unavailable because no VideoToolbox encoder is registered.
- Independent ScreenCaptureKit system audio and microphone output paths feed AudioToolbox AAC encoders; system audio passes a short real run while microphone permission/capture remains untested.
- The shared timestamp-based encoded replay and macOS AVAssetWriter adapter now complete one physical recovered `Hotkeys` → `clip;length=5` → H.264/AAC MP4 → original `contentCreate` → probe/thumbnail/library-row path. AVFoundation decode and independent ffprobe pass; imported Chromium playback/seek, full application restart and file/library persistence pass.
- The latest imported authenticated UI run additionally completed one original `Audio` popover → `Save Edits` overwrite → timestamped H.264/two-AAC output → absolute-index metadata persistence → original playback → full restart path. The output is independently validated by ffprobe and AVFoundation; the sidecar AAC files are validated by ffprobe. The importer/source patches are shared JS/Python changes and must be retained on Linux.
- The visible original library/player remains account-gated at the unauthenticated Welcome screen. No login/upload, microphone, permission lifecycle, crash recovery, editor, release package or sustained-performance gate has passed.

## Exact build/test/run commands

See `PROGRESS.md`, `reports/m0/` and `reports/native/`. Current native regression is `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer cmake --build build-macos -j 8 && DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ctest --test-dir build-macos --output-on-failure -V`; current result is 6/6 passed. Importer/security regression is `python3 -m unittest -v tests/test_importer.py`; current result is 7/7 passed. Operational details are in `reports/native/m3.5-operational-replay-result.md`.

## Common interfaces Linux must preserve

- `native/core/include/native_port/platform_adapter.hpp` defines the platform enumeration boundary used by the helper.
- Existing JSON-RPC/settings/timestamp/replay/capture-settings/capture-geometry/clip-action interfaces under `native/core/include/native_port/` are shared and additive changes must preserve macOS tests. Encoded retention is time-based and exports must start on a configured keyframe.
- The private authentication extension is the `x-native-port-secret` upgrade header; it is not part of Medal's recovered JSON-RPC protocol.
- Recovered method/settings inventories in `FEATURE_LEDGER.json` and `research/PROTOCOL.md` remain authoritative evidence boundaries.

## Remaining macOS work

M1 recovery/external-source cleanup, the remainder of M2 resilience/inventory, the M3 shortcut matrix, microphone/drift/permission lifecycle, HEVC full-client compatibility, Save Copy/unmute/failure-rollback editor paths, authenticated upload, crash/export recovery and all release/package/performance gates remain. Stable-Xcode-27 reruns remain required. No upload or publish was performed.

## Linux starting point

The current development starting point is above. A formal macOS-complete M7
handoff still requires the remaining gates; historical commits below are not the
recommended Linux base.

## Regression route

Current baseline: `python3 validate_pack.py`, importer tests, inherited original-client tests, the CMake/CTest command above, and the actual Electron protocol evidence route recorded in `PROGRESS.md`. Linux changes must keep the macOS adapter and helper build path intact.
