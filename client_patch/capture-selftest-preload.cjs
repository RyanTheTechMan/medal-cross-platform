'use strict'

const { ipcRenderer } = require('electron')

const wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds))
const request = (method, params = {}) => ipcRenderer.invoke('recorder:sendRecorderWSRequest', method, params)

async function waitFor(predicate, timeoutMilliseconds, description) {
  const deadline = Date.now() + timeoutMilliseconds
  let last
  while (Date.now() < deadline) {
    last = await request('nativePort.captureStatus')
    if (predicate(last)) return last
    if (last?.state === 'failed' || last?.sourceEnumeration?.state === 'failed') {
      throw new Error(`${description} failed: ${last?.lastError || last?.sourceEnumeration?.lastError || 'unknown error'}`)
    }
    await wait(250)
  }
  throw new Error(`${description} timed out; last state ${JSON.stringify(last)}`)
}

async function waitForRecorder() {
  const deadline = Date.now() + 20000
  while (Date.now() < deadline) {
    try {
      if (await request('ping') === null) return
    } catch {
      // The authenticated helper may still be starting.
    }
    await wait(100)
  }
  throw new Error('native recorder did not become ready')
}

window.addEventListener('DOMContentLoaded', async () => {
  const kind = process.env.NATIVE_PORT_CAPTURE_SELFTEST_KIND
  const videoCodec = process.env.NATIVE_PORT_CAPTURE_SELFTEST_CODEC || 'H264'
  const captureSystemAudio = process.env.NATIVE_PORT_CAPTURE_SELFTEST_SYSTEM_AUDIO === '1'
  const captureMicrophone = process.env.NATIVE_PORT_CAPTURE_SELFTEST_MICROPHONE === '1'
  const exportMp4 = process.env.NATIVE_PORT_CAPTURE_SELFTEST_EXPORT_MP4 === '1'
  const registerExport = process.env.NATIVE_PORT_CAPTURE_SELFTEST_REGISTER === '1'
  const operationalHotkey = process.env.NATIVE_PORT_CAPTURE_SELFTEST_HOTKEY === '1'
  const hotkeyLengthSeconds = Number(process.env.NATIVE_PORT_CAPTURE_SELFTEST_HOTKEY_LENGTH_SECONDS || 5)
  const hotkeyInputs = process.env.NATIVE_PORT_CAPTURE_SELFTEST_HOTKEY_INPUTS || 'F8'
  const registrationUuid = process.env.NATIVE_PORT_CAPTURE_SELFTEST_UUID
  const bitrateMegabitsPerSecond = Number(
    process.env.NATIVE_PORT_CAPTURE_SELFTEST_BITRATE_MBPS || (videoCodec === 'H264' ? 15 : 10)
  )
  const startedAt = new Date().toISOString()
  let diagnosticStatus = null
  let exportResult = null
  let registrationResult = null
  try {
    if (!['display', 'window', 'application'].includes(kind)) throw new Error(`invalid capture kind ${kind}`)
    if (!['H264', 'H265', 'AV1'].includes(videoCodec)) throw new Error(`invalid video codec ${videoCodec}`)
    if (!Number.isFinite(bitrateMegabitsPerSecond) || bitrateMegabitsPerSecond < 1 || bitrateMegabitsPerSecond > 100) {
      throw new Error(`invalid capture bitrate ${bitrateMegabitsPerSecond} Mbps`)
    }
    if (!Number.isInteger(hotkeyLengthSeconds) || hotkeyLengthSeconds < 1 || hotkeyLengthSeconds > 120) {
      throw new Error(`invalid operational hotkey replay length ${hotkeyLengthSeconds}`)
    }
    await waitForRecorder()
    const officialSettingsResult = await request('settings', {
      settings: [
        { key: 'TargetFPS', value: 60, categoryId: null },
        { key: 'Resolution', value: { width: 1920, height: 1080 }, categoryId: null },
        { key: 'Bitrate', value: bitrateMegabitsPerSecond, categoryId: null },
        { key: 'Codec', value: videoCodec, categoryId: null },
        { key: 'ShowCursor', value: true, categoryId: null },
        { key: 'Hotkeys', value: { hotkeys: [
          { action: `clip;length=${hotkeyLengthSeconds}`, device: 'keyboard', type: 'short_press', inputs: hotkeyInputs }
        ] }, categoryId: null }
      ]
    })
    if (officialSettingsResult !== null) throw new Error('official settings Task did not return null')
    const interactiveSessionPreflight = await request('nativePort.interactiveSessionPreflight')
    if (!interactiveSessionPreflight?.interactive) {
      ipcRenderer.send('native-port:capture-selftest-result', {
        schemaVersion: 1,
        status: 'blocked',
        blockedReason: 'macOS session is locked or non-interactive; unlock the console session before a ScreenCaptureKit picker test',
        interactiveSessionPreflight,
        kind,
        videoCodec,
        bitrateMegabitsPerSecond,
        captureSystemAudio,
        captureMicrophone,
        exportMp4,
        registerExport,
        startedAt,
        completedAt: new Date().toISOString()
      })
      return
    }
    const enumerationAccepted = await request('nativePort.enumerateSources')
    if (!enumerationAccepted?.accepted) throw new Error('source enumeration was not accepted')
    const enumerated = await waitFor(
      status => status?.sourceEnumeration?.state === 'complete',
      60000,
      'ScreenCaptureKit source enumeration'
    )
    const pickerAccepted = await request('nativePort.presentSourcePicker', {
      preferredSourceKind: kind,
      width: 1920,
      height: 1080,
      framesPerSecond: 60,
      bitrateBitsPerSecond: bitrateMegabitsPerSecond * 1000000,
      videoCodec,
      bitrateMegabitsPerSecond,
      showCursor: true,
      captureSystemAudio,
      captureMicrophone
    })
    if (!pickerAccepted?.accepted) throw new Error('source picker was not accepted')
    const capturing = await waitFor(
      status => status?.state === 'capturing' && status?.framesEncoded > 0,
      120000,
      'picker selection and first encoded frame'
    )
    if (capturing.sourceKind !== kind) {
      throw new Error(`selected source kind ${capturing.sourceKind}; test requires ${kind}`)
    }
    await wait(8000)
    const running = await request('nativePort.captureStatus')
    diagnosticStatus = running
    if (!running.hardwareEncoder) throw new Error('VideoToolbox did not report hardware acceleration')
    if (running.framesEncoded < 2 || running.replay?.packetCount < 2) {
      throw new Error('capture did not feed encoded frames into the replay store')
    }
    if (captureSystemAudio &&
        (running.audio?.system?.packetsEncoded < 2 || running.audio?.system?.encodeFailures !== 0)) {
      throw new Error('system audio did not produce native AAC packets')
    }
    if (captureMicrophone &&
        (running.audio?.microphone?.packetsEncoded < 2 || running.audio?.microphone?.encodeFailures !== 0)) {
      throw new Error('microphone audio did not produce native AAC packets')
    }
    if (operationalHotkey) {
      const deadline = Date.now() + 120000
      while (Date.now() < deadline) {
        registrationResult = await request('nativePort.captureStatus')
        const action = registrationResult?.lastClipAction
        if (action?.state === 'acknowledged') {
          if (action.action !== `clip;length=${hotkeyLengthSeconds}` || action.inputs !== hotkeyInputs ||
              !action.fileName?.endsWith('.mp4')) {
            throw new Error(`operational hotkey returned invalid clip metadata: ${JSON.stringify(action)}`)
          }
          exportResult = action
          break
        }
        if (action?.state === 'failed') {
          throw new Error(`operational hotkey failed: ${action.error || 'unknown error'}`)
        }
        await wait(250)
      }
      if (!exportResult) throw new Error(`timed out waiting for physical clip hotkey ${hotkeyInputs}`)
    } else if (exportMp4) {
      const profile = process.env.NATIVE_PORT_PROFILE_DIR
      if (!profile || !profile.startsWith('/')) throw new Error('MP4 export requires an absolute isolated profile')
      exportResult = await request('nativePort.saveReplay', {
        durationSeconds: 120,
        outputPath: `${profile.replace(/\/$/, '')}/capture-selftest.mp4`
      })
      if (!exportResult?.saved || exportResult.videoPacketCount < 2 ||
          (captureSystemAudio && exportResult.systemAudioPacketCount < 2) ||
          (captureMicrophone && exportResult.microphonePacketCount < 2)) {
        throw new Error('native MP4 replay export did not contain the requested tracks')
      }
      if (registerExport) {
        if (!registrationUuid) throw new Error('content registration requires an isolated test UUID')
        registrationResult = await request('nativePort.registerExportedReplay', {
          uuid: registrationUuid,
          createdAt: Date.now(),
          clipLocation: `${profile.replace(/\/$/, '')}/capture-selftest.mp4`,
          exportStatsDuration: exportResult.durationNanoseconds / 1000000000
        })
        const registrationDeadline = Date.now() + 60000
        while (Date.now() < registrationDeadline) {
          registrationResult = await request('nativePort.registrationStatus', { uuid: registrationUuid })
          if (registrationResult?.state === 'acknowledged') break
          if (registrationResult?.state === 'failed') {
            throw new Error(`contentCreate failed: ${registrationResult.error || 'unknown error'}`)
          }
          await wait(100)
        }
        if (registrationResult?.state !== 'acknowledged') {
          throw new Error(`contentCreate acknowledgement timed out: ${JSON.stringify(registrationResult)}`)
        }
      }
    } else if (registerExport) {
      throw new Error('content registration requires MP4 export')
    }
    await request('nativePort.stopCapture')
    const stopped = await waitFor(status => status?.state === 'stopped', 15000, 'capture stop')
    ipcRenderer.send('native-port:capture-selftest-result', {
      schemaVersion: 1,
      status: 'passed',
      kind,
      videoCodec,
      bitrateMegabitsPerSecond,
      captureSystemAudio,
      captureMicrophone,
      exportMp4,
      registerExport,
      operationalHotkey,
      hotkeyLengthSeconds,
      hotkeyInputs,
      actionRoute: operationalHotkey ? 'official Hotkeys setting -> clip;length=N' : 'private capture self-test',
      startedAt,
      completedAt: new Date().toISOString(),
      sourceEnumeration: enumerated.sourceEnumeration,
      capturing,
      running,
      stopped,
      exportResult,
      registrationResult
    })
  } catch (error) {
    try { diagnosticStatus = await request('nativePort.captureStatus') } catch {}
    try { await request('nativePort.stopCapture') } catch {}
    ipcRenderer.send('native-port:capture-selftest-result', {
      schemaVersion: 1,
      status: 'failed',
      kind,
      videoCodec,
      bitrateMegabitsPerSecond,
      captureSystemAudio,
      captureMicrophone,
      exportMp4,
      registerExport,
      operationalHotkey,
      hotkeyLengthSeconds,
      hotkeyInputs,
      startedAt,
      completedAt: new Date().toISOString(),
      diagnosticStatus,
      exportResult,
      registrationResult,
      error: String(error?.stack || error).replace(/[\r\n]+/g, ' ').slice(0, 2000)
    })
  }
})
