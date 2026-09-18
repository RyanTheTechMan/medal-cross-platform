#!/usr/bin/env python3
"""Regenerate human-readable protocol reference from extracted audit metadata."""
import json,re
from pathlib import Path
root=Path(__file__).resolve().parent.parent
meta=json.loads((root/'evidence/recorder_metadata.json').read_text())
settings=json.loads((root/'evidence/settings_catalog.json').read_text())

def short(t):
    t=t.replace('System.Threading.Tasks.Task`1<','Task<').replace('System.Collections.Generic.List`1<','List<')
    for p in ['RESTService.IConnection+','MedalEncoder.ScreenUtils+','MedalEncoder.AutoClipCatalog+']:t=t.replace(p,'')
    return t.replace('System.Threading.Tasks.Task','Task')
text='''# Observed Medal recorder protocol

Build-pinned: client 2637.461.1 / recorder 2638.2751.1. This is a recovered interface inventory, not a vendor specification or claim that every method is fully understood. CLR declarations, IL inspection and client call sites establish the shapes below; real .NET serialization was not executed. The isolated tests cover the subset in evidence/protocol_results.json.

## Transport and lifecycle

Electron hosts a WebSocket server at 127.0.0.1 on a probed port starting at 10603. The helper connects, using the selected port supplied as `--electronPort`; actual recorder launch also supplies `--environment` and `--wsComms`. Requests/notifications can travel in both directions on the same socket. No browser Origin header is accepted by this client's verifyClient predicate. The inspected predicate checks Origin absence, not the recorder's optional token header. A production port should add a per-launch local secret to both ends without treating it as a cloud credential.

Recorder-to-client request:

```json
{"jsonrpc":"2.0","id":1,"method":"handshake","params":{"supportedVersions":[1],"preferredVersion":1}}
```

Client response:

```json
{"jsonrpc":"2.0","id":1,"result":{"result":"success","errorMessage":null,"data":{"version":1,"capabilities":[]}}}
```

The extra Medal envelope is used by the client's registered request handlers. `ping` in this direction returns envelope data `"pong"`. An incompatible handshake can return envelope data `{}` with nominal success: validate `data.version`, not only the success field.

In the other direction, recorder handlers return ordinary JSON-RPC values. For example an availableMicDevices request can return `{"jsonrpc":"2.0","id":2,"result":["Microphone"]}`. CLR `Task` without a type argument completes without a value (`null` result expected); a notification has no response. Method `ping` on the recorder has this void-task signature, unlike the client's ping result.

The recorder heartbeat IL uses a 20,000 ms interval and two failed attempts before disconnection logic. Its request timeout is 15 seconds; the client request wrapper has a 10-second timeout. Reconnect behavior should be bounded, not a hot loop. A `recordingReady` call causes the original client to transition ready and assign a session UUID. Emit it only when the helper is genuinely initialized; ready does not mean frames are currently being recorded. Capture state has separate messages. The client sends `shutdown` and recognizes the WebSocket close reason `shutdown`.

## All 34 methods declared by the recorder

Parameter names must match exactly. A Task<T> completes with T as the JSON-RPC result; List<T> is a JSON array. The table is derived from JsonRpcMethodAttribute and CLR parameter metadata, including method tokens for verification. Error behavior and every nested enum value are not fully recovered.

| RPC method | Named parameters and CLR types | CLR return | Method token |
|---|---|---|---|
'''
for m in meta['rpc_methods']:
    params=', '.join(p['Name']+': '+short(t) for p,t in zip(m['params'],m['signature_decoded']['args'])) or 'none'
    text+=f"| `{m['first_string']}` | `{params}` | `{short(m['signature_decoded']['return'])}` | `{m['method_token']}` |\n"
text+='''
## All 40 handler names registered by the client

These are entry points a helper may call/notify; not all are needed for a minimum recorder. Details and event sequences beyond the tested subset require further tracing.

```
recordingReady  setKV  diskSpace  contentDelete  contentFailed  contentUpdate
 gameStarted  gameEnded  gameServerStarted  gameMatchStarted  gameMatchEnded
 subgameStarted  subgameEnded  fallbackEncoder  recorderError
 voiceCommandDetected  hotkeyCaptureState  hotkeyCaptured  hotkeyCaptureCancelled
 gameState  captureStarted  captureStopped  requestAdmin
 overlaySize  overlayEnabled  overlayShow  overlayInjected  callback
 steamGamesInLibrary  autoClipCatalogChanged
 ping  user  recordingSettings  customGameSettings  handshake  targetProcess
 contentCreate  hardwareInfo  environment  gameAudioOnlyEnabled
```

The enumerated recorder methods do not include `saveClip`, `saveLast30Seconds`, or an inbound `user` handler. The recorder can pull `user` from the client; the client also has a proactive user send path, which is one compatibility detail to resolve rather than blindly treating both inventories as identical. Some recorder strings also mention liveStarted/hotkeyCaptureRejected, absent from this client's registered map. Independent versions require explicit compatibility testing.

## Settings

The client sends `settings` with a `settings` array, not a flat dictionary. Each object includes key, value, and categoryId. Preserve typed values and global/per-game scope.

```json
{
  "jsonrpc":"2.0", "id":3, "method":"settings",
  "params":{"settings":[
    {"key":"TargetFPS","value":60,"categoryId":null},
    {"key":"Resolution","value":{"width":1920,"height":1080},"categoryId":null},
    {"key":"Codec","value":"H264","categoryId":null},
    {"key":"Hotkeys","value":{"hotkeys":[
      {"action":"clip;length=30","device":"keyboard","type":"short_press","inputs":"F8"}
    ]},"categoryId":null}
  ]}
}
```

This illustrates the observed envelope and action grammar, not a recording request executed in this investigation. The settings catalog records 60 recorder keys. Observed UI conversions include MicSoundGain /100 and AudioNotificationVolume /100, JSON stringification for ExternalFileSources, and a nested hotkeys object. Do not assume UI slider values equal recorder values. Bitrate's exact unit-conversion path has not been fully traced. Global/default versus per-game merge and deletion behavior need regression tests.

Known action strings include `clip;length=30`, `segment_toggle`, `bookmark`, `switch_game`, `screenshot`. Keyboard capture for rebinding is separate from registering operational global shortcuts. There is no observed JSON-RPC SaveClip method to invoke as a shortcut.

All recorder keys:

```
'''
text+='\n'.join(settings['recorderKeys'])+'\n```\n'
text+='''
## Native-source and device DTO quirks

`activeDisplays({captureScreenshots: false})` returns ScreenInfo objects with fields including **DeviceName, FriendlyName, CurrentScreenshot, IsPrimaryScreen** (PascalCase). The client renderer reads DeviceName and IsPrimaryScreen directly. ScreenInfo also has a CurrentScreenshotFile field in metadata. Screenshot encoding/path behavior is not completely traced; defer display thumbnails until reproduced correctly.

`getDefaultAudioDevices()` uses **input/output** (camelCase). ActiveProcessInfo and TargetedProcessInfo also have explicit CamelCaseNamingStrategy attributes; see evidence/wire_dto_attributes.json. In particular, ActiveProcessInfo's processName is a string and captionName/className are lists, whereas targeted-process DTO fields are strings. Do not flatten every DTO into one uniform shape.

The observed client call for adding a target is `setTargetProcess({data:{processName: ...}})`. The CLR TargetProcessData can also hold CaptionName and ClassName lists. There is no PID parameter in this specific observed request. Map outward process names to native target IDs internally; a PID-only replacement is not wire-compatible. switchGameRecording similarly receives `data` with processName/categoryId semantics, not a naked process ID.

WebcamDeviceInfo uses explicitly named id/label/value/type properties. Device APIs commonly return arrays of names/strings rather than rich native platform device descriptors. Implement a persistent mapping to internal stable IDs and handle devices changing or disappearing.

## State publication

`setKV` parameters are key/value. The client retains the key in recorder session state and translates some values into application settings. Observed special keys:

| setKV key | Client-side setting |
|---|---|
| gpuDevices | AvailableGPUDevices |
| gpuCodecs | AvailableGPUCodecs |
| gameDevice | SelectedAudioDevices |
| micDevice | SelectedMicDevice |
| encoderOptions | EncoderOptions |
| bitrate | Bitrate |

Other published session keys include micDevices, gameDevices, hardwareId and activeDisplays. Honest capability/device lists should reflect the native backend. Do not pretend NVAPI, Windows Game Mode or an injected overlay is available to satisfy UI checks.

## Clip registration: actually tested subset

The test finalized a synthetic H.264/AAC MP4 and sent a contentCreate request with a fresh UUID, createdAt (milliseconds), absolute clipLocation, a test gameCategoryId, clipType `clip`, captureType `screen`, a synthetic processName, and metadata.triggerType/exportStatsDuration. This is a **test fixture**, not a complete production metadata schema or valid service category.

The original client runs m7e -> gfe -> w5. It augments currentSessionId, probes media duration/dimensions, generates thumbnails, inserts its library record and acknowledges:

```json
{"jsonrpc":"2.0","id":4,"result":{"result":"success","errorMessage":null,"data":{"uuid":"the-same-uuid","contentId":null}}}
```

The test had no logged-in account, so contentId was null and no cloud registration occurred. A logged-in client may register remote content, rename files, and auto-upload according to user settings. Do not use a live profile for uncontrolled protocol probes.

The recorder ClipSavedData DTO includes ClipLocation, ImageLocation, GameTitle, SavedTime, GameCategoryId, SaveType, CaptionName, ProcessName, ClassName, CaptureType, GameRequestId, Uuid, SkipDraft, Metadata, ClipType, ContentType and FileSource. The .NET names are not a promise that on-wire event keys use the same casing; the tested client event uses camelCase. Schemas in evidence/ are metadata inventories, not full JSON Schema validators.

Continuous sessions use additional contentUpdate/end-state behavior. Bookmarks, segment toggles, crash recovery, auto-clipping and multi-track export are additional implementations, not implied by the minimum clip test.
'''
(root/'PROTOCOL.md').write_text(text)
