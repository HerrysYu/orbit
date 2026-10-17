// Durable, seq-numbered event log (`ev`) + ephemeral `live` fan-out — docs/protocol.md §4.
import { EventEmitter } from 'node:events';
import type { Db } from './db.ts';

export interface Ev { t: 'ev'; seq: number; ts: number; k: string; d: unknown }
export interface Live { t: 'live'; k: string; d: unknown }

/** Max events replayed on sync before we tell the client to reset and send a snapshot instead. */
const MAX_REPLAY = 2000;

export class EventLog extends EventEmitter {
  constructor(private db: Db) { super(); }

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
