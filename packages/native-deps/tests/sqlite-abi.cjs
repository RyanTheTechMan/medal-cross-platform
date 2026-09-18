'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const packageRoot = path.resolve(__dirname, '..');
const projectRoot = path.resolve(packageRoot, '..', '..');
const importedWrapper = path.join(
  projectRoot,
  'research',
  'extracted-macos-m0',
  'app',
  'vendor',
  'better-sqlite3'
);
const nativeBinding = path.join(
  packageRoot,
  'node_modules',
  'better-sqlite3',
  'build',
  'Release',
  'better_sqlite3.node'
);
const Database = require(importedWrapper);

async function main() {
  assert.equal(process.versions.electron, '43.2.0');
  assert.equal(process.versions.modules, '148');
  assert.equal(process.arch, 'arm64');
  assert.equal(process.platform, 'darwin');
  assert(fs.existsSync(nativeBinding), nativeBinding);

  const testDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'native-medal-sqlite-'));
  const databasePath = path.join(testDirectory, 'library space 雪.db');
  const backupPath = path.join(testDirectory, 'backup 雪.db');
  const result = {
    runtime: {
      electron: process.versions.electron,
      node: process.versions.node,
      modules: process.versions.modules,
      v8: process.versions.v8,
      platform: process.platform,
      architecture: process.arch
    },
    nativeBinding,
    importedWrapper,
    assertions: []
  };

  let database = new Database(databasePath, { nativeBinding });
  const sqliteVersion = database.prepare('SELECT sqlite_version() AS version').get().version;
  assert.equal(sqliteVersion, '3.53.3');
  result.sqliteVersion = sqliteVersion;
  result.assertions.push('matched imported wrapper loaded the rebuilt Electron addon');

  const journalMode = database.pragma('journal_mode = WAL', { simple: true });
  assert.equal(String(journalMode).toLowerCase(), 'wal');
  database.pragma('synchronous = NORMAL');
  database.exec(`
    CREATE TABLE contents (
      local_content_id TEXT UNIQUE NOT NULL,
      metadata BLOB NOT NULL,
      created_at INTEGER NOT NULL
    );
    CREATE TABLE key_values (
      key TEXT UNIQUE NOT NULL,
      value BLOB NOT NULL
    );
  `);

  const jsonbType = database
    .prepare("SELECT typeof(jsonb(?)) AS type, json_extract(jsonb(?), '$.nested.value') AS value")
    .get('{"nested":{"value":42}}', '{"nested":{"value":42}}');
  assert.deepEqual(jsonbType, { type: 'blob', value: 42 });
  result.assertions.push('SQLite JSONB and json_extract are available');

  const insertContent = database.prepare(
    'INSERT INTO contents(local_content_id, metadata, created_at) VALUES (?, jsonb(?), ?)'
  );
  const insertPair = database.transaction((firstId, secondId) => {
    insertContent.run(firstId, JSON.stringify({ isFavorited: true, ordinal: 1 }), 1);
    insertContent.run(secondId, JSON.stringify({ isFavorited: false, ordinal: 2 }), 2);
  });
  insertPair('one', 'two');
  assert.equal(database.prepare('SELECT count(*) AS count FROM contents').get().count, 2);
  assert.equal(
    database.prepare("SELECT json_extract(metadata, '$.ordinal') AS ordinal FROM contents WHERE local_content_id = ?").get('two').ordinal,
    2
  );
  database.prepare("UPDATE contents SET metadata = jsonb_set(metadata, '$.ordinal', 3) WHERE local_content_id = ?").run('two');
  database.prepare('DELETE FROM contents WHERE local_content_id = ?').run('one');
  assert.equal(database.prepare('SELECT count(*) AS count FROM contents').get().count, 1);
  result.assertions.push('prepared insert/query/update/delete and transaction succeeded');

  const secondConnection = new Database(databasePath, { nativeBinding });
  assert.equal(secondConnection.pragma('journal_mode', { simple: true }), 'wal');
  assert.equal(secondConnection.prepare('SELECT count(*) AS count FROM contents').get().count, 1);
  secondConnection.close();
  result.assertions.push('second WAL connection read committed data');

  await database.backup(backupPath);
  database.close();
  database = new Database(databasePath, { nativeBinding });
  assert.equal(database.prepare("SELECT json_extract(metadata, '$.ordinal') AS ordinal FROM contents").get().ordinal, 3);
  assert.equal(database.pragma('integrity_check', { simple: true }), 'ok');
  database.close();

  const backup = new Database(backupPath, { nativeBinding, readonly: true });
  assert.equal(backup.prepare('SELECT count(*) AS count FROM contents').get().count, 1);
  assert.equal(backup.pragma('integrity_check', { simple: true }), 'ok');
  backup.close();
  result.assertions.push('close/reopen, backup, readonly reopen, and integrity checks succeeded');

  fs.rmSync(testDirectory, { recursive: true, force: true });
  result.status = 'passed';
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

main().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});

