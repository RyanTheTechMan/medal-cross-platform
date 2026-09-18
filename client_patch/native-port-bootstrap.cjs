'use strict'

const fs = require('node:fs')
const path = require('node:path')
const crypto = require('node:crypto')
const { app, BrowserWindow, ipcMain } = require('electron')

const fail = message => {
  const error = new Error(`Native port bootstrap: ${message}`)
  error.code = 'NATIVE_PORT_BOOTSTRAP_INVALID'
  throw error
}

if (process.platform !== 'darwin' || process.arch !== 'arm64') {
  fail(`this prepared client requires darwin-arm64, got ${process.platform}-${process.arch}`)
}
if (process.versions.electron !== '43.2.0' || process.versions.modules !== '148') {
  fail(`expected Electron 43.2.0 / ABI 148, got Electron ${process.versions.electron} / ABI ${process.versions.modules}`)
}

const configuredProfile = process.env.NATIVE_PORT_PROFILE_DIR
if (configuredProfile && !path.isAbsolute(configuredProfile)) fail('NATIVE_PORT_PROFILE_DIR must be an absolute path')
const profile = configuredProfile || path.join(app.getPath('appData'), 'Native Medal Development Profile')
fs.mkdirSync(profile, { recursive: true, mode: 0o700 })
app.setPath('userData', profile)
app.setPath('sessionData', path.join(profile, 'Session Data'))
app.setPath('logs', path.join(profile, 'Logs'))

const configuredTools = process.env.NATIVE_PORT_TOOLS_DIR
if (configuredTools && !path.isAbsolute(configuredTools)) fail('NATIVE_PORT_TOOLS_DIR must be an absolute path')
const tools = configuredTools || path.join(__dirname, 'tools')
for (const tool of ['ffmpeg', 'ffprobe', 'sqlite3']) {
  const candidate = path.join(tools, tool)
  const stat = fs.statSync(candidate, { throwIfNoEntry: false })
  if (!stat || !stat.isFile() || (stat.mode & 0o111) === 0) fail(`missing executable ${candidate}`)
}

const recorder = path.join(
  __dirname,
  'bin',
  'NativeMedalRecorder.app',
  'Contents',
  'MacOS',
  'native_medal_recorder'
)
const recorderStat = fs.statSync(recorder, { throwIfNoEntry: false })
if (!recorderStat || !recorderStat.isFile() || (recorderStat.mode & 0o111) === 0) {
  fail(`missing native recorder ${recorder}`)
}
process.env.NATIVE_PORT_RECORDER_EXE = recorder
process.env.NATIVE_PORT_SESSION_SECRET = crypto.randomBytes(32).toString('base64url')

if (process.env.NATIVE_PORT_DISABLE_RECORDER === 'true') process.env.NO_RECORDER = '1'
global.nativePort = Object.freeze({ profile, tools, recorder, updater: 'manual' })
console.log(`[native-port] Electron ${process.versions.electron}, ABI ${process.versions.modules}, ${process.arch}`)

const selfTestMode = process.env.NATIVE_PORT_CLIENT_DB_SELFTEST
if (selfTestMode) {
  if (!['write', 'verify'].includes(selfTestMode)) fail('invalid NATIVE_PORT_CLIENT_DB_SELFTEST mode')
  const report = process.env.NATIVE_PORT_SELFTEST_REPORT
  if (!report || !path.isAbsolute(report)) fail('NATIVE_PORT_SELFTEST_REPORT must be absolute')
  const relativeReport = path.relative(profile, report)
  if (relativeReport.startsWith('..') || path.isAbsolute(relativeReport)) {
    fail('NATIVE_PORT_SELFTEST_REPORT must stay inside the isolated profile')
  }
  ipcMain.once('native-port:db-selftest-result', (_event, result) => {
    fs.mkdirSync(path.dirname(report), { recursive: true, mode: 0o700 })
    const temporary = `${report}.${process.pid}.tmp`
    fs.writeFileSync(temporary, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 })
    fs.renameSync(temporary, report)
    global.nativePortDbSelfTestWindow?.destroy()
    global.nativePortDbSelfTestWindow = null
  })
  app.whenReady().then(() => {
    setTimeout(() => {
      const window = new BrowserWindow({
        show: false,
        webPreferences: {
          contextIsolation: true,
          nodeIntegration: false,
          sandbox: true,
          partition: 'native-port-db-selftest',
          preload: path.join(__dirname, 'db-selftest-preload.cjs')
        }
      })
      global.nativePortDbSelfTestWindow = window
      window.loadURL('data:text/html,<meta charset="utf-8"><title>Native port DB self-test</title>')
    }, 1500)
  })
}

const protocolSelfTestReport = process.env.NATIVE_PORT_PROTOCOL_SELFTEST_REPORT
if (protocolSelfTestReport) {
  if (!path.isAbsolute(protocolSelfTestReport)) fail('NATIVE_PORT_PROTOCOL_SELFTEST_REPORT must be absolute')
  const relativeReport = path.relative(profile, protocolSelfTestReport)
  if (relativeReport.startsWith('..') || path.isAbsolute(relativeReport)) {
    fail('NATIVE_PORT_PROTOCOL_SELFTEST_REPORT must stay inside the isolated profile')
  }
  ipcMain.once('native-port:protocol-selftest-result', (_event, result) => {
    fs.mkdirSync(path.dirname(protocolSelfTestReport), { recursive: true, mode: 0o700 })
    const temporary = `${protocolSelfTestReport}.${process.pid}.tmp`
    fs.writeFileSync(temporary, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 })
    fs.renameSync(temporary, protocolSelfTestReport)
    global.nativePortProtocolSelfTestWindow?.destroy()
    global.nativePortProtocolSelfTestWindow = null
  })
  app.whenReady().then(() => {
    setTimeout(() => {
      const window = new BrowserWindow({
        show: false,
        webPreferences: {
          contextIsolation: true,
          nodeIntegration: false,
          sandbox: true,
          partition: 'native-port-protocol-selftest',
          preload: path.join(__dirname, 'protocol-selftest-preload.cjs')
        }
      })
      global.nativePortProtocolSelfTestWindow = window
      window.loadURL('data:text/html,<meta charset="utf-8"><title>Native port protocol self-test</title>')
    }, 1500)
  })
}

const captureSelfTestReport = process.env.NATIVE_PORT_CAPTURE_SELFTEST_REPORT
if (captureSelfTestReport) {
  if (!path.isAbsolute(captureSelfTestReport)) fail('NATIVE_PORT_CAPTURE_SELFTEST_REPORT must be absolute')
  const relativeReport = path.relative(profile, captureSelfTestReport)
  if (relativeReport.startsWith('..') || path.isAbsolute(relativeReport)) {
    fail('NATIVE_PORT_CAPTURE_SELFTEST_REPORT must stay inside the isolated profile')
  }
  if (!['display', 'window', 'application'].includes(process.env.NATIVE_PORT_CAPTURE_SELFTEST_KIND)) {
    fail('NATIVE_PORT_CAPTURE_SELFTEST_KIND must be display, window or application')
  }
  if (process.env.NATIVE_PORT_CAPTURE_SELFTEST_CODEC &&
      !['H264', 'H265', 'AV1'].includes(process.env.NATIVE_PORT_CAPTURE_SELFTEST_CODEC)) {
    fail('NATIVE_PORT_CAPTURE_SELFTEST_CODEC must be H264, H265 or AV1')
  }
  ipcMain.once('native-port:capture-selftest-result', (_event, result) => {
    fs.mkdirSync(path.dirname(captureSelfTestReport), { recursive: true, mode: 0o700 })
    const temporary = `${captureSelfTestReport}.${process.pid}.tmp`
    fs.writeFileSync(temporary, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 })
    fs.renameSync(temporary, captureSelfTestReport)
    global.nativePortCaptureSelfTestWindow?.destroy()
    global.nativePortCaptureSelfTestWindow = null
    setTimeout(() => app.quit(), 250)
  })
  app.whenReady().then(() => {
    setTimeout(() => {
      const window = new BrowserWindow({
        show: false,
        webPreferences: {
          contextIsolation: true,
          nodeIntegration: false,
          sandbox: true,
          partition: 'native-port-capture-selftest',
          preload: path.join(__dirname, 'capture-selftest-preload.cjs')
        }
      })
      global.nativePortCaptureSelfTestWindow = window
      window.loadURL('data:text/html,<meta charset="utf-8"><title>Native capture self-test</title>')
    }, 1500)
  })
}
