# M0 evidence report

Run date: 2026-09-18 on macOS 27.2 arm64.

- `environment.txt`: actual host/toolchain discovery. It proves stable Xcode 27 is absent and records the installed alternatives.
- `input-sha256.txt`: pinned input hashes after the read-only test run.
- `extraction.log` / `extraction-report.json`: A01 evidence subset from the pinned extractor.
- `media-fixture.log` / `media-result.json`: synthetic FFmpeg fixture evidence only.
- `inherited-baseline.log` / `protocol-results.json`: B01's 12 isolated original-client checks only.

None of these files is evidence for native Electron GUI, target-native SQLite, screen/audio/camera capture, hardware encoding, permission attribution, signing, packaging, account, upload, editor, or performance gates.

