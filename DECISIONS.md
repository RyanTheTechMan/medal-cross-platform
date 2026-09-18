# Implementation decisions

## Decision D001 — Keep native verification blocked while using the available beta SDK for compile-only progress

- Date / commit: 2026-09-18 / `9082bbe`, updated by pending checkpoint.
- Problem and evidence: the machine is macOS 27.2 arm64, but stable Xcode 27 is absent. The subsequently installed Xcode 27.2 beta build 27B5019j provides SDK 27.2.
- Selected approach: use an explicit `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` for development builds and compiler/runtime API probes. Do not treat beta-built packaging, permission attribution, performance, or release gates as stable release evidence.
- Alternatives and tradeoffs: using stable Xcode 26.6 would not compile against the required SDK; treating beta results as release evidence would violate the requirement.
- Affected interfaces: build configuration only; no common protocol or media interface change.
- Security/privacy/packaging impact: beta-built artifacts are development-only and will not be described as release/notarized artifacts.
- Tests required and actual results: environment discovery is recorded in `reports/m0/environment.txt`; the shared core and macOS API probe compile and pass under `reports/native/`.
- Source references: `CODEX_MASTER_PROMPT.md` sections 5.1, 10, and 11; `SOURCES.md` S01.

## Decision D002 — Preserve inherited tests as reference evidence only

- Date / commit: 2026-09-18 / no Git commit yet.
- Problem and evidence: the 12-test harness substitutes Electron objects, the database accessor, and selected media dependencies.
- Selected approach: retain B01 as an isolated compatibility baseline and create separate reports for actual Electron, addon, helper, capture, permission, and service gates.
- Alternatives and tradeoffs: promoting B01 to A04/A05/B02/M03 would be quicker but false.
- Affected interfaces: none.
- Security/privacy/packaging impact: the baseline uses synthetic local media and no account or capture permission.
- Tests required and actual results: 12/12 isolated checks passed; see `reports/m0/protocol-results.json`.
- Source references: `research/README.md`, `research/FINDINGS.md`, `ACCEPTANCE_TESTS.md` B01.

## Decision D003 — Patch only the pinned user-imported tree and activate immutable versions atomically

- Date / commit: 2026-09-18 / pending checkpoint commit.
- Problem and evidence: the imported installer contains proprietary application resources plus Windows-only native modules and update paths; modifying the read-only source or accepting changed anchors would make rollback and provenance ambiguous.
- Selected approach: validate the installer and five patch-critical source hashes, copy into a same-filesystem staging directory, apply exact-count replacements with pre/post hashes, install separately built native files, then atomically replace a managed `current` symlink. Keep `previous` and every version directory for rollback. Do not execute installer lifecycle scripts.
- Alternatives and tradeoffs: in-place patching was rejected because failure can damage the only working import; global platform spoofing was rejected because it would route unrelated Windows behavior into macOS code.
- Affected interfaces: startup bootstrap, both Velopack import sites, SQLite addon/CLI resolution and FFmpeg/ffprobe resolution.
- Security/privacy/packaging impact: imported inputs remain unchanged; unknown builds fail closed; automatic proprietary client and recorder updates are not permitted to overwrite native artifacts.
- Tests required and actual results: six importer security tests and an idempotent second real import pass. Full rollback/profile preservation and decompression fixtures remain for A03/A09.
- Source references: `ACCEPTANCE_TESTS.md` A01-A03/A06/A09; `CODEX_MASTER_PROMPT.md` sections 6 and 10.

## Decision D004 — Use one explicit manual-update adapter for both client update entry points

- Date / commit: 2026-09-18 / pending checkpoint commit.
- Problem and evidence: `index.js` calls Velopack during earliest startup while `main.min.js` creates its own update manager; allowing only one path to fail could still apply Windows packages or report a false healthy updater.
- Selected approach: replace the pinned Velopack JS export with a chain-compatible startup adapter and an `UpdateManager` that throws `NATIVE_PORT_MANUAL_UPDATES`. The client's existing error handling then reports updates unavailable. New imports are the only supported development update path.
- Alternatives and tradeoffs: returning `null` from update checks would falsely imply a successful no-update result; importing the Windows addon is impossible and unsafe.
- Affected interfaces: update startup hooks and `UpdateManager` construction only; the renderer/main client code otherwise remains vendor code.
- Security/privacy/packaging impact: no TLS or signature validation is bypassed, and no remote replacement binary is accepted.
- Tests required and actual results: actual native Electron startup reaches the original renderer without a Velopack native-load error; packaged/update UI behavior is still required for A06.
- Source references: `ACCEPTANCE_TESTS.md` A04/A06; `research/PATCH_PLAN.json` bootstrap-runtime.

## Decision D005 — Authenticate the loopback recorder socket with an inherited per-launch secret

- Date / commit: 2026-09-18 / pending M2 checkpoint.
- Problem and evidence: the recovered server accepted any no-Origin loopback client. A second local process could otherwise connect before the recorder and impersonate it.
- Selected approach: generate 32 random bytes before each Electron launch, inherit the secret through the child environment, and require an exact `x-native-port-secret` upgrade header. The secret is never placed in argv or protocol logs. Preserve the original no-Origin restriction and loopback-only listener.
- Alternatives and tradeoffs: a fixed token would cross profiles and restarts; an argv token leaks through process inspection; treating loopback alone as authentication does not satisfy B04.
- Affected interfaces: a namespaced private HTTP upgrade header on both patched Electron and native helper endpoints. Recovered JSON-RPC envelopes remain unchanged.
- Security/privacy/packaging impact: profile launches cannot reuse stale credentials; missing and incorrect secrets fail before WebSocket upgrade.
- Tests required and actual results: two unauthorized upgrades returned HTTP 401; the authenticated helper connected on the client-selected occupied-port fallback; argv contained no secret. See `reports/native/m2.6-websocket-auth.json` and `m2.6-process-evidence.txt`.
- Source references: `research/PROTOCOL.md`; `ACCEPTANCE_TESTS.md` B02-B04.

## Decision D006 — Treat client/helper logs as protocol-shape evidence, not payload dumps

- Date / commit: 2026-09-18 / pending M2 checkpoint.
- Problem and evidence: the imported client logged complete WebSocket messages, exposing real device labels, camera identifiers and settings; its feature client also logged per-profile context in a URL.
- Selected approach: exact-patch inbound/outbound recorder logs to method/id/error-code shapes, summarize setKV values by key/count, and redact feature client context creation/stream URLs. Native helper fatal messages do not include secrets or device inventories.
- Alternatives and tradeoffs: post-processing reports would leave sensitive values in live application logs; suppressing all logs would remove useful lifecycle/error evidence.
- Affected interfaces: logging only; wire values and client state remain unchanged.
- Security/privacy/packaging impact: retained reports contain no observed personal device labels, feature-context token or session secret.
- Tests required and actual results: actual M2.6 log retained handshake/readiness/method/error/shutdown evidence, and repository report scans found none of the observed labels/context markers.
- Source references: repository privacy rules; `ACCEPTANCE_TESTS.md` B03/B04.
