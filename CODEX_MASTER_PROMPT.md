# Codex implementation brief: native Medal compatibility client + recorder

## 0. Mission and working mode

Implement a maintainable product, not just another architecture report or a recorder demo. The product has a local importer/patcher that consumes a user's own official Medal Windows installer, runs the recovered Medal Electron application with a native host, and connects that application to our separate, native cross-platform recorder.

Develop and test **macOS first: Apple silicon, arm64, macOS 27, stable Xcode with the macOS 27 SDK**. Preserve a portable common implementation and then continue this same repository on **Linux x86-64**, implementing and testing its native backend there. Linux work must not fork/rewrite the wire protocol or silently regress macOS.

Default product architecture: native Electron + targeted client compatibility patches + a C++20 common recorder core + Objective-C++ macOS backend + C++ Linux backend. No Wine, Rosetta, Windows recorder, OBS installation, browser MediaRecorder or JavaScript raw-frame pipeline in the final capture path. OBS may be an optional development comparison tool only; do not make it a runtime prerequisite.

Continue beyond first recording: implement the library round-trip, audio, replay, sessions, settings, hotkeys, camera, supported effects, editor/export paths, recovery, packaging and performance work below. Do not stop after producing scaffolding or a short silent MP4. Do not mark a feature implemented because a stub returns success. For an OS- or service-specific feature, investigate the real capability and implement the best supported equivalent; document precise limits with evidence rather than manufacturing parity.

Make code changes, run tests and keep progress files current. Use small independently testable increments. When a required interactive permission/account/signing action is unavailable, record the exact missing action and continue independent work. Do not bypass consent, fake a successful authorization, or misclassify a skipped test as passed. Avoid repeatedly asking broad design questions already resolved here.

Read `AGENTS.md`, this entire brief, `PLATFORM_CROSSCHECK.md`, `ACCEPTANCE_TESTS.md`, `SOURCES.md`, `FEATURE_LEDGER.json`, and the supplied `research/` documentation before changing compatibility behavior. The original recovered evidence is build-specific, not a vendor specification. On Linux also read `LINUX_CONTINUATION_PROMPT.md` and the actual macOS handoff.

## 1. Inputs and evidence hierarchy

Expected local inputs (the user must place these in `inputs/`; conversation uploads do not automatically appear on another computer):

- `Medal-production-2637.461.1-Setup.exe`
- `v2638.2751.1.zip`
- Optional original recorder version-response markdown/JSON.

Pinned fingerprints:

```
installer SHA256 e6477e89f968593fe4b8335f09fc25f81889dd412c28ff85522a0a37415decdb
recorder  SHA256 d33c6e3c0506c1f6b71e6158716fda3a9866bfacc41060f2ec29c4d792ca1312
main.min.js     5a2a6dd5d1370a15577b0c09bc2d021059e2f9e7dba6a2e40cc41b4685e0c8ff
client version 2637.461.1
recorder version 2638.2751.1
observed packaged Electron 43.2.0
observed Windows native binding directory node-v148-win32-x64
```

The supplied EXE can be read as a ZIP without executing it. Its application is in `lib/app/resources/app.asar` plus unpacked resources. The original extractor recovered 1,582 files and verified 999 packed integrity records. Five unpacked entries differ from their ASAR metadata; the report records these discrepancies. Do not suppress them or assert publisher authenticity from a hash comparison. Research inspected the supplied bytes, not the publisher's signing chain.

Keep original inputs read-only and out of Git/release assets. Do not execute the Windows installer, the recorder's dependency downloader, or npm lifecycle scripts from the extracted application. Do not install the original package's private `workspace:*` dependencies; its distribution already contains bundled outputs.

Use `research/evidence/test_symbols.json` and fingerprinted AST/call-site matches to locate code. Names like `K7e`, `$at`, `m7e`, `gfe`, `w5`, `Ro`, and `lhe` are only anchors for this build. An unexpected fingerprint means inspection/new-adapter work, not fuzzy production patching.

Research already contains an isolated 12-test suite. It has been reproduced in a Linux container with synthetic H.264/AAC media and adapted Electron/database dependencies. It does NOT establish full GUI startup, actual better-sqlite3 compatibility, account login, upload, camera/audio capture, hardware encoding, permissions or packaging. Preserve this distinction in reports.

Evidence priority: tested original behavior on the pinned build; original call sites/CLR metadata with scope noted; installed platform headers and compile/runtime probes; official platform documentation; explicit engineering inference. Never convert inferred CLR DTO casing or enum values into claimed observed wire traffic.

## 2. Repository and implementation choices

Use this structure or a clearly equivalent one; keep platform code behind explicit interfaces:

```
inputs/                          # ignored, user-owned upstream archives
research/                        # recovered documentation and tools
spec/                            # wire schemas, settings, capabilities, transcripts
packages/importer/               # TypeScript CLI and later setup UI integration
packages/client-adapter/         # audited patches/host bootstrap/preload UI integration
patches/2637.461.1/               # exact predicates, hashes, original/patched checks
native/core/                     # C++20: protocol, settings, state, packets, replay, jobs
native/backends/macos/           # Objective-C++, ARC, native Apple framework use
native/backends/linux/           # C++, GDBus, PipeWire, native media/graphics APIs
native/optional/speech-macos/    # small Swift module only if SpeechAnalyzer needs it
native/tools/                    # diagnostics and synthetic frame/audio generator
third_party/                     # dependency lock/provenance, not vendored OS drivers
packaging/macos/                 # host/helper Info.plist, entitlements, signing
packaging/linux/                 # .desktop integration and package definitions
scripts/                        # doctor/build/test/package commands
fixtures/                        # nonprivate fixtures; original code extracted locally
artifacts/                      # ignored outputs
reports/                        # structured test/performance evidence; redact secrets
```

Build common/native code with **CMake, Ninja and C++20**. macOS uses Apple clang and Objective-C++ with ARC; use AppKit for the helper's application lifecycle and native picker UI. This is native Apple API access; a full Swift rewrite is unnecessary. Keep Apple types out of public common-core headers. A small Swift bridge for a Swift-only speech API is acceptable, not a second recorder state machine.

Use **Boost.Beast/Asio** for the helper's bidirectional WebSocket control transport and **nlohmann/json** for explicit serialization. Keep the network/control executor off real-time callbacks. Avoid implementing the WebSocket protocol from scratch. No remote helper control listener is required: the helper connects only to its parent client. Pin audited dependency versions and hashes; do not use floating branches.

Use **libavformat/libavutil** for a shared encoded-packet MP4 writer, with needed FFmpeg dependencies pinned and licensed. Use **VideoToolbox directly** for macOS video and **AudioToolbox AudioConverter** for native AAC. Linux uses **libavcodec** hardware encoder integrations and AAC, with libswresample where needed. No FFmpeg CLI pipe in the normal capture loop. Bundled native ffmpeg/ffprobe remain available for the existing client editor, thumbnails, probing, recovery and explicit conversions.

Use TypeScript for our importer/client patches and Node's test runner for control tests. Reuse/harden the Python extractor initially; final end-user setup should not require Python, Node, Xcode or a package compiler. Expose importer functions from a packaged native Electron bootstrap so a user can select the installer in a setup window. Build tools may require these development dependencies. Use explicit, locked public dependencies such as @electron/packager, @electron/rebuild, @electron/asar, @electron/osx-sign and @electron/notarize where appropriate. Validate compatibility before pinning actual versions.

Start from target-native **Electron 43.2.0** to minimize changes to the inspected client; verify official target artifacts and runtime `process.versions` values. Do not assume `node-v148` for a different runtime or use external Node's ABI to build an Electron addon. Upgrade Electron only as a separately tested security/compatibility change. A platform-independent source API does not mean binaries can be copied between arm64 macOS and x64 Linux.

## 3. Required client importer and bootstrap

### 3.1 Safe deterministic import

Implement `inspect`, `prepare`, `patch`, `verify`, `launch`, `rollback`, `uninstall-port` and a corresponding setup UI. Command names may differ, but the behavior must exist.

Validate SHA-256 before applying known patches. Safe-extract ZIP/ASAR with traversal, symlink, case-folding/Unicode collision, entry-count and expanded-size protections. Do not overwrite an official installation, existing output, clips or profile. Stage on the same filesystem, validate, then activate atomically. Record per-file patch fingerprints and patch counts. Each transform has an exact precondition, exactly the expected number of matches, a postcondition and a regression test. Idempotent re-running either reports already prepared or creates a new version; never applies the same patch twice.

Maintain separate port-owned userData, logs, cache, pending-export journal and clip-storage paths. Separate profiles by test/production and platform; migrate only via backed-up, tested explicit workflows. Default setup is a fresh normal login, not copied Windows credentials. Preserve local clips through rollback and uninstall unless the user independently chooses deletion.

### 3.2 Native runtime and SQLite

Retain upstream main/renderer/preload code where compatible. Resolve all native executables using verified absolute packaged paths, not the terminal PATH. The client needs a true Electron-compatible native SQLite addon, not a Node test substitute.

The two known `.node` dependencies are better_sqlite3 and Velopack. Locate the exact bundled JS wrapper/version/any native API customizations. Build or obtain the compatible addon source, compile for Electron/OS/arch, and validate every exercised API. Do not assume the newest upstream better-sqlite3 is a drop-in. If matching source is unavailable, build a narrowly scoped compatibility implementation backed by a known SQLite version and test the worker API exhaustively; record that it is a replacement, not a rebuild of unknown source.

The client uses SQLite JSONB and json_extract. Test worker initialization, all schema migrations, prepared statements, JSONB expressions, transactions, WAL/locking, close/reopen and recovery with the real native addon under Electron. Replace `lib/sqlite3.exe` for recovery with a packaged native CLI and correct argument handling. Do not let the original sqlite asset downloader overwrite target-native binaries.

### 3.3 Updater and supervisor

Patch BOTH updater entry points: the try/catch in index.js AND the independent top-level Velopack import/integration in main.min.js. Supply a deliberately disabled/manual upstream-update state during development; implement coherent port-controlled updates before release. Do not simply return success from an updater stub.

Replace the original recorder AssetManager/download/install/copy-hardlink flow, not only the helper executable path. Prevent automatic restoration of Windows recorder DLLs, native addons or FFmpeg. Version the compatible client payload, patch adapter, native dependencies and helper as a tested set. Unknown upstream builds fail closed with an actionable message. Atomic updates need rollback and data-schema compatibility checks; file rollback alone does not reverse an irreversible DB migration.

Replace `RecorderHandler2.run()`'s win32-only behavior, executable resolution, Windows liveness/elevation/tasklist/PowerShell paths and kill logic with a native process supervisor. Preserve upstream lifecycle states and `RecorderHandler2:state` / `RecorderHandler2:stateChange` IPC. Do not globally spoof process.platform. The production `MEDAL_ENCODER_EXE` variable is not an unconditional override; change the actual adapter path. `NO_RECORDER=1` is only useful for initial isolated bootstrap, not a final solution.

Open the selected localhost server before spawning the helper. Pass `--electronPort <actual-selected-port> --environment <actual-channel> --wsComms`. Start probing at the original port if retained, but never hardcode the helper to 10603. Run exactly one helper per client profile. Monitor exit/socket state, bound restart backoff, distinguish intentional shutdown and crashes, and avoid restart loops when permission is denied. Terminate capture on parent death by default; do not create an unattended privileged recorder.

### 3.4 Editor, shell integration and accounts

Audit every ffmpeg/ffprobe/sqlite invocation and path-dependent reader/writer. Replace Windows-specific codec names, devices, filters, quoting, drive/UNC assumptions and file URI construction where needed. A binary path substitution alone is insufficient. The recovered non-Windows remux function returns null: implement the intended behavior and test actual trim/export pipelines. Test spaces, Unicode and user-selected external clip folders.

Preserve original feed/login/library/settings/editor/upload behavior where valid. Test video playback, thumbnails, scrubbing, trimming, export, audio-track controls, library reload and an explicitly authorized private upload separately. H.264/AAC SDR is the interoperability baseline. Native HEVC encode support does NOT prove Chromium playback, editor compatibility or service acceptance; probe all three and offer a transparent compatibility proxy/transcode where necessary.

Trace the Windows-guarded hardwareId → capabilities/JWT path and the proactive client `user` send that has no matching recorder declaration in the recovered inventory. Preserve real service authentication and paid entitlements. Define a legitimate port installation identity only if compatible with actual service expectations; do not impersonate Windows hardware, forge tokens or locally grant paid features. Keep backend hardware capabilities separate from account capabilities. A service refusal must remain visible. Do not forward authentication material unnecessarily to the native media core or logs.

Implement menus/keyboard conventions, tray/status behavior, normal file dialogs, Open/Revealer actions, URI/deep-link dispatch and single-instance rules. Derive the upstream login callback behavior from code; do not arbitrarily change OAuth callbacks or take over an existing official URI handler without user choice. Native autostart must be user-controlled and must not mean automatic unconsented capture. Preserve the original renderer security boundaries; don't add broad Node access, disable web security/TLS, or expose unrestricted IPC for convenience.

## 4. Exact Medal control protocol

`research/PROTOCOL.md` and its evidence files are the recovered contract. Generate executable tests and explicit C++/TypeScript schemas from confirmed shapes; do not assume metadata inventories are complete JSON Schemas.

### 4.1 Direction, envelopes and connection

Electron is the WebSocket SERVER at 127.0.0.1; the recorder is the connecting CLIENT. Both sides can initiate JSON-RPC requests/notifications on the same connection. No browser Origin header is accepted in the original predicate.

Helper sends:

```json
{"jsonrpc":"2.0","id":1,"method":"handshake","params":{"supportedVersions":[1],"preferredVersion":1}}
```

Client response:

```json
{"jsonrpc":"2.0","id":1,"result":{"result":"success","errorMessage":null,"data":{"version":1,"capabilities":[]}}}
```

Validate `result.data.version`; an incompatible handshake can return nominal success with empty data. Client-handler responses have the extra Medal envelope. Helper-handler responses are ordinary JSON-RPC results. Helper `availableMicDevices` returns a raw array; no-value Task handlers are expected to return null for requests, subject to actual transcript validation. Notifications receive no response. Preserve -32601 for unknown methods and proper errors for invalid params/internal failure; never fake success.

Client-side ping gives envelope data `pong`. Recorder-side ping is declared a no-value Task. Recovered timings: recorder heartbeat interval 20 seconds, two missed attempts before disconnect logic, recorder request timeout 15 seconds, client wrapper timeout 10 seconds. Use independent correlation IDs, request maps, cancellation and bounds; handle simultaneous requests, ping control frames, JSON-RPC ping, fragmentation and text payload limits correctly.

Add a **private local authentication extension on both endpoints**: per-launch 256-bit random secret from the parent, transferred over an inherited pipe/FD, not command-line arguments or logs. Verify in the WebSocket upgrade, admit the intended helper, bind only loopback, reject wrong/stale secrets, and rotate on restart. This is not cloud authentication and not a defense against fully compromised same-user processes. Preserve Origin rejection. Test token-free diagnostic mode separately, never silently enable it in production. Keep unpatched compatibility tests as well as private-extension tests.

`recordingReady` means initialized/able to handle requests, not that frames are recording. Publish it only once device/state initialization succeeds; permission/source selection may still be required and must be visible. `captureStarted` must reflect successful native capture, not receipt of a start request. Honor shutdown notification and close reason `shutdown`, drain/finalize safely with a bounded timeout.

### 4.2 Required method inventory

There are **34 recorder RPC declarations**, **40 client handler names**, and **60 recorder setting keys** in the pinned evidence. `FEATURE_LEDGER.json` preserves all names. Track every entry as implemented+tested, conditional with evidence, not applicable with correct UI behavior, or unresolved. Do not claim all 34 are understood merely because their names are known.

Core lifecycle/config: ping, settings, shutdown, hardwareId, deleteAllCustomGameSettings, deleteCustomGameSettings.

Device queries: activeDisplays, availableAudioDevices, availableMicDevices, getDefaultAudioDevices, webcamDevices, gameSoundAudioDevice, micAudioDevice, audioProcesses.

Targets: setTargetProcess, deleteTargetProcess, getTargetedProcesses, getActiveProcesses, setGameRequestId, switchGameRecording.

Capture/actions: clipRecovery, toggleSessionRecording, toggleBroadcast; hotkey listening/rebinding/suspension; micTesting, voiceCommandsTesting, soundAlertTest.

Conditional/OS-specific: gamePluginsInstalled, installGamePlugin, uninstallGamePlugin, autoClipEvents, windowsGameMode. Preserve exact parameter names and return shapes from PROTOCOL.md, not shorthand above. Windows Game Mode is not macOS Game Mode or Linux GameMode; don't substitute another service without a separate explicit feature.

### 4.3 Settings, DTOs and source IDs

`settings` params contain a `settings` ARRAY of `{key,value,categoryId}`, not a flat map. Preserve global/per-game scope, types, merging, deletion and order-sensitive transitions. Inspect all 60 keys. Trace units, codec enum values and defaults in the client before mapping. Known conversions include MicSoundGain /100, AudioNotificationVolume /100, ExternalFileSources stringification and nested Hotkeys. **Bitrate's precise client-to-recorder conversion remains a research task**: prove it through the UI, transformed RPC and actual encoder settings. Do not guess Mbps/kbps/bps.

ScreenInfo uses PascalCase DeviceName/FriendlyName/CurrentScreenshot/IsPrimaryScreen. Default audio devices use input/output. Process DTOs have explicit camelCase rules; active-process captionName/className are arrays, targeted-process fields differ. Webcam DTO fields include id/label/value/type. Use explicit serializers; preserve null/empty distinctions required by the client. Trace screenshot encoding/path behavior before implementing thumbnails.

`setTargetProcess` receives `{data:{processName:...}}`, not a PID-only object. Native sources need a private SourceRegistry with stable identity where possible, a per-session handle, display label, source kind, current authorization, optional process association and loss notification. A saved process name is not an OS capture authorization. Never turn an invalid game/window target into whole-desktop capture silently. Keep native permission tokens out of Medal service requests. For sources without a meaningful process identity, patch the selection UI rather than fabricate one.

Publish actual backend capability/device lists through observed setKV mappings (gpuDevices, gpuCodecs, encoderOptions, micDevice/gameDevice and related session keys) only after recovering their nested value shapes. Don't invent NVENC/NVAPI devices on macOS. Add a distinct versioned `nativePort.*` capability extension for native source picker, effective capture path and unsupported reasons. Patch only our UI integration to understand it; do not reinterpret the empty original handshake capabilities array.

### 4.4 Actions and private extensions

No observed saveClip/saveLast30Seconds RPC exists. The original `Hotkeys` setting carries actions like `clip;length=30`, segment_toggle, bookmark, switch_game and screenshot. Implement an ActionDispatcher that receives validated actions from native hotkeys, optional voice commands and a patched local button. Different triggers share the same export logic.

A private extension such as `nativePort.performAction`, `nativePort.selectSource`, `nativePort.getCapabilities` and async job-status events may be added to both our client adapter and helper. Clearly mark it as NEW, negotiate its version independently, validate arguments, authenticate it, and test it. Long permission dialogs and exports must not block the original 10-second request wrapper: return a truthful accepted job state in our extension and later completion/error, while preserving original method semantics.

Operational shortcuts and the UI's 'listen for new hotkey' mode are different states. Implement conflict reporting, cancel, suspend/resume, press/release, hold/toggle behavior and actual registered-binding display. Never install both Electron and native listeners that fire the same action twice.

## 5. Native macOS backend (primary deliverable)

### 5.1 Native helper and permissions

Build a genuine arm64 helper application with a stable, project-owned bundle identity, application run loop, main-thread AppKit operations and a controlled parent-launched lifecycle. Suggested project names are NeutralPortHost and NativeRecorder; label affiliation honestly. Don't impersonate Medal's signing identity.

Use Xcode's actual macOS 27 SDK. Record `sw_vers`, `uname -m`, `xcodebuild -version`, `xcrun --sdk macosx --show-sdk-version`, compiler/SDK path and whether any executable runs translated. Deployment target is macOS 27 for this first deliverable; older OS support is not required. Verify every named symbol/deprecation by compiling small probes rather than inventing macOS 27-only APIs.

Capture permission belongs to the actual responsible process/code identity; test attribution in the packaged host/helper combination, not only when launching from Terminal. Include correct NSMicrophoneUsageDescription and NSCameraUsageDescription, plus NSAudioCaptureUsageDescription where process-tap/system-audio capture requires it. Do not invent an NSScreenRecordingUsageDescription key or treat an Info.plist string as permission. Request the actual OS authorization/picker workflow. Grant only entitlements actually needed by each binary; Electron JIT needs and recorder privileges are not identical.

Normal recording runs as the logged-in user. No root daemon, kext, screen-permission database edits, silent TCC reset, security-disable script or mandatory virtual audio driver. Parent process loss, permission revocation, screen lock/session change and OS stop-sharing events must stop or visibly suspend according to a documented privacy-first policy.

### 5.2 Capture source selection and frame delivery

Primary APIs: SCContentSharingPicker, SCContentFilter, SCShareableContent, SCStreamConfiguration, SCStream, SCStreamOutput. Present the native picker from the helper's main thread. Handle selection, cancellation, filter changes and OS-initiated termination. Add a native source-selector button/status to Medal instead of depending exclusively on its Windows process list. Use direct enumeration only within granted permissions; refresh without continuous broad scanning.

Support displays, individual windows and applicable application filters. A desktop-independent window filter is useful when a window moves between displays. Handle Retina point/pixel differences, crop geometry, window resize, multiple monitors, rotation, fullscreen Spaces and display disconnect. Test minimized/occluded/offscreen behavior on the target OS and report it accurately; never claim Windows injection-equivalent behavior. Never silently enlarge a window capture into a desktop capture on failure.

Get CMSampleBuffer video from SCStreamOutput. Validate readiness and frame status, preserve content rectangle/scale/color attachments, and extract the CVPixelBuffer/IOSurface-backed surface without a CPU image roundtrip. Set a modest bounded queueDepth based on the SDK and measured behavior; it is NOT a replay buffer. Release capture-owned buffers promptly after their GPU/encoder consumers finish, or perform an explicitly measured GPU copy into an owned pool when retaining the producer surface would starve capture.

Default baseline is configurable 1920×1080 at 60 fps, H.264 SDR and 48 kHz audio, provided actual hardware/source capability permits it. These are starting test settings, not guarantees for all games/hardware. Honor source cadence and rational timestamps. Don't label unchanged-screen idle samples as dropped frames.

### 5.3 GPU processing and video encoding

Use CoreVideo CVMetalTextureCache and Metal only when cropping/scaling/compositing/color conversion requires processing beyond ScreenCaptureKit output configuration. Avoid drawing every frame merely to use Metal. Prefer a tested native YCbCr path directly to VideoToolbox for plain capture; for effects, use owned IOSurface-backed CVPixelBufferPool buffers with explicit Metal/VideoToolbox-compatible attributes, plane layouts and completion/lifetime tracking.

Use VTCompressionSessionCreate/EncodeFrame/CompleteFrames/Invalidate directly. Request hardware via kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder when hardware mode is selected; query kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder and report the actual encoder path. Query supported properties before setting them. Configure real-time behavior, bitrate, GOP/keyframe interval and frame reordering intentionally. Start with a short closed-GOP, no-B-frame configuration for correctness; improve quality only after timestamp/export tests pass. Never assume every VideoToolbox H.264/HEVC/AV1 option is supported on every Apple silicon chip.

Convert encoded CMSampleBuffers into a portable packet representation with codec, track ID, codec-configuration generation, PTS/DTS, duration, timebase and keyframe/dependency information. Correctly transfer H.264/HEVC parameter sets and sample framing into the muxer's format; don't confuse Annex B data with length-prefixed MP4 samples. Treat AAC configuration/priming equally carefully. Test decoding exported files from their first sample and seeking near both ends.

HDR is a later required capability-gated feature, not 'set HEVC=true'. Use supported ScreenCaptureKit HDR configuration/presets, appropriate 10-bit formats, actual color primaries/transfer/matrix/range metadata, and validated HEVC profiles. Preserve or deliberately tone-map colors with a documented transform. Disable incompatible UI combinations. Verify HDR playback/editor/upload and an SDR compatibility path. Don't infer HDR from pixel size alone or promise unsupported 4K/120-fps/AV1 profiles.

SCRecordingOutput can be an optional smoke test/oracle for a simple continuous file. It is not the primary engine because our design needs encoded replay ownership, controlled track semantics, compositing and common export/recovery behavior. No claim is made that ScreenCaptureKit itself provides a 'last N seconds' buffer.

### 5.4 Audio: screen, system, process and microphone

For ordinary screen/game recording, use SCStream's audio output plus its microphone output (`captureMicrophone`, `microphoneCaptureDeviceID`, SCStreamOutputTypeMicrophone) where appropriate. Do not open a second AVAudioEngine microphone simultaneously for the same recording by accident. Native device discovery/settings map to stable CoreAudio/AVFoundation identifiers; keep user-facing labels separate and resolve duplicate names.

SCStream audio filtering is application-level, not necessarily one audio stream per window. For independent game/application audio selection, device-targeted routing or audio-only capture, implement a separate **Core Audio process-tap backend** using Apple's sample and the installed SDK. Relevant APIs include CATapDescription, AudioHardwareCreateProcessTap and private aggregate-device/IO-proc lifecycle; verify exact signatures and process AudioObjectID translation. OS PIDs and Core Audio process object IDs are different identifiers. Preserve normal playback: do not mute/replace the system output or change global audio defaults simply to capture. Clean up taps/aggregates on success, failure and crash reconciliation.

Use AVAudioEngine/CoreAudio for standalone microphone testing or additional microphone modes when no SCStream mic is active. Choose one microphone owner and define the switch lifecycle. Respect camera/mic privacy permissions separately. Never silently capture all system audio when 'game only' cannot be satisfied; return an actionable state and let the user deliberately select a broader source.

Build a bounded float-PCM mixing/DSP layer for gain, mute, mono, noise gate, push-to-talk and optional suppression, followed by native AudioConverter AAC compression. Use AVAudioConverter or AudioToolbox conversion to a common rate when needed. Do not assume system and microphone buffers have equal sizes/rates or an identical start time because they came from one SCStream. Normalize timestamps to a common monotonic timeline; track drift, packet gaps, resampling ratio and device-change discontinuities. Maintain channel layouts, avoid clipping when mixing and test Bluetooth sample-rate changes and USB hotplug.

Noise suppression is a separate feature from a noise gate. Evaluate Apple's native voice-processing path only where it integrates without double capture or unwanted routing/latency changes. A small opt-in, licensed RNNoise backend is an acceptable portable fallback after a source/license/performance audit; do not advertise native system suppression when using a different algorithm. Default expensive speech/suppression processing off unless the user's settings request it.

Implement actual multi-track audio semantics expected by the client editor. Recover ordering/labels/metadata from code and test fixtures before choosing mixed/game/mic tracks. Extra MP4 audio tracks alone do not prove Medal can edit or upload them correctly. Mute/push-to-talk must affect both isolated tracks and the mix consistently.

### 5.5 Camera, shortcuts, screenshots, feedback and voice

Use AVCaptureDevice/AVCaptureSession/AVCaptureVideoDataOutput for webcam frames and permissioned camera discovery. Composite through Metal using the same configured scene geometry as preview/export. Test camera removal, virtual cameras and Continuity Camera only when available. Do not label untested device classes supported. A low-rate preview must not become a second full-resolution recording pipeline. Handle ScreenCaptureKit system Presenter Overlay/effect-start/effect-stop callbacks explicitly: it can supply already-composited frames and change normal camera delivery. Do not double-composite the webcam or treat a system effect transition as a lost camera. Test both the project's recorded overlay and system-managed effects when available (S03).

For registered macOS key combinations, prefer a native registered-hotkey API available in the SDK (RegisterEventHotKey with pressed/released events if still supported). Compile/probe it on macOS 27. Use a consented CGEvent tap only for input modes that truly need it and advertise the extra permission; no broad hidden keyboard monitoring. An Electron globalShortcut adapter is acceptable for initial single-action tests, but it does not on its own implement complete push-to-talk key-release semantics. Rebinding capture must not leak unrelated keyboard input into logs.

Use SCScreenshotManager for permissioned screenshots; trace the original content/thumbnail event shape before registering screenshot items. Use local notifications/AppKit feedback for saved clips; recorded webcam/text graphics are not the same thing as Windows injected game overlays. A HUD visible over fullscreen apps needs its own actual platform test. Don't report overlayInjected without injection or mislabel compositor feedback as an injected overlay.

Implement optional on-device voice clipping through SpeechAnalyzer/SpeechTranscriber if the installed SDK, language assets and supported device permit it. A thin Swift module may bridge this one feature to C++. Check asset availability, obtain user approval for downloads, measure memory/CPU, and do not silently fall back to remote recognition. Linux will use a separate optional provider. Phrase/action configuration must feed the same ActionDispatcher and produce accurate original voice-test events where their semantics are recovered.

## 6. Common replay, session and library engine

This is shared C++ code from the start, not a future Linux rewrite.

Define strongly typed interfaces for SourceRegistry, backend capabilities, SettingsStore, ClockMapper, EncodedPacketSink, ReplayStore, ExportJob, ClipOutbox and ActionDispatcher. Native frames remain backend-owned opaque RAII resources. Core timestamps are signed integer/rational values with explicit conversion; never millisecond wall-clock doubles for media synchronization. Translate createdAt wall-clock milliseconds only at the library boundary.

Replay stores **encoded video/audio**, not tens of seconds of raw pixels. Keep an explicit byte/time budget and retain the decoder configuration and prerequisite keyframe for any retained interval. Reference-count/export-snapshot packets so simultaneous saves don't duplicate an entire ring. Bound export concurrency and memory; capture must not block waiting for disk, JSON-RPC or a slow upload.

At 20,000,000 video bits/sec, 30 seconds is about 75,000,000 bytes of video payload before audio/keyframe/headroom. This is a planning calculation, not a measured memory target or Medal bitrate unit. Report actual occupied bytes and retention, enforce hard limits, and switch to an explicitly selected disk-backed policy rather than silently exhausting memory.

Define replay duration policy. Fast export may start at the preceding random-access point and contain up to a GOP of preroll; label requested versus actual duration. Exact frame-accurate trim requires a validated edit-list/player path or boundary re-encoding; don't claim stream-copy can start decoding on an arbitrary dependent frame. AAC priming, A/V start offsets, B-frame dependencies, codec changes and timestamp rebasing need fixtures. Never concatenate unrelated codec configurations into one invalid track.

Implement continuous sessions, start/stop/bookmark/segment toggles, game/source changes and per-game settings. Decide which changes can occur live and which start a new encoding generation/segment. Recover client contentUpdate/session completion behavior before marking full-session support. Keep replay and full-session retention/storage policies independently bounded.

Use libavformat for finalized MP4 exports and a recoverable segmented/disk-backed format for long sessions. Flush and close, validate media, atomically publish on the destination filesystem, then call original `contentCreate` with the tested shape. Cross-volume moves require a safe copy/fsync/rename sequence. Don't make the MP4 visible as complete before its headers/trailer are valid. Never delete the only good recording when registration fails.

Client owns its library DB. The tested path is contentCreate → original m7e → gfe → w5 → probe/thumbnail/library → uuid/contentId acknowledgement. Use native absolute paths and stable UUIDs. The earlier synthetic category/process fixture is NOT a real service category. Derive valid normal/manual-source metadata and game categories from actual client behavior. Keep unsupported metadata absent rather than invent values.

Persist a port-owned outbox for pending exported files, not a second Medal library. Handle lost ACK, helper/client restart, original client renaming, library deletion and user storage policy. Prove idempotency using UUID reconciliation against the client's actual code; don't blindly resend contentCreate if it creates duplicates. A small authenticated client-side deduplication patch may be needed. Test crash before export, after export/before notification, after DB insertion/before ACK, and during file rename.

Cloud operations stay under normal original client behavior and user-selected privacy/auto-upload settings. Test explicit private upload only with consent; no public uploads in an automated fixture. Record offline-library capability separately from authenticated service behavior.

## 7. Linux backend contract (design now, implement/test on Linux)

Reuse core, protocol, exporter, settings/actions, importer and client patches. Do not ship an Apple build or try to translate Metal calls. Linux gets its own capture/graphics/audio implementations.

### 7.1 Desktop identity and portal source selection

Implement direct **GDBus/GIO** calls to org.freedesktop.portal.Desktop, with gio-unix FD passing; use native PipeWire C/SPA APIs for media. A wrapper such as libportal may be substituted only with a documented dependency/licensing decision and tests; no need to embed GTK solely to call the portal.

CreateSession → SelectSources → Start → OpenPipeWireRemote, handling asynchronous Request.Response and Session.Closed. SelectSources/Start are not reusable arbitrary setters: manage session recreation correctly. Introspect interface versions and AvailableSourceTypes/AvailableCursorModes. Install and use a stable reverse-DNS .desktop identity matching the actual requester. Forward a valid parent-window/activation token only when the host can export one; otherwise use the documented unparented route, not a guessed Wayland handle.

Use the granted FD with pw_context_connect_fd. Current ScreenCast v6 can return pipewire-serial; prefer it/PW_KEY_TARGET_OBJECT where available. Older backends need a session-scoped node-ID fallback with destruction/reconnection checks. Never persist a numeric PipeWire node ID as a durable source identity. Store and rotate single-use restore tokens, handle revocation/missing sources and present the picker again. Capture permission is not permission to enumerate all Wayland windows or target a new game silently.

Linux audio uses a **separate normal-session PipeWire connection** and actual policy-granted graph access; the ScreenCast remote does not expose arbitrary microphones/system nodes. Camera access similarly has its own Camera portal path. Detect missing desktop services and report installation/configuration requirements instead of hanging or requesting root.

### 7.2 Native frames and encoders

Consume PipeWire buffers/SPA format metadata. Negotiate valid dimensions, formats, strides, plane offsets and buffer kinds. Prefer DMA-BUF on a compatible GPU pipeline. Use libdrm/DRM format information and AVDRMFrameDescriptor for representations. Respect modifiers, fences, producer/consumer ownership and buffer recycle timing. pw_stream_queue_buffer returns capture storage to the producer; do not queue it while an encoder/GPU still reads it. Do no blocking work or allocations in real-time process callbacks.

Primary Intel/AMD path: query VA-API driver profiles/entrypoints, use a compatible hardware-frame context with libavcodec h264_vaapi/hevc_vaapi, and use VA-API processing for simple scaling/conversion where supported. Advanced compositing may use EGL/OpenGL through libepoxy with negotiated DMA-BUF import/export; validate EGL extensions and every plane/modifier. Do not require Vulkan merely because Windows uses Direct3D. Add a Vulkan backend only if a measured need justifies it.

NVIDIA path: query actual NVENC support/driver requirements and use libavcodec h264_nvenc/hevc_nvenc. Implement a tested GPU import path where supported. Do not promise every compositor's DMA-BUF imports directly into CUDA/NVENC. Multi-GPU and unsupported modifiers may need an explicit copy path; report it. Optional AV1 only after hardware, driver, container, client and service tests.

Probe by opening an encoder and encoding/decoding real samples, not merely listing FFmpeg encoders. Software fallback is explicit and visible, preferably with lower-cost settings, never labeled hardware accelerated. User drivers remain system-provided; do not redistribute arbitrary vendor drivers or require root/KMS capture for normal operation. No universal zero-copy or FPS-impact claim without per-machine measurements.

### 7.3 Audio, camera, shortcuts and X11

PipeWire handles device discovery, default changes, mic sources, sink monitors and policy-allowed per-application streams. Bind by stable identities and actual session mapping, not transient numeric IDs. For game-only capture, identify the real playback stream(s), including child processes/Proton where applicable, and prove isolation with a second app playing distinct test audio. A whole-output monitor is not game-only audio. Do not change the user's default audio sink or quietly fall back to all applications. Keep the shared DSP/timeline/track/export logic.

Use the Camera portal/PipeWire for the portal-friendly webcam path; native V4L2 is a tested optional nonsandboxed fallback. Permission denial, camera unplug and format changes require clean failure. Composition geometry and output metadata must match macOS.

Use GlobalShortcuts portal CreateSession/BindShortcuts and Activated/Deactivated signals for actions and hold/release behavior. Test actual assignment/cancel/conflict/reconfigure flows. The user's chosen portal bindings override requested preferred triggers. Missing portal support must show a clear capability limitation and an in-app trigger or documented compositor binding alternative; don't add invasive input capture or root access. Avoid duplicate listeners with Electron globalShortcut.

Support a native X11 fallback separately if a release target needs it: XCB/XComposite/XDamage/XShm for capture, XRandR for displays and tested native key grabs for actions. XWayland visibility does not equal all-Wayland-window access. Reuse PipeWire audio. Do not claim Linux complete based only on Xvfb, X11, or a VM without GPU hardware.

### 7.4 Packaging and user data

Use native linux-x64 Electron and ABI-correct addon/FFmpeg/CLI/helper artifacts. Respect XDG config/data/cache/state/runtime directories and permissions. Desktop launch must work with a minimal PATH. Ship an unpacked user-local development bundle first, then an appropriate deb/rpm or portable package for tested distributions. Add Flatpak only after sandbox permissions, document-path mapping, portal identity and upload/file handling are actually solved. An AppImage is not an automatic cure for graphics-driver/glibc/portal compatibility.

Don't default to --no-sandbox or run Electron as root. Diagnose unsupported user namespaces/sandbox configuration honestly. Autostart, inhibition during actual recording, notifications, URI handlers and session logout must be tested in a real desktop. Do not launch a recorder at boot outside the authorized user's graphical session.

## 8. Optional/game-specific features and truthful parity

Core features are not optional merely because they take work. Complete display/window capture, game/window selection where permitted, replay saves, full sessions/bookmarks, mic/system audio, tested game-only isolation, multi-track editing, hotkeys/PTT, camera overlays, supported HDR, local library/editor/export, recovery, settings and lifecycle first, then expand integrations.

For auto-clipping/game events, inspect native availability and supported game-owned APIs/log files/SDKs. Re-create permitted event providers per game and feed the shared ActionDispatcher. Windows plugin DLLs and injection helpers are not portable assets. Don't attempt anti-cheat bypasses or patch other games to conceal injection. An unavailable Windows-only game/plugin can be specifically unsupported, but that does not justify stubbing the entire auto-clipping catalog without investigation.

Broadcasting/live integrations require recovered transport/service contracts and actual authorization. `toggleBroadcast` being declared does not specify a streaming backend. Keep it conditional until traced/tested; do not fabricate cloud endpoints or acknowledgements. OpenVR/OpenXR and injected HUDs are separate optional integration projects, not prerequisites for the native capture engine.

Implement unsupported UI states per feature with a reason and available alternative. Don't say 'all features work' while blanket-disabling major portable ones. Maintain the full feature ledger and separate platform support from service, permission and hardware availability.

## 9. Release/signing strategy

Local patching of signed bundle resources changes the final bundle and requires appropriate signing. A patcher cannot produce the project's Developer ID signature without the private key; NEVER ship such a key or ask end users to disable Gatekeeper/SIP globally.

Development mode: assemble a native host/helper locally, use explicit local development/ad-hoc signing as appropriate, label the build developmental, keep bundle IDs/paths stable, and test permission attribution/regrant behavior. Do not call this notarized release packaging.

Preferred distribution design to investigate: a project-owned, prebuilt signed/notarized native bootstrap host and separately signed recorder, with immutable signed resources. Import the user's patched upstream JavaScript/assets into a versioned private Application Support/data directory outside the signed bundle. The trusted bootstrap validates known hashes/patch manifests and loads that local payload. Package required native addons/binaries in their correctly signed locations or a separately verified native component. Adapt original app-path/resource resolution explicitly. Test Electron fuses, ASAR integrity, library validation, dynamic module loading and actual Gatekeeper behavior; do not globally weaken these settings to make it run. This design is a proposal requiring a demonstrated trust/update model and distribution-policy review, not a guarantee of notarization approval.

Alternative release packaging needs its own valid signing/permission plan. Keep capture code identity stable through client-payload updates. Test fresh install, repair/reimport, helper upgrade, rollback, relocation and launch from Finder on a clean test account. Use proper nested signing order, minimal per-binary entitlements and actual notarization/stapling verification when credentials are available.

No Medal executable/bundle/assets/fonts, account data, recordings or third-party secrets in our public distribution. Supply only our patcher/host/helper/dependencies permitted by their licenses; imported Medal content remains user-local. Record FFmpeg build flags/licenses and source obligations. Local patching is not by itself proof of contractual permission. Preserve authentication, entitlements, publisher attribution and OS recording consent.

## 10. Work sequence and gates

**M0 — Evidence and environment.** Verify inputs, inspect SDK/runtime/compilers, re-run inherited isolated tests, produce a dependency/source lock and a feature/unknown-schema inventory. Keep unresolved units/DTO fields explicitly unresolved.

**M1 — Native client bootstrap.** Implement deterministic importer, native runtime, both updater fixes, exact native SQLite worker/CLI and resource paths. Open the real GUI in an isolated profile. Prove library persistence and offline navigation. Diagnose actual failures before changing more code.

**M2 — Protocol and supervisor.** Implement native helper control loop, selected-port launch, auth extension, readiness/device/capability/state publication, settings and graceful stop/restart. Test against original extracted handlers AND actual running native Electron. A fake Electron server alone is insufficient.

**M3 — Native macOS recording.** Build permissioned source picker, native screen + system/mic capture, hardware H.264/AAC, common packet/export pipeline and a real clip shown in the Medal library. Validate actual hardware-use property and native permissions. Do not stop here.

**M4 — Replay/sessions/audio.** Complete bounded rolling replay, hotkey actions/PTT/rebinding, sessions/bookmarks, per-game settings, game-only audio taps, mic DSP, multi-track editor behavior, camera and sound feedback, pending-export recovery and storage limits.

**M5 — Feature completion/client workflows.** Implement screenshot path, real editing/export/remux, HEVC/HDR capability gates, supported voice/native game-event providers, selection/recovery edge cases and user-authorized service workflows. Inspect every recorded setting/RPC; no silent unused toggles. Record precise unavailable conditional integrations.

**M6 — macOS hardening/package.** Measure sustained performance; test sleep/wake, permission revocation, device loss, low disk, concurrent exports, update/rollback and clean-account launch. Produce installable development/release artifacts with honest signing labels and test evidence.

**M7 — Linux handoff.** Freeze the shared protocol/replay contract, commit fixture/spec updates, document native/core interfaces and open issues. Produce `HANDOFF_LINUX.md` with exact build IDs, commands, tested macOS features, failures, SDK/compiler versions, media paths, dependency locks, test results and next tasks. Preserve a macOS build/test job where available.

**L0–L6 — Linux continuation.** On the actual Linux machine re-run shared tests first; complete its native Electron/importer/SQLite package; implement portal capture/audio/camera/hotkeys; implement and measure real hardware encode; integrate all original client workflows; test multiple desktop backends and package cleanly. Follow LINUX_CONTINUATION_PROMPT.md. Keep missing hardware/compositors explicitly untested, not passed.

## 11. Verification and final completion rules

Use `ACCEPTANCE_TESTS.md` as release gates and expand it from actual failures. Add CTest/unit tests, sanitizers, captured/redacted protocol fixtures, original-code integration tests and real native app tests. Prefer a synthetic moving test window plus timestamped visual/audio impulses for repeatable synchronization tests; real gameplay tests are additional, not a substitute for deterministic measurements.

Report helper and Electron CPU, memory, GPU/copy path, dropped/duplicated frames, audio drift, wakeups, energy observations, export latency and incremental game frametime impact separately. Log actual chip/GPU/driver/display/codec/settings/workload. Numeric budgets in the acceptance file are proposed targets, not measured claims. Don't silently relax them when a test fails.

Never run account-changing, uploading, screenshot or microphone tests without user consent. A GUI permission prompt may need a human; preserve exact instructions and keep other tasks moving. Don't record credentials or unrelated private content in fixtures. Use method names/parameter keys and redacted structural logging, not full JWT/settings dumps.

Keep `PROGRESS.md`, `DECISIONS.md`, `KNOWN_LIMITATIONS.md`, `HANDOFF_LINUX.md`, a build lock, and machine-readable feature/test reports. Each session ends with actual changed files, commands/results, remaining work and the next runnable task. Context loss is handled with files, not claims that previous work passed without evidence. Do not label a final release while mandatory tests remain pending; produce the working artifact and precise unfinished items rather than a blanket success statement.

Start now with M0 and implement successive gates. This is authorization to develop the compatibility project, not authorization to override system permissions, publish clips, grant entitlements or distribute proprietary assets.
