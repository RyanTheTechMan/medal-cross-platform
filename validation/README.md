# Reproduced research baseline

Reproduced during the 2026-09-18 cross-check session in a Linux container, using the supplied original installer and the inherited inspected tests. No Windows executable was run.

Commands (working directory was the inherited research folder):

```sh
python3 tools/extract_medal.py /mnt/data/Medal-production-2637.461.1-Setup.exe --out ../extracted
python3 tests/make_media.py
node tests/original_client.cjs ../extracted/app
```

Observed: **12/12 isolated protocol/library assertions passed**. Synthetic H.264/AAC closed-GOP segments produced an approximately four-second replay, with actual FFmpeg/ffprobe and a temporary SQLite library plus generated thumbnail. Node v22.16.0 and FFmpeg 7.1.5 were available in the container. The extractor recovered 1,582 files and its expected integrity results.

The original WebSocket/JSON-RPC and selected client registration functions were extracted from the user's input. Electron objects, DB accessor and selected dependencies were adapted, and no cloud calls were exercised. Media is a synthetic fixture; it is not screen/audio capture or hardware encoding.

**Not tested:** complete native Electron GUI, real Electron better-sqlite3 addon, login/upload, actual macOS or Wayland capture, camera/microphone permissions, GPU encoding, native editor export, signing, installation or performance. No macOS machine was used for these tests.

protocol_results.json and media_result.json are the actual rerun outputs. Their absolute media paths refer to the temporary research environment; re-running the included scripts generates new local paths/UUIDs. extraction-report.json records the newly extracted input. Historical reports remain separately under research/evidence/. Native FEATURE_LEDGER states remain not_started because an isolated reference test is not an implemented native port.
