# Implementation and release acceptance gates

These are **tests Codex must implement/run**, not statements that the native port already passes. `validation/` contains only the newly reproduced inherited isolated baseline. This plan is original engineering guidance grounded in the recovered interface and the platform APIs indexed in `SOURCES.md`.

For every run record ID, UTC date, commit, input hashes, toolchain/runtime, OS, chip/GPU/driver, display/session/compositor, settings, workload, command, exit status, assertions and evidence path. Status is passed/failed/skipped/blocked. No GUI/permission/GPU test may pass by substituting its backend. Store redacted fixtures and nonprivate synthetic media only.

**Release tiers:** C = mandatory common product behavior; M = mandatory macOS behavior; L = mandatory Linux behavior on the declared target desktops/hardware; K = conditional hardware, entitlement, game/API or optional feature. A conditional unavailable configuration needs a tested disabled state, not success. Core replay/audio/library/editor functions are not optional. Manual consent/account/signing steps must be recorded and performed by an authorized user.

## A. Importer, native client, storage and updater

| ID | Tier | Test / required observation |
|---|---|---|
| A01 | C | Known installer hash matches; ZIP/ASAR extraction reproduces expected file counts/integrity; original bytes remain unchanged. Retain the five recorded unpacked discrepancies without claiming publisher verification. |
| A02 | C | Reject traversal, symlink escape, case/Unicode collisions, oversized/decompression-bomb entries, unknown build and unsupported patch predicate. A refused import does not damage an existing working install. |
| A03 | C | Every patch has exact match counts/pre/post hashes; second import is idempotent; intentionally changed upstream anchor fails closed; staged activation is atomic. |
| A04 | C | Native Electron opens original renderer/preload/main flows in an isolated profile with no Windows `.node`, updater, executable or PATH error. Verify actual process architecture and Electron ABI. |
| A05 | C | Real Electron SQLite worker/addon executes migrations, JSONB queries, insert/update/delete, transactions, close/reopen and recovery. An adapted `node:sqlite` harness does not satisfy this gate. |
| A06 | C | Both Velopack entry points, client updates, SQLite asset download and recorder AssetManager cannot replace target binaries with Windows content. UI accurately shows update availability/state. |
| A07 | C | Packaged native FFmpeg/ffprobe/sqlite3 resolve from absolute trusted paths when launched from Finder/desktop with minimal PATH; spaces/Unicode and external clip folders work. |
| A08 | C | Fresh profile, restart, full library reload, settings save/reload and multiple isolated profiles do not share ports, helpers, credentials or DB files accidentally. |
| A09 | C | Failed update and explicit rollback preserve clips and profile; incompatible DB migration blocks naive rollback and provides a backed-up recovery path. Uninstall-port keeps recordings by default. |
| A10 | C | Normal login/deep-link callback and authorized service features work; no fabricated entitlement/JWT/hardware success. Logged-out and service-refused states remain usable for supported local behavior. Account actions require consent. |

## B. Bidirectional recorder protocol and supervisor

| ID | Tier | Test / required observation |
|---|---|---|
| B01 | C | Reproduce all 12 inherited isolated checks on the pinned extracted client. Record the adapted dependencies and do not promote their scope. |
| B02 | C | Real native Electron starts its server before the real native helper; occupied base port forces a new selected port that reaches the helper correctly. No recorder listener binds a public interface. |
| B03 | C | Both directions use the correct JSON-RPC envelopes, IDs/notifications, error mapping and version validation. Nominal success with empty handshake data is rejected. |
| B04 | C | Fresh per-launch local secret accepted; missing/old/incorrect secret rejected; reconnect cannot join another profile; full tokens never appear in argv/logs. Origin restrictions remain effective. |
| B05 | C | Heartbeat timeout, slow handler, malformed/oversized frame, duplicate ID, close/reconnect and client restart produce bounded behavior; unknown methods do not return success. |
| B06 | C | Initial readiness means initialized, not recording; permission denial/source cancellation never emits captureStarted; captureStopped and user-visible errors occur on actual backend stop/failure. |
| B07 | C | Shutdown request/notification and close reason preserve original lifecycle; helper exits, devices release and pending exports remain recoverable. Parent death stops capture. No restart loop after denial. |
| B08 | C | Device DTO casing/types match fixtures; duplicate labels and disappearing devices preserve stable mapping; current selections/settings reflect actual native capabilities. |
| B09 | C | All 60 settings and 34 recorder methods receive a ledger disposition with code/test evidence; per-game overrides/deletion, live reconfiguration and UI conversion match actual client behavior. Bitrate units are established before conversion. |
| B10 | C | Extended source-picker/actions/capabilities have explicit namespaced schemas and version checks on both patched endpoints. A delayed native picker does not block the original 10-second request wrapper. |

## C. macOS capture, audio and native integration

| ID | Tier | Test / required observation |
|---|---|---|
| M01 | M | Native arm64 build with installed macOS 27 SDK; available APIs/signatures checked by compiler; no Rosetta/Wine/OBS runtime required. Stable helper identity and final parent launch arrangement recorded. |
| M02 | M | Source picker display/window/application selection, cancellation, switch, closed window, system stop action and permission revocation yield correct UI/backend states. Never silently broaden selected content. |
| M03 | M | Synthetic moving window records H.264 SDR with actual VideoToolbox hardware-use property true in hardware mode; unsupported setting gets clear error/capability state, not silent CPU fallback. |
| M04 | M | Screen pixels retain valid lifetime through encoder consumption; resize/Retina/rotation/refresh/HDR-source-to-SDR conversion and unchanged-screen frames remain correct. Delayed encoder stress shows no reused-buffer corruption. |
| M05 | M | Independently verify system audio, mic audio, both together and neither; exactly one mic capture owner; selected/default devices, gain/mute and device loss/reconnect work. No duplicated/echoed mic. |
| M06 | M | Core Audio game/process-only path includes intended app process group and excludes an independent test sound; taps/aggregate devices clean up; normal playback/default output is unchanged. |
| M07 | M | Microphone-only test opens without unintended screen/camera capture; Bluetooth/USB changes and rate/channel changes cause controlled reconfiguration; permission denial/regrant is visible. |
| M08 | M | Native global save, PTT press/release, hotkey rebinding/cancel/suspend, conflict and fullscreen focus behavior verified. Additional accessibility/input-monitoring prompts occur only for chosen features that need them. |
| M09 | M | Real camera permission/discovery/capture/composited clip and disable/remove/reconnect; camera preview does not run another full recording pipeline; system Presenter Overlay does not cause duplicate compositing or false device loss. Unavailable camera shows an honest optional state. |
| M10 | M | Finder launch on a clean account exercises actual capture-owning code identity, usage descriptions, microphone/camera/screen/tap consent; development signing is labeled. No TCC edits or Gatekeeper/SIP disablement. |
| M11 | K | Supported HEVC/HDR capture preserves correct metadata/colors through playback/editor/export. Incompatible decoder/service gets an explicit compatibility choice. Unsupported codec/hardware correctly disabled. |
| M12 | K | Optional on-device voice clipping checks assets/locale, approval for downloads, command recognition and resource overhead; no silent remote audio upload. |

## D. Linux capture and desktop integration

| ID | Tier | Test / required observation |
|---|---|---|
| L01 | L | Native x64 Electron/helper/addon package starts from desktop without Windows binaries or developer shell. Actual glibc/runtime/session/portal/driver versions recorded. |
| L02 | L | Native ScreenCast selection for monitor/window as supported, deny/cancel/stop/sessionClosed and parent-window handling work on real GNOME and KDE Wayland targets. Extra desktops are separately reported. |
| L03 | L | Interface introspection, older node IDs and current pipewire-serial routing select only the granted stream. Restore-token rotation works; denied/expired restore triggers explicit reselection. |
| L04 | L | PipeWire format/plane/stride/modifier negotiation, DMA-BUF ownership/synchronization and delayed consumer backpressure produce correct frames; fallback copies are reported. |
| L05 | L | At least one actual target hardware encode path records real frames and reports active device/profile/encoder. VAAPI and NVENC claims require separate real-GPU tests; compile/list-only checks are insufficient. |
| L06 | L | Mic, system and game-only audio use the correct policy-authorized audio graph; screen remote is not misused for arbitrary audio. Default changes/hotplug/subprocess routing and isolation verified. |
| L07 | L | GlobalShortcuts session binds actual assigned keys and implements Activated/Deactivated; conflict/rebind/PTT works where supported. Missing portal has a tested explicit in-app-action alternative. |
| L08 | L | Camera portal access is independent, selected device works, denial/removal releases resources; optional V4L2 behavior is explicitly restricted/tested. |
| L09 | K | Optional X11 backend captures intended source and hotkeys without claiming native Wayland coverage. XWayland-only windows do not imply access to every desktop window. |
| L10 | L | Desktop identity, .desktop file, notifications, URI callback, login/logout, suspend/resume and user-controlled autostart work in a real session. No general --no-sandbox workaround. |
| L11 | K | Multi-GPU and unsupported modifiers/drivers trigger accurate copy/encoder fallback policies; forced hardware-only mode fails visibly when unavailable. |
| L12 | L | Install/upgrade/rollback/uninstall in a clean test user preserves media and port-owned paths. Package doesn't require building dependencies on the end-user machine. |

## E. Media correctness, replay, library and all-feature workflows

| ID | Tier | Test / required observation |
|---|---|---|
| E01 | C | Requested replay durations 5/15/30/60/120 seconds export decodable first frames with expected audio alignment; requested vs actual duration and GOP preroll are accurately reported. |
| E02 | C | Replay during early startup, rapid repeated saves, simultaneous exports, settings changes and codec-generation transitions never emits invalid mixed configurations or blocks capture. |
| E03 | C | No-B-frame baseline then any supported B-frame mode: PTS/DTS, keyframe dependencies, AAC priming, timebase rebasing, seek and end-of-file validation. Independent decoder probes export files. |
| E04 | C | Native operational `clip;length=N` action, not an invented original saveClip RPC, produces a real clip through actual contentCreate → library → thumbnail → playback. |
| E05 | C | Continuous-session start/stop, bookmarks, segment toggles, source switches and contentUpdate/end state reproduce recovered client behavior; pending session survives crash recovery. |
| E06 | C | Mixed/game/mic tracks have correct labels/order/metadata and actual editor controls; mute/PTT affects all intended tracks consistently. Three encoded tracks alone is not acceptance. |
| E07 | C | Original editor scrubbing, trim, remux/transcode and export produce correct playback and duration with native tool arguments; external files and file URIs survive restart/relocation as supported. |
| E08 | C | Source screenshot action creates a correct image/library item with the actual event shape; sound alerts obey volume/mute choices without accidental capture feedback. |
| E09 | C | Stable export UUID/outbox handles acknowledgement loss, retry, client rename, restart and reconnection without duplicate library records or deleting the sole recording. Trace idempotency instead of assuming it. |
| E10 | C | Storage limit, unwritable path, disk full mid-export, removed external volume, interrupted rename and corrupt journal all preserve recoverable committed files and explain failures. |
| E11 | C | User-authorized upload preserves privacy/auto-upload choices and accepted format. Service rejection is not represented as success; local library remains intact. |
| E12 | C | Every visible recorder control is implemented or explicitly capability-disabled with a reason; action/settings inventory has no silent no-op. Existing cloud feature entitlements stay authoritative. |
| E13 | K | Supported game-event providers, voice commands, broadcaster or overlay integration each has real endpoint/event evidence and tests. Unavailable Windows-only integrations have scoped limitations, not invented success. |

## F. Performance and robustness

**Proposed targets, not measurements or universal guarantees.** Use a documented non-saturated moving reference window at 1920×1080/60, H.264 SDR around 20 Mbit/s, 48 kHz game+mic audio, 30-second replay and no camera/effects. Run on the actual Apple silicon target and each declared Linux hardware path. Later stress gameplay, 4K/HDR, webcam, noise processing and multi-GPU separately. Idle source samples are not dropped frames.

| ID | Required measurement / initial target |
|---|---|
| P01 | Capture pipeline contains no per-frame JS/JSON/base64/network transfer, no software video encoder when hardware-only was selected and no FFmpeg CLI pipe as primary recording engine. Log actual native path. |
| P02 | Reference workload: target dropped/late source frames under 0.5% after warmup, zero decoder errors, no unexplained long stalls. Record requested/actual source cadence and saturation. |
| P03 | Timestamped visual/audio impulses: target A/V error ≤50 ms over 30 minutes and ≤100 ms over a two-hour soak, with no progressive drift. Document measurement method and device changes separately. |
| P04 | Ring hard byte/time cap enforced. With 20 Mbit/s ×30 seconds expect roughly 75 MB encoded video before audio/GOP/headroom; actual RSS includes more. Export snapshots do not copy the entire ring per job. At fixed settings, no unbounded steady-state memory growth. |
| P05 | Initial reference helper CPU target ≤20% of one logical core averaged over 10 minutes; idle-without-recording target ≤1% of one core. Report the metric convention and Electron CPU separately. These are optimization targets, not assumed platform facts. |
| P06 | 30-second fast remux replay on a documented local SSD: target p95 export-to-finalized-file ≤2 seconds across 20 saves, while capture continues. Time library registration/thumbnail separately. |
| P07 | Record game median/p95/p99 frametime with recorder off/on for the same repeatable workload; target median overhead ≤5% for the reference preset. Do not generalize to every game, thermally constrained state or codec/effect setting. |
| P08 | Report helper/host RSS, GPU path/readback count, GPU time where measurable, wakeups, queues, dropped frames, disk writes and power/thermal observations. A zero-copy assertion needs evidence, not just DMA-BUF/IOSurface usage. |
| P09 | Two-hour soak plus multiple export, helper/client crash, sleep/wake, lock/unlock, permission revoke, device disappearance and resolution changes; no orphaned capture or growing queue. |
| P10 | Permission denied or no source/encoder available never triggers a high-rate restart loop, silent all-screen capture or automatic software fallback without policy/user visibility. |

Do not weaken a failing budget silently. Capture evidence, identify the stage causing cost, optimize and remeasure. A specific attainable revised preset/budget can be proposed with documented evidence and user-visible tradeoffs. Mandatory correctness/privacy requirements are not performance tradeoffs.

## G. Handoff and honest release status

Each feature entry must point to implementation files, test IDs and reports separately for macOS/Linux. Maintain a support table distinguishing compiled, isolated-tested, native-tested, blocked by consent/hardware and unsupported with evidence. Do not average feature percentages to conceal missing essential workflows.

A macOS release candidate requires A/B/E mandatory gates, applicable M gates, P measurements and genuine packaging tests. A Linux release candidate additionally requires L gates on each advertised environment and shared regression tests. Conditional tests can be unavailable with precise limits; a missing mandatory workflow remains incomplete.

`HANDOFF_LINUX.md` must state the actual macOS commit/toolchain, commands/results, media/core interfaces, input/dependency locks, unimplemented contracts and exact next runnable Linux task. When Linux changes common code, run shared regressions immediately and retain a macOS regression path; lack of a Mac on that session is a reported test gap, not automatic success.
