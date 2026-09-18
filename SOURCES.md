# Primary-source cross-check

Research date: 2026-09-18. These are public API references, not evidence that the proposed Medal port is implemented. `research/` contains the separate, build-pinned Medal investigation. Some Apple API pages expose only a JavaScript shell to automated readers; their titles/locators and Apple's accessible conference transcripts were checked. The agent must verify symbol availability, signatures, entitlements and deprecations in the installed macOS 27 SDK before committing implementations. Do not infer undocumented macOS 27 improvements from the target OS number.

## Apple

**S01 — Xcode SDK/system requirements.** Apple lists Xcode 27 with the macOS 27 SDK. Use a stable installed Xcode toolchain with that SDK, capture its build number, and compile native arm64. Do not choose a beta merely because it is newer.
`https://developer.apple.com/xcode/system-requirements`

**S02 — Meet ScreenCaptureKit.** Capture/filter APIs, native samples, application-level audio filtering and IOSurface-backed video. Relevant names: SCShareableContent, SCContentFilter, SCStreamConfiguration, SCStream, SCStreamOutput.
`https://developer.apple.com/videos/play/wwdc2022/10156/`

**S03 — What's new in ScreenCaptureKit.** Native content picker, stream changes, screenshot API and system sharing UI. This does not promise that arbitrary background capture permission persists indefinitely.
`https://developer.apple.com/videos/play/wwdc2023/10136/`

**S04 — Capture HDR content with ScreenCaptureKit.** Separate screen/system-audio/microphone outputs; captureMicrophone and microphoneCaptureDeviceID; HDR settings/presets; SCRecordingOutput for direct file recording. Our replay-buffer design is an engineering choice, not a built-in replay feature claimed by this source.
`https://developer.apple.com/videos/play/wwdc2024/10088/`

**S05 — Core Audio process taps.** Native capture of outgoing audio from a process or process group. Use Apple's sample and actual SDK for the complete process-object, aggregate-device and permission lifecycle.
`https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps?language=objc`
The accessible sample text confirms CATapDescription → AudioHardwareCreateProcessTap, aggregate-device use and NSAudioCaptureUsageDescription for its permission flow. Verify actual deployment/runtime behavior locally.

**S06 — Require a hardware video encoder.** Apple documents failure of compression-session creation when hardware acceleration cannot satisfy the requested configuration. Validate actual resource/profile availability with a real session; setting this requirement already implies hardware acceleration is enabled.
`https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_requirehardwareacceleratedvideoencoder`

**S07 — Inspect actual hardware encoder use.** Apple documents this Boolean query through VTSessionCopyProperty; do not equate a configuration request with successful hardware operation.
`https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_usinghardwareacceleratedvideoencoder`

**S08 — Low-latency VideoToolbox encoding.** Background on hardware compression/latency tradeoffs. For replay recording, choose settings by measured quality, load and export correctness rather than automatically selecting every low-latency option.
`https://developer.apple.com/videos/play/wwdc2021/10158/`

**S09 — Capture authorization.** Camera/microphone authorization reference. Check usage descriptions and request permissions in the actual capture-owning signed application.
`https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media`

**S10 — System-audio usage description.** API locator for NSAudioCaptureUsageDescription; distinguish this from microphone authorization and screen sharing consent.
`https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription`

**S11 — SpeechAnalyzer.** Native speech processing with module/asset availability considerations. Optional voice clipping must be off by default and must not silently send audio to a cloud service.
`https://developer.apple.com/videos/play/wwdc2025/277/`

**S12 — Notarization.** Distribution/signing reference. A development build or locally modified app is not automatically a notarized release.
`https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution`

## Linux/media

**S13 — ScreenCast portal.** CreateSession → SelectSources → Start → OpenPipeWireRemote. Current documentation describes interface v6. Introspect the installed interface/backend; rotate one-use restore tokens. Prefer pipewire-serial/PW_KEY_TARGET_OBJECT where returned; retain a tested fallback for older backends. The granted remote exposes the screen-cast nodes, not arbitrary audio devices.
`https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html`

**S14 — GlobalShortcuts portal.** Session-scoped bindings, Activated/Deactivated, actual assigned shortcuts and reconfiguration. Availability and supported behavior require testing on each compositor.
`https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html`

**S15 — Camera portal.** Separate camera authorization/PipeWire access, not implicit permission from a ScreenCast session.
`https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Camera.html`

**S16 — PipeWire stream C API.** Real-time callback constraints, dequeue/queue lifetime, format negotiation, timing and target selection.
`https://docs.pipewire.org/group__pw__stream.html`

**S17 — PipeWire properties.** Device/node identity, targets, routing and clock/resampling properties. Do not infer application-level audio isolation merely from the existence of a device monitor.
`https://docs.pipewire.org/page_man_pipewire-props_7.html`

**S18 — Kernel DMA-BUF synchronization.** Buffer sharing and implicit/explicit synchronization; exporting a file descriptor does not eliminate synchronization or ownership requirements.
`https://www.kernel.org/doc/html/v6.12/driver-api/dma-buf.html`

**S19 — VA-API.** Linux hardware video API; actual driver/profile/format support must be queried.
`https://intel.github.io/libva/`

**S20 — NVIDIA Video Codec SDK.** Hardware encoding interface and capabilities; runtime hardware/driver support is separate from compiled FFmpeg codec names.
`https://developer.nvidia.com/video-codec-sdk`

**S21 — FFmpeg DRM hardware frames.** AVDRMFrameDescriptor and object/layer/plane representation. This is a representation, not a guarantee that every encoder can import every DMA-BUF.
`https://ffmpeg.org/doxygen/trunk/hwcontext__drm_8h_source.html`

**S22 — libavformat muxing.** Common encoded-packet container writing. Using it for muxing does not require using FFmpeg as macOS screen capture or as a software video encoder.
`https://ffmpeg.org/doxygen/trunk/group__lavf__encoding.html`

**S23 — FFmpeg licensing/build conditions.** Record exact configuration and dependent library licenses; GPL/nonfree features change distribution obligations. Tests using system FFmpeg do not establish that its build is suitable for shipping.
`https://ffmpeg.org/legal.html`

## Electron/shared implementation/Codex

**S24 — Electron native modules.** Match/rebuild native modules for the chosen Electron ABI, platform and architecture, then test the bundled JavaScript/native interface.
`https://www.electronjs.org/docs/latest/tutorial/using-native-node-modules`

**S25 — Electron 43.2.0 release.** Public release locator corresponding to the runtime version found inside the supplied installer. Verify target downloads/checksums and local runtime values; do not silently upgrade while debugging compatibility.
`https://github.com/electron/electron/releases/tag/v43.2.0`

**S26 — Electron code signing.** Sign the resulting code bundle in the correct order; changing signed resources is a separate operation from retaining a valid final signature. Separate local development from releasable packaging.
`https://www.electronjs.org/docs/latest/tutorial/code-signing`

**S27 — Electron globalShortcut.** Useful single-action bootstrap alternative and desktop-identity reference. It is not our primary cross-platform press/release implementation. Current docs differ from older feature-flag examples; check the selected Electron version before adding switches.
`https://www.electronjs.org/docs/latest/api/global-shortcut`

**S28 — Boost.Beast.** Proposed shared native WebSocket transport on Boost.Asio. This is a control-plane library, not the capture path. Build only the needed client functionality and pin the dependency.
`https://www.boost.org/doc/libs/latest/libs/beast/doc/html/index.html`

**S29 — nlohmann/json.** Proposed shared JSON implementation; use explicit DTO serializers rather than a global naming conversion.
`https://json.nlohmann.me/`

**S30 — Codex AGENTS.md guidance.** Repository instructions can direct Codex to the larger specification and progress/handoff files. A prompt does not substitute for permissions, real hardware, code signing credentials or test results.
`https://developers.openai.com/codex/guides/agents-md/`

**S31 — FFmpeg's VideoToolbox encoder implementation.** Additional primary-source implementation reference for compression property names, capability checks and parameter mapping. Do not copy configuration from this file without matching the pinned FFmpeg/SDK version and its license.
`https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/videotoolboxenc.c`

## Evidence rule

Tag conclusions as: recovered Medal behavior; public API capability; proposed implementation; compiled; isolated-test passed; native-test passed; or unresolved. A passing mocked test is never a native-test pass. Sources describe interfaces, not Medal's permission to use a service or successful end-to-end performance.
