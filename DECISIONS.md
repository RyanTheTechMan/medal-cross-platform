# Implementation decisions

## Decision D001 — Keep native verification blocked while using the available beta SDK for compile-only progress

- Date / commit: 2026-09-18 / no Git commit yet.
- Problem and evidence: the machine is macOS 27.2 arm64, but stable Xcode 27 is absent. Xcode 27.0 beta 3 provides SDK 27.0; Xcode 26.6 provides SDK 26.5.
- Selected approach: use an explicit `DEVELOPER_DIR` pointing to Xcode 27 beta only for independent development and compile probes. Do not mark M01, packaging, permission attribution, performance, or release gates verified until a stable Xcode 27 build is rerun.
- Alternatives and tradeoffs: using stable Xcode 26.6 would not compile against the required SDK; treating beta results as release evidence would violate the requirement.
- Affected interfaces: build configuration only; no common protocol or media interface change.
- Security/privacy/packaging impact: beta-built artifacts are development-only and will not be described as release/notarized artifacts.
- Tests required and actual results: environment discovery recorded in `reports/m0/environment.txt`; native tests pending.
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

