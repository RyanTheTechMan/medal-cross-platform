# Start here

This pack contains the implementation prompts, platform cross-check, acceptance criteria and prior Medal research needed for the macOS-first/Linux-second project. **It does not contain the finished port.** The 12 reference protocol tests were reproduced in this research session; full native application/capture tests remain to be run on the destination machines.

## macOS session

Extract this folder into a dedicated working repository on the Apple silicon Mac running macOS 27. Keep the files in the repository root so Codex finds `AGENTS.md`. Place your own original files in an ignored `inputs/` directory:

```
inputs/Medal-production-2637.461.1-Setup.exe
inputs/v2638.2751.1.zip
```

These archives are not shipped in this pack and conversation attachment paths do not automatically exist on that Mac. The recorder ZIP is research/reference material, not a macOS executable to launch. Development requires an appropriate installed Xcode SDK/toolchain; the final end-user product must not require compilers.

Open that repository in Codex and use:

```text
Read AGENTS.md and CODEX_MASTER_PROMPT.md completely, then PLATFORM_CROSSCHECK.md,
ACCEPTANCE_TESTS.md, SOURCES.md and the recovered research. Implement this project
on this Apple silicon Mac running macOS 27, starting at M0 and continuing through
the macOS completion gates. The original input archives are in inputs/.

Build the actual native Electron client integration and native recorder, not
just a demo or another plan. Use the specified cross-platform C++ core with
native Apple-framework adapters. Keep progress and test evidence on disk and
produce the actual HANDOFF_LINUX.md when macOS work is ready to transfer.

Do not assume any native tests have already passed. Request genuinely necessary
permission/account/signing interaction, preserve privacy and entitlements, and
continue independent tasks rather than faking successful tests.
```

The master brief is the detailed prompt; this short activation text is not a replacement for reading it.

## Linux session

Transfer the **actual implemented repository**, commit history, dependency locks, nonprivate fixtures, results and handoff to Linux. Do not transfer only the original prompt pack and expect macOS code to appear. Bring your own original installers separately where required; do not copy account tokens/private recordings into a public repository.

Use:

```text
Read AGENTS.md, CODEX_MASTER_PROMPT.md, LINUX_CONTINUATION_PROMPT.md and the actual
HANDOFF_LINUX.md, progress files and test reports. Continue this same project on
Linux x86-64 through all Linux implementation and validation gates. Re-run the
shared baseline first; do not assume the macOS phase passed without evidence.

Preserve the macOS implementation and shared Medal protocol/replay engine. Finish
the Linux native Electron setup, portal/PipeWire capture, audio, shortcuts,
hardware encoding, full Medal-library/editor integration and packaging. Test on
real available desktops/hardware and mark missing environments untested. Do not
replace absent capabilities with successful no-op replies.
```

## Files to use

- `CODEX_MASTER_PROMPT.md`: full product specification, concrete dependencies/APIs, client patches, recorder protocol, implementation stages and release rules.
- `PLATFORM_CROSSCHECK.md`: why these native APIs are selected and where the two platforms differ.
- `ACCEPTANCE_TESTS.md`: end-to-end gates and proposed measurable performance targets.
- `LINUX_CONTINUATION_PROMPT.md`: Linux execution and regression instructions.
- `AGENTS.md`: persistent repository instructions pointing to the full documents.
- `FEATURE_LEDGER.json`: 34 recovered recorder methods, 40 client handlers, 60 settings and workflow inventory, all native implementation states initially not_started.
- `SOURCES.md`: primary public references and limits of the research.
- `research/`: the original investigation, evidence, extractor and isolated tests; its older OBS-first suggestion is superseded for the final product by the master prompt, not deleted from the historical evidence.
- `validation/`: reproduction results and exact limits; no native GUI/GPU claims.
- `templates/`: blank progress and platform-handoff templates, not results.

## Reproduce the inherited research baseline

The development-only tests require Python, a compatible Node with node:sqlite/global WebSocket, and FFmpeg/ffprobe with libx264/AAC. The current reproduction used Node 22.16.0. The final recorder need not use libx264; this is synthetic test generation, not its capture/encode implementation.

From the repository root, with the original installer present:

```sh
python3 research/tools/extract_medal.py inputs/Medal-production-2637.461.1-Setup.exe --out research/extracted
python3 research/tests/make_media.py
node research/tests/original_client.cjs research/extracted/app
```

The extractor refuses an existing output directory; use a new output path to repeat an extraction. Media/results are generated locally. The reference scripts do not start the original Windows executables, capture your screen/microphone or log in to Medal. Twelve isolated passes are expected for the pinned input. Actual native SQLite, Electron GUI, capture, service and packaging tests remain distinct.

Run `python3 validate_pack.py` to check the documentation/evidence inventory before development. It validates the starter pack's consistency, not the port's functionality.
