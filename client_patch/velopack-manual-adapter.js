'use strict'

const unavailable = () => {
  const error = new Error('Automatic updates are unavailable in this local native port; import a verified client build manually.')
  error.code = 'NATIVE_PORT_MANUAL_UPDATES'
  return error
}

class VelopackApp {
  static build() { return new VelopackApp() }
  onAfterInstallFastCallback() { return this }
  onBeforeUninstallFastCallback() { return this }
  onBeforeUpdateFastCallback() { return this }
  onAfterUpdateFastCallback() { return this }
  onRestarted() { return this }
  onFirstRun() { return this }
  setArgs() { return this }
  setLocator() { return this }
  setLogger() { return this }
  setAutoApplyOnStartup() { return this }
  run() {}
}

class FileSource { constructor(path) { this.path = path } }
class HttpSource { constructor(url, options) { this.url = url; this.options = options } }
class GithubSource { constructor(repoUrl, accessToken, prerelease = false) { Object.assign(this, { repoUrl, accessToken, prerelease }) } }
class GitlabSource extends GithubSource {}
class GiteaSource extends GithubSource {}
class VelopackFlowSource { constructor(baseUri) { this.baseUri = baseUri } }
class UpdateManager { constructor() { throw unavailable() } }

module.exports = {
  VelopackApp,
  FileSource,
  HttpSource,
  GithubSource,
  GitlabSource,
  GiteaSource,
  VelopackFlowSource,
  UpdateManager
}
