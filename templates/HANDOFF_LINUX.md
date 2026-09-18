# Actual macOS → Linux handoff

TEMPLATE ONLY. Fill from the implemented repository and real reports. Do not mark any row passed merely by copying this file.

## Build identity
- Commit / dirty-tree changes:
- Input and patched payload hashes:
- macOS version/build / Apple chip:
- Xcode/SDK/compiler versions:
- Electron version/ABI and native addon provenance:
- Dependency lock / recorder protocol revision:
- Signing identity/category and packaging status (no secrets):

## What actually works
- Native client bootstrap and SQLite report:
- Real client/helper communication report:
- Screen/system/mic/game-only capture report:
- Hardware encoder property/probe:
- Replay/sessions/track/editor/library report:
- Permissions/device-change/recovery report:
- Performance reports and actual presets:
- Account/upload status and authorized test scope:

## Exact build/test/run commands
Record commands and exit statuses, prerequisites, output paths and manual steps. Distinguish synthetic tests from native tests.

## Common interfaces Linux must preserve
List source registry, clocks/packets, settings, replay, export/outbox and wire schema files. Note any changed contracts and regression fixtures. List known original-protocol uncertainties.

## Remaining macOS work
Unimplemented features, failed tests, unavailable devices, permission/account/signing blockers, source/API uncertainty and actual user-visible limitations. Do not write 'complete' while mandatory gates are pending.

## Linux starting point
Implemented shared code; Linux code that compiles; Linux code actually executed; missing backend operations. Exact first runnable task and expected assertion. Link LINUX_CONTINUATION_PROMPT.md.

## Regression route
How to run common tests on Linux and macOS tests again. Record Mac availability/CI limits rather than claiming it remains working without a test.
