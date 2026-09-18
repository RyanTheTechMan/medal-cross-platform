# Actual macOS → Linux handoff

Status: **not ready for transfer**. This file is live and must not be interpreted as a completed handoff.

## Build identity

- Commit / dirty-tree changes: `9082bbe` (M0) and `861023f` (shared core/M1); M2 helper integration is pending its checkpoint commit.
- Input hashes: installer `e6477e89f968593fe4b8335f09fc25f81889dd412c28ff85522a0a37415decdb`; recorder ZIP `d33c6e3c0506c1f6b71e6158716fda3a9866bfacc41060f2ec29c4d792ca1312`.
- macOS / chip: macOS 27.2 build 26B5086k; arm64 Apple M5 Max.
- Toolchain: stable Xcode 27 unavailable; Xcode 27.2 beta build 27B5019j with SDK 27.2 and Apple clang 21.0.0 is used for development only.
- Electron/addon/signing/package: actual Electron 43.2.0 / ABI 148 and locally built better-sqlite3 12.12.0 run arm64-native. No signed/notarized/package artifact exists.
- Dependency lock / protocol: `DEPENDENCIES.lock.json`; recovered protocol version 1 unchanged.

## What actually works

- Pinned read-only extraction and 12/12 inherited isolated protocol/library tests pass on this Mac.
- The actual imported native Electron client and actual C++ helper complete authenticated version-1 WebSocket handshake/readiness, device/settings queries and clean shutdown on the selected loopback port.
- Shared C++ JSON-RPC, settings/timestamp/replay data structures and the macOS platform-adapter interface compile/test. CoreGraphics/CoreAudio/AVFoundation enumeration is active.
- No capture, hardware encoder, replay export, editor, permission, recovery, account, packaging, or performance gate has yet passed.

## Exact build/test/run commands

See `PROGRESS.md`, `reports/m0/` and `reports/native/`. Current native regression is `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer cmake --build build-macos --parallel 2 && DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ctest --test-dir build-macos --output-on-failure`.

## Common interfaces Linux must preserve

- `native/core/include/native_port/platform_adapter.hpp` defines the platform enumeration boundary used by the helper.
- Existing JSON-RPC/settings/timestamp/replay interfaces under `native/core/include/native_port/` are shared and additive changes must preserve macOS tests.
- The private authentication extension is the `x-native-port-secret` upgrade header; it is not part of Medal's recovered JSON-RPC protocol.
- Recovered method/settings inventories in `FEATURE_LEDGER.json` and `research/PROTOCOL.md` remain authoritative evidence boundaries.

## Remaining macOS work

M1 recovery/external-source cleanup, the remainder of M2 resilience/inventory, all M3–M6 capture/media/permission/package work and stable-Xcode-27 reruns remain.

## Linux starting point

Do not start Linux implementation from this state. The exact first Linux task will be recorded after the shared capture/media interfaces and macOS completion gates are implemented and frozen.

## Regression route

Current baseline: `python3 validate_pack.py`, importer tests, inherited original-client tests, the CMake/CTest command above, and the actual Electron protocol evidence route recorded in `PROGRESS.md`. Linux changes must keep the macOS adapter and helper build path intact.
