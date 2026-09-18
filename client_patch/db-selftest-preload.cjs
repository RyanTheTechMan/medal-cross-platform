'use strict'

const { ipcRenderer } = require('electron')

const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds))
const invokeWhenRegistered = async (channel, ...args) => {
  let lastError
  for (let attempt = 0; attempt < 20; attempt += 1) {
    try {
      return await ipcRenderer.invoke(channel, ...args)
    } catch (error) {
      lastError = error
      if (!String(error).includes('No handler registered')) throw error
      await sleep(250)
    }
  }
  throw lastError
}

window.addEventListener('DOMContentLoaded', async () => {
  const mode = process.env.NATIVE_PORT_CLIENT_DB_SELFTEST
  const persistentKey = 'native-port:a05-close-reopen'
  const temporaryKey = 'native-port:a05-bulk-delete'
  const result = { mode, passed: false, checks: [] }
  try {
    if (mode === 'write') {
      await invokeWhenRegistered('kv:del', persistentKey, null)
      await invokeWhenRegistered('kv:put', persistentKey, { phase: 'insert', count: 1 }, null)
      const inserted = await invokeWhenRegistered('kv:get', persistentKey, null)
      if (inserted?.phase !== 'insert' || inserted?.count !== 1) throw new Error('insert/read mismatch')
      result.checks.push('jsonb insert and read')

      await invokeWhenRegistered('kv:put', persistentKey, { phase: 'updated', count: 2 }, null)
      const updated = await invokeWhenRegistered('kv:get', persistentKey, null)
      if (updated?.phase !== 'updated' || updated?.count !== 2) throw new Error('update/read mismatch')
      result.checks.push('JSONB update and read')

      await invokeWhenRegistered('kv:putBulk', [[temporaryKey, { bulk: true }]], null)
      const bulk = await invokeWhenRegistered('kv:get', temporaryKey, null)
      if (bulk?.bulk !== true) throw new Error('bulk write mismatch')
      await invokeWhenRegistered('kv:del', temporaryKey, null)
      if (await invokeWhenRegistered('kv:get', temporaryKey, null) != null) throw new Error('delete mismatch')
      result.checks.push('bulk insert and delete')
      result.leftForReopen = persistentKey
    } else if (mode === 'verify') {
      const reopened = await invokeWhenRegistered('kv:get', persistentKey, null)
      if (reopened?.phase !== 'updated' || reopened?.count !== 2) throw new Error('close/reopen value mismatch')
      result.checks.push('close and reopen persistence')
      await invokeWhenRegistered('kv:del', persistentKey, null)
      if (await invokeWhenRegistered('kv:get', persistentKey, null) != null) throw new Error('cleanup delete mismatch')
      result.checks.push('reopened delete and read')
    } else {
      throw new Error(`unsupported self-test mode: ${mode}`)
    }
    result.passed = true
  } catch (error) {
    result.error = error?.stack || String(error)
  }
  ipcRenderer.send('native-port:db-selftest-result', result)
})
