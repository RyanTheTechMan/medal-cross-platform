# Known limitations

This file records observed limits, not excuses for successful no-op behavior.

## Environment

- Stable Xcode 27 with the macOS 27 SDK is not installed. The user authorized Xcode 27.2 beta build 27B5019j / SDK 27.2 for implementation; beta-built artifacts remain development-only and release evidence still requires the specified stable-toolchain rerun.
- A valid Apple Development identity now signs the stable `com.squirrel.medal.medal` host and `.recorder` helper IDs. `Medal.app` uses the imported Medal icon. No Developer ID Application/notarization evidence is claimed; Apple Development signing is not distribution signing or notarization.

## Current implementation state

- The real native Electron GUI, imported SQLite worker and native C++ helper run together in isolated profiles and as a hardened, team-signed local development app. TCC-authorized ScreenCaptureKit display/window video passes; microphone, camera and input-monitoring permission have not been requested.
- The original Windows better_sqlite3 and Velopack `.node` files are PE x86-64 and unusable on arm64 macOS.
- The inherited 12-test suite uses adapted dependencies and proves only its documented protocol/library subset.
- The current development client still tries one Windows registry-based external-clip discovery command on macOS; A04 remains open until that path has an explicit platform adapter.
- The prepared FFmpeg/ffprobe diagnostic tools originate from a Homebrew GPL-enabled development build, and the SQLite CLI is a development copy of the system tool. They are not a self-contained or release-cleared A07 package. The native recorder and MP4 mux path do not link those Homebrew libraries; the signed helper uses Apple frameworks and system libraries only.
- The native helper currently covers the handshake/readiness, settings, device-query and shutdown subset. Heartbeat/reconnect, malformed/oversized frames, slow handlers, duplicate in-flight IDs and most capture/control RPCs remain incomplete.
- `getActiveProcesses` now enumerates regular macOS GUI applications plus visible window captions and bundle identifiers, and the original Game chooser displays them. `getTargetedProcesses` tracks only the current manual target and `audioProcesses` remains empty. Automatic game classification, launch/termination monitoring, exclusions and application-capture completion are not yet verified.
- The original client's renderer IPC wrapper resolves an explicit recorder wire error as `null` after logging it. Wire error `-32601` is verified, but renderer capability controls must prevent unsupported calls rather than depend on Promise rejection.
- Display enumeration now returns the recovered outward shape plus real in-memory ScreenCaptureKit thumbnails and friendly labels verified in the original UI. Persistent stable-ID mapping across topology changes, duplicate-name selection and hotplug behavior are not implemented.
- The prepared tree and Apple-Development-signed app are ignored under `artifacts/`; they are not Developer-ID signed, notarized, redistributable, or release candidates.
- ScreenCaptureKit display and individual-window H.264 capture plus display HEVC capture pass short real runs through hardware-required VideoToolbox. Requested/final resolution, content rect/scale and aspect-fit geometry are now separated and the final H.264 operational run produced exact 1920x1080 from a 2560x1440 source. Source disappearance, minimized/offscreen behavior, complete color/HDR attachments and long-duration performance remain unverified.
- Separate native system-audio and microphone ScreenCaptureKit outputs feed independent AudioToolbox AAC-LC encoders. The operational H.264 run produced 379 system-audio packets with zero encode failures/discontinuities; its short-run start offset was +41.133625 ms and the acknowledged registration snapshot's end drift was -40.352126 ms. Microphone permission/capture is not tested and the 30-minute A/V drift gate remains open, so these short values are diagnostic evidence only.
- One real physical hotkey replay now survives timestamp-based idle periods, begins at a configured keyframe, writes H.264/AAC without transcoding, passes AVFoundation and ffprobe validation, is acknowledged by original `contentCreate`, generates the original thumbnail/library row, plays/seeks through the imported Electron runtime and persists unchanged over full app restart. Crash/disk-pressure/export recovery, duplicate contentCreate/idempotency, authenticated original-library UI, editor and upload remain unverified.
- The operational shortcut test covers one `Command+Shift+8` short-press and a synthetic physical-event dispatch probe. F-keys, keyboard-layout changes, conflicts, rebinding rollback, suspension, restart registration, sleep/wake and press/release behavior needed for push-to-talk remain open. The adapter returns OS registration failures rather than claiming success.
- The unauthenticated original renderer exposes only Medal's Welcome/login flow. The underlying original content handler, database row, thumbnail and imported-runtime playback/restart checks pass, but a visible original library-card/player test now legitimately requires login to the isolated profile; authentication has not been bypassed and no upload has been attempted.
- This Apple M5 Max exposes hardware H.264/HEVC encoders but no registered VideoToolbox AV1 encoder; a hardware-required AV1 session fails with OSStatus `-12908`. AV1 is honestly hidden on this host. This is host-specific evidence, not a global Apple-silicon claim.
- Hardware HEVC SDR packet capture passes, but HDR metadata/colors, container muxing, playback, thumbnail, editor/export and Medal service compatibility are unverified. H.264 remains the compatibility default.
- The original renderer Desktop selector and status UI now drive direct native display capture, with recovered `captureStarted`, `gameState`, and `captureStopped` events verified. The temporary namespaced M3 controls remain for diagnostics; the original Game chooser's targeted-application and automatic-detection workflows remain incomplete.

## Recovered-contract unknowns

- Bitrate is resolved for the pinned client/recorder hashes: the numeric wire value is decimal Mbps and the original recorder multiplies by 1,000,000 for native bits/second. Changed builds must fail the hash/predicate verifier and be retraced.
- Complete nested DTO/error/event payloads and event ordering outside tested paths.
- Proactive client `user` behavior and hardwareId/capability/JWT behavior on a legitimate port installation.
- Continuous-session `contentUpdate` and completion semantics.
- Production contentCreate retry/idempotency and client path-renaming reconciliation.
- Multi-track ordering, labels, editor metadata, and service acceptance.
- Broadcast, overlay-injection, auto-clip plugin, and voice semantics not established by method names alone.
