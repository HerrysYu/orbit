// Self-scheduled wakeups for the butler: one-shot (at / in) and recurring (cron / every).
import type { Db } from '../store/db.ts';
import { nextCron, parseCron } from '../util/cron.ts';
import { uid } from '../util/log.ts';

export interface Schedule {
  id: string;
  note: string;             // what the butler should do when this fires
  kind: 'once' | 'cron' | 'every';
  at?: number;              // once
  cron?: string;            // cron
  everyMinutes?: number;    // every
  taskId?: string;
  createdAt: number;
  nextAt?: number;
  firedCount: number;
}

export class Scheduler {
  private timer?: NodeJS.Timeout;
  onFire: (s: Schedule) => void = () => {};

  constructor(private db: Db, private tz: () => string) {}

  start() {
    this.timer = setInterval(() => this.tick(), 15_000);
    this.tick();
  }

  stop() { clearInterval(this.timer); }

  add(o: { note: string; at?: number; inMinutes?: number; cron?: string; everyMinutes?: number; taskId?: string }): Schedule {
    const now = Date.now();
    const s: Schedule = { id: uid('s_'), note: o.note, kind: 'once', createdAt: now, firedCount: 0, taskId: o.taskId };
    if (o.cron) {
      parseCron(o.cron); // validate
      s.kind = 'cron'; s.cron = o.cron;
    } else if (o.everyMinutes) {
      if (o.everyMinutes < 5) throw new Error('everyMinutes 至少 5 分钟');
      s.kind = 'every'; s.everyMinutes = o.everyMinutes;
    } else if (o.at || o.inMinutes) {
      s.at = o.at ?? now + o.inMinutes! * 60_000;
      if (s.at <= now) throw new Error('时间已经过去了');
    } else throw new Error('需要 at / in_minutes / cron / every_minutes 之一');
    s.nextAt = this.computeNext(s, now);
    this.save(s);
    return s;
  }

  cancel(id: string): boolean {
    return Number(this.db.sql.prepare('UPDATE schedules SET active = 0 WHERE id = ? AND active = 1').run(id).changes) > 0;
  }

  list(): Schedule[] {
    return this.db.listDocs<Schedule>('schedules', 'active = 1 ORDER BY next_at');
  }

  private computeNext(s: Schedule, after: number): number | undefined {
    if (s.kind === 'once') return s.firedCount ? undefined : s.at;
    if (s.kind === 'every') return after + s.everyMinutes! * 60_000;
    return nextCron(parseCron(s.cron!), after, this.tz());
  }

  private save(s: Schedule) {
    this.db.sql.prepare(`INSERT INTO schedules(id, data, next_at, active) VALUES (?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET data = excluded.data, next_at = excluded.next_at, active = excluded.active`)
      .run(s.id, JSON.stringify(s), s.nextAt ?? null, s.nextAt ? 1 : 0);
  }

  private tick() {
    const now = Date.now();
    const due = this.db.listDocs<Schedule>('schedules', 'active = 1 AND next_at <= ?', now);
    for (const s of due) {
      s.firedCount++;
      s.nextAt = this.computeNext(s, now);
      this.save(s);
      this.onFire(s);
    }
  }
}
