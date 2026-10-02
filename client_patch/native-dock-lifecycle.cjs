'use strict'

// Observe only Medal's original main window, never recorder HUDs or test windows.
// Original close/tray/activate/second-instance handlers still own window lifetime.
function createDockLifecycle({ app, platform = process.platform, now = () => performance.now(),
  schedule = setTimeout, cancel = clearTimeout, onError = console.error, onState = () => {} }) {
  let window, quitting = false, pendingShow = false, retry, lastHide = -Infinity, lastShow = -Infinity
  const bindings = new Map()
  const clearRetry = () => { if (retry !== undefined) cancel(retry); retry = undefined }
  const wantsDock = () => window && !window.isDestroyed() &&
    (window.isVisible() || window.isMinimized())
  const report = phase => onState({ phase, dockVisible: app.dock.isVisible(),
    mainVisible: !!window && !window.isDestroyed() && window.isVisible(),
    mainMinimized: !!window && !window.isDestroyed() && window.isMinimized() })
  const reconcile = () => {
    clearRetry()
    if (quitting || !window || !app.dock) return
    if (wantsDock()) {
      if (app.dock.isVisible() || pendingShow) return
      pendingShow = true
      Promise.resolve().then(() => {
        if (!quitting && wantsDock()) { lastShow = now(); return app.dock.show() }
      }).catch(error => {
        onError('[native-port] Dock show failed', error)
      }).finally(() => { pendingShow = false; report('show-settled'); if (!wantsDock()) reconcile() })
    } else {
      if (pendingShow || !app.dock.isVisible()) return
      // Pinned Electron 43.2 DockHide ignores calls within one second of DockShow.
      // Also avoid the repeated-hide cooldown described by current API docs.
      const delay = 1100 - (now() - Math.max(lastHide, lastShow))
      if (delay > 0) { retry = schedule(reconcile, delay); return }
      try { app.dock.hide(); lastHide = now(); report('hide') }
      catch (error) { onError('[native-port] Dock hide failed', error) }
    }
  }
  const unbind = () => {
    for (const [event, handler] of bindings) window?.removeListener(event, handler)
    bindings.clear()
  }
  const beforeQuit = () => { quitting = true; clearRetry() }
  if (platform === 'darwin') app.on('before-quit', beforeQuit)
  return Object.freeze({
    bind(mainWindow) {
      if (platform !== 'darwin' || mainWindow === window) return
      clearRetry(); unbind(); window = mainWindow
      for (const event of ['show', 'hide', 'minimize', 'restore', 'closed']) {
        bindings.set(event, reconcile); window.on(event, reconcile)
      }
      // Do not change startup activation policy before the original ready/show.
    },
    dispose() { beforeQuit(); unbind(); app.removeListener('before-quit', beforeQuit) },
  })
}

module.exports = { createDockLifecycle }
