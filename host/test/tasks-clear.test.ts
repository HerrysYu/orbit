// `tasks.clear` (protocol.md §4.2) and `task.remove` (§4.3): State level and through the app request handler.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { Host } from '../src/app.ts';
import { CodexBridge } from '../src/codex/bridge.ts';
import { CodexRpc } from '../src/codex/rpc.ts';
import { State } from '../src/butler/state.ts';
import { Db } from '../src/store/db.ts';
import { EventLog, type Ev } from '../src/store/events.ts';
import type { Session, SessionStatus, TaskStatus } from '../src/types.ts';

const sorted = (xs: string[]) => [...xs].sort();

/** Settles with `p`, or with 'timed out' after `ms`; clears its timer either way so nothing lingers. */
const within = <T>(ms: number, p: Promise<T>) => new Promise<T | 'timed out'>((resolve, reject) => {
  const timer = setTimeout(() => resolve('timed out'), ms);
  p.then((v) => { clearTimeout(timer); resolve(v); }, (e) => { clearTimeout(timer); reject(e); });
});

describe('State.removeTasks / finishedTasks / sessionsOfTasks', () => {
  function makeState() {
    const db = new Db(':memory:');
    const ev = new EventLog(db);
    return { st: new State(db, ev), ev };
  }

  it('deletes the given tasks and emits ONE durable task.remove event', () => {
    const { st, ev } = makeState();
    const a = st.createTask('A', 'a');
    const b = st.createTask('B', 'b');
    const c = st.createTask('C', 'c');
    const before = ev.lastSeq();

    // Unknown ids are ignored, repeated ids count once.
    expect(st.removeTasks([a.id, b.id, 'ghost', a.id])).toEqual([a.id, b.id]);

    expect(st.task(a.id)).toBeUndefined();
    expect(st.task(b.id)).toBeUndefined();
    expect(st.task(c.id)).toBeDefined();
    const events = ev.since(before)!;
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ k: 'task.remove', d: { ids: [a.id, b.id] } });
    // Durable: a client replaying from 0 sees it after the upserts.
    const all = ev.since(0)!;
    expect(all.at(-1)!.k).toBe('task.remove');
    expect(all.filter((e) => e.k === 'task.remove')).toHaveLength(1);
  });

  it('emits nothing when nothing was removed', () => {
    const { st, ev } = makeState();
    st.createTask('A', 'a');
    const before = ev.lastSeq();
    expect(st.removeTasks([])).toEqual([]);
    expect(st.removeTasks(['ghost'])).toEqual([]);
    expect(ev.lastSeq()).toBe(before);
  });

  it('finishedTasks returns done / failed / cancelled only, with no list cap', () => {
    const { st } = makeState();
    const active = [st.createTask('plan', 'p'), st.createTask('run', 'r', ['s'])];
    st.updateTask(st.createTask('wait', 'w').id, { status: 'waiting_user' });
    st.updateTask(st.createTask('block', 'b').id, { status: 'blocked' });
    for (let i = 0; i < 105; i++) st.updateTask(st.createTask(`done ${i}`, 'g').id, { status: (['done', 'failed', 'cancelled'] as const)[i % 3] });
    const finished = st.finishedTasks();
    expect(finished).toHaveLength(105);
    expect(finished.every((t) => ['done', 'failed', 'cancelled'].includes(t.status))).toBe(true);
    expect(finished.some((t) => active.some((x) => x.id === t.id))).toBe(false);
  });

  it('sessionsOfTasks returns non-archived sessions of exactly those tasks', () => {
    const { st } = makeState();
    const t1 = st.createTask('t1', 'g');
    const t2 = st.createTask('t2', 'g');
    const t3 = st.createTask('t3', 'g');
    st.upsertSession({ id: 's1', taskId: t1.id, title: 's1', status: 'running' });
    st.upsertSession({ id: 's2', taskId: t1.id, title: 's2', status: 'archived' });
    st.upsertSession({ id: 's3', taskId: t2.id, title: 's3', status: 'idle' });
    st.upsertSession({ id: 's4', taskId: t3.id, title: 's4', status: 'idle' });
    st.upsertSession({ id: 's5', title: 'no task', status: 'idle' });
    expect(sorted(st.sessionsOfTasks([t1.id, t2.id]).map((s) => s.id))).toEqual(['s1', 's3']);
    expect(st.sessionsOfTasks([])).toEqual([]);
    expect(st.sessionsOfTasks(['ghost'])).toEqual([]);
  });
});

describe('tasks.clear through the request handler', () => {
  const cleanups: (() => void)[] = [];
  afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

  /** A Host over an in-memory database and a bridge whose `archive` we control (no Codex process is started). */
  function makeHost(archive: (id: string) => Promise<void> = async () => {}) {
    const db = new Db(':memory:');
    const bridge = new CodexBridge(new CodexRpc(process.execPath, []));
    const archived: string[] = [];
    vi.spyOn(bridge, 'archive').mockImplementation(async (id: string) => { archived.push(id); await archive(id); });
    const host = new Host({ db, bridge });
    const events: Ev[] = [];
    host.ev.on('ev', (e: Ev) => events.push(e));
    cleanups.push(() => { host.butler.scheduler.stop(); bridge.rpc.stop(); db.sql.close(); });

    const st = host.butler.state;
    /** Creates a task in `status` plus the given Codex sessions attached to it. */
    const task = (title: string, status: TaskStatus, sessions: [id: string, status?: SessionStatus][] = []) => {
      const t = st.createTask(title, `goal of ${title}`, status === 'planning' ? [] : ['step']);
      if (status !== 'running' && status !== 'planning') st.updateTask(t.id, { status });
      for (const [id, s] of sessions) st.upsertSession({ id, taskId: t.id, title: `session ${id}`, status: s ?? 'idle' });
      return t;
    };
    const clear = (d: unknown) => host.handle('dev1', 'tasks.clear', d) as Promise<{ removed: string[]; skipped: string[] }>;
    const removeEvents = () => events.filter((e) => e.k === 'task.remove');
    return { host, st, events, archived, task, clear, removeEvents };
  }

  it('without ids clears every finished task, archives their sessions and leaves active work alone', async () => {
    const { st, archived, task, clear, removeEvents, host } = makeHost();
    const done = task('done', 'done', [['s-done-1', 'running'], ['s-done-2', 'idle']]);
    const failed = task('failed', 'failed', [['s-failed', 'error']]);
    const cancelled = task('cancelled', 'cancelled');
    const running = task('running', 'running', [['s-running', 'running']]);
    const waiting = task('waiting', 'waiting_user', [['s-waiting', 'waiting_approval']]);
    const planning = task('planning', 'planning');
    const blocked = task('blocked', 'blocked', [['s-blocked', 'idle']]);

    const res = await clear({});

    expect(sorted(res.removed)).toEqual(sorted([done.id, failed.id, cancelled.id]));
    expect(res.skipped).toEqual([]);
    expect(sorted(st.tasks(false).map((t) => t.id))).toEqual(sorted([running.id, waiting.id, planning.id, blocked.id]));

    // Sessions of removed tasks: closed on the Codex side and marked archived in our state.
    expect(sorted(archived)).toEqual(['s-done-1', 's-done-2', 's-failed']);
    for (const id of ['s-done-1', 's-done-2', 's-failed']) expect(st.session(id)!.status).toBe('archived');
    // Sessions of tasks that are still alive are untouched.
    expect(st.session('s-running')!.status).toBe('running');
    expect(st.session('s-waiting')!.status).toBe('waiting_approval');
    expect(st.session('s-blocked')!.status).toBe('idle');

    // ONE task.remove event with every removed id, and it is in the durable log.
    expect(removeEvents()).toHaveLength(1);
    expect(sorted((removeEvents()[0].d as { ids: string[] }).ids)).toEqual(sorted(res.removed));
    expect(host.ev.since(0)!.filter((e) => e.k === 'task.remove')).toHaveLength(1);
  });

  it('with ids removes only the finished ones and reports active or unknown ids as skipped', async () => {
    const { st, archived, task, clear, removeEvents } = makeHost();
    const done = task('done', 'done', [['s-done', 'idle']]);
    const failed = task('failed', 'failed', [['s-failed', 'error']]);
    const running = task('running', 'running', [['s-running', 'running']]);

    const res = await clear({ ids: [done.id, running.id, 'ghost'] });

    expect(res).toEqual({ removed: [done.id], skipped: [running.id, 'ghost'] });
    expect(st.task(done.id)).toBeUndefined();
    expect(st.task(failed.id)).toBeDefined(); // finished, but not asked for
    expect(st.task(running.id)).toBeDefined();
    expect(archived).toEqual(['s-done']);
    expect(st.session('s-running')!.status).toBe('running');
    expect(st.session('s-failed')!.status).toBe('error');
    expect(removeEvents().map((e) => e.d)).toEqual([{ ids: [done.id] }]);
  });

  it('is not limited to the 100 rows that list calls return', async () => {
    const { st, archived, task, clear, removeEvents } = makeHost();
    const finished = Array.from({ length: 105 }, (_, i) => task(`old ${i}`, (['done', 'failed', 'cancelled'] as const)[i % 3], [[`s${i}`, 'idle']]));
    const active = task('still going', 'running', [['s-active', 'running']]);

    const res = await clear({});

    expect(res.removed).toHaveLength(105);
    expect(sorted(res.removed)).toEqual(sorted(finished.map((t) => t.id)));
    expect(archived).toHaveLength(105);
    expect(finished.every((_, i) => st.session(`s${i}`)?.status === 'archived')).toBe(true);
    expect(st.task(active.id)).toBeDefined();
    expect(st.session('s-active')!.status).toBe('running');
    expect(removeEvents()).toHaveLength(1);
    expect((removeEvents()[0].d as { ids: string[] }).ids).toHaveLength(105);
  });

  it('an empty ids list clears nothing (only an omitted ids means "all")', async () => {
    const { st, task, clear, removeEvents } = makeHost();
    const done = task('done', 'done', [['s1']]);
    expect(await clear({ ids: [] })).toEqual({ removed: [], skipped: [] });
    expect(st.task(done.id)).toBeDefined();
    expect(removeEvents()).toHaveLength(0);
    // null behaves like an omitted field.
    expect((await clear({ ids: null })).removed).toEqual([done.id]);
  });

  it('handles repeated ids once and a second clear is a no-op', async () => {
    const { archived, task, clear, removeEvents } = makeHost();
    const done = task('done', 'done', [['s1']]);
    task('running', 'running');

    expect(await clear({ ids: [done.id, done.id] })).toEqual({ removed: [done.id], skipped: [] });
    expect(removeEvents()).toHaveLength(1);

    // Everything already gone: nothing removed, nothing archived again, no extra event.
    expect(await clear({})).toEqual({ removed: [], skipped: [] });
    expect(await clear({ ids: [done.id] })).toEqual({ removed: [], skipped: [done.id] });
    expect(archived).toEqual(['s1']);
    expect(removeEvents()).toHaveLength(1);
  });

  it('keeps going when Codex cannot archive a thread, and never touches sessions that are already archived', async () => {
    const { st, archived, task, clear } = makeHost(async (id) => { if (id === 's-lost') throw new Error('thread not found'); });
    const done = task('done', 'done', [['s-lost', 'idle'], ['s-ok', 'running'], ['s-old', 'archived']]);

    const res = await clear({});

    expect(res.removed).toEqual([done.id]);
    expect(sorted(archived)).toEqual(['s-lost', 's-ok']); // s-old was archived long ago
    expect(st.session('s-lost')!.status).toBe('archived'); // marked locally even though Codex refused
    expect(st.session('s-ok')!.status).toBe('archived');
    expect(st.session('s-old')!.status).toBe('archived');
  });

  it('replies right away without waiting for Codex to archive the threads (the app gives tasks.clear only ~20 s)', async () => {
    // A bridge whose archive never settles, like a wedged Codex app-server.
    const { st, events, archived, task, clear } = makeHost(() => new Promise<void>(() => {}));
    const done = task('done', 'done', [['s1', 'running'], ['s2', 'idle']]);
    task('running', 'running', [['s3', 'running']]);
    const before = events.length;

    const outcome = await within(1000, clear({}));

    expect(outcome).toEqual({ removed: [done.id], skipped: [] });
    // Everything the app can see had already happened by the time of the reply (events go out ahead of the response):
    // the task is gone, the removal was broadcast, and the sessions are archived.
    expect(st.task(done.id)).toBeUndefined();
    const sent = events.slice(before);
    expect(sent.map((e) => e.k)).toEqual(['task.remove', 'session.upsert', 'session.upsert']);
    expect(sent[0].d).toEqual({ ids: [done.id] });
    expect(sorted(sent.slice(1).map((e) => (e.d as Session).id))).toEqual(['s1', 's2']);
    expect(sent.slice(1).every((e) => (e.d as Session).status === 'archived')).toBe(true);
    expect(st.session('s1')!.status).toBe('archived');
    expect(st.session('s2')!.status).toBe('archived');
    // Codex was asked about each thread, but nothing waits for the answer; unrelated sessions are left alone.
    expect(sorted(archived)).toEqual(['s1', 's2']);
    expect(st.session('s3')!.status).toBe('running');
  });

  it('a status update that lands while Codex is still archiving cannot bring the session back, even if the archive then fails', async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const ctx: ReturnType<typeof makeHost> = makeHost(async (id) => {
      await gate;
      // What the butler does once the interrupt ends the turn: mirror the bridge's live status into state...
      ctx.host.butler.syncSession(id, { status: 'idle' });
      // ...and then Codex fails to archive the thread.
      throw new Error('thread/archive: thread not found');
    });
    const { st, events, task, clear } = ctx;
    task('done', 'done', [['s1', 'running']]);
    const statuses = () => events.filter((e) => e.k === 'session.upsert' && (e.d as Session).id === 's1').map((e) => (e.d as Session).status);
    const before = statuses().length;

    await clear({});
    expect(statuses().slice(before)).toEqual(['archived']);

    release();
    await vi.waitFor(() => expect(statuses().slice(before)).toEqual(['archived', 'idle', 'archived']));
    expect(st.session('s1')!.status).toBe('archived');
  });

  it('a Codex archive that finishes later changes nothing the app has already seen', async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const { events, archived, task, clear } = makeHost(() => gate);
    task('done', 'done', [['s1', 'running']]);
    await clear({});
    const seen = events.length;

    release();
    await new Promise((r) => setTimeout(r, 30));

    expect(archived).toEqual(['s1']);
    expect(events).toHaveLength(seen); // no second task.remove / session.upsert
  });

  it('rejects a malformed ids field without removing anything', async () => {
    const { st, task, clear, removeEvents } = makeHost();
    const done = task('done', 'done');
    await expect(clear({ ids: done.id })).rejects.toThrow(/ids/);
    await expect(clear({ ids: { 0: done.id } })).rejects.toThrow(/ids/);
    expect(st.task(done.id)).toBeDefined();
    expect(removeEvents()).toHaveLength(0);
  });
});
