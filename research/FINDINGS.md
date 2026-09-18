# Medal portability investigation

## Scope, evidence and result

Inspected the user-provided Windows installer `Medal-production-2637.461.1-Setup.exe` and recorder ZIP `v2638.2751.1.zip`. File fingerprints and archive sizes are in `evidence/input_audit.json`. The client and recorder are independently versioned; this report does not assume they expose perfectly identical feature sets.

The most useful boundary is the client's existing bidirectional JSON-RPC connection to the recorder. Reimplement that protocol and its state/file semantics, rather than translating every Windows function called by the recorder. This is an architectural recommendation based on static dependency analysis and isolated integration tests, not a measured cross-platform performance comparison.

## Verified packaging and native dependencies

The installer is directly readable as a ZIP (666 entries). It contains a Velopack `win-x64` application, `lib/app/version` reports Electron 43.2.0, and resources/app.asar contains the main JS, renderer, preload, chunks and dependencies. Extraction reconstructs 1,582 files; 999 packed entries have verified SHA-256 integrity records. The five unpacked executable/addon integrity discrepancies are explicitly recorded by the extractor; they are consistent with changes after ASAR packing, such as signing, not evidence by themselves of corruption. Publisher signatures were not validated.

The native client modules found are:

```
lib/binding/node-v148-win32-x64/better_sqlite3.node
node_modules/velopack/lib/native/velopack_nodeffi_win_x64_msvc.node
```

The packaged Velopack JS supports platform-specific loader names, but this installer supplies only the Windows x64 native implementation. An actual isolated import on Linux failed with MODULE_NOT_FOUND for `velopack_nodeffi_linux_x64_gnu.node`. An import of the packaged SQLite binding failed with ERR_DLOPEN_FAILED / invalid ELF header. See `evidence/native_dependency_results.json`. These tests do not evaluate correctly rebuilt Linux/macOS addons.

Other Windows executables include lib/sqlite3.exe, elevate.exe, and a small Medal.exe helper. The Electron runtime executable must also be replaced by a real target-platform runtime. The JS package includes many private `workspace:*` dependencies that are already bundled; `npm install` on the extracted package is not a source reconstruction strategy.

### SQLite details

Binding selection is already platform/architecture/ABI aware: `node-v${process.versions.modules}-${process.platform}-${process.arch}`. A port can supply a matching binding in that directory, but must verify the bundled JS/native API match and JSONB support. The client can attempt to download a binding from its sqlite asset channel; availability for target platforms was not established.

The database implementation is embedded in worker code within main.min.js. The client uses JSONB and json_extract, so an arbitrary old SQLite replacement is insufficient. `getSqlite3Path()` still points to `lib/sqlite3.exe` for CLI recovery. The `contents` schema includes created_at, category_id, video_path, image_path, thumbnail_path, metadata, remote_content_id, local_content_id and parent_id (plus a film-reel migration). The helper should not own or directly mutate this database.

## Exact client patches to plan

1. Native host and bootstrap: use target-native Electron; retain main/renderer/preload. index.js invokes Velopack in a try/catch, but main.min.js independently imports Velopack at top level. Fix both the bootstrap hook and updater integration. Do not stub only index.js and expect native startup to work.
2. Recorder supervisor: `RecorderHandler2.run()` returns immediately when process.platform is not win32. Replace this implementation with a native helper lifecycle adapter. Preserve inactive/updating/running/ready states and `RecorderHandler2:state` / `RecorderHandler2:stateChange` UI IPC events. `MEDAL_ENCODER_EXE` is honored only under the client's development-mode predicate, not as an unconditional production override.
3. Actual spawn contract: helper receives `--electronPort <selected-port> --environment <channel> --wsComms`. The Electron server binds 127.0.0.1, begins probing at 10603, and can select another port. Use the chosen argument, not a fixed port. Shutdown uses a JSON-RPC `shutdown` notification; the client recognizes the WebSocket close reason `shutdown` and otherwise has a bounded exit wait before kill.
4. Updates: the recorder's AssetManager downloads checksummed Windows recorder bundles and copies/hardlinks FFmpeg and DLLs. Replace this path as well as Windows client updating. A helper path patch alone leaves an updater that can restore incompatible binaries. Native dependencies, helper and patched client should be separately versioned and rolled back atomically. Unknown upstream hashes must trigger an unsupported-build result, not fuzzy patching.
5. Resources and paths: replace sqlite3.exe and ffmpeg/ffprobe resolution with bundled native absolute paths; remove dependence on a terminal user's PATH. There is some real non-Windows handling already, including a function that returns bare ffmpeg/ffprobe command names. Another remux helper returns null on non-Windows. Audit actual editor/export paths independently.
6. Platform behavior: replace elevation/tasklist/PowerShell/GPU detection; keep injected overlay and Windows Game Mode controls unsupported or hidden initially. Add appropriate autostart, tray, URI handlers and permissions. Do not globally pretend process.platform is win32, as that re-enables unrelated Windows code paths.
7. User data: use a separate test profile and port-specific paths. Do not run the original update/migration logic against a live Windows profile. Have users log in normally on the target platform; credential/session migration was not tested. No claim is made that Medal's code uses Electron safeStorage (no such symbol was found in main.min.js).
8. Capability and entitlement handling: there is Windows-guarded hardwareId -> authenticated capabilities/JWT logic. Preserve actual service authentication and paid feature decisions; do not forge a hardware identity, entitlement token or cloud success. A private backend capability map can disable unsupported local controls without changing cloud authorization.

Build-specific symbol ranges (both JS UTF-16 offsets and UTF-8 byte offsets) are in `evidence/test_symbols.json`; they refer to main.min.js SHA-256 5a2a6dd5d1370a15577b0c09bc2d021059e2f9e7dba6a2e40cc41b4685e0c8ff. Names such as K7e, $at, w5 and gfe are build-specific, not stable public APIs.

## Recorder architecture

The executable is AMD64 PE with CLR IL, targets .NET Framework 4.6.2 and has 195 direct P/Invoke declarations and 59 assembly references. It depends on Windows Forms, System.Drawing, Windows management, SharpDX, NAudio and Windows native utilities. It is not a portable modern .NET application just because metadata can be read.

ScopeSharp.dll targets .NET Standard 2.0 but is a wrapper with 196 native imports. The native scope.dll itself imports Windows graphics/desktop libraries (D3D11/DXGI/D3D9/D2D/DWM/AVRT) and FFmpeg. Its ABI includes capture targets, video encoders, audio sources/mixing, effects, memory/disk/mmap buffers, muxers and pipeline lifecycle. Examples: scope_vcap_create_window_target, scope_vcap_create_screen_target, scope_venc_create_gpu, scope_io_vid_memory_buffer_create, scope_io_buffer_export_from_timestamp, scope_pipeline_start. Rebuilding ScopeSharp alone cannot supply a native platform engine.

The Host directory contains injection helpers and graphics hooks. Licenses/obs_source_offer.txt specifically identifies OBS-derived components in Host and describes them as separate from the rest of the recorder. This is not an offer of the entire proprietary recorder source. Requesting the offered corresponding source may help a hook investigation, but it is not necessary for an initial user-consented window/display recorder.

## Protocol and clip lifecycle

See PROTOCOL.md for exact RPC declarations and wire examples. Important discoveries:

- Electron hosts the server; the recorder is the connecting client.
- The real client registers 40 recorder-facing handler names.
- The inspected recorder declares 34 JSON-RPC methods.
- Protocol version 1 is negotiated, with an empty capabilities list in this client.
- Replies to recorder-originated requests use a Medal success/errorMessage/data envelope inside the outer JSON-RPC result. Replies from recorder handlers are ordinary JSON-RPC values.
- Unknown client methods produce -32601 in the isolated test. An incompatible handshake produces empty success data; a helper must reject a missing compatible version.
- `activeDisplays` returns PascalCase fields, while default audio devices and process DTOs use camelCase. The latter have explicit CamelCaseNamingStrategy attributes in recorder metadata; ScreenInfo does not. Do not apply a global casing convention.
- There is no saveClip/saveLast30Seconds method among the 34 declarations. The client delivers Hotkeys settings containing actions such as `clip;length=30`. Native hotkey handling or an explicit private extension must trigger replay export.
- A minimal test clip event goes through the real contentCreate handler m7e -> gfe -> w5. The client probes the video, creates thumbnails, adds local library metadata and returns uuid/contentId. Optional cloud and auto-upload behavior exists but was not exercised. Preserve the user's upload choices.

The helper should finalize/close the media file before registration, use native absolute paths, supply a stable UUID and observed metadata fields, and retain export state until acknowledgement. A failed registration is not a reason to delete the only saved recording. Implement retry/reconciliation carefully; production idempotency and crash recovery remain to be traced/tested.

## Native backends: proposed implementation, not tested here

macOS: Swift/Objective-C++ access to ScreenCaptureKit for permissioned sources and media samples; optional Metal processing for crop/scale/composition; VideoToolbox compression; native audio input/mixing and timestamp handling. Metal is not the H.264/HEVC hardware encoder API. Keep buffer ownership and GPU completion explicit. Prefer native arm64 for Apple Silicon rather than emulating Windows x64 recording. Inspect the platform's actual encoder capabilities and fail visibly when a hardware-only configuration cannot be met. Permission prompts, signing/entitlements and minimum OS support need real-device tests.

Linux: ScreenCast portal session -> user-selected source -> PipeWire stream under Wayland; optional X11 backend. Use available hardware encoders only after runtime capability checks (for example VAAPI/NVENC). Global shortcuts need a supported portal/compositor route, not assumptions that Windows key hooks work. A Windows process-name selector cannot be silently treated as universal Wayland permission to capture any window. The UI needs a native source-picker action and an internal map to protocol-facing names.

Shared: codec-independent request adapter, settings merge, state machine, monotonic timestamps, encoded replay buffer, export/mux/metadata, crash reconciliation and tests. Maintain keyframe boundaries, decoder configuration, PTS/DTS, audio clock alignment, channel layouts and output track ordering. Keep raw GPU frames local to each backend rather than carrying them across JS IPC.

## Preferred development route

First prove the patched UI with a native Electron runtime and binding. Keep the recorder supervisor disabled initially while the diagnostic probe validates transport. Then register a finalized local test clip under normal user consent. For the first real replay recording, bridge to a mature external backend such as OBS through its independent obs-websocket protocol. This is an engineering recommendation, not a tested OBS integration here.

The bridge would map the Medal Hotkeys action to OBS SaveReplayBuffer, then consume ReplayBufferSaved.savedReplayPath and issue Medal contentCreate with mapped metadata. Sources, encoder settings, audio tracks and replay-buffer configuration still need explicit setup; this is not a two-line drop-in. OBS's socket protocol is not Medal's protocol. Using a separate process is useful for proving the interface; embedding libobs later adds build/distribution/licensing work.

A direct ScreenCaptureKit/VideoToolbox backend can then replace the OBS adapter without changing the Medal-facing protocol. This avoids making both a UI port and an entirely new production capture engine prerequisites for the first useful clip.

## Tests completed and limitations

All 433 files named in the uploaded manifest's latest recorder entry match its MD5 checksums. That establishes consistency with the provided manifest, not trusted publisher provenance. ZIP has 445 entries including directory/non-checksummed entries.

The extraction tool was rerun against the original installer. The regenerated test fixture and isolated integration suite passed 12 checks, including an independent Node WebSocket probe, version negotiation, heartbeat/envelopes, unknown methods, setKV, recordingReady, raw recorder replies, real clip registration, Origin rejection and shutdown-close behavior. Original-client functions are extracted at test time rather than redistributed.

The media test used synthetic lavfi video and audio, H.264/AAC, 2-second closed-GOP segments and stream-copy concatenation of two completed segments. A roughly four-second replay was produced and ffprobe validated its streams. This proves a basic replay-remux/registration path, not an exact-duration arbitrary-keyframe ring buffer or recording performance. The DB test uses Node SQLite JSONB and an adapted accessor, not the Windows addon.

Missing tests: complete native Electron startup; target-platform addon rebuild; normal login and service permissions; editor export; actual screen/system/mic capture; mixed audio; window changes; macOS permission/signing lifecycle; Wayland compositor behavior; real hardware encoding/performance; suspend/resume; disk exhaustion; upgrades and rollback. No end-to-end working Medal port is claimed.

## Primary external references checked

These references describe platform APIs/terms, not proof about the uploaded binaries.

- Electron native-module ABI/build guidance: https://www.electronjs.org/docs/latest/tutorial/using-native-node-modules
- Apple ScreenCaptureKit overview: https://developer.apple.com/videos/play/wwdc2022/10156/
- Apple VideoToolbox session: https://developer.apple.com/documentation/videotoolbox/vtcompressionsession
- Apple hardware encoder specification: https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_requirehardwareacceleratedvideoencoder
- XDG ScreenCast portal: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html
- XDG GlobalShortcuts portal: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html
- OBS protocol (SaveReplayBuffer, ReplayBufferSaved): https://raw.githubusercontent.com/obsproject/obs-websocket/master/docs/generated/protocol.md
- OBS developer docs: https://docs.obsproject.com/
- Medal terms, retrieved 2026-09-18: https://medal.tv/terms

A comparison to other client mods does not establish permission. Medal's terms contain IP, license and exploitation/modification restrictions; the commercial-modification language should not be misrepresented as a blanket express prohibition of every noncommercial modification. Local patch-only distribution changes redistribution exposure but is not automatic contractual approval. Obtain appropriate permission/advice before a public release, and preserve authentication, service entitlements and OS recording consent.
