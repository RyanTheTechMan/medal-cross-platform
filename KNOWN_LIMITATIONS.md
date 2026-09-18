# Known limitations

This file records observed limits, not excuses for successful no-op behavior.

## Environment

- Stable Xcode 27 with the macOS 27 SDK is not installed. The user authorized using the available Xcode 27.0 beta 3 toolchain for implementation; release evidence still requires the stable-toolchain rerun specified by the project brief.
- No Developer ID Application identity, notarization credentials, or release provisioning evidence has been supplied or requested yet. Development/ad-hoc signing is not notarization.

## Current implementation state

- The repository began as a prompt/research pack. No native Electron app, native helper, recorder, importer product, or packaged artifact has yet passed a native gate.
- The original Windows better_sqlite3 and Velopack `.node` files are PE x86-64 and unusable on arm64 macOS.
- The inherited 12-test suite uses adapted dependencies and proves only its documented protocol/library subset.

## Recovered-contract unknowns

- Exact bitrate conversion and encoder unit.
- Complete nested DTO/error/event payloads and event ordering outside tested paths.
- Proactive client `user` behavior and hardwareId/capability/JWT behavior on a legitimate port installation.
- Continuous-session `contentUpdate` and completion semantics.
- Production contentCreate retry/idempotency and client path-renaming reconciliation.
- Multi-track ordering, labels, editor metadata, and service acceptance.
- Broadcast, overlay-injection, auto-clip plugin, and voice semantics not established by method names alone.
