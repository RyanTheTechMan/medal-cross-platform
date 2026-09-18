'use strict'

const fs = require('node:fs')
const path = require('node:path')
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

const profile = process.env.NATIVE_PORT_PROFILE_DIR
if (!profile || !path.isAbsolute(profile)) fail('NATIVE_PORT_PROFILE_DIR must be an absolute path')
fs.mkdirSync(profile, { recursive: true, mode: 0o700 })
app.setPath('userData', profile)
app.setPath('sessionData', path.join(profile, 'Session Data'))
app.setPath('logs', path.join(profile, 'Logs'))

const tools = process.env.NATIVE_PORT_TOOLS_DIR
if (!tools || !path.isAbsolute(tools)) fail('NATIVE_PORT_TOOLS_DIR must be an absolute path')
for (const tool of ['ffmpeg', 'ffprobe', 'sqlite3']) {
  const candidate = path.join(tools, tool)
  const stat = fs.statSync(candidate, { throwIfNoEntry: false })
  if (!stat || !stat.isFile() || (stat.mode & 0o111) === 0) fail(`missing executable ${candidate}`)
}

if (process.env.NATIVE_PORT_DISABLE_RECORDER === 'true') process.env.NO_RECORDER = '1'
global.nativePort = Object.freeze({ profile, tools, updater: 'manual' })
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
