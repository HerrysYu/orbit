// Domain state (tasks, sessions, cards, approvals, imports, artifacts) — persisted + emitted as `ev`s.
import type { Db } from '../store/db.ts';
import type { EventLog } from '../store/events.ts';
import type { Approval, Card, ImportItem, Session, Step, Task, TaskStatus } from '../types.ts';
import { uid } from '../util/log.ts';

export interface PendingApproval extends Approval {
  status: 'pending' | 'approved' | 'denied' | 'expired';
  resolve?: (ok: boolean, note?: string) => void;
}

/** A task in one of these states is over: the app may clear it (`tasks.clear`). */
export const FINISHED_TASK_STATUSES: readonly TaskStatus[] = ['done', 'failed', 'cancelled'];
export const isFinishedTask = (t: Pick<Task, 'status'>): boolean => FINISHED_TASK_STATUSES.includes(t.status);

export class State {
  private pendingResolvers = new Map<string, (ok: boolean, note?: string) => void>();

  constructor(private db: Db, private ev: EventLog) {}

  // ───────── tasks ─────────
  createTask(title: string, goal: string, steps: string[] = []): Task {
    const now = Date.now();
    const t: Task = {
      id: uid('t_'), title, goal, status: steps.length ? 'running' : 'planning',
      steps: steps.map((s) => ({ id: uid('st_'), title: s, status: 'pending' })), createdAt: now, updatedAt: now,
    };
    this.saveTask(t);
    return t;
  }

  task(id: string): Task | undefined { return this.db.getDoc<Task>('tasks', id); }

  tasks(active = true): Task[] {
    return active
      ? this.db.listDocs<Task>('tasks', "status NOT IN ('done','failed','cancelled') ORDER BY updated_at DESC")
      : this.db.listDocs<Task>('tasks', '1=1 ORDER BY updated_at DESC LIMIT 100');
  }

  /** Every finished task, newest first (no list-size cap, unlike `tasks(false)`). */
  finishedTasks(): Task[] {
    return this.db.listDocs<Task>('tasks', `status IN (${FINISHED_TASK_STATUSES.map(() => '?').join(', ')}) ORDER BY updated_at DESC`, ...FINISHED_TASK_STATUSES);
  }

  /**
   * Deletes task rows and tells clients with ONE durable `task.remove {ids}` event. Unknown ids are ignored; returns the
   * ids that were actually deleted (no event when that is empty). Whether a task may be removed is the caller's call —
   * `tasks.clear` only ever passes finished ones.
   */
  removeTasks(ids: string[]): string[] {
    const del = this.db.sql.prepare('DELETE FROM tasks WHERE id = ?');
    const removed: string[] = [];
    for (const id of new Set(ids)) if (Number(del.run(id).changes) > 0) removed.push(id);
    if (removed.length) this.ev.emitEv('task.remove', { ids: removed });
    return removed;
  }

  updateTask(id: string, patch: { status?: TaskStatus; summary?: string; title?: string; addSteps?: string[];
    steps?: { id: string; status?: Step['status']; sessionId?: string; title?: string }[] }): Task {
    const t = this.task(id);
    if (!t) throw new Error(`unknown task ${id}`);
    if (patch.status) t.status = patch.status;
    if (patch.summary !== undefined) t.summary = patch.summary;
    if (patch.title) t.title = patch.title;
    for (const s of patch.addSteps ?? []) t.steps.push({ id: uid('st_'), title: s, status: 'pending' });
    for (const sp of patch.steps ?? []) {
      const s = t.steps.find((x) => x.id === sp.id || x.title === sp.id);
      if (!s) continue;
      if (sp.status) s.status = sp.status;
      if (sp.sessionId) s.sessionId = sp.sessionId;
      if (sp.title) s.title = sp.title;
    }
    if (t.status === 'planning' && t.steps.length) t.status = 'running';
    t.updatedAt = Date.now();
    this.saveTask(t);
    return t;
  }

  private saveTask(t: Task) {
    this.db.putDoc('tasks', t.id, t, t.status, t.updatedAt);
    this.ev.emitEv('task.upsert', t);
  }

  // ───────── sessions ─────────
  upsertSession(s: Partial<Session> & { id: string }): Session {
    const prev = this.session(s.id);
    const now = Date.now();
    const next: Session = {
      title: '', status: 'idle', permission: 'manual', createdAt: now, ...prev, ...s, updatedAt: now,
    } as Session;
    if (prev && JSON.stringify({ ...prev, updatedAt: 0 }) === JSON.stringify({ ...next, updatedAt: 0 })) return prev;
    this.db.putDoc('sessions', next.id, next, next.status, now);
    this.ev.emitEv('session.upsert', next);
    return next;
  }

  session(id: string): Session | undefined { return this.db.getDoc<Session>('sessions', id); }

  sessions(active = true): Session[] {
    return this.db.listDocs<Session>('sessions', active ? "status != 'archived' ORDER BY updated_at DESC LIMIT 50" : '1=1 ORDER BY updated_at DESC LIMIT 100');
  }

  /** Non-archived sessions that belong to any of `taskIds` (no list-size cap, unlike `sessions()`). */
  sessionsOfTasks(taskIds: string[]): Session[] {
    if (!taskIds.length) return [];
    return this.db.listDocs<Session>('sessions', `status != 'archived' AND json_extract(data, '$.taskId') IN (${taskIds.map(() => '?').join(', ')}) ORDER BY updated_at DESC`, ...taskIds);
  }

  // ───────── cards ─────────
  renderCard(c: Omit<Card, 'id' | 'ts'> & { id?: string }): Card {
    const card: Card = { ...c, id: c.id ?? uid('c_'), ts: Date.now() };
    this.db.sql.prepare('INSERT OR REPLACE INTO cards(id, data, ts) VALUES (?, ?, ?)').run(card.id, JSON.stringify(card), card.ts);
    this.ev.emitEv('ui.render', { card });
    return card;
  }

  /** Most recent card of `component` whose props[key] === value (used to avoid duplicate auto-cards). */
  findCard(component: string, key: string, value: string): Card | undefined {
    return (this.db.sql.prepare(`SELECT data FROM cards WHERE json_extract(data, '$.component') = ? AND json_extract(data, '$.props.' || ?) = ? ORDER BY ts DESC LIMIT 1`)
      .all(component, key, value) as { data: string }[]).map((r) => JSON.parse(r.data) as Card)[0];
  }

  card(id: string): Card | undefined { return this.db.getDoc<Card>('cards', id); }

  patchCard(id: string, props: Record<string, unknown>): Card {
    const card = this.card(id);
    if (!card) throw new Error(`unknown card ${id}`);
    card.props = { ...card.props, ...props };
    this.db.sql.prepare('UPDATE cards SET data = ? WHERE id = ?').run(JSON.stringify(card), id);
    this.ev.emitEv('ui.patch', { id, props });
    return card;
  }

  // ───────── approvals ─────────
  /** Creates an approval and resolves when the user answers, or after `timeoutMs` (→ denied). */
  requestApproval(a: Omit<Approval, 'id' | 'createdAt'>, timeoutMs = 30 * 60_000): { approval: Approval; done: Promise<{ ok: boolean; note?: string; by: string }> } {
    const approval: Approval = { ...a, id: uid('ap_'), createdAt: Date.now(), expiresAt: Date.now() + timeoutMs };
    this.db.putDoc('approvals', approval.id, { ...approval, status: 'pending' }, 'pending', approval.createdAt);
    this.ev.emitEv('approval.request', approval);
    const done = new Promise<{ ok: boolean; note?: string; by: string }>((resolve) => {
      const timer = setTimeout(() => this.resolveApproval(approval.id, false, 'timeout'), timeoutMs);
      this.pendingResolvers.set(approval.id, (ok, note) => { clearTimeout(timer); resolve({ ok, note, by: note === 'timeout' ? 'timeout' : 'user' }); });
    });
    return { approval, done };
  }

  resolveApproval(id: string, ok: boolean, note?: string, by: 'user' | 'butler' | 'timeout' = note === 'timeout' ? 'timeout' : 'user'): boolean {
    const r = this.pendingResolvers.get(id);
    const doc = this.db.getDoc<PendingApproval>('approvals', id);
    if (!doc || doc.status !== 'pending') return false;
    doc.status = by === 'timeout' ? 'expired' : ok ? 'approved' : 'denied';
    this.db.putDoc('approvals', id, doc, doc.status, doc.createdAt);
    this.ev.emitEv('approval.resolved', { id, decision: ok ? 'approve' : 'deny', by });
    this.pendingResolvers.delete(id);
    r?.(ok, note);
    return true;
  }

  approvalStatus(id: string): PendingApproval['status'] | undefined {
    return this.db.getDoc<PendingApproval>('approvals', id)?.status;
  }

  pendingApprovals(): Approval[] {
    return this.db.listDocs<Approval>('approvals', "status = 'pending' ORDER BY created_at");
  }

  /** On restart nobody is waiting on old approvals any more. */
  expireStaleApprovals() {
    for (const a of this.pendingApprovals()) if (!this.pendingResolvers.has(a.id)) this.resolveApproval(a.id, false, 'timeout', 'timeout');
  }

  // ───────── imports ─────────
  addImports(items: ImportItem[]): string[] {
    return items.map((it) => {
      const id = uid('im_');
      const stored = { ...it, id, dataB64: undefined, hasData: !!it.dataB64 };
      this.db.putDoc('imports', id, stored, 'new', Date.now());
      if (it.dataB64) this.putArtifact(`import:${id}`, it.title ?? it.kind, it.mime ?? 'application/octet-stream', it.dataB64, id);
      return id;
    });
  }

  imports(status?: string): any[] {
    return status ? this.db.listDocs('imports', 'status = ? ORDER BY created_at DESC LIMIT 50', status)
      : this.db.listDocs('imports', '1=1 ORDER BY created_at DESC LIMIT 50');
  }

  markImport(id: string, status: 'processed' | 'ignored') {
    const doc = this.db.getDoc<any>('imports', id);
    if (doc) this.db.putDoc('imports', id, doc, status, Date.now());
  }

  // ───────── artifacts (large blobs kept out of the model context) ─────────
  putArtifact(title: string, desc: string, mime: string, body: string, id = uid('a_')): string {
    this.db.sql.prepare('INSERT OR REPLACE INTO artifacts(id, title, mime, body, created_at) VALUES (?, ?, ?, ?, ?)').run(id, `${title} ${desc}`.trim(), mime, body, Date.now());
    return id;
  }

  artifact(id: string): { id: string; title: string; mime: string; body: string } | undefined {
    return this.db.sql.prepare('SELECT id, title, mime, body FROM artifacts WHERE id = ?').get(id) as any;
  }
}
