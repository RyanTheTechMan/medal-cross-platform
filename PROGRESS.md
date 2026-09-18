# Implementation progress

## Current gate and next runnable task

- Gate: M0 evidence/environment is in progress. Input and inherited isolated-test evidence is reproduced; the stable Xcode 27 prerequisite is not presently installed.
- Next command/change: identify and pin the packaged better-sqlite3 wrapper source, create the native build skeleton, and compile the macOS 27 API probes with the installed Xcode 27 beta while keeping M01 blocked on a stable toolchain.
- Expected observation: an exact addon-source match or an explicit replacement decision, followed by arm64 CMake/CTest configuration without claiming native capture success.

## Implemented changes

- Reproduced read-only extraction of the pinned installer into ignored `research/extracted-macos-m0/`.
- Generated a synthetic H.264/AAC fixture and reran the inherited original-client harness.
- Matched every bundled better-sqlite3 wrapper file to public tag v12.12.0 / commit `38f111acfacced350ac17e62944ba9a4dbd176e5`; both source and imported binary identify SQLite 3.53.3. The Git tag is not signed, so the commit and local comparison are recorded explicitly.
- Added on-disk M0 environment, dependency, unknown-contract, progress, decision, limitation, and handoff records.
- Commit: repository was supplied without Git metadata; no commit exists yet.

## Tests run

- Starter-pack validator: `python3 validate_pack.py`; exit 0; 34 RPCs, 40 handlers, 60 settings, 30 workflows, 67 acceptance IDs, 31 sources; this is documentation consistency only.
- A01 evidence subset: pinned SHA-256 values matched both archives; extractor recovered 1,582 files, verified 999 packed integrity records, and retained the five documented unpacked mismatches. See `reports/m0/`.
- B01: `node research/tests/original_client.cjs research/extracted-macos-m0/app`; exit 0; 12/12 inherited isolated checks passed. Electron, database accessor, media dependencies, cloud, native capture, GUI, permissions, and GPU remain outside this result.
- Synthetic media: `python3 research/tests/make_media.py`; exit 0; FFmpeg-generated H.264/AAC fixture only.
- Manual/user interaction required: none so far.

## Failed or blocked gates

- M01 toolchain prerequisite is blocked: no stable Xcode with macOS 27 SDK is installed. `/Applications/Xcode-27.0.0-beta.3.app` supplies SDK 27.0, while stable Xcode 26.6 supplies SDK 26.5 and selected command-line tools supply SDK 26.2.
- A04/A05 and every native GUI/capture gate remain untested; the extracted Windows native modules are not usable on arm64 macOS.
- Independent work that can continue: common core, exact client analysis/patch contracts, public native dependency build, tests, SDK compile probes with the beta toolchain, importer hardening, and isolated native helper integration.

## Contracts and unknowns

- No recovered wire contract was changed.
- Bitrate units, several nested DTO/event payloads, session/contentUpdate ordering, proactive `user`, production contentCreate idempotency, multi-track ordering, and broadcast/plugin semantics remain unresolved in `spec/unknowns.json`.

## Artifacts

- Development/release status: no application artifact or release candidate exists yet.
- M0 reports: `reports/m0/`.
- Extracted proprietary payload and generated media remain ignored and local.
