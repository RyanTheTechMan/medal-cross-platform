# Codex continuation prompt: complete the Linux implementation

You are continuing the **same repository** previously developed on Apple silicon/macOS 27. Implement and test the Linux x86-64 native client/recorder, preserving macOS behavior. Do not recreate the project, replace the upstream Medal UI with a generic demo, fork the protocol, or treat cross-compilation as a substitute for real Linux tests.

## Read before changing behavior

Read AGENTS.md, CODEX_MASTER_PROMPT.md, PLATFORM_CROSSCHECK.md, ACCEPTANCE_TESTS.md, SOURCES.md, FEATURE_LEDGER.json, the actual HANDOFF_LINUX.md and progress/decision/limitation reports. Read the recovered `research/PROTOCOL.md` and evidence. The handoff template is not a completed handoff. Where the actual repository has no native code/results yet, say so and implement the prerequisites; do not assume the macOS phase passed merely because this prompt is being run second.

Inspect Git status, input hashes, dependency/runtime locks, build scripts and the common interfaces. Preserve unrelated local changes. Inventory which common components are genuinely implemented and verified: JSON-RPC, settings, source IDs, packet timing, replay, mux/export, outbox, session lifecycle, UI patches, SQLite and signing/update boundaries. Correct an existing shared bug through a regression test, not a Linux-only wire workaround.

## L0 — Real environment and shared baseline

Record distro/OS, uname architecture, glibc, kernel, compiler, desktop/session, compositor, display server, PipeWire and portal/frontend/backend versions, GPU(s)/driver, render-node access and installed codec support. Use actual tool results. Do not install a bundle of speculative packages blindly, replace graphics drivers, change global audio defaults or change security policies without specific need and authorization.

Run inherited isolated tests and the implemented shared-core/unit/integration suite first. Keep Windows input archives read-only and ignored. Build common native code with CMake/Ninja. Use native Electron and rebuild the exact required SQLite addon for its actual ABI; development Node's ABI is not sufficient. The inherited SQLite test is an adapted test harness, not acceptance for the real addon.

## L1 — Linux client/bootstrap/package

Complete importer/patcher on Linux: safe extraction, exact input/patch hashes, both Velopack entry points, native SQLite worker/CLI, native FFmpeg/ffprobe, recorder AssetManager replacement and correct native resource paths. Existing macOS implementation should expose these as platform adapters, not copied special cases.

Run the actual Medal Electron app from a native desktop entry in a fresh port-owned profile with minimal PATH. Validate library persistence, main/preload/renderer boundaries, source-selection UI, settings, editor and normal authentication/deep-link behavior. Preserve account/entitlement guards. Do not use --no-sandbox, disabled web security or a forged win32 platform to hide failures.

Use explicit XDG config/data/cache/state paths and a stable reverse-DNS desktop identity shared by the host/helper as appropriate. Do not move a macOS user's credentials or profile implicitly. Prove the actual selected WebSocket port reaches the native helper. Keep the existing asymmetric envelopes and per-launch authentication. Validate startup, stop/restart and parent death against the actual native client, not just a mock server.

## L2 — Permissioned native video sources

Implement GDBus/GIO ScreenCast calls with asynchronous request responses and correct Unix-FD extraction: CreateSession → SelectSources → Start → OpenPipeWireRemote. Inspect installed versions/features before using options. Support cancel/deny/sessionClosed, explicit source switching, restore failure and rotation of returned single-use restore tokens.

Use returned pipewire-serial with a supported PW_KEY_TARGET_OBJECT path where provided by current interfaces; support older session-specific node IDs where required. Do not persist an ephemeral node number as a universal source ID. A granted screen-cast PipeWire remote exposes the session's streams, not every audio/video node in the desktop.

Integrate native source selection into patched Medal. Use a real exported parent-window handle if available, otherwise the documented unparented behavior. Do not invent a Wayland handle from an arbitrary Electron window ID. Process names from the original protocol are outward identity hints; on Wayland they do not authorize capture of arbitrary windows. Preserve the user's exact consent scope.

Consume the stream using PipeWire/SPA C APIs. Negotiate dimensions/framerate/formats, strides, planes/modifiers and DMA-BUF versus shared-memory paths. Never block/allocate uncontrollably in real-time callbacks. Hold buffers until GPU/encoder consumption finishes; exercise intentional downstream delay to detect early buffer reuse. Propagate resize, format discontinuity and source closure into the common state/codec-generation engine.

## L3 — Encoding, GPU processing and clock correctness

Use libavcodec hardware sessions: VAAPI for supported Intel/AMD drivers, NVENC for supported NVIDIA devices. A listed encoder or successful library load is not proof of hardware recording. Query profiles/formats and encode actual test frames; report active GPU/path. Record driver/hardware/profile failures accurately.

For plain capture, avoid a gratuitous compositor. Use compatible DMA-BUF imports/DRM frames and encoder-native video processing where tested. For needed webcam/text/crop/color composition, use a validated EGL/OpenGL path through native APIs. Explicitly handle modifier, synchronization and cross-GPU limits. No universal DMA-BUF-to-NVENC zero-copy promise. An optional CPU copy/conversion fallback must be a visible policy with measured cost; hardware-only selection must not silently become software encoding.

Keep Linux frame representations behind backend interfaces. Reuse common encoded packets, timestamp conversion, keyframe-aware ring, libavformat writer and outbox exactly. Do not transmit frames through Electron. Linux audio encoding may use libavcodec AAC while keeping shared track semantics and timestamps. Probe baseline H.264/AAC first; add HEVC/HDR only with full player/editor/service capability checks.

## L4 — Audio, camera, actions and complete workflows

Use a separately authorized PipeWire audio connection for microphone/system/application streams. Distinguish a device monitor from game-only isolation. Test multi-process native/Wine/Proton games with independent sound sources. Do not capture unrelated apps when isolation fails or reroute/mute the user's normal audio as a shortcut. Handle default changes, rate/channel changes, device loss, gaps/drift and mic-monitor feedback.

Reuse DSP, gain, mono, gate, PTT, mix/isolated-track policy and action mapping. Implement a measured suppression option where feasible; label its actual provider. The same original Hotkeys actions trigger replay/bookmark/session/screenshot behavior. Use GlobalShortcuts portal sessions, Activated/Deactivated, actual assigned bindings, cancellation/rebinding and supported conflict behavior. If a backend lacks global shortcuts, explain and expose a usable in-app trigger rather than falsely registering keys.

Use Camera portal/PipeWire for camera authorization/access. Direct V4L2 is optional for explicitly supported nonsandboxed sessions. Render overlays through the same recording scene/compositor and avoid duplicate full-resolution preview pipelines. Recorded overlays are not Windows injected HUDs; do not emit overlayInjected falsely.

Implement screenshots and all portable original settings; complete real contentCreate acknowledgements, library thumbnails/playback, full sessions/bookmarks/contentUpdate, original editor trim/export and actual multi-track handling. Test a normal authorized private upload only with user consent. Inspect game-specific event providers and optional local speech support without fabricating upstream APIs or downloading model assets without approval.

## L5 — Real desktop and hardware matrix

Run the declared acceptance gates on actual GNOME and KDE Wayland environments where available. Optional wlroots/X11 require their own tests. Headless containers/Xvfb verify only the subset they can exercise; they do not prove Wayland portal, native GPU encode or privacy UI.

Test at least the target machine's real GPU encode path. Claims for Intel, AMD, NVIDIA, multi-GPU or other compositors require their own measured evidence. Mark absent equipment blocked/untested rather than universally unsupported or verified.

Exercise fullscreen/source changes, desktop locking, suspend/resume, session logout, mic/camera hotplug, stop/revoke permission, restore tokens, disk full, crashed helper/client, pending exports, duplicate acknowledgement and clean shutdown. Use synthetic visual/audio timestamp impulses for timing; real gameplay is additional. Report CPU/RSS/GPU-copy path/drops/drift/export latency and incremental game frametime, with settings and driver versions.

## L6 — Installation and handoff back to macOS

Produce a runnable native Linux artifact and user setup flow that imports the official installer without requiring end-user compilers, Node/Python or OBS. Start with a verified unpacked user-local build, then package appropriate deb/rpm/portable outputs for declared distributions. Do not claim one glibc build works on every distro. Delay Flatpak claims until portal identity, filesystem access, native dependencies and sandbox rules are demonstrated; don't paper over them with broad filesystem/privilege grants.

Test installation/upgrade/reimport/rollback/uninstall with a clean user and desktop launch. Preserve recordings. Register URI handlers and autostart only through user-visible choices. Keep updater components architecture-specific and pinned. No Windows recorder/addon may be restored by an upstream asset update.

Run shared regressions after common changes and retain macOS build coverage. When a Mac is not available, record exact changes requiring macOS re-test; don't say macOS still works solely because Linux does. Update FEATURE_LEDGER.json, reports, limitations and a cross-platform handoff with actual code/tests/artifacts and open items.

The goal is a working original Medal client plus native Linux recorder and tested feature coverage, not just compiling a PipeWire example. Continue through all gates feasible on the machine, surface required user interactions precisely, and never substitute false-success stubs or invented test results for implementation.
