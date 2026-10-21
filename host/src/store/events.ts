// Durable, seq-numbered event log (`ev`) + ephemeral `live` fan-out — docs/protocol.md §4.
import { EventEmitter } from 'node:events';
import type { Db } from './db.ts';

export interface Ev { t: 'ev'; seq: number; ts: number; k: string; d: unknown }
export interface Live { t: 'live'; k: string; d: unknown }
export interface ChatClearBarrier { seq: number; clearedAt: number }

/** Max events replayed on sync before we tell the client to reset and send a snapshot instead. */
const MAX_REPLAY = 2000;

export class EventLog extends EventEmitter {
  constructor(private db: Db) { super(); }

  /**
   * Remove the durable chat timeline and cards as one transaction, while keeping the global AUTOINCREMENT sequence
   * intact. The `chat.cleared` marker is inserted in that same transaction so reconnecting devices can clear their local
   * timeline at exactly the sequence returned by `chat.clear`.
   */
  clearChat(clearedAt = Date.now()): Ev {
    this.db.sql.exec('BEGIN IMMEDIATE');
    let ev: Ev;
    try {
      this.db.sql.prepare("DELETE FROM events WHERE k IN ('msg.user', 'msg.assistant', 'ui.render', 'ui.patch')").run();
      this.db.sql.prepare('DELETE FROM cards').run();
      // These keys are part of the conversation context. Clearing them in the same transaction prevents a Host restart
      // from resuming the old brain thread if shutdown lands immediately after this operation.
      this.db.sql.prepare("DELETE FROM kv WHERE key IN ('brain.threadId', 'brain.configKey')").run();
      const d = { clearedAt };
      const r = this.db.sql.prepare('INSERT INTO events(ts, k, d) VALUES (?, ?, ?)').run(clearedAt, 'chat.cleared', JSON.stringify(d));
      ev = { t: 'ev', seq: Number(r.lastInsertRowid), ts: clearedAt, k: 'chat.cleared', d };
      this.db.sql.prepare('INSERT INTO kv(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
        .run('chat.clearBarrier', JSON.stringify({ seq: ev.seq, clearedAt } satisfies ChatClearBarrier));
      this.db.sql.exec('COMMIT');
    } catch (e) {
      try { this.db.sql.exec('ROLLBACK'); } catch { /* preserve the original transaction error */ }
      throw e;
    }
    // Notify only after commit: listeners and connected devices never observe a tombstone for a rolled-back clear.
    // A transport listener can throw after the transaction is durable; that must not make the caller roll its local
    // generation back while the database has already cleared. Reconnecting devices recover the marker through sync.
    try { this.emit('ev', ev); } catch { /* the durable event remains available to sync */ }
    return ev;
  }

  /** The most recent clear marker, retained even after it falls out of the bounded sync replay window. */
  chatClearBarrier(): ChatClearBarrier | undefined {
    const stored = this.db.get<unknown>('chat.clearBarrier');
    if (isChatClearBarrier(stored)) return stored;
    // Recover safely from databases written before the KV barrier existed, or from a partial legacy migration.
    const row = this.db.sql.prepare("SELECT seq, ts, d FROM events WHERE k = 'chat.cleared' ORDER BY seq DESC LIMIT 1").get() as
      { seq: number; ts: number; d: string } | undefined;
    if (!row) return undefined;
    let data: any;
    try { data = JSON.parse(row.d); } catch { return undefined; }
    const barrier = { seq: Number(row.seq), clearedAt: Number(data?.clearedAt ?? row.ts) };
    if (!isChatClearBarrier(barrier)) return undefined;
    this.db.set('chat.clearBarrier', barrier);
    return barrier;
  }

  emitEv(k: string, d: unknown): Ev {
    const ts = Date.now();
    const r = this.db.sql.prepare('INSERT INTO events(ts, k, d) VALUES (?, ?, ?)').run(ts, k, JSON.stringify(d));
    const ev: Ev = { t: 'ev', seq: Number(r.lastInsertRowid), ts, k, d };
    this.emit('ev', ev);
    return ev;
  }

  emitLive(k: string, d: unknown): void {
    this.emit('live', { t: 'live', k, d } satisfies Live);
  }

  lastSeq(): number {
    const row = this.db.sql.prepare('SELECT MAX(seq) AS s FROM events').get() as { s: number | null };
    return row.s ?? 0;
  }

  /** Events with seq > lastSeq, or null when the gap is too large (client must reset). */
  since(lastSeq: number): Ev[] | null {
    const top = this.lastSeq();
    if (lastSeq > top) return null; // client from a different/old database
    if (top - lastSeq > MAX_REPLAY) return null;
    return (this.db.sql.prepare('SELECT seq, ts, k, d FROM events WHERE seq > ? ORDER BY seq').all(lastSeq) as any[])
      .map((r) => ({ t: 'ev', seq: r.seq, ts: r.ts, k: r.k, d: JSON.parse(r.d) }));
  }
}

function isChatClearBarrier(value: unknown): value is ChatClearBarrier {
  if (!value || typeof value !== 'object') return false;
  const v = value as Partial<ChatClearBarrier>;
  return Number.isSafeInteger(v.seq) && Number(v.seq) > 0 && Number.isSafeInteger(v.clearedAt) && Number(v.clearedAt) > 0;
}
