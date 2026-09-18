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
  const bitrateMegabitsPerSecond = Number(
    process.env.NATIVE_PORT_CAPTURE_SELFTEST_BITRATE_MBPS || (videoCodec === 'H264' ? 15 : 10)
  )
  const startedAt = new Date().toISOString()
  let diagnosticStatus = null
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
      captureSystemAudio: false,
      captureMicrophone: false
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
    await request('nativePort.stopCapture')
    const stopped = await waitFor(status => status?.state === 'stopped', 15000, 'capture stop')
    ipcRenderer.send('native-port:capture-selftest-result', {
      schemaVersion: 1,
      status: 'passed',
      kind,
      videoCodec,
      bitrateMegabitsPerSecond,
      startedAt,
      completedAt: new Date().toISOString(),
      sourceEnumeration: enumerated.sourceEnumeration,
      capturing,
      running,
      stopped
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
      startedAt,
      completedAt: new Date().toISOString(),
      diagnosticStatus,
      error: String(error?.stack || error).replace(/[\r\n]+/g, ' ').slice(0, 2000)
    })
  }
})
