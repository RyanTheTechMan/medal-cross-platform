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
- `getTargetedProcesses`, `getActiveProcesses` and `audioProcesses` currently return explicit empty arrays because no native process mapper exists yet. This is not evidence that process/game capture is supported.
- The original client's renderer IPC wrapper resolves an explicit recorder wire error as `null` after logging it. Wire error `-32601` is verified, but renderer capability controls must prevent unsupported calls rather than depend on Promise rejection.
- Device enumeration returns correct recovered outward shapes, but persistent stable-ID mapping, duplicate-name selection and hotplug behavior are not implemented.
- The prepared tree and Apple-Development-signed app are ignored under `artifacts/`; they are not Developer-ID signed, notarized, redistributable, or release candidates.
- ScreenCaptureKit display and individual-window H.264 capture plus display HEVC capture pass short real runs through hardware-required VideoToolbox. Source disappearance, geometry/scale/color attachments, minimized/offscreen behavior and long-duration performance remain unverified.
- Separate native system-audio and microphone ScreenCaptureKit outputs feed independent AudioToolbox AAC-LC encoders. A short signed-client system-audio run produced 378 AAC packets with zero encode failures/discontinuities; microphone permission/capture is not tested and the 30-minute A/V drift gate remains open. The observed short-run video/audio start offset was +62.521375 ms and end drift was -51.875958 ms, which is diagnostic evidence rather than a soak-test pass.
- A synthetic VideoToolbox H.264 + AudioToolbox AAC replay snapshot writes and reads back through the Apple AVAssetWriter/AVAssetReader path without transcoding. The first real export attempt failed closed under backpressure and removed its partial file; the next picker attempt received no source selection. A post-fix real captured MP4, restart survival, playback, thumbnail generation and Medal library registration remain unverified.
- This Apple M5 Max exposes hardware H.264/HEVC encoders but no registered VideoToolbox AV1 encoder; a hardware-required AV1 session fails with OSStatus `-12908`. AV1 is honestly hidden on this host. This is host-specific evidence, not a global Apple-silicon claim.
- Hardware HEVC SDR packet capture passes, but HDR metadata/colors, container muxing, playback, thumbnail, editor/export and Medal service compatibility are unverified. H.264 remains the compatibility default.
- The temporary namespaced M3 controls run through the actual imported client's generic recorder IPC and WebSocket path. A normal renderer source-selection/status UI and recovered captureStarted/captureStopped event integration remain open.

## Recovered-contract unknowns

- Exact bitrate conversion and encoder unit.
- Complete nested DTO/error/event payloads and event ordering outside tested paths.
- Proactive client `user` behavior and hardwareId/capability/JWT behavior on a legitimate port installation.
- Continuous-session `contentUpdate` and completion semantics.
- Production contentCreate retry/idempotency and client path-renaming reconciliation.
- Multi-track ordering, labels, editor metadata, and service acceptance.
- Broadcast, overlay-injection, auto-clip plugin, and voice semantics not established by method names alone.
