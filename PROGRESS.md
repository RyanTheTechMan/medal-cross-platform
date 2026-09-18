# Implementation progress

## Current gate and next runnable task

- Gate: deterministic team-backed `Medal.app` / recorder identities now precede all TCC work. The host uses the imported Windows client ID `com.squirrel.medal.medal`, normal Medal naming and the imported Medal icon; the signed actual client/helper communication test passes. The first M3 ScreenCaptureKit enumeration/picker/direct-VideoToolbox path compiles but remains `implemented_unverified`; no Screen Recording, microphone, system-audio, camera or other TCC prompt has been requested and no capture gate is marked passed.
- Next runnable task: with the user present, launch the isolated signed M3.1 capture self-test, approve only Screen & System Audio Recording if macOS requests it, select the requested display, and retain the resulting status/encoder evidence. Repeat separately for window and application selection after the display path is sound.
- Expected observation: source enumeration completes, the system picker owns authorization, actual complete/started frames go directly from ScreenCaptureKit CVPixelBuffers to a hardware-required VideoToolbox H.264 session, idle/blank/suspended/stopped states are distinguished, and encoded packets enter the C++ replay store without raw-frame IPC.

## Implemented changes

- Reproduced read-only extraction of the pinned installer into ignored `research/extracted-macos-m0/`.
- Generated a synthetic H.264/AAC fixture and reran the inherited original-client harness.
- Matched every bundled better-sqlite3 wrapper file to public tag v12.12.0 / commit `38f111acfacced350ac17e62944ba9a4dbd176e5`; both source and imported binary identify SQLite 3.53.3. The Git tag is not signed, so the commit and local comparison are recorded explicitly.
- Built and tested the C++20 shared JSON-RPC/settings/timestamp/replay core and an Objective-C++ macOS 27.2 public-API probe with Xcode 27.2 beta on arm64.
- Added a deterministic local importer with pinned input hashes, traversal/symlink/case/Unicode/bomb checks, exact-count patch predicates, pre/post hashes, same-filesystem staging, atomic activation, retained rollback target and idempotent re-import.
- Prepared and launched the actual imported renderer/preload/main code under Electron 43.2.0 arm64 / ABI 148 in an isolated profile. The Welcome to Medal window was observed through macOS accessibility, and the original renderer stayed sandboxed.
- Replaced both Velopack entry points with one explicit manual-update adapter, blocked non-Windows SQLite asset fallback, installed the matching arm64 addon, and changed FFmpeg/ffprobe resolution to absolute prepared paths.
- Exercised the imported client's own SQLite worker and IPC: schema version 4, JSONB insert/read/update, bulk insert/delete, clean close/reopen persistence, cleanup delete and quick-check all succeeded. Recovery remains untested.
- Added a native arm64 helper launched by the imported client's actual recorder supervisor with the client-selected port and parent PID. It authenticates with a fresh 256-bit per-launch secret carried only in the WebSocket header, validates the recovered version-1 handshake envelope, and publishes readiness/device/capability state.
- Added CoreGraphics/CoreAudio/AVFoundation-backed macOS enumeration through a shared C++ platform-adapter interface. Display DTO casing, default audio DTO casing and webcam DTO shape are exercised through the actual Electron IPC → WebSocket → C++ helper path.
- Implemented the recovered `ping`, all-settings apply, scoped setting deletion, display/audio/mic/default/webcam queries, process-list placeholders with explicit empty semantics, and clean shutdown. Unknown methods return JSON-RPC `-32601`; unimplemented features are not acknowledged as success.
- Patched the pinned client's recorder transport logs to retain method/id/error shapes while redacting device/settings payloads, and redacted per-profile feature-service context URLs/keys.
- Verified selected-port propagation with 10603 deliberately occupied, loopback-only server binding on 10604, arm64 Electron/helper processes, missing/incorrect-secret HTTP 401 rejection, clean code-1000 `shutdown`, port release, and helper termination after forced parent death.
- Added fixed development bundle identities for the Electron host, all Electron child helpers and the native recorder; the host uses the recovered upstream Windows AppUserModelID `com.squirrel.medal.medal`, is presented as `Medal.app`, and uses an `.icns` generated from the archive's own `MedalApp.png`. Client and recorder are signed by the same Apple Development team with hardened runtime and stable designated requirements. Added the required microphone/camera/audio-capture descriptions without inventing a screen-recording usage key.
- Added an atomically versioned local development-app builder that signs nested Mach-O/framework boundaries inside-out (including Electron's `libffmpeg.dylib`), retains old versions, and labels the output development-only/not notarized.
- Added a shared capture-session interface and Objective-C++ ScreenCaptureKit backend for explicit source enumeration, system display/window/application picker selection, stopped/idle/blank/suspended handling, and direct CVPixelBuffer submission to a hardware-required H.264 VideoToolbox encoder. Keyframes carry AVC decoder configuration into the existing encoded replay store.
- Added namespaced `nativePort.enumerateSources`, `nativePort.presentSourcePicker`, `nativePort.captureStatus` and `nativePort.stopCapture` test controls through the actual imported client's existing IPC/WebSocket path. They return explicit accepted/status data; no unsupported original RPC is acknowledged as success.
- Added on-disk M0 environment, dependency, unknown-contract, progress, decision, limitation, and handoff records.
- Commits: `9082bbe` establishes M0; `861023f` establishes the native core and M1 Electron bootstrap; `e91b60d` establishes authenticated actual-client/helper M2 integration. The deterministic-signing/M3.1 capture checkpoint is pending.

## Tests run

- Starter-pack validator: `python3 validate_pack.py`; exit 0; 34 RPCs, 40 handlers, 60 settings, 30 workflows, 67 acceptance IDs, 31 sources; this is documentation consistency only.
- A01 evidence subset: pinned SHA-256 values matched both archives; extractor recovered 1,582 files, verified 999 packed integrity records, and retained the five documented unpacked mismatches. See `reports/m0/`.
- B01: `node research/tests/original_client.cjs research/extracted-macos-m0/app`; exit 0; 12/12 inherited isolated checks passed. Electron, database accessor, media dependencies, cloud, native capture, GUI, permissions, and GPU remain outside this result.
- Synthetic media: `python3 research/tests/make_media.py`; exit 0; FFmpeg-generated H.264/AAC fixture only.
- Manual/user interaction required: none so far.
- Native core: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer cmake --build build-macos --verbose` and `ctest --test-dir build-macos --output-on-failure -V`; exit 0; two tests passed. See `reports/native/build-xcode-27.2-beta.log` and `reports/native/ctest-xcode-27.2-beta.log`.
- Importer security: `python3 -m unittest -v tests/test_importer.py`; exit 0; 6/6 tests passed. See `reports/native/importer-security-tests.log`.
- Real GUI: Electron 43.2.0 / ABI 148 / arm64 opened the original renderer in `artifacts/profiles/m1-gui-2`; actual main, renderer, GPU and network processes used the isolated profile. See `reports/native/electron-m1-gui-2.log`.
- Real client DB close/reopen: imported IPC handlers and worker passed; see the local ignored `artifacts/profiles/m1-db/db-selftest-verify.json` and `reports/native/electron-m1-db-{write,verify}.log`.
- M2 build: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer cmake --build build-macos --parallel 2` and matching `ctest`; exit 0; 2/2 tests passed. See `reports/native/build-m2.6-xcode-27.2-beta.log` and `ctest-m2.6-xcode-27.2-beta.log`.
- Actual bidirectional protocol: the hidden sandboxed test renderer used the imported client's real IPC handler and WebSocket server to call the real C++ helper; ping, recovered DTOs, scoped settings/deletion and explicit unknown-method wire error passed. See `reports/native/m2.6-protocol-selftest.json` and `electron-m2.6-protocol.log`.
- M2 authentication/network/process: missing and incorrect secrets returned 401; 10603 occupation selected 10604; the listener was loopback-only; both main/helper files were Mach-O arm64; no secret appeared in argv. See `reports/native/m2.6-websocket-auth.json` and `m2.6-process-evidence.txt`.
- Lifecycle: actual app quit sent `shutdown`, observed close code 1000/reason `shutdown`, both processes exited and port 10604 released in 761 ms. Forced parent death terminated the helper and released its port in 20 ms. See `reports/native/m2.6-clean-shutdown.txt` and `m2-parent-death-result.txt`.
- M3.1 compile/core: the ScreenCaptureKit/VideoToolbox backend and signed recorder build with Xcode 27.2 beta; 2/2 CTests and 6/6 importer tests pass. See `build-m3.0-xcode-27.2-beta.log`, `ctest-m3.1-xcode-27.2-beta.log` and `importer-tests-m3.1.log`.
- Development signing/presentation: current `Medal.app` and recorder have fixed identifiers, Apple Development authority, team `XDB9K8JX58`, stable designated requirements and strict/deep verification. The imported icon hashes match the packaged evidence and the signed actual client protocol self-test passed. See `m3.2-development-app-build.json`, `m3.2-medal-identity.txt` and `m3.2-signed-protocol-selftest.json`.
- Manual/user interaction required next: Screen & System Audio Recording approval if macOS prompts, followed by an explicit system-picker display choice. The prerequisite and prohibited bypasses are recorded in `m3.2-tcc-prerequisite.md`. Microphone/camera/input-monitoring permission and Medal login are not requested at this gate.

## Failed or blocked gates

- Stable Xcode 27 is still absent. Xcode 27.2 beta build 27B5019j and SDK 27.2 compile/run the development evidence; beta-built output is not release evidence.
- A04 is not complete: the GUI works, but original external-clip discovery still attempts the Windows `REG` command and logs a command/PATH error on macOS.
- A05 is not complete: the real worker passed migrations/JSONB/CRUD/close-reopen, but deliberate corruption and the packaged sqlite recovery CLI path have not run.
- A06/A07 are not complete: the client updater and SQLite download path are controlled, but native recorder AssetManager replacement and self-contained FFmpeg/sqlite packaging remain outstanding. Current prepared tools are development copies.
- B05 is incomplete: JSON-RPC heartbeat timeout, bounded reconnect, oversized/malformed frames, duplicate in-flight IDs and slow-handler behavior still need actual-process tests.
- B08/B09 are incomplete: enumeration wire shapes passed, but stable internal device mappings, hotplug/disappearance and dispositions for every method/setting are not complete. Process methods currently return explicit empty arrays; capture/control methods return `-32601`.
- The original client's IPC wrapper converts a recorder wire error into `null` for its caller after logging the error. The actual wire response carries `-32601`; capability/UI disabling must avoid relying on a rejected renderer promise.
- The M3 capture path is compiled only: no TCC-authorized frame, hardware-use runtime result, source-disappearance runtime result, captured audio, H.264/AAC file, editor, account or release-package gate has passed.

## Contracts and unknowns

- No recovered wire contract was changed.
- Bitrate units, several nested DTO/event payloads, session/contentUpdate ordering, proactive `user`, production contentCreate idempotency, multi-track ordering, and broadcast/plugin semantics remain unresolved in `spec/unknowns.json`.

## Artifacts

- Development/release status: ignored local prepared payload and signed Apple Development app versions exist under `artifacts/`; they are not redistributable, Developer-ID signed, notarized or release candidates.
- M0 reports: `reports/m0/`.
- Native/M1 reports: `reports/native/`.
- Extracted proprietary payload and generated media remain ignored and local.
