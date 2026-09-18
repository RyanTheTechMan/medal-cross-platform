# Actual macOS → Linux handoff

Status: **not ready for transfer**. This file is live and must not be interpreted as a completed handoff.

## Build identity

- Commit / dirty-tree changes: source pack had no Git metadata; implementation work is uncommitted until repository initialization.
- Input hashes: installer `e6477e89f968593fe4b8335f09fc25f81889dd412c28ff85522a0a37415decdb`; recorder ZIP `d33c6e3c0506c1f6b71e6158716fda3a9866bfacc41060f2ec29c4d792ca1312`.
- macOS / chip: macOS 27.2 build 26B5086k; arm64 Apple M5 Max.
- Toolchain: stable Xcode 27 unavailable; Xcode 27.0 beta 3 build 27A5218g with SDK 27.0 is available for development only.
- Electron/addon/signing/package: not yet built or verified.
- Dependency lock / protocol: `DEPENDENCIES.lock.json`; recovered protocol version 1 unchanged.

## What actually works

- Pinned read-only extraction and 12/12 inherited isolated protocol/library tests pass on this Mac.
- No native client, helper communication, capture, hardware encoder, replay, editor, permission, recovery, account, packaging, or performance gate has yet passed.

## Exact build/test/run commands

See `PROGRESS.md` and `reports/m0/`. Commands and exit status will be expanded as gates run.

## Common interfaces Linux must preserve

No new common interfaces have been frozen yet. Recovered method/settings inventories in `FEATURE_LEDGER.json` and `research/PROTOCOL.md` remain authoritative evidence boundaries.

## Remaining macOS work

All M1–M6 implementation and native verification work remains, plus stable-Xcode-27 reruns.

## Linux starting point

Do not start Linux implementation from this state. The exact first Linux task will be recorded after the shared core and macOS interfaces are implemented and frozen.

## Regression route

Current baseline: `python3 validate_pack.py`, extractor, synthetic media generator, and `node research/tests/original_client.cjs <extracted-app>`. Native regression commands do not exist yet.

