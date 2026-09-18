# Native M1/M2 evidence

These reports record exact development commands and observed output. Electron logs have their LaunchDarkly context URLs redacted because they contain per-profile anonymous device identifiers. The redaction does not remove process version, architecture, ABI, startup, database, WebSocket, GUI or failure evidence.

Passing native reports do not imply capture, permissions, packaging, signing or authenticated workflows passed. `electron-m1-gui.log` and `importer-prepare.json` retain the first failed M1 attempts; subsequent numbered reports show the fixes and successful runs.

M2.6 is the retained integrated helper run. It deliberately occupied port 10603, observed the actual client select loopback port 10604, exercised both protocol directions through real Electron IPC and the real C++ helper, verified missing/incorrect-secret rejection, and recorded normal shutdown. `m2-parent-death-result.txt` is the exact forced-parent-death result from the same helper implementation. Pre-M2.6 iteration logs remain ignored under `artifacts/iteration-reports/`; some contain real device labels and must not be committed or shared.
