// Single SQLite file (node:sqlite) holding all host state.
import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';

export const OPA_HOME = process.env.OPA_HOME ?? join(homedir(), '.opa');

const SCHEMA = `
CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, k TEXT NOT NULL, d TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, pub TEXT NOT NULL, name TEXT NOT NULL, paired_at INTEGER NOT NULL, last_seen INTEGER);
CREATE TABLE IF NOT EXISTS push_tokens (device_id TEXT NOT NULL, kind TEXT NOT NULL, token TEXT NOT NULL, env TEXT NOT NULL,
  activity_id TEXT, task_id TEXT, updated_at INTEGER NOT NULL, PRIMARY KEY (device_id, kind, token));
CREATE TABLE IF NOT EXISTS tasks (id TEXT PRIMARY KEY, data TEXT NOT NULL, status TEXT NOT NULL, updated_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, data TEXT NOT NULL, status TEXT NOT NULL, updated_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS approvals (id TEXT PRIMARY KEY, data TEXT NOT NULL, status TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS cards (id TEXT PRIMARY KEY, data TEXT NOT NULL, ts INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS memories (id TEXT PRIMARY KEY, text TEXT NOT NULL, kind TEXT NOT NULL, source TEXT NOT NULL,
  confidence REAL NOT NULL, status TEXT NOT NULL DEFAULT 'active', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(text, content='memories', content_rowid='rowid', tokenize='trigram');
CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
  INSERT INTO memories_fts(rowid, text) VALUES (new.rowid, new.text); END;
CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
  INSERT INTO memories_fts(memories_fts, rowid, text) VALUES ('delete', old.rowid, old.text); END;
CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
  INSERT INTO memories_fts(memories_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
  INSERT INTO memories_fts(rowid, text) VALUES (new.rowid, new.text); END;
CREATE TABLE IF NOT EXISTS schedules (id TEXT PRIMARY KEY, data TEXT NOT NULL, next_at INTEGER, active INTEGER NOT NULL DEFAULT 1);
CREATE TABLE IF NOT EXISTS imports (id TEXT PRIMARY KEY, data TEXT NOT NULL, status TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS artifacts (id TEXT PRIMARY KEY, title TEXT NOT NULL, mime TEXT NOT NULL, body TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS transcript (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, item TEXT NOT NULL, compacted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS audit (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, actor TEXT NOT NULL, action TEXT NOT NULL, detail TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS client_msgs (client_id TEXT PRIMARY KEY, msg_id TEXT NOT NULL, ts INTEGER NOT NULL);
`;

export class Db {
  readonly sql: DatabaseSync;

  constructor(path = join(OPA_HOME, 'opa.sqlite')) {
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
    this.sql = new DatabaseSync(path);
    this.sql.exec('PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;');
    this.sql.exec(SCHEMA);
    // Columns added after a table first shipped, applied to every database (new ones included). ALTER has no IF NOT EXISTS,
    // so "duplicate column" is the normal answer on every start after the first; any other error is real.
    try {
      this.sql.exec('ALTER TABLE push_tokens ADD COLUMN bundle_id TEXT'); // the app's own bundle id = APNs topic (NULL: older apps don't report it)
    } catch (e: any) {
      if (!/duplicate column/i.test(String(e?.message))) throw e;
    }
  }

  get<T>(key: string): T | undefined {
    const row = this.sql.prepare('SELECT value FROM kv WHERE key = ?').get(key) as { value: string } | undefined;
    return row ? (JSON.parse(row.value) as T) : undefined;
  }

  set(key: string, value: unknown): void {
    this.sql.prepare('INSERT INTO kv(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
      .run(key, JSON.stringify(value));
  }

  /** Upsert a JSON-document row into one of the doc tables (tasks/sessions/approvals/cards/imports/schedules). */
  putDoc(table: 'tasks' | 'sessions' | 'approvals' | 'imports', id: string, data: any, status: string, at: number): void {
    const col = table === 'approvals' || table === 'imports' ? 'created_at' : 'updated_at';
    this.sql.prepare(`INSERT INTO ${table}(id, data, status, ${col}) VALUES (?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET data = excluded.data, status = excluded.status${col === 'updated_at' ? ', updated_at = excluded.updated_at' : ''}`)
      .run(id, JSON.stringify(data), status, at);
  }

  getDoc<T>(table: string, id: string): T | undefined {
    const row = this.sql.prepare(`SELECT data FROM ${table} WHERE id = ?`).get(id) as { data: string } | undefined;
    return row ? (JSON.parse(row.data) as T) : undefined;
  }

  listDocs<T>(table: string, where = '1=1', ...params: (string | number)[]): T[] {
    return (this.sql.prepare(`SELECT data FROM ${table} WHERE ${where}`).all(...params) as { data: string }[])
      .map((r) => JSON.parse(r.data) as T);
  }

  audit(actor: string, action: string, detail: unknown): void {
    this.sql.prepare('INSERT INTO audit(ts, actor, action, detail) VALUES (?, ?, ?, ?)')
      .run(Date.now(), actor, action, JSON.stringify(detail).slice(0, 8000));
  }
}
