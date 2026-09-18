# Native-platform cross-check and implementation decisions

**Prepared 2026-09-18.** This is a researched design for implementation, not a completed native port. The build-pinned Medal facts come from `research/PROTOCOL.md`, `research/FINDINGS.md` and their evidence. Public platform capabilities are indexed in `SOURCES.md` as S01–S31. Everything described as a choice, policy, gate or proposed architecture is an engineering recommendation rather than an observed behavior of Medal.

## 1. Recommended boundary and languages

Keep Medal's application logic on a target-native Electron runtime. Replace only the operating-system integration, native dependencies, updater/supervisor and identified recorder interface. Implement an independent recorder rather than loading the Windows `MedalEncoder.exe` or reproducing its 195 P/Invokes and the 196-entry ScopeSharp wrapper.

Use C++20 for common control/protocol, settings, encoded packets, replay, export and recovery. Use Objective-C++ for the macOS backend and C++ for Linux. Objective-C++ directly calls Apple's frameworks and integrates with C++ without turning pixels into serialized messages. A small Swift bridge is appropriate for a Swift-only optional speech API. This language selection is not a measured speed comparison to Rust or Swift; it minimizes interface friction in this particular two-platform project.

Native control transport: Boost.Beast/Asio plus explicit nlohmann/json DTOs (S28–S29). Media container writing: libavformat/libavutil, not an FFmpeg subprocess in the live pipeline (S22). Retain a separate packaged native ffmpeg/ffprobe toolchain because the existing Electron client uses media tools in its editor/library paths. Compile only the needed native components and record dependencies/licenses (S23).

The previous kit proposed an OBS bridge for the first proof. That historical recommendation is preserved in its original report. **For this user's requested final product, the master prompt instead requires a direct native recorder; OBS is optional development comparison tooling, not a dependency.**

## 2. Concrete platform mapping

| Responsibility | macOS 27 / arm64 implementation | Linux x86-64 implementation | Shared requirement or limit |
|---|---|---|---|
| Development toolchain | Stable Xcode with macOS 27 SDK; Apple clang/ARC Objective-C++; CMake/Ninja | C++20 compiler; CMake/Ninja; distro development packages | Pin dependency versions and build provenance; inspect installed SDK/runtime |
| Native app shell | Native Electron 43.2.0 initially; correctly signed application/helper | Native Electron 43.2.0 initially; desktop integration | Original observed version, not a universal promise of compatibility |
| Source selection | SCContentSharingPicker; SCShareableContent/SCContentFilter | XDG ScreenCast portal through GDBus | A process name is not a native capture authorization |
| Video acquisition | SCStream; CMSampleBuffer/CVPixelBuffer/IOSurface | Permissioned PipeWire stream; negotiated SPA buffers | Native resource ownership; no raw frames in Electron IPC |
| Ordinary system and microphone audio | SCStream separate audio/microphone outputs; one microphone owner | Separate policy-authorized PipeWire audio graph access | ScreenCast's restricted connection is not a general audio connection |
| Independent app/game audio | Core Audio process taps when the required selection is not supplied by SCStream | Route the appropriate application streams, not merely an output monitor | Process groups/subprocesses and permission failures need real tests |
| Additional microphone modes | Core Audio/AVAudioEngine where SCStream microphone is not active | PipeWire input streams | Gain, mono, gate, push-to-talk, drift and hotplug handling |
| GPU transformations | Optional Metal with CVMetalTextureCache and owned pixel-buffer pools | Encoder-native VPP where sufficient; EGL/OpenGL DMA-BUF import for composition when supported | Skip extra rendering passes in a plain capture path |
| Video compression | Direct VTCompressionSession, query actual hardware use | libavcodec VAAPI for suitable Intel/AMD; NVENC for suitable NVIDIA | Compiled encoder name is not proof that a session works |
| Audio compression | AudioToolbox AudioConverter AAC | libavcodec AAC | Preserve priming, channels, sample timing and codec configuration |
| Replay and file writing | Shared packet ring / libavformat | Same common code | Keyframe-safe start, timebases, configuration generations, bounded memory |
| Camera | AVFoundation capture session; Metal compositor | Camera portal/PipeWire; direct V4L2 only for a deliberately supported environment | Permission/device availability separate from screen capture |
| Operational shortcuts | SDK-supported registered shortcuts; consented event tap only when necessary | GlobalShortcuts portal; X11 grabs only in X11 backend | Need press/release for PTT; rebind and actual-assigned-key behavior |
| Screenshots | SCScreenshotManager | A permissioned frame or native Screenshot portal path | Trace Medal's screenshot event/library semantics separately |
| Voice clipping | Optional SpeechAnalyzer/SpeechTranscriber when assets/locale/hardware permit | Optional local provider with explicit model/license audit | Not a required always-on speech service; no silent cloud fallback |
| Library and editor | Patched original client plus native SQLite/FFmpeg resources | Same original client flows with Linux dependencies | Recorder submits completed files; client owns library database |
| App lifecycle | AppKit helper lifecycle, stable code identity, normal privacy prompts | User-session process, D-Bus/portal lifetime and desktop identity | Stop on parent exit; don't create a root capture daemon |

Platform documentation: S01–S11 for Apple; S13–S21 for Linux; S24–S27 for Electron. The platform mapping is a design, not a declaration that every row has already passed a native test.

## 3. macOS: details that change the plan

### Three outputs do not require three independent recording stacks

Apple's ScreenCaptureKit update describes separate screen, system-audio and microphone outputs (S04). Start with these for ordinary recording. Do not simultaneously open a second microphone engine just because an older design used AVAudioEngine. Use a separate microphone path for mic-only tests or modes that need it, with an explicit ownership transition.

SCStream application filtering and Core Audio process taps solve related but different selection problems (S02, S05). Use taps for independent audio-only, process-group or routing requirements, not as an unconditional virtual-audio-driver dependency. Map actual Core Audio process objects instead of assuming their IDs equal operating-system PIDs. Validate multi-process games, browsers and the user's selected output/microphone routes. A game-only setting must never silently become capture-all-system-audio.

### Metal does graphics; VideoToolbox does compression

The default capture frame can often avoid an extra application-owned rendering pass. Use Metal only where source configuration alone cannot supply the needed crop/scale/color/composite operation. Preserve ownership until encoding has finished consuming the buffer. Use VTCompressionSession for actual H.264/HEVC, query supported properties and require/check hardware operation where selected (S06–S08, S31).

The default interop target is H.264 SDR with AAC. HEVC/HDR needs end-to-end testing through the actual Electron player's decoder, Medal's editor, and an authorized upload—not just a successful VideoToolbox session. Color range, primaries, transfer function, bit depth and tone mapping are separate implementation tasks.

SCRecordingOutput is useful to verify a simple native recording independently (S04). It is not the primary implementation in this design: the project needs controlled encoded-packet replay, multiple tracks, recovery and a shared exporter. That is a design choice, not a claim that the API cannot record useful files.

### Permissions and packaging are part of the recording implementation

Build with the installed macOS 27 SDK and use documented native APIs rather than hypothesizing new macOS 27 functions (S01). Capture-owning helper identity must be stable. Test privacy prompts with the final parent/helper launch arrangement, not only a command run from Terminal. Camera, microphone, system-audio taps and screen sharing have distinct authorization/configuration paths (S03, S09–S10).

Do not assume the helper automatically inherits every permission granted to Electron. Record the responsible application shown by macOS, requirements of the actual launch mechanism, regrant behavior after development signing, and revoked-permission handling. Do not invent a screen-recording usage-description key or treat an entitlement as user consent.

## 4. Linux: differences to solve explicitly

### The portal is a user-authorized source, not a process-to-window API

Use CreateSession → SelectSources → Start → OpenPipeWireRemote (S13), handling asynchronous requests, cancellation and session closure. Introspect interface version and backend capabilities. Current documentation describes v6 `pipewire-serial` identity; use it with the supported target-object path where available and test older node-ID behavior separately. Rotate one-use restore tokens; persistence is not permanent consent.

Expose a native picker button and a real source mapping in Medal's UI. A Windows `processName` request cannot authorize an arbitrary Wayland window. Restore failure should reopen selection, not capture a broader screen silently.

The ScreenCast remote only exposes granted screen-cast nodes (S13). Connect to normal-policy audio streams separately (S16–S17). Camera is separately authorized (S15). A screen session alone does not establish access to the user's microphone or webcam.

### DMA-BUF is not automatically a zero-copy codec pipeline

Negotiate formats and honor every plane/stride/modifier plus synchronization requirements (S18, S21). Returning the PipeWire buffer before the encoder/compositor has finished can cause corruption even when a short demo happens to look correct. Queue/dequeue ownership and real-time callback restrictions are part of the implementation (S16).

Runtime probe the real hardware encoder using frames, not just `ffmpeg -encoders`. VAAPI and NVENC are selected targets (S19–S20). Cross-GPU capture and unsupported modifiers may require additional copies. The UI/performance report must disclose a software conversion or CPU readback; no universal zero-copy claim. Vulkan is not a prerequisite for the first Linux backend.

### Global shortcuts and game discovery vary with the desktop

Use the GlobalShortcuts portal where implemented, including Activated/Deactivated for press/release (S14). The portal's actual assigned key combination must be reflected in the UI. An unavailable backend needs an honest fallback, such as an in-app save action, not a claim that the configured global hotkey is active.

An X11 implementation is a separate supported backend. Access to XWayland does not grant access to all native Wayland applications. Test GNOME and KDE Wayland, and only label additional compositor/X11 combinations supported after their own tests. Process-name mappings for Wine/Proton games are discovery hints; they are not a reason to inject Windows hooks or evade anti-cheat controls.

## 5. Client and wire integration that must be implemented on BOTH systems

The actual integration contract is recovered rather than inferred:

1. Native Electron hosts a loopback WebSocket server; the helper connects using the **selected** `--electronPort`, plus original environment/wsComms arguments. Add a per-launch local secret in a compatible private extension; no control-plane listening on the network.
2. Keep the asymmetric JSON-RPC results. Client responses wrap data in Medal's success/errorMessage/data envelope; helper responses are ordinary method results. Reject an unnegotiated version even if the client returns nominal success.
3. Preserve all 34 recorder methods, 40 client handler names and 60 setting keys as an **implementation inventory**, not a blanket success-stub table. Trace uncertain return schemas/bitrate units and proactive `user` behavior.
4. Native operational actions are driven by settings such as `clip;length=30`. There is no observed inbound `saveClip` method. A new picker/action/capability command must be visibly named as a port extension and implemented on both ends.
5. Preserve device DTO casing, per-game settings scope, state transitions and genuine readiness. Publish capabilities based on actual permissions/devices/encoders, not Windows GPU names.
6. Close the exported file before contentCreate. Keep a UUID-keyed pending-export journal, preserve clips after failures, and reconcile acknowledgement loss and client-renamed paths. Do not mutate the Medal library database from the recorder.

For client startup specifically: replace both Velopack entry points; rebuild/provide the matching Electron SQLite addon and native recovery CLI; replace the Windows recorder AssetManager/supervisor; audit all FFmpeg/remux/resource paths; maintain normal account authorization. The inherited SQLite test substituted its accessor; it does not establish that the real addon or native GUI already works. See `research/FINDINGS.md` and S24.

## 6. The patcher/signing issue

A local patcher cannot modify the resources of a signed `.app` and retain its original final signature (S26). Nor can it create the project's Developer ID signature without the private key. Do not distribute such a key or conceal ad-hoc development signing as notarized distribution.

The proposed release architecture is an **immutable project-owned signed bootstrap/helper**, with user-imported, hash-verified patched Medal JS/assets outside the signed bundle. Native dependencies need correctly signed packaging and verified paths. This preserves a stable recording-helper identity while permitting local client import. It requires actual validation of Electron's loader, fuses, ASAR integrity/library validation, update trust and distribution policies. It is an engineering direction to prove, not a guarantee of notarization approval (S12, S26).

During implementation, an explicitly developmental locally assembled app is acceptable. It must not be represented as a release artifact, and no systemwide security disablement is an installation step.

## 7. What remains uncertain

Exact build-specific bitrate conversion, all nested state/event payloads, serialized error shapes, original overlay/broadcast/plugin semantics, client account/capability guards and production clip-registration idempotency still require inspection or traces. Current evidence is sufficient to build the adapter incrementally, not to fabricate these contracts.

Native API availability is not a benchmark. Apple silicon model, source resolution, display refresh rate, camera/effects, driver/compositor behavior and workload all change cost. Final acceptance must report actual hardware, selected encoder, dropped frames, memory, clock drift and game frametime impact separately.

The output is a detailed implementation contract plus a reproduced research baseline. Complete native GUI/capture/GPU/permission/editor/service testing remains work for Codex on the specified destination machines.
