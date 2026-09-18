# Implementation progress

## Current gate and next runnable task

- Gate: M0 evidence is complete enough to proceed and M1 is implemented but not complete. A real isolated Electron GUI and real imported database worker run arm64-native; A04/A05 remain open for the Windows-only discovery error and recovery-path coverage. M2 helper integration is next.
- Next command/change: implement the native helper WebSocket client/supervisor path, selected-port propagation and namespaced per-launch authentication, then test against the actual running Electron server.
- Expected observation: the helper connects only to loopback using the client-selected port, validates a fresh secret, completes the recovered handshake/readiness/device/settings flow, and exits cleanly with the client instead of the current 10-second no-helper shutdown timeout.

## Implemented changes

- Reproduced read-only extraction of the pinned installer into ignored `research/extracted-macos-m0/`.
- Generated a synthetic H.264/AAC fixture and reran the inherited original-client harness.
- Matched every bundled better-sqlite3 wrapper file to public tag v12.12.0 / commit `38f111acfacced350ac17e62944ba9a4dbd176e5`; both source and imported binary identify SQLite 3.53.3. The Git tag is not signed, so the commit and local comparison are recorded explicitly.
- Built and tested the C++20 shared JSON-RPC/settings/timestamp/replay core and an Objective-C++ macOS 27.2 public-API probe with Xcode 27.2 beta on arm64.
- Added a deterministic local importer with pinned input hashes, traversal/symlink/case/Unicode/bomb checks, exact-count patch predicates, pre/post hashes, same-filesystem staging, atomic activation, retained rollback target and idempotent re-import.
- Prepared and launched the actual imported renderer/preload/main code under Electron 43.2.0 arm64 / ABI 148 in an isolated profile. The Welcome to Medal window was observed through macOS accessibility, and the original renderer stayed sandboxed.
- Replaced both Velopack entry points with one explicit manual-update adapter, blocked non-Windows SQLite asset fallback, installed the matching arm64 addon, and changed FFmpeg/ffprobe resolution to absolute prepared paths.
- Exercised the imported client's own SQLite worker and IPC: schema version 4, JSONB insert/read/update, bulk insert/delete, clean close/reopen persistence, cleanup delete and quick-check all succeeded. Recovery remains untested.
- Added on-disk M0 environment, dependency, unknown-contract, progress, decision, limitation, and handoff records.
- Commits: `9082bbe` establishes the M0 evidence/dependency baseline. The current M1/native-core work is pending the next checkpoint commit.

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

## Failed or blocked gates

- Stable Xcode 27 is still absent. Xcode 27.2 beta build 27B5019j and SDK 27.2 compile/run the development evidence; beta-built output is not release evidence.
- A04 is not complete: the GUI works, but original external-clip discovery still attempts the Windows `REG` command and logs a command/PATH error on macOS.
- A05 is not complete: the real worker passed migrations/JSONB/CRUD/close-reopen, but deliberate corruption and the packaged sqlite recovery CLI path have not run.
- A06/A07 are not complete: the client updater and SQLite download path are controlled, but native recorder AssetManager replacement and self-contained FFmpeg/sqlite packaging remain outstanding. Current prepared tools are development copies.
- With no helper connected, settings and shutdown notifications time out, and the database worker reports exit code 1 during app shutdown. This is recorded M2 lifecycle work, not a pass.
- All native capture, TCC, encoder, audio, editor, account and packaging gates remain untested.

## Contracts and unknowns

- No recovered wire contract was changed.
- Bitrate units, several nested DTO/event payloads, session/contentUpdate ordering, proactive `user`, production contentCreate idempotency, multi-track ordering, and broadcast/plugin semantics remain unresolved in `spec/unknowns.json`.

## Artifacts

- Development/release status: a local ignored prepared development tree exists under `artifacts/native-client`; it is not distributable, signed, notarized or a release candidate.
- M0 reports: `reports/m0/`.
- Native/M1 reports: `reports/native/`.
- Extracted proprietary payload and generated media remain ignored and local.
