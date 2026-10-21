import { afterEach, describe, expect, it, vi } from 'vitest';
import { Host } from '../src/app.ts';
import { CodexBridge } from '../src/codex/bridge.ts';
import { CodexRpc } from '../src/codex/rpc.ts';
import { Gateway } from '../src/gateway/gateway.ts';
import { Db } from '../src/store/db.ts';
import { EventLog, type Ev } from '../src/store/events.ts';
import { TOOL_MAP } from '../src/butler/tools.ts';

describe('chat.clear', () => {
  const cleanups: (() => void)[] = [];
  afterEach(() => { while (cleanups.length) cleanups.pop()!(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

  function makeHost(db = new Db(':memory:')) {
    const bridge = new CodexBridge(new CodexRpc(process.execPath, []));
    const host = new Host({ db, bridge });
    vi.spyOn(host.butler, 'push').mockImplementation(() => {});
    cleanups.push(() => { host.butler.scheduler.stop(); bridge.rpc.stop(); });
    return { host, db, bridge };
  }

  it('atomically clears chat history and cards, preserves other state, and replays the tombstone at the returned seq', async () => {
    const db = new Db(':memory:');
    db.set('brain.threadId', 'brain-before-clear');
    db.set('brain.configKey', 'old-config');
    const { host } = makeHost(db);
    const sent = await host.handle('dev1', 'chat.send', { clientId: 'old-client', text: 'old user message' }) as { msgId: string };
    host.ev.emitEv('msg.assistant', { id: 'old-assistant', text: 'old reply' });
    const card = host.butler.state.renderCard({ component: 'text_card', props: { markdown: 'old card' } });
    host.butler.state.patchCard(card.id, { markdown: 'patched old card' });

    const task = host.butler.state.createTask('保留的任务', '继续运行', ['执行']);
    host.butler.state.upsertSession({ id: 'worker-1', title: '后台工作', status: 'running' });
    host.db.putDoc('approvals', 'approval-1', { id: 'approval-1', title: '保留审批' }, 'pending', Date.now());
    host.db.putDoc('imports', 'import-1', { id: 'import-1', kind: 'link', status: 'new' }, 'new', Date.now());
    host.db.sql.prepare('INSERT INTO schedules(id, data, next_at, active) VALUES (?, ?, ?, ?)')
      .run('schedule-1', JSON.stringify({ id: 'schedule-1', note: '保留提醒' }), Date.now() + 60_000, 1);
    host.butler.memory.write('主人喜欢清淡饮食');
    host.db.set('settings', { models: { butler: 'model-kept' } });
    host.id.addDevice({ id: 'dev1', pub: 'public-key', name: 'Phone' });
    host.db.audit('test', 'preserved', { ok: true });

    const broadcast: Ev[] = [];
    host.gw.channels.add({ state: 'open', deviceId: 'dev1', synced: true, send: (frame: Ev) => broadcast.push(frame) } as any);
    let duringClear: Promise<unknown> | undefined;
    let nestedClear: Promise<unknown> | undefined;
    host.ev.on('ev', (event: Ev) => {
      if (event.k === 'chat.cleared') {
        duringClear = host.handle('dev1', 'chat.send', { clientId: 'during-clear', text: 'retry me' }).catch((e) => e);
        nestedClear = host.handle('dev1', 'chat.clear', {}).catch((e) => e);
      }
    });

    const result = await host.handle('dev1', 'chat.clear', {}) as { cleared: true; seq: number; clearedAt: number };
    expect(result).toMatchObject({ cleared: true, seq: expect.any(Number), clearedAt: expect.any(Number) });
    expect(result.clearedAt).toBeGreaterThan(0);
    expect(broadcast.filter((frame) => frame.k === 'chat.cleared')).toHaveLength(1);
    expect(broadcast.find((frame) => frame.k === 'chat.cleared')).toMatchObject({ seq: result.seq, d: { clearedAt: result.clearedAt } });
    expect(await duringClear).toBeInstanceOf(Error);
    expect(await nestedClear).toBeInstanceOf(Error);

    const events = host.ev.since(0)!;
    expect(events.find((e) => e.k === 'chat.cleared')).toMatchObject({ seq: result.seq, d: { clearedAt: result.clearedAt } });
    expect(events.some((e) => ['msg.user', 'msg.assistant', 'ui.render', 'ui.patch'].includes(e.k))).toBe(false);
    expect(events.some((e) => e.k === 'task.upsert')).toBe(true);
    expect(host.db.sql.prepare('SELECT COUNT(*) AS n FROM cards').get()).toEqual({ n: 0 });
    expect(host.db.get('brain.threadId')).toBeUndefined();
    expect(host.db.get('brain.configKey')).toBeUndefined();

    // Exercise the actual Gateway replay code with a plain channel fixture (no sockets or device keys needed).
    const replay: any[] = [];
    (host.gw as any).doSync({ synced: false, send: (frame: unknown) => replay.push(frame) }, 'sync-1', 0);
    expect(replay[0]).toMatchObject({
      t: 'res', id: 'sync-1', ok: true,
      d: { reset: false, toSeq: result.seq, chatCleared: { seq: result.seq, clearedAt: result.clearedAt } },
    });
    expect(replay.filter((frame) => frame.k === 'chat.cleared')).toHaveLength(1);
    expect(replay.some((frame) => frame.k === 'msg.user' || frame.k === 'ui.render' || frame.k === 'ui.patch')).toBe(false);

    // The dedupe tombstone survives, so retrying the old client message cannot recreate the old chat event.
    expect(await host.handle('dev1', 'chat.send', { clientId: 'old-client', text: 'retry old message' }))
      .toEqual({ msgId: sent.msgId, duplicate: true });
    const newer = await host.handle('dev1', 'chat.send', { clientId: 'new-client', text: 'new conversation' }) as { msgId: string };
    expect(newer.msgId).not.toBe(sent.msgId);
    expect(host.ev.since(result.seq)!.map((e) => e.k)).toEqual(['msg.user']);
    expect(host.ev.lastSeq()).toBeGreaterThan(result.seq);

    expect(host.butler.state.task(task.id)).toBeDefined();
    expect(host.butler.state.session('worker-1')).toBeDefined();
    expect(host.butler.memory.list().map((m) => m.text)).toContain('主人喜欢清淡饮食');
    expect(host.db.get('settings')).toEqual({ models: { butler: 'model-kept' } });
    expect(host.id.devices().map((d) => d.id)).toEqual(['dev1']);
    expect(host.db.sql.prepare('SELECT COUNT(*) AS n FROM approvals').get()).toEqual({ n: 1 });
    expect(host.db.sql.prepare('SELECT COUNT(*) AS n FROM schedules').get()).toEqual({ n: 1 });
    expect(host.db.sql.prepare('SELECT COUNT(*) AS n FROM imports').get()).toEqual({ n: 1 });
    expect(host.db.sql.prepare('SELECT COUNT(*) AS n FROM audit').get()).toEqual({ n: 1 });
    expect(host.db.sql.prepare('SELECT COUNT(*) AS n FROM client_msgs').get()).toEqual({ n: 2 });
  });

  it('rolls back a failed clear and keeps the existing brain and chat context usable', async () => {
    const db = new Db(':memory:');
    db.set('brain.threadId', 'keep-brain-on-failure');
    db.set('brain.configKey', 'keep-config-on-failure');
    const { host } = makeHost(db);
    host.ev.emitEv('msg.user', { id: 'keep-user', text: 'still here' });
    const card = host.butler.state.renderCard({ component: 'text_card', props: { markdown: 'still here' } });
    const seq = host.ev.lastSeq();
    db.sql.exec(`CREATE TRIGGER fail_chat_clear BEFORE INSERT ON events
      WHEN NEW.k = 'chat.cleared' BEGIN SELECT RAISE(ABORT, 'forced clear failure'); END`);

    await expect(host.handle('dev1', 'chat.clear', {})).rejects.toThrow('forced clear failure');
    expect(host.ev.lastSeq()).toBe(seq);
    expect(host.ev.since(0)!.map((ev) => ev.k)).toEqual(['msg.user', 'ui.render']);
    expect(host.butler.state.card(card.id)).toBeDefined();
    expect(host.butler.brain.threadId).toBe('keep-brain-on-failure');
    expect(db.get('brain.threadId')).toBe('keep-brain-on-failure');
    expect(db.get('brain.configKey')).toBe('keep-config-on-failure');
    expect(db.get('chat.clearBarrier')).toBeUndefined();
  });

  it('keeps the latest clear barrier in sync after its tombstone ages out of both replay windows and EventLog is rebuilt', async () => {
    const { host, db } = makeHost();
    host.ev.emitEv('msg.user', { id: 'old-user', text: 'old' });
    host.butler.state.renderCard({ component: 'text_card', props: { markdown: 'old card' } });
    const clear = await host.handle('dev1', 'chat.clear', {}) as { seq: number; clearedAt: number };

    // Exceed both EventLog's MAX_REPLAY and Gateway's 500-event snapshot window without making real work run.
    for (let i = 0; i < 2_105; i++) host.ev.emitEv('task.progress', { i });
    const rebuilt = new EventLog(db);
    expect(rebuilt.chatClearBarrier()).toEqual({ seq: clear.seq, clearedAt: clear.clearedAt });
    expect(rebuilt.since(0)).toBeNull();

    const gateway = new Gateway(host.id, db, rebuilt, host.gw.opts);
    const frames: any[] = [];
    (gateway as any).doSync({ synced: false, send: (frame: unknown) => frames.push(frame) }, 'old-client', 0);
    const top = rebuilt.lastSeq();
    expect(frames[0]).toEqual({
      t: 'res', id: 'old-client', ok: true,
      d: {
        fromSeq: top - 500 + 1,
        toSeq: top,
        reset: true,
        chatCleared: { seq: clear.seq, clearedAt: clear.clearedAt },
      },
    });
    expect(frames.slice(1).some((frame) => frame.k === 'chat.cleared')).toBe(false);
    expect(frames.slice(1).some((frame) => frame.k === 'msg.user' || frame.k === 'ui.render')).toBe(false);
  });

  it('does not let delayed ui_render or ui_patch image embedding recreate cards after clear', async () => {
    const { host } = makeHost();
    const releases: ((response: Response) => void)[] = [];
    const fetchStub = vi.fn(() => new Promise<Response>((resolve) => releases.push(resolve))) as unknown as typeof fetch;
    vi.stubGlobal('fetch', fetchStub);

    const render = TOOL_MAP.get('ui_render')!;
    const renderPending = render.run({ component: 'image_gallery', props: { images: [{ url: 'http://127.0.0.1/slow-render.png' }] } }, host.butler);
    expect(fetchStub).toHaveBeenCalledTimes(1);
    await host.handle('dev1', 'chat.clear', {});
    releases.shift()!(new Response('', { status: 503 }));
    expect(await renderPending).toBe('本轮对话已清空。');
    expect(host.db.sql.prepare('SELECT COUNT(*) AS n FROM cards').get()).toEqual({ n: 0 });
    expect(host.db.sql.prepare("SELECT COUNT(*) AS n FROM events WHERE k = 'ui.render'").get()).toEqual({ n: 0 });

    const card = host.butler.state.renderCard({ component: 'image_gallery', props: { images: [{ url: 'https://example.com/existing.png' }] } });
    const patch = TOOL_MAP.get('ui_patch')!;
    const patchPending = patch.run({ card_id: card.id, props: { images: [{ url: 'http://127.0.0.1/slow-patch.png' }] } }, host.butler);
    expect(fetchStub).toHaveBeenCalledTimes(2);
    await host.handle('dev1', 'chat.clear', {});
    releases.shift()!(new Response('', { status: 503 }));
    expect(await patchPending).toBe('本轮对话已清空。');
    expect(host.db.sql.prepare('SELECT COUNT(*) AS n FROM cards').get()).toEqual({ n: 0 });
    expect(host.db.sql.prepare("SELECT COUNT(*) AS n FROM events WHERE k IN ('ui.render', 'ui.patch')").get()).toEqual({ n: 0 });
  });

  it('resets only the brain turn, drops old queue/recent state, and ignores late output', async () => {
    const db = new Db(':memory:');
    db.set('brain.threadId', 'brain-old');
    db.set('brain.configKey', 'old-config');
    const { host, bridge } = makeHost(db);
    vi.mocked(host.butler.push).mockRestore();
    (host.butler as any).wireBrain();
    (host.butler as any).inbox = [
      { type: 'user_message', body: 'old user input', fromUser: true, ts: 1 },
      { type: 'session_update', body: 'background progress', ts: 2 },
    ];
    (host.butler as any).recent.push('old carry-over');
    bridge.sessions.set('worker-1', { threadId: 'worker-1', title: '后台工作', permission: 'manual', status: 'running', activeTurnId: 'worker-turn', turns: 1 } as any);
    const cancelPhone = vi.spyOn(host.butler.phone, 'cancelAll');
    const interruptWorker = vi.spyOn(bridge, 'interrupt');
    const requests: { method: string; params: any }[] = [];
    let releaseTurnStart!: (value: unknown) => void;
    let releaseSteer!: (value: unknown) => void;
    vi.spyOn(bridge.rpc, 'request').mockImplementation(((method: string, params: any = {}) => {
      requests.push({ method, params });
      if (method === 'turn/start') return new Promise((resolve) => { releaseTurnStart = resolve; });
      if (method === 'turn/steer') return new Promise((resolve) => { releaseSteer = resolve; });
      return Promise.resolve({});
    }) as any);

    const live: any[] = [];
    host.ev.on('live', (frame) => live.push(frame));
    const oldTurn = host.butler.brain.turn('old turn input');
    bridge.rpc.emit('notification', 'turn/started', { threadId: 'brain-old', turn: { id: 'brain-turn' } });
    bridge.rpc.emit('notification', 'item/agentMessage/delta', { threadId: 'brain-old', delta: 'visible before clear' });
    expect(host.butler.brain.busy).toBe(true);
    (host.butler as any).running = true;
    host.butler.push({ type: 'user_message', body: 'pending steer must not requeue', fromUser: true });
    expect(requests.some((r) => r.method === 'turn/steer')).toBe(true);

    const result = await host.handle('dev1', 'chat.clear', {}) as { seq: number; clearedAt: number };
    expect(await oldTurn).toBe('interrupted');
    live.length = 0;
    expect(host.butler.brain.threadId).toBeUndefined();
    expect(host.butler.brain.busy).toBe(false);
    expect(host.butler.brain.contextTokens).toBe(0);
    expect((host.butler as any).recent).toEqual([]);
    expect((host.butler as any).inbox).toEqual([{ type: 'session_update', body: 'background progress', ts: 2 }]);
    expect((host.butler as any).streamingId).toBeUndefined();
    expect(cancelPhone).not.toHaveBeenCalled();
    expect(interruptWorker).not.toHaveBeenCalled();
    expect(bridge.sessions.get('worker-1')?.activeTurnId).toBe('worker-turn');
    expect(requests).toContainEqual({ method: 'turn/interrupt', params: { threadId: 'brain-old', turnId: 'brain-turn' } });

    // A turn/start response arriving after the clear is interrupted on its original thread and cannot restore the brain.
    releaseTurnStart({ turn: { id: 'late-turn' } });
    releaseSteer(false);
    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(requests).toContainEqual({ method: 'turn/interrupt', params: { threadId: 'brain-old', turnId: 'late-turn' } });
    bridge.rpc.emit('notification', 'item/agentMessage/delta', { threadId: 'brain-old', delta: 'stale delta' });
    bridge.rpc.emit('notification', 'item/completed', { threadId: 'brain-old', item: { type: 'agentMessage', id: 'stale', text: 'stale final' } });
    bridge.rpc.emit('notification', 'turn/completed', { threadId: 'brain-old', turn: { id: 'late-turn', status: 'completed', error: null } });
    expect(live.filter((frame) => frame.k === 'msg.start' || frame.k === 'msg.delta')).toEqual([]);
    expect((host.butler as any).inbox).toEqual([{ type: 'session_update', body: 'background progress', ts: 2 }]);
    expect(host.db.sql.prepare("SELECT COUNT(*) AS n FROM events WHERE k = 'msg.assistant'").get()).toEqual({ n: 0 });
    expect(host.db.get('brain.threadId')).toBeUndefined();
    expect(host.db.get('brain.configKey')).toBeUndefined();
    expect(host.ev.lastSeq()).toBe(result.seq);
    expect(requests.some((r) => r.method === 'thread/archive' && r.params.threadId === 'brain-old')).toBe(true);
  });
});
