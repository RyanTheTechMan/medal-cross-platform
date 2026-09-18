# Known limitations

This file records observed limits, not excuses for successful no-op behavior.

## Environment

- Stable Xcode 27 with the macOS 27 SDK is not installed. The user authorized Xcode 27.2 beta build 27B5019j / SDK 27.2 for implementation; beta-built artifacts remain development-only and release evidence still requires the specified stable-toolchain rerun.
- A valid Apple Development identity now signs the stable `com.squirrel.medal.medal` host and `.recorder` helper IDs. `Medal.app` uses the imported Medal icon. No Developer ID Application/notarization evidence is claimed; Apple Development signing is not distribution signing or notarization.

## Current implementation state

- The real native Electron GUI, imported SQLite worker and native C++ helper now run together in isolated development profiles and as a hardened, team-signed local development app. No TCC-authorized capture or media roundtrip has passed yet.
- The original Windows better_sqlite3 and Velopack `.node` files are PE x86-64 and unusable on arm64 macOS.
- The inherited 12-test suite uses adapted dependencies and proves only its documented protocol/library subset.
- The current development client still tries one Windows registry-based external-clip discovery command on macOS; A04 remains open until that path has an explicit platform adapter.
- The current prepared FFmpeg/ffprobe files originate from a Homebrew GPL-enabled development build, and the SQLite CLI is a development copy of the system tool. They are not a self-contained or release-cleared A07 package.
- The native helper currently covers the handshake/readiness, settings, device-query and shutdown subset. Heartbeat/reconnect, malformed/oversized frames, slow handlers, duplicate in-flight IDs and most capture/control RPCs remain incomplete.
- `getTargetedProcesses`, `getActiveProcesses` and `audioProcesses` currently return explicit empty arrays because no native process mapper exists yet. This is not evidence that process/game capture is supported.
- The original client's renderer IPC wrapper resolves an explicit recorder wire error as `null` after logging it. Wire error `-32601` is verified, but renderer capability controls must prevent unsupported calls rather than depend on Promise rejection.
- Device enumeration returns correct recovered outward shapes, but persistent stable-ID mapping, duplicate-name selection and hotplug behavior are not implemented.
- The prepared tree and Apple-Development-signed app are ignored under `artifacts/`; they are not Developer-ID signed, notarized, redistributable, or release candidates.
- ScreenCaptureKit display and individual-window capture plus hardware-required VideoToolbox H.264 pass short real runs. Source disappearance, geometry/scale/color attachments, minimized/offscreen behavior and long-duration performance remain unverified. Audio outputs are configured but not yet consumed or AAC-encoded; no H.264/AAC recording exists.
- The temporary namespaced M3 controls run through the actual imported client's generic recorder IPC and WebSocket path. A normal renderer source-selection/status UI and recovered captureStarted/captureStopped event integration remain open.

## Recovered-contract unknowns

- Exact bitrate conversion and encoder unit.
- Complete nested DTO/error/event payloads and event ordering outside tested paths.
- Proactive client `user` behavior and hardwareId/capability/JWT behavior on a legitimate port installation.
- Continuous-session `contentUpdate` and completion semantics.
- Production contentCreate retry/idempotency and client path-renaming reconciliation.
- Multi-track ordering, labels, editor metadata, and service acceptance.
- Broadcast, overlay-injection, auto-clip plugin, and voice semantics not established by method names alone.
