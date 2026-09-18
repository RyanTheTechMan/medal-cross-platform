# Repository instructions: native Medal compatibility project

## Mission

Build the product specified in `CODEX_MASTER_PROMPT.md`. macOS 27 / Apple silicon first; continue the same source tree on Linux x86-64 afterward. Read the entire master prompt, platform cross-check, acceptance tests, primary-source index and recovered research. On Linux also read the continuation prompt and actual handoff. These files are requirements, not a request for another proposal-only response.

The initial repository is a prompt/research pack, NOT a completed native app. Existing isolated tests do not count as GUI, GPU, real capture or service tests. Implement, test and report accurately.

## Fixed design

- Native Electron running minimally patched user-imported Medal JS/resources; separate native recorder.
- C++20 shared core, Objective-C++ macOS framework adapters, C++ Linux adapters; CMake/Ninja. Optional small Swift speech bridge only.
- Native macOS ScreenCaptureKit/Metal-as-needed/VideoToolbox/AudioToolbox; Linux portal/PipeWire/VAAPI-or-NVENC. No OBS/Wine/Rosetta/MediaRecorder requirement in the final capture path.
- Shared protocol, settings, timestamps, packet ring, export/recovery and tests. Never serialize raw recording frames through Electron IPC.
- Electron is the WebSocket server; helper connects. Preserve recovered message names/envelopes and genuine state transitions. Private extensions must be namespaced and patched on both ends.
- Source/version/ABI locks; no global platform spoof; fix both updater entry points and the recorder download/AssetManager path.

## Evidence and test discipline

Read `research/PROTOCOL.md` and evidence before guessing an interface. Unknown DTO values, bitrate units or event order must be traced, not filled with plausible values. Preserve casing/scoped settings. A stub is not feature completion. Unsupported platform features need a visible reason, not successful no-op replies.

Use separate profiles and synthetic fixtures. Never mark skipped/manual/unavailable-hardware tests passed. Real-addon SQLite tests, actual native Electron communication, real capture, permission revocation, editor/export and authenticated workflows are separate gates.

Update `FEATURE_LEDGER.json` with actual code/test references per platform. Valid states: `not_started`, `investigating`, `implemented_unverified`, `verified`, `blocked`, `unsupported_with_evidence`. An unavailable lab GPU is `blocked`/untested, not a globally unsupported feature. Existing isolated test results are reference evidence only.

Run focused tests after each meaningful change; build before claiming code compiles. Record exact commands, versions, environment, exit status and artifacts. Never silently relax acceptance targets. Do not commit generated proprietary application files, account data, recordings, binaries or signing keys.

## Privacy, packaging and operations

Keep user-owned input archives read-only. Safe extraction, exact patch predicates, backups and atomic activation/rollback are mandatory. Do not run lifecycle scripts from the imported installer or install its private workspace dependencies. Do not write the recorder's own records into Medal's library DB; use the recovered registration protocol.

Do not bypass recording consent, TCC, portal authorization, sandboxing, authentication, paid entitlements or anti-cheat controls. Do not disable Gatekeeper/SIP, web security, TLS validation or Electron's sandbox to make a failing test disappear. No root recording daemon. Stop capture on parent death.

Ask only for genuinely necessary user interaction, such as a privacy prompt, login, upload confirmation or unavailable signing credentials. An instruction to develop does not authorize publishing clips, capturing private screens, changing account state or distributing proprietary code. Log redacted shapes, not tokens or raw private settings.

Preserve valid signing boundaries. Development/ad-hoc artifacts are not notarized releases. A local patcher must never receive a distributed publisher signing private key.

## Session continuity

Create/update `PROGRESS.md`, `DECISIONS.md`, `KNOWN_LIMITATIONS.md`, `HANDOFF_LINUX.md`, dependency locks and `reports/` as work proceeds. Read them when resuming rather than infer success from prior summaries. Maintain a short next-runnable-task section and exact failed/blocked gates. Do not treat a hypothetical future test as evidence.

Before a Linux handoff, include actual macOS build IDs, shared-interface changes, test results, known failures and commands. Linux work may extend the common core through additive/tested interfaces; it must not erase the macOS backend or fork the protocol.

End each work session with actual implemented changes, test outcomes, remaining blockers and artifact paths. Do not stop at a standalone recorder demo or label a release complete while mandatory client integration is missing.
