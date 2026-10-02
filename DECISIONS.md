# Implementation decisions

## Decision D018 — Authoritative audio metadata and uncategorized capture status (2026-10-02)

Original main library `wi` returns metadata as JSON text; preload `y` parses it
for renderer callers. Native media services must parse/bound/validate this trusted
row rather than infer source identities from ffprobe tags. Native AVAssetWriter
uiso/titl titles are not FFmpeg handler_name tags. Missing UI source controls mute
their buses; a prepared manifest containing both master and stems fails closed.
Preserve nondestructive stems while regenerating the selected default master.

The original header is category-driven. Add namespaced read-only
`nativePort.captureActivity` schema 1 with actual state and targeted application
name, and use it only when the original header would say Waiting For Game during
real native capture. It does not classify games or report unsupported RPC success.
Raw frames/packets remain native. Windows behavior and original error/disabled/
category precedence remain intact. Actual original UI/header tests pass on the
new signed build; see `reports/native/audio-20261002-live-routing.md`.

## Decision D017 — Native audio families and explicit outputs (2026-10-02)

Use HAL audio objects as authority, with native executable/bundle/ancestor
evidence to group helpers under the selected app. Generate Medal process DTOs
only at the boundary. Never identify an app family by a loose bundle-ID prefix
or substitute the entire system mix. Keep source gain/identity independent.
Resolve explicit output selections to real UID/stream taps; missing/ambiguous
devices fail closed. Retain Auto-only SCK and deduplicate Auto/default UID.
Original H4's explicit-empty devices are authoritative over stale legacy Auto.
Separate packet source names from IDs for correct finalized labels.

Nine CTests and fresh native media validation pass. Permissioned family/device
isolation remains unverified; GUI gate blocked when Mac locked. Bundle-only
automatic restoration disabled until verified listeners exist. Same development
signing/TCC identities; no uploads/security reset. See
`reports/native/audio-20261002-routing-status.md`.

## Decision D016 — One native PCM clock and actual combined master (2026-10-02)

PC, application and microphone sources enter the shared 48 kHz timeline before
AAC. Source gains apply once at acquisition; editable stems retain capture gain.
The master uses a defined stereo limiter and is the sole default playback track.
Valid HAL capture timestamps remain absolute, matching SCK video. Audio topology
changes retain video and start a fresh compatible media generation at a forced
keyframe. No source is silently replaced with whole-system capture. Fixture
encode/mux/spectral passes remain separate from permissioned routing/GUI evidence.

## Decision D015 — Source-preserving native audio edits and audition ownership (2026-09-25)

- Native editing resolves a local UUID through Medal's actual library API, probes
  real absolute audio indexes, writes a new file, validates the output manifest,
  then uses the original persistence IPC with readback before updating UI caches.
  Original files are retained; source GC is deferred because other rows/undo may
  reference them. FFmpeg operates only on completed media, never live frames.
- Existing no-master clips migrate to a real `All Audio` mix plus copied sources.
  Save Copy's zero/full-range defaults are not treated as a seek, preserving AAC
  priming packets. Windows' original trim body stays byte-for-byte unchanged;
  native media capability supports Darwin/Linux with explicit failure otherwise.
- Original Audio popovers drive audition through state effects. A zero-gain
  Web Audio gate owns baseline suppression independently of the user's mute and
  volume. Failures remain silent and visible. Sidecars use opaque, leased local
  assets and measured timeline offsets. No arbitrary-file or encoder RPC exists.
- September 20 audio-edit restart assertions were retracted after auditing actual
  ENOENT/decoder errors. A visible thumbnail is not a playback test. All failed
  evidence remains on disk; native live master/per-app gates stay incomplete.

## Decision D001 — Keep native verification blocked while using the available beta SDK for compile-only progress

- Date / commit: 2026-09-18 / `9082bbe`, updated by pending checkpoint.
- Problem and evidence: the machine is macOS 27.2 arm64, but stable Xcode 27 is absent. The subsequently installed Xcode 27.2 beta build 27B5019j provides SDK 27.2.
- Selected approach: use an explicit `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` for development builds and compiler/runtime API probes. Do not treat beta-built packaging, permission attribution, performance, or release gates as stable release evidence.
- Alternatives and tradeoffs: using stable Xcode 26.6 would not compile against the required SDK; treating beta results as release evidence would violate the requirement.
- Affected interfaces: build configuration only; no common protocol or media interface change.
- Security/privacy/packaging impact: beta-built artifacts are development-only and will not be described as release/notarized artifacts.
- Tests required and actual results: environment discovery is recorded in `reports/m0/environment.txt`; the shared core and macOS API probe compile and pass under `reports/native/`.
- Source references: `CODEX_MASTER_PROMPT.md` sections 5.1, 10, and 11; `SOURCES.md` S01.

## Decision D002 — Preserve inherited tests as reference evidence only

- Date / commit: 2026-09-18 / no Git commit yet.
- Problem and evidence: the 12-test harness substitutes Electron objects, the database accessor, and selected media dependencies.
- Selected approach: retain B01 as an isolated compatibility baseline and create separate reports for actual Electron, addon, helper, capture, permission, and service gates.
- Alternatives and tradeoffs: promoting B01 to A04/A05/B02/M03 would be quicker but false.
- Affected interfaces: none.
- Security/privacy/packaging impact: the baseline uses synthetic local media and no account or capture permission.
- Tests required and actual results: 12/12 isolated checks passed; see `reports/m0/protocol-results.json`.
- Source references: `research/README.md`, `research/FINDINGS.md`, `ACCEPTANCE_TESTS.md` B01.

## Decision D003 — Patch only the pinned user-imported tree and activate immutable versions atomically

- Date / commit: 2026-09-18 / pending checkpoint commit.
- Problem and evidence: the imported installer contains proprietary application resources plus Windows-only native modules and update paths; modifying the read-only source or accepting changed anchors would make rollback and provenance ambiguous.
- Selected approach: validate the installer and five patch-critical source hashes, copy into a same-filesystem staging directory, apply exact-count replacements with pre/post hashes, install separately built native files, then atomically replace a managed `current` symlink. Keep `previous` and every version directory for rollback. Do not execute installer lifecycle scripts.
- Alternatives and tradeoffs: in-place patching was rejected because failure can damage the only working import; global platform spoofing was rejected because it would route unrelated Windows behavior into macOS code.
- Affected interfaces: startup bootstrap, both Velopack import sites, SQLite addon/CLI resolution and FFmpeg/ffprobe resolution.
- Security/privacy/packaging impact: imported inputs remain unchanged; unknown builds fail closed; automatic proprietary client and recorder updates are not permitted to overwrite native artifacts.
- Tests required and actual results: six importer security tests and an idempotent second real import pass. Full rollback/profile preservation and decompression fixtures remain for A03/A09.
- Source references: `ACCEPTANCE_TESTS.md` A01-A03/A06/A09; `CODEX_MASTER_PROMPT.md` sections 6 and 10.

## Decision D004 — Use one explicit manual-update adapter for both client update entry points

- Date / commit: 2026-09-18 / pending checkpoint commit.
- Problem and evidence: `index.js` calls Velopack during earliest startup while `main.min.js` creates its own update manager; allowing only one path to fail could still apply Windows packages or report a false healthy updater.
- Selected approach: replace the pinned Velopack JS export with a chain-compatible startup adapter and an `UpdateManager` that throws `NATIVE_PORT_MANUAL_UPDATES`. The client's existing error handling then reports updates unavailable. New imports are the only supported development update path.
- Alternatives and tradeoffs: returning `null` from update checks would falsely imply a successful no-update result; importing the Windows addon is impossible and unsafe.
- Affected interfaces: update startup hooks and `UpdateManager` construction only; the renderer/main client code otherwise remains vendor code.
- Security/privacy/packaging impact: no TLS or signature validation is bypassed, and no remote replacement binary is accepted.
- Tests required and actual results: actual native Electron startup reaches the original renderer without a Velopack native-load error; packaged/update UI behavior is still required for A06.
- Source references: `ACCEPTANCE_TESTS.md` A04/A06; `research/PATCH_PLAN.json` bootstrap-runtime.

## Decision D005 — Authenticate the loopback recorder socket with an inherited per-launch secret

- Date / commit: 2026-09-18 / pending M2 checkpoint.
- Problem and evidence: the recovered server accepted any no-Origin loopback client. A second local process could otherwise connect before the recorder and impersonate it.
- Selected approach: generate 32 random bytes before each Electron launch, inherit the secret through the child environment, and require an exact `x-native-port-secret` upgrade header. The secret is never placed in argv or protocol logs. Preserve the original no-Origin restriction and loopback-only listener.
- Alternatives and tradeoffs: a fixed token would cross profiles and restarts; an argv token leaks through process inspection; treating loopback alone as authentication does not satisfy B04.
- Affected interfaces: a namespaced private HTTP upgrade header on both patched Electron and native helper endpoints. Recovered JSON-RPC envelopes remain unchanged.
- Security/privacy/packaging impact: profile launches cannot reuse stale credentials; missing and incorrect secrets fail before WebSocket upgrade.
- Tests required and actual results: two unauthorized upgrades returned HTTP 401; the authenticated helper connected on the client-selected occupied-port fallback; argv contained no secret. See `reports/native/m2.6-websocket-auth.json` and `m2.6-process-evidence.txt`.
- Source references: `research/PROTOCOL.md`; `ACCEPTANCE_TESTS.md` B02-B04.

## Decision D006 — Treat client/helper logs as protocol-shape evidence, not payload dumps

- Date / commit: 2026-09-18 / pending M2 checkpoint.
- Problem and evidence: the imported client logged complete WebSocket messages, exposing real device labels, camera identifiers and settings; its feature client also logged per-profile context in a URL.
- Selected approach: exact-patch inbound/outbound recorder logs to method/id/error-code shapes, summarize setKV values by key/count, and redact feature client context creation/stream URLs. Native helper fatal messages do not include secrets or device inventories.
- Alternatives and tradeoffs: post-processing reports would leave sensitive values in live application logs; suppressing all logs would remove useful lifecycle/error evidence.
- Affected interfaces: logging only; wire values and client state remain unchanged.
- Security/privacy/packaging impact: retained reports contain no observed personal device labels, feature-context token or session secret.
- Tests required and actual results: actual M2.6 log retained handshake/readiness/method/error/shutdown evidence, and repository report scans found none of the observed labels/context markers.
- Source references: repository privacy rules; `ACCEPTANCE_TESTS.md` B03/B04.

## Decision D007 — Freeze team-backed development identities before the first TCC call

- Date / commit: 2026-09-18 / pending M3.1 checkpoint.
- Problem and evidence: macOS privacy grants belong to the responsible signed code requirement; the earlier bare helper and ad-hoc Electron identity would vary or be attributed ambiguously across rebuilds.
- Selected approach: present the host as `Medal.app`, reuse the imported Windows client's exact recovered AppUserModelID `com.squirrel.medal.medal`, use `com.squirrel.medal.medal.recorder` for the distinct capture helper, derive stable child-helper IDs, and sign with Apple Development identity fingerprint `32396A31EA92D7AB513FC0B8EFB8F22E3CC83320`. Generate the app icon from the imported `MedalApp.png`, sign nested Electron code inside-out with hardened runtime, retain an atomically versioned local app, and verify designated requirements before any ScreenCaptureKit enumeration. The recorder owns capture; the Electron host does not transport raw frames.
- Alternatives and tradeoffs: ad-hoc signing was rejected because it does not provide a stable team-backed TCC requirement; Developer ID/release signing was not used because this is a local development gate and notarization is neither available nor implied. TCC reset/database edits and security disablement are prohibited.
- Affected interfaces: development packaging and the namespaced `nativePort.*` capture-test methods only. Recovered Medal method envelopes remain unchanged.
- Security/privacy/packaging impact: imported payload remains ignored/local; usage descriptions cover microphone, camera and audio capture while screen consent is exercised through the real ScreenCaptureKit picker. This does not grant consent or produce a redistributable package.
- Tests required and actual results: strict/deep signature verification, the actual signed-client/helper protocol route, upstream-ID check and imported-icon hash check pass. Manual Screen Recording grant/deny/cancel/revoke/regrant tests remain pending under `reports/native/m3.2-tcc-prerequisite.md`.
- Source references: `CODEX_MASTER_PROMPT.md` sections 7.1 and 10; `PLATFORM_CROSSCHECK.md` sections 3 and 6; `ACCEPTANCE_TESTS.md` M10.

## Decision D008 — Layer automatic targeting, an in-app chooser and the system picker

- Date / commit: 2026-09-18 / real-video capture checkpoint.
- Problem and evidence: automatic Medal-style targeting is convenient, while the ScreenCaptureKit picker gives clear user-mediated authorization and handles privacy policy changes. A saved process name alone is neither a stable native source nor authorization.
- Selected approach: automatically select only a still-valid authorized SourceRegistry target associated with the detected game/application; provide an in-app enumerated display/window/application chooser when broad Screen Recording authorization permits it; keep the native macOS picker as the first-consent and explicit alternative. Persist stable identities where the API permits, refresh on disappearance, and never convert an invalid window/application target into whole-display capture silently.
- Alternatives and tradeoffs: system-picker-only behavior adds friction to automatic clipping; enumeration-only behavior can require broader permission and provides weaker per-selection consent. Supporting both adds state/UI work but matches user expectations and platform privacy boundaries.
- Affected interfaces: future SourceRegistry, renderer source-selection controls and namespaced native capabilities. The current M3 test uses the system picker only.
- Security/privacy/packaging impact: automatic capture remains bounded by prior authorization and explicit recording settings; autostart must not imply unconsented recording.
- Tests required and actual results: basic picker-selected display and window capture pass. Automatic target reacquisition, in-app chooser, denial/cancel, stale target and no-desktop-fallback tests remain open.
- Source references: `CODEX_MASTER_PROMPT.md` sections 6.3 and 7.2; `PLATFORM_CROSSCHECK.md` section 3; `ACCEPTANCE_TESTS.md` M02/M04/P10.

## Decision D009 — Publish only real hardware codecs through the recovered client controls

- Date / commit: 2026-09-18 / pending M3.3 checkpoint.
- Problem and evidence: the imported renderer already exposes resolution, FPS, bitrate and `Codec` controls with recovered values `H264`, `H265` and `AV1`, driven by `AvailableGPUCodecs`. Decoder support or an Apple-silicon marketing assumption is not encoder evidence. On this Apple M5 Max, VideoToolbox registers hardware H.264/HEVC encoders and no AV1 encoder; hardware-required AV1 session creation returns OSStatus `-12908`.
- Selected approach: publish `gpuDevices`, `gpuCodecs` and `encoderOptions` through the client's existing `setKV` model, advertising only codecs that have a registered hardware encoder. Keep the shared codec type capable of H.264/HEVC/AV1 and reject unavailable hardware session creation explicitly. Use real-time mode, disabled frame reordering, requested average bitrate and `PrioritizeEncodingSpeedOverQuality=false`. Keep H.264 as the compatibility default until container/player/service gates pass.
- Alternatives and tradeoffs: advertising decode capability as encode support would produce a broken AV1 choice. Apple's High Quality preset was not selected for rolling capture because an actual HEVC run retained only one of seven received frames during static-source look-ahead, and forced zero/one-frame caps were rejected. The selected quality-priority real-time configuration encoded 441/441 HEVC frames but is not yet a comparative visual-quality benchmark.
- Affected interfaces: additive shared `VideoCodec`, encoded packet codec tags, macOS adapter capability publication, recovered setting validation and the namespaced capture-test method. Recovered RPC envelopes and client UI remain unchanged.
- Security/privacy/packaging impact: no new permission or account access. Codec probing uses synthetic pixel buffers; the one final ScreenCaptureKit run used the existing stable signed identities and explicit user picker selection.
- Tests required and actual results: signed protocol capability publication passed; four-frame hardware H.264/HEVC probes passed with configuration atoms and bounded completion; AV1 absence/failure was recorded; real signed HEVC display capture encoded 441/441 frames with zero failures. See `reports/native/m3.3-codec-result.md`.
- Source references: `research/PROTOCOL.md`; recovered renderer `Codec` and `AvailableGPUCodecs` handling; local Xcode 27.2 VideoToolbox headers; `ACCEPTANCE_TESTS.md` M03/M11/P01.

## Decision D010 — Preserve portable encoded configuration and use Apple passthrough muxing

- Date / commit: 2026-09-18 / pending M3.4 checkpoint.
- Problem and evidence: the rolling replay must save without transcoding, but a Homebrew libav development link was rejected by hardened-runtime library validation because its dylibs were ad-hoc signed. Supplying only the portable two-byte AAC AudioSpecificConfig to AVFoundation also produced an invalid `mp4a.40.0` description that Apple could not read.
- Selected approach: keep the replay/export data model in shared C++ and implement the macOS container adapter in Objective-C++ with AVAssetWriter passthrough. Preserve portable `avcC`/`hvcC`/`av1C`/AAC AudioSpecificConfig and, separately, AudioToolbox's opaque compression cookie for the Apple adapter. Feed each encoded track through its own AVAssetWriter pull queue, write to an in-profile temporary file, and rename atomically only after completion.
- Alternatives and tradeoffs: disabling hardened-runtime library validation was rejected. Bundling the host's GPL-enabled, dependency-heavy Homebrew FFmpeg graph was rejected as a development shortcut rather than a release-cleared dependency. A hand-written MP4 muxer would increase container correctness risk. AVAssetWriter is macOS-specific, so Linux must implement the same shared export contract with its own tested adapter.
- Affected interfaces: additive encoded-packet audio metadata, shared `write_mp4` contract, macOS export adapter and namespaced test-only `nativePort.saveReplay`. Recovered Medal RPC envelopes remain unchanged.
- Security/privacy/packaging impact: the signed recorder now links only Apple/system frameworks; library validation stays enabled. Test exports are restricted to an absolute `.mp4` path inside the isolated profile, refuse overwrite, and activate atomically.
- Tests required and actual results: synthetic VideoToolbox H.264 plus AudioToolbox AAC survives replay mux and AVAssetReader readback; the real system-audio packet path passes. A post-fix real H.264/AAC replay now passes original contentCreate probe/thumbnail/library insertion, AVFoundation decode, independent ffprobe, imported-Electron playback/seek and full restart persistence. Authenticated original-library UI, HEVC compatibility, editor/service/upload and recovery remain required.
- Source references: `CODEX_MASTER_PROMPT.md` shared export/recovery and native-framework requirements; `ACCEPTANCE_TESTS.md` E01-E04/M05/M07; local AVAssetWriter and CoreMedia headers.

## Decision D011 — Bind physical shortcuts to original actions and acknowledge only completed content registration

- Date / commit: 2026-09-19 / pending M3.5 checkpoint.
- Problem and evidence: Carbon accepted the first F8 and modifier registrations but the helper pumped only the CFRunLoop, so queued hotkey events were never dispatched and the user observed no clip sound or toast. A private `nativePort.saveReplay` command could prove the muxer but would not prove Medal's actual `Hotkeys` → `clip;length=N` behavior. Success feedback before library acknowledgement could also report a clip that the original client rejected.
- Selected approach: keep Carbon entirely behind `PlatformAdapter`, explicitly receive and dispatch Carbon hotkey events from the native helper loop, parse only the recovered `clip;length=N` action grammar, slice the shared timestamp-based replay at the nearest configured keyframe and send the resulting metadata through original recorder-to-client `contentCreate`. Report registration errors honestly. Present feedback only after the original client acknowledges the request, using the exact hash-pinned embedded `ClipEffect.wav`, the recovered notification-volume `/100` conversion and the imported Medal icon in a non-focus-stealing AppKit HUD.
- Alternatives and tradeoffs: routing keypresses through Electron was rejected because operational capture and frame/packet traffic stay native. Treating `RegisterEventHotKey` success as proof of dispatch was rejected after the observed failure. Using Notification Center was not necessary for this local acknowledgement and could request another permission; the HUD is app-owned and non-persistent. A private test-save action remains useful as a component test but cannot satisfy the operational gate.
- Affected interfaces: additive platform shortcut/event-pump/feedback methods, typed shared clip-action parser, helper pending-registration state and namespaced test reporting. The recovered Hotkeys value and contentCreate envelope are unchanged; raw frames and encoded packets never cross Electron IPC.
- Security/privacy/packaging impact: no accessibility/input-monitoring permission is required by Carbon global hotkeys, and no new TCC grant is requested. The official sound is extracted from the pinned user-owned recorder archive without executing it and is not committed. Feedback is local and occurs only for an acknowledged physical action.
- Tests required and actual results: the synthetic Carbon event-pump probe fires once with zero pump errors; the physical `Command+Shift+8` action fires once, writes a keyframe-aligned H.264/AAC MP4, receives original contentCreate acknowledgement and records sound/HUD feedback. F-key/conflict/rebind/layout/suspend/restart/sleep-wake/press-release coverage remains open. See `reports/native/m3.5-operational-replay-result.md`.
- Source references: `research/PROTOCOL.md` action grammar and client handlers; `ACCEPTANCE_TESTS.md` E01-E04/E08; repository requirement to keep platform hotkeys abstract and unsupported RPCs honest.

## Decision D012 — Drive Desktop capture through recovered UI state and permissioned native thumbnails

- Date / commit: 2026-09-19 / pending M3.6 checkpoint.
- Problem and evidence: returning display DTOs with `CurrentScreenshot: null` made the original Desktop cards selectable but blank. Emitting only `captureStarted` changed the main recorder state while the renderer stayed on `Capturing...`; recovered `useGameState` derives its recording category exclusively from the original `gameState` context.
- Selected approach: when the original client requests `activeDisplays({captureScreenshots:true})`, use ScreenCaptureKit `SCShareableContent` plus `SCScreenshotManager` under the deterministic recorder identity, scale to a bounded preview, encode an in-memory JPEG, and return it in the recovered `CurrentScreenshot` field. On native display start/stop, emit the recovered `captureStarted`, `gameState`, and `captureStopped` handlers with one stable UUID and a Screen Capture CATEGORY context whose `metadata.recording` reflects actual native state.
- Alternatives and tradeoffs: deprecated CoreGraphics screen-copy APIs were rejected in favor of the required Apple capture adapter. A private renderer flag was rejected because it would not exercise original Medal behavior. The current synchronous helper request has an eight-second total timeout so failure remains bounded; a future asynchronous cache can reduce UI latency and handle hotplug refreshes.
- Affected interfaces: recovered `activeDisplays`, `captureStarted`, `gameState`, and `captureStopped` payloads; one exact renderer label patch prefers the DTO's existing `FriendlyName`. Raw frames and encoded recording packets remain outside Electron IPC.
- Security/privacy/packaging impact: previews are requested only from the already permissioned signed helper, are not written to disk, and live-screen images are excluded from repository evidence. No TCC reset or global security change is used.
- Tests required and actual results: the original authenticated Desktop selector visibly rendered three previews; original Start Recording transitioned to `Now Clipping / Screen Recording`; original Stop Desktop Capture returned `capturing -> ready` and `Waiting For Game`. See `reports/native/m3.6-desktop-ui-roundtrip.md`.
- Source references: recovered `renderer-useActiveDisplays.js`, `renderer-useGameState.js`, main handler symbols `U7e`/`F7e`/`H7e`; `ACCEPTANCE_TESTS.md` M01/M02/C01/C02.

## Decision D013 — Keep a typed native target identity and resolve ScreenCaptureKit by PID

- Date / commit: 2026-09-19 / pending M3.7 checkpoint.
- Problem and evidence: the original Game chooser automatically listed `ADanceOfFireAndIce` and the Java process used by Minecraft, but the old helper converted the selection into a Windows-shaped JSON object and re-enumerated by name. A real selection then failed with `the selected process is no longer running`, even though the process had been visible moments earlier. The recovered client expects `captionName`/`className` arrays and then sends the successful target to `/games/requests`.
- Selected approach: retain PID, bundle identifier, executable path/name, ScreenCaptureKit application identity and CoreGraphics/ScreenCaptureKit window IDs/titles in `ProcessIdentity`; generate the Medal wire DTO only at the adapter boundary; pass the typed target into ScreenCaptureKit and match `SCRunningApplication.processID` first. Surface Java processes as `Minecraft` only when a real visible window title contains Minecraft, without replacing the native identity.
- Alternatives and tradeoffs: matching only process names is race-prone and ambiguous when multiple Java/game instances exist. Persisting raw Objective-C objects in shared C++ would break the Linux design, so native pointers remain adapter-local and the shared identity is plain value data. Adding a local game database was rejected because the original client already owns authenticated game-request/category classification.
- Affected interfaces: additive `ProcessIdentity`/`ProcessWindowIdentity`, `PlatformAdapter::process_targets`, and target-aware `CaptureSession::start_application`; original `getActiveProcesses`, `getTargetedProcesses`, `setTargetProcess`, `setGameRequestId` envelopes remain unchanged apart from additive diagnostic identity fields.
- Security/privacy/packaging impact: no graphics injection, anti-cheat bypass, TCC reset or global security change. Targeted capture still requires the signed helper's Screen Recording authorization and fails honestly when the PID/window disappears. Window titles and PIDs are held in memory and are not written to reports.
- Tests required and actual results: Xcode 27.2 beta build and 6/6 native CTests pass. The post-change authenticated original UI automatically selected and captured A Dance of Fire and Ice, resolved its category through `/games/requests` plus category search, and emitted accepted original category events; Minecraft fallback/source lifecycle and the replay rerun remain open. The pre-change stale-name/PID failure and the pre-consent TCC failure are preserved in `reports/native/m3.7-process-target-model.md` and `reports/native/m3.7-auto-classification.md`.
- Source references: recovered `hfe`/`h7e` game-request flow in the pinned `main.min.js`; `ACCEPTANCE_TESTS.md` M04/P10; `reports/native/m3.7-process-target-model.md`.

## Decision D014 — Hand authenticated category identity back through the original game-state contract

- Date / commit: 2026-09-19 / pending M3.7 checkpoint.
- Problem and evidence: the native target could be selected, but the imported client needs its original `targetProcess -> /games/requests -> setGameRequestId` flow and category metadata before it will treat the capture as a game. The first authenticated post-consent run also exposed a real server rejection because the recovered `Context.Members` list was null.
- Selected approach: keep native PID/bundle/window identity in the helper, add only the namespaced `nativePort.gameClassification` control notification, resolve the category with the imported client's authenticated `Ehe`/`xd` helpers, and then emit the original `gameStarted`, `captureStarted`, and `gameState` envelopes with `members: []`. No local game database or successful no-op RPC is used.
- Alternatives and tradeoffs: inventing category IDs would make the UI appear to work while corrupting Medal state; omitting the member list fails the real API. The additive namespaced handoff preserves the original protocol boundary and keeps raw frames/packets out of Electron IPC.
- Security/privacy/packaging impact: the path uses the already authenticated isolated profile and prior Screen Recording grant; no upload, TCC reset, global security change, or token logging is performed. The deterministic signed app identity remains `com.squirrel.medal.medal`.
- Tests required and actual results: Xcode beta build and 6/6 CTests pass. The signed original UI/log run shows `nativePort.gameClassification`, category `lRhniATDdq` / `A Dance of Fire and Ice`, and accepted category `gameState` with `members: []`. Minecraft fallback, target disappearance/window recreation, game-only audio and the post-change physical replay round trip remain open. See `reports/native/m3.7-auto-classification.md`.
