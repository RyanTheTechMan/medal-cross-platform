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
    await wait(100)
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
  const bitrateMegabitsPerSecond = Number(
    process.env.NATIVE_PORT_CAPTURE_SELFTEST_BITRATE_MBPS || (videoCodec === 'H264' ? 15 : 10)
  )
  const startedAt = new Date().toISOString()
  let diagnosticStatus = null
  let exportResult = null
  try {
    if (!['display', 'window', 'application'].includes(kind)) throw new Error(`invalid capture kind ${kind}`)
    if (!['H264', 'H265', 'AV1'].includes(videoCodec)) throw new Error(`invalid video codec ${videoCodec}`)
    if (!Number.isFinite(bitrateMegabitsPerSecond) || bitrateMegabitsPerSecond < 1 || bitrateMegabitsPerSecond > 100) {
      throw new Error(`invalid capture bitrate ${bitrateMegabitsPerSecond} Mbps`)
    }
    await waitForRecorder()
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
    if (exportMp4) {
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
      startedAt,
      completedAt: new Date().toISOString(),
      sourceEnumeration: enumerated.sourceEnumeration,
      capturing,
      running,
      stopped,
      exportResult
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
      startedAt,
      completedAt: new Date().toISOString(),
      diagnosticStatus,
      exportResult,
      error: String(error?.stack || error).replace(/[\r\n]+/g, ' ').slice(0, 2000)
    })
  }
})
