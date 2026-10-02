# Known limitations

This file records observed limits, not excuses for successful no-op behavior.

October 2 Dock lifecycle: original main-window close now hides the Dock identity
without quitting the host/helper. Original Finder reopening restores the same
instance; native red-close/activation-policy evidence is in
`reports/native/dock-20261002.md`. Menu-bar Show remains the original upstream
handler; its native UI click, full-screen and login-item matrix are not
promoted to passes. No signing identity, TCC or global security change. The
common/native workflow is sufficient for Linux development, not macOS-complete
M7/release acceptance; see the current top of `HANDOFF_LINUX.md`.

Latest endpoint continuation: `reports/native/audio-20261002-endpoint.md`.
Original retained recordings' actual packet-tail deltas are -221.001/-243.667 ms;
the earlier -211.666/-228.333 ms values came from container start+duration, not
packet endpoints. New shared fixed-event endpoint path passes native hardware
fixture/10 CTests and physical original-client replay/probe/player/full restart.
Actual AAC endpoint coverage and 25%/50% isolated gains pass; live 150%, microphone,
devices/lifecycle/feedback and sustained timing remain open.
Very long entirely idle intervals may require excessive retained GOP preroll;
they are reported, not claimed exact. No sustained timing/latency pass.

Current continuation: `reports/native/audio-20261002-live-routing.md` supersedes
the earlier locked-session gate, without erasing that failed/blocked evidence.
Original UI physical F8 → replay/contentCreate/probe/thumbnail/player passes
for synthetic All PC Audio and Specific Apps. Native process-tap isolation,
original mute/Save/full restart and independent post-save digital-silence/source
preservation pass. Explicit output-device, microphone, process/default-device/
format listeners and sustained routing remain open; taps currently require
mono/stereo. Generic rebind listening was rejected; original Unset Hotkey worked.
Test tones stopped after validation. No automatic unlock, TCC reset or uploads.

The PCM graph buffers 200 ms for reorder. Old running-hotkey exports have
AAC packet endpoints 221.001–243.667 ms before video. Preserve the physical press
endpoint while waiting for required packets; merely delaying a latest snapshot
would shift the requested moment. This observed missing tail is not a long-run
drift pass. Preview maximumObservedDrift currently includes loops/seeks and must
not be presented as a steady-play timing measurement.

## Environment

- Current fresh build uses installed Xcode 27.1 (27A9269), SDK 27.0; the former Xcode-beta installation is gone. Existing historical beta reports remain evidence for their exact builds only. No release/notarization claim.
- A valid Apple Development identity now signs the stable `com.squirrel.medal.medal` host and `.recorder` helper IDs. `Medal.app` uses the imported Medal icon. No Developer ID Application/notarization evidence is claimed; Apple Development signing is not distribution signing or notarization.

## Current implementation state

- Native multi-track metadata uses absolute MP4 stream indexes. The October 2 actual native All PC/Specific Apps original Audio popover mute → Save → full restart/playback gate now passes, with source stems preserved and masters independently decoded to digital silence. The hidden-master failure caused by main-library JSON-text metadata is fixed, and failed evidence is retained. Long-run/physical latency and broader microphone/device variants remain open.
- The previous Balatro “Thumbnail not found” result was traced to an empty packaged FFmpeg/ffprobe dylib closure, not to the MP4 or Medal category flow. The importer now fails closed when that closure is empty; a rebuilt app bundles 17 dylibs and the original client successfully regenerated both existing Balatro thumbnails. Fresh post-fix contentCreate/playback is still the next normal UI validation, while crash recovery and upload remain open.
- Balatro automatic detection is now verified: the native process model discovered its Steam-launched `love` process and the imported authenticated client resolved the real Medal category `Balatro` through `/games/requests` and category search, without manual selection. The candidate filter is launch-origin based for visible-window processes in Steam/Epic/GOG/Riot/Battle.net roots; it is not a local game database. Other launcher origins and full target lifecycle monitoring remain separate gates. The live run also retained a microphone/TCC denial as separate evidence.
- The manual macOS Game selector now filters at the native-to-Medal wire boundary: regular AppKit/Dock-style applications are shown, while Dock/AutoFill/WindowManager/accessibility/Electron helper processes are hidden. Java-launched Minecraft and A Dance of Fire and Ice are explicit exceptions when they own a real ScreenCaptureKit window. Automatic detection intentionally retains the complete typed native process model. This selector policy is live-checked in `reports/native/m3.9-process-selector-filter.md`; target lifecycle and game-audio isolation remain open.
- The real native Electron GUI, imported SQLite worker and native C++ helper run together in isolated profiles and as a hardened, team-signed local development app. Deterministic TCC onboarding now attributes the nested helper to the signed `Medal.app` host, and the real System Settings panes show `Medal.app` enabled for Microphone and Screen & System Audio Recording. Camera remains opt-in; a fresh normal clip with Medal's microphone setting enabled is still needed to verify microphone packets/playback, and revocation/regrant is not yet tested.
- A repeated generic recorder-error loop was traced to a 96 kHz ScreenCaptureKit microphone being passed to a 96 kHz AAC converter (AudioConverter OSStatus `1718449215`). AAC output is now fixed at 48 kHz with native resampling; microphone encoder failure is isolated and reported once, and terminal capture failure is idempotent. The signed app was restarted with no new converter failures or recorder-error notifications. A fresh normal UI clip with microphone enabled is still required to verify microphone packets and playback.
- The extra Dock item was a stale foreground Launch Services registration for an Electron utility helper, not the native recorder. The builder now enforces `LSUIElement=true` on all Electron helper bundles; a clean re-registration/launch leaves only the `Medal` Dock identity. Medal's imported `Start Test` button is a voice-trigger recognition test, not a microphone monitor, so it intentionally produces no audible sidetone.
- The original Windows better_sqlite3 and Velopack `.node` files are PE x86-64 and unusable on arm64 macOS.
- The inherited 12-test suite uses adapted dependencies and proves only its documented protocol/library subset.
- The current development client still tries one Windows registry-based external-clip discovery command on macOS; A04 remains open until that path has an explicit platform adapter.
- The prepared FFmpeg/ffprobe diagnostic tools originate from a Homebrew GPL-enabled development build, and the SQLite CLI is a development copy of the system tool. They are not a self-contained or release-cleared A07 package. The native recorder and MP4 mux path do not link those Homebrew libraries; the signed helper uses Apple frameworks and system libraries only.
- The native helper currently covers the handshake/readiness, settings, device-query and shutdown subset. Heartbeat/reconnect, malformed/oversized frames, slow handlers, duplicate in-flight IDs and most capture/control RPCs remain incomplete.
- `getActiveProcesses` uses the typed native process/window model and translates only at the wire boundary. Earlier ADOFAI/Minecraft category evidence remains scoped to its reports. `audioProcesses` now enumerates active HAL clients; the original UI listed all three tone apps. New helper-family aggregation is build/model-tested, not permissioned isolation evidence. Target and audio-family lifecycle monitoring remain open.
- The original client's renderer IPC wrapper resolves an explicit recorder wire error as `null` after logging it. Wire error `-32601` is verified, but renderer capability controls must prevent unsupported calls rather than depend on Promise rejection.
- Display enumeration now returns the recovered outward shape plus real in-memory ScreenCaptureKit thumbnails and friendly labels verified in the original UI. Persistent stable-ID mapping across topology changes, duplicate-name selection and hotplug behavior are not implemented.
- The prepared tree and Apple-Development-signed app are ignored under `artifacts/`; they are not Developer-ID signed, notarized, redistributable, or release candidates.
- ScreenCaptureKit display and individual-window H.264 capture plus display HEVC capture pass short real runs through hardware-required VideoToolbox. Requested/final resolution, content rect/scale and aspect-fit geometry are now separated and the final H.264 operational run produced exact 1920x1080 from a 2560x1440 source. Source disappearance, minimized/offscreen behavior, complete color/HDR attachments and long-duration performance remain unverified.
- Separate native system-audio and microphone ScreenCaptureKit outputs feed independent AudioToolbox AAC-LC encoders. The operational H.264 run produced 379 system-audio packets with zero encode failures/discontinuities; its short-run start offset was +41.133625 ms and the acknowledged registration snapshot's end drift was -40.352126 ms. Microphone permission/capture is not tested and the 30-minute A/V drift gate remains open, so these short values are diagnostic evidence only.
- One real physical hotkey replay now survives timestamp-based idle periods, begins at a configured keyframe, writes H.264/AAC without transcoding, passes AVFoundation and ffprobe validation, is acknowledged by original `contentCreate`, generates the original thumbnail/library row, plays/seeks through the imported Electron runtime and persists unchanged over full app restart. Crash/disk-pressure/export recovery, duplicate contentCreate/idempotency, authenticated original-library UI, editor and upload remain unverified.
- The operational shortcut test covers one `Command+Shift+8` short-press and a synthetic physical-event dispatch probe. F-keys, keyboard-layout changes, conflicts, rebinding rollback, suspension, restart registration, sleep/wake and press/release behavior needed for push-to-talk remain open. The adapter returns OS registration failures rather than claiming success.
- The unauthenticated original renderer exposes only Medal's Welcome/login flow. The underlying original content handler, database row, thumbnail and imported-runtime playback/restart checks pass, but a visible original library-card/player test now legitimately requires login to the isolated profile; authentication has not been bypassed and no upload has been attempted.
- This Apple M5 Max exposes hardware H.264/HEVC encoders but no registered VideoToolbox AV1 encoder; a hardware-required AV1 session fails with OSStatus `-12908`. AV1 is honestly hidden on this host. This is host-specific evidence, not a global Apple-silicon claim.
- Hardware HEVC SDR packet capture passes, but HDR metadata/colors, container muxing, playback, thumbnail, editor/export and Medal service compatibility are unverified. H.264 remains the compatibility default.
- The original renderer Desktop selector and status UI now drive direct native display capture, with recovered `captureStarted`, `gameState`, and `captureStopped` events verified. The original Game chooser's ADOFAI automatic target/classification path is also evidenced; failed-source cleanup now waits for the old stream to stop before replacement, while Minecraft fallback and target lifecycle behavior remain unverified.
- An earlier normal Desktop UI run emitted a real `gameState` request but returned HTTP 400 `members must not be null`; this failed evidence is retained. The recovered `Context.Members` list is now sent as `[]`, and the post-consent ADOFAI run produced the accepted category game-state sequence. A synthetic app-level key event still did not reach Carbon and is not replay evidence; the next replay gate requires a physical hotkey in one single-instance client.

## Recovered-contract unknowns

- Bitrate is resolved for the pinned client/recorder hashes: the numeric wire value is decimal Mbps and the original recorder multiplies by 1,000,000 for native bits/second. Changed builds must fail the hash/predicate verifier and be retraced.
- Complete nested DTO/error/event payloads and event ordering outside tested paths.
- Proactive client `user` behavior and hardwareId/capability/JWT behavior on a legitimate port installation.
- Continuous-session `contentUpdate` and completion semantics.
- Production contentCreate retry/idempotency and client path-renaming reconciliation.
- Multi-track ordering, labels, editor metadata, and service acceptance.
- Broadcast, overlay-injection, auto-clip plugin, and voice semantics not established by method names alone.
# Audio review open gates (updated 2026-09-25)

- September 20 original audio-edit playback/restart claims are withdrawn: retained logs contain ENOENT and decoder-open errors. Fresh source-preserving edits pass 40 FFmpeg fixture checks and 11 AVFoundation MP4/M4A decodes. New September 25 synthetic original-UI overwrite/unmute/Save Copy/restart passes on exact persisted files. See `reports/native/audio-20260925-status.md` for narrow scope and remaining tests.
- Xcode-beta is no longer installed; fresh builds use installed Xcode 27.1 (27A9269) in `build-macos-20260925`. Old generated artifact targets were removed outside this work; broken managed links are preserved, with new managed roots for these builds.

- The aggregate Specific Apps master is replaced by a shared clock-aligned PCM mixer. Synthetic hardware tests and actual normal original-UI SCK/HAL All PC/Specific Apps tone isolation and 25%/50% gains pass; actual microphone/150%/device/lifecycle/sustained routing remains open. See `reports/native/audio-20261002-endpoint.md` and the retained earlier evidence.
- The native Medal Clip Sound source is intentionally reported unavailable until a project-owned feedback PCM bus is implemented. It is never mapped to the Electron host PID or silently replaced by whole-system audio.
- HAL process enumeration and bounded tap timing/format diagnostics are implemented; permissioned per-app 440/660 Hz isolation with unselected 880 Hz excluded now passes on this Mac. Full helper-family/two-instance/device/target lifecycle and long-duration routing are not thereby verified.
- The imported original-client sidecar audition controller and secure range-serving protocol pass short original-UI mute-both/save/restart/unmute/copy/restart tests, plus an actual browser audio-graph meter. Individual-source/restart and cancel/seek/rate/lifecycle coverage, physical sub-100-ms audible response and ten-minute sync remain open. Persistence failure/rollback is injected in unit tests, not the real user's library.
- The AVFoundation probe now has an explicit audio-only mode; 11 synthetic MP4/M4A decodes pass. Old audio-only failures are preserved. Edited current-row media passes independent ffprobe/AVFoundation and actual imported-client decoded playback. No clip upload or publish test is run.
