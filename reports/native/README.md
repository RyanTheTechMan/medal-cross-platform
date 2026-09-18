# Native and M1 evidence

These reports record exact development commands and observed output. Electron logs have their LaunchDarkly context URLs redacted because they contain per-profile anonymous device identifiers. The redaction does not remove process version, architecture, ABI, startup, database, WebSocket, GUI or failure evidence.

Passing native reports do not imply capture, permissions, packaging, signing or authenticated workflows passed. `electron-m1-gui.log` and `importer-prepare.json` retain the first failed M1 attempts; subsequent numbered reports show the fixes and successful runs.
