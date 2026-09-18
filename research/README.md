# Medal native-port research kit

Investigated on 2026-09-18. Client 2637.461.1; recorder 2638.2751.1.

**This is an extraction, protocol-inspection and regression-test kit, not a finished Medal port or native recorder.** It contains no Medal executables, application bundle, fonts, account data or credentials. The tests obtain original functions from your own extracted installer. All original files remain unchanged.

## What works here

The extractor reads the supplied EXE as a ZIP and reconstructs its Electron application without running Windows binaries. The protocol test loads the actual extracted WebSocket handler and JSON-RPC implementation, along with actual clip-registration functions, in an isolated Node VM. A standalone diagnostic helper connects to that original handler. A synthetic H.264/AAC replay is registered in a real temporary SQLite JSONB library and receives a generated JPEG thumbnail.

The test suite passed 12 checks. Its Electron environment, cloud operations, DB accessor and selected media dependencies are deliberately substituted. It does **not** establish GUI startup, login, upload, native better-sqlite3 compatibility, screen capture, audio permissions, GPU encoding, editing or platform packaging.

## Read first

- `FINDINGS.md`: concrete findings, evidence paths, design and remaining work.
- `PROTOCOL.md`: all 34 recorder RPC declarations, client handler names, settings and wire quirks.
- `PATCH_PLAN.json`: proposed patch contracts and acceptance gates, NOT applied binary patches.
- `evidence/`: fingerprints, extracted metadata/attributes, symbol offsets, settings and test results.

## Reproduce extraction and tests

Prerequisites: Python 3.10+, Node 22.16 or later with `node:sqlite` and global WebSocket, FFmpeg/ffprobe with libx264 and AAC support. Node 22.16 was tested. Node's SQLite implementation is a test replacement; the real client still needs its Electron-compatible native SQLite addon. Nothing is downloaded by these scripts.

From this directory:

```sh
python3 tools/extract_medal.py /path/to/Medal-production-2637.461.1-Setup.exe --out ./extracted
python3 tests/make_media.py
node tests/original_client.cjs ./extracted/app
```

Expected result: 12 PASS lines. Tests create only local synthetic media and an in-memory database; no real screen or account is used. The build-specific test harness refuses a different `main.min.js` hash. The extractor refuses unknown installer fingerprints unless you explicitly select inspection-only `--allow-unknown`. It refuses existing output directories and archive path traversal/symlink/case-collision cases.

Extraction validates 999 packed ASAR file hashes in this build. Five unpacked executable/addon entries differ from their ASAR header hash/size; this is consistent with post-pack signing, but the signing history was not verified. Their actual ZIP bytes are retained and discrepancies reported. Our SHA-256 fingerprints identify the exact supplied files; this is **not** Authenticode/publisher-signature validation.

## Probe a separately running test client

Only after the client's native bootstrap dependencies are fixed, use an isolated profile with the official recorder stopped. `NO_RECORDER=1` prevents initial supervisor launch in the inspected client but does not fix native dependency loading. Do not connect a second helper alongside the real recorder.

```sh
node tools/recorder_probe.mjs --port 10603
# Or keep the diagnostic connection open:
node tools/recorder_probe.mjs --port 10603 --hold
```

Replace 10603 with the actual port selected by that client instance. The probe verifies the negotiated handshake and heartbeat. It handles incoming `ping` and `shutdown`; all other requests receive method-not-implemented errors. It does not report `recordingReady`, claim capture capabilities, save clips, apply settings or fetch account details. Logs contain method names and parameter keys, not values. This build's original server requires no browser Origin header; the Node WebSocket connection meets that condition. A production port should add a per-launch local authentication secret to both ends; this probe does not implement such a private extension.

## Proposed production architecture

Keep Medal's bundled renderer/main/preload code where compatible. Use native Electron, a rebuilt SQLite binding, an explicit platform adapter, a replaced recorder supervisor and port-controlled updates. Keep the JSON-RPC protocol adapter separate from capture backends. Start with an existing recorder engine, such as a separately installed OBS controlled through obs-websocket, to prove real clip integration. Then add a direct ScreenCaptureKit/Metal/VideoToolbox backend on macOS and a portal/PipeWire backend on Linux if desired.

The kit is not affiliated with or approved by Medal. Local patch-only distribution avoids bundling Medal's application, but does not establish contractual or legal permission. Do not disable account authentication, service entitlements, OS recording consent or access controls. Review Medal's current terms and obtain appropriate advice/permission before release.
