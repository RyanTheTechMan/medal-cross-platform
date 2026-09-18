'use strict'

const { ipcRenderer } = require('electron')

const wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds))

async function waitForRecorder() {
  const deadline = Date.now() + 15000
  while (Date.now() < deadline) {
    try {
      const result = await ipcRenderer.invoke('recorder:sendRecorderWSRequest', 'ping', {})
      if (result === null) return ipcRenderer.invoke('recorder:getState')
    } catch {
      // The server can be running before the authenticated helper has connected.
    }
    await wait(100)
  }
  throw new Error('recorder did not become ready within 15 seconds')
}

function assert(condition, message) {
  if (!condition) throw new Error(message)
}

window.addEventListener('DOMContentLoaded', async () => {
  const checks = []
  const request = (method, params = {}) => ipcRenderer.invoke('recorder:sendRecorderWSRequest', method, params)
  try {
    const readyState = await waitForRecorder()
    checks.push({
      name: 'ready',
      passed: true,
      recorderStatus: typeof readyState?.status === 'string' ? readyState.status : 'not-exposed',
      hasSessionId: Boolean(readyState?.sessionState?.currentSessionId)
    })

    const videoCapabilities = await request('nativePort.videoEncoderCapabilities')
    const gpuCodecs = videoCapabilities?.gpuCodecs
    assert(gpuCodecs && typeof gpuCodecs === 'object' && !Array.isArray(gpuCodecs),
      'gpuCodecs must be an object keyed by GPU device')
    const availableCodecs = [...new Set(Object.values(gpuCodecs).flat())]
    assert(availableCodecs.includes('H264'), 'hardware H264 must be published to AvailableGPUCodecs')
    assert(availableCodecs.every(codec => ['H264', 'H265', 'AV1'].includes(codec)),
      'only recovered Medal codec names may be published')
    assert(Array.isArray(videoCapabilities?.gpuDevices), 'gpuDevices must be an array')
    assert(Array.isArray(videoCapabilities?.encoderOptions), 'encoderOptions must be an array')
    checks.push({
      name: 'native-video-codec-capabilities',
      passed: true,
      gpuDevices: videoCapabilities.gpuDevices,
      gpuCodecs,
      encoderOptions: videoCapabilities.encoderOptions,
      av1HardwareEncode: videoCapabilities.capabilities?.av1HardwareEncode === true
    })

    const ping = await request('ping')
    assert(ping === null, 'ping must return JSON-RPC null for Task')
    checks.push({ name: 'ping-null-result', passed: true })

    const displays = await request('activeDisplays', { captureScreenshots: false })
    assert(Array.isArray(displays) && displays.length > 0, 'activeDisplays must return at least one display')
    for (const display of displays) {
      assert(typeof display.DeviceName === 'string', 'DeviceName must use recovered PascalCase')
      assert(typeof display.FriendlyName === 'string', 'FriendlyName must use recovered PascalCase')
      assert(typeof display.IsPrimaryScreen === 'boolean', 'IsPrimaryScreen must be boolean')
      assert(Object.hasOwn(display, 'CurrentScreenshot'), 'CurrentScreenshot must be present')
      assert(Object.hasOwn(display, 'CurrentScreenshotFile'), 'CurrentScreenshotFile must be present')
    }
    checks.push({ name: 'display-dto', passed: true, count: displays.length })

    const outputDevices = await request('availableAudioDevices')
    const microphones = await request('availableMicDevices')
    const defaults = await request('getDefaultAudioDevices')
    assert(Array.isArray(outputDevices), 'availableAudioDevices must return an array')
    assert(Array.isArray(microphones), 'availableMicDevices must return an array')
    assert(typeof defaults?.input === 'string' && typeof defaults?.output === 'string',
      'getDefaultAudioDevices must return camelCase input/output strings')
    checks.push({
      name: 'audio-device-dtos',
      passed: true,
      outputCount: outputDevices.length,
      microphoneCount: microphones.length,
      hasDefaultInput: defaults.input.length > 0,
      hasDefaultOutput: defaults.output.length > 0
    })

    const webcams = await request('webcamDevices', { includeVirtualDevices: false })
    assert(Array.isArray(webcams), 'webcamDevices must return an array')
    for (const webcam of webcams) {
      for (const key of ['id', 'label', 'value', 'type']) assert(typeof webcam[key] === 'string', `${key} must be a string`)
    }
    checks.push({ name: 'webcam-dto', passed: true, count: webcams.length })

    const settingsResult = await request('settings', {
      settings: [
        { key: 'TargetFPS', value: 60, categoryId: null },
        { key: 'Resolution', value: { width: 1920, height: 1080 }, categoryId: null },
        { key: 'Codec', value: 'H264', categoryId: 'native-port-selftest-game' }
      ]
    })
    assert(settingsResult === null, 'settings Task must return null')
    assert(await request('deleteCustomGameSettings', {
      customGameSettings: [{ categoryId: 'native-port-selftest-game', settingKeys: ['Codec'] }]
    }) === null, 'deleteCustomGameSettings Task must return null')
    assert(await request('deleteAllCustomGameSettings', {
      categoryIds: ['native-port-selftest-game']
    }) === null, 'deleteAllCustomGameSettings Task must return null')
    checks.push({ name: 'scoped-settings-and-deletion', passed: true })

    let unknownRejected = false
    let unknownMessage = ''
    let unknownResult
    try {
      unknownResult = await request('nativePort.selftest.unknownMethod')
    } catch (error) {
      unknownRejected = true
      unknownMessage = String(error?.message || error).replace(/[\r\n]+/g, ' ').slice(0, 240)
    }
    checks.push({
      name: 'unknown-method-wire-error-requested',
      passed: true,
      clientRejected: unknownRejected,
      clientReturnedUndefinedAfterWireError: !unknownRejected && unknownResult === undefined,
      clientReturnedNullAfterWireError: !unknownRejected && unknownResult === null,
      errorObserved: unknownMessage.length > 0
    })

    ipcRenderer.send('native-port:protocol-selftest-result', {
      schemaVersion: 1,
      status: 'passed',
      checks,
      completedAt: new Date().toISOString()
    })
  } catch (error) {
    ipcRenderer.send('native-port:protocol-selftest-result', {
      schemaVersion: 1,
      status: 'failed',
      checks,
      error: String(error?.stack || error).replace(/[\r\n]+/g, ' ').slice(0, 1000),
      completedAt: new Date().toISOString()
    })
  }
})
