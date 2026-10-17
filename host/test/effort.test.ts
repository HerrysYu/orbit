// Reasoning effort + heartbeat model settings — docs/protocol.md §4.5.
// What settings.set stores, what models.list reports, and which model / effort every bot round and every Codex
// worker turn is started with.
import { EventEmitter } from 'node:events';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { Host } from '../src/app.ts';
import { Butler } from '../src/butler/butler.ts';
import { parseEffortSetting, pickEffort, readEffort } from '../src/butler/effort.ts';
import { GPT_6_1_SOL_OPTION, mergeModelOptions } from '../src/butler/model-options.ts';
import { ModelCatalog } from '../src/butler/models.ts';
import { TOOL_MAP, workerEffort } from '../src/butler/tools.ts';
import { CodexBridge } from '../src/codex/bridge.ts';
import { CodexRpc } from '../src/codex/rpc.ts';
import { Db } from '../src/store/db.ts';
import { EventLog } from '../src/store/events.ts';
import { DEFAULT_SETTINGS, type Settings } from '../src/types.ts';
import { log } from '../src/util/log.ts';

const FAKE = join(import.meta.dirname, 'fake-codex.mjs');

/** A Codex `model/list` entry. */
const codexModel = (id: string, efforts: string[], extra: Record<string, unknown> = {}) => ({
  id, model: id, displayName: `Model ${id}`, description: '', hidden: false, isDefault: false,
  supportedReasoningEfforts: efforts.map((reasoningEffort) => ({ reasoningEffort, description: '' })),
  defaultReasoningEffort: efforts.includes('medium') ? 'medium' : efforts[0],
  ...extra,
});
const CATALOG = [
  codexModel('gpt-main', ['low', 'medium', 'high', 'xhigh'], { isDefault: true }),
  codexModel('gpt-mini', ['low', 'medium']),
  codexModel('gpt-lite', ['low', 'high'], { defaultReasoningEffort: 'high' }), // no 'medium'
  { id: 'gpt-bare', model: 'gpt-bare', displayName: 'Bare', description: '', hidden: false, isDefault: false }, // says nothing about efforts
];

const quietWarn = () => vi.spyOn(log, 'warn').mockImplementation(() => {});
afterEach(() => vi.restoreAllMocks());

describe('effort helpers', () => {
  it('parseEffortSetting: "", null and undefined are auto; anything else must be a lowercase word', () => {
    for (const auto of ['', null, undefined]) expect(parseEffortSetting(auto)).toBe('');
    for (const ok of ['minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'a', 'abcdefghijklmnop']) expect(parseEffortSetting(ok)).toBe(ok);
    for (const bad of ['High', 'x-high', 'x high', ' high', 'high ', 'abcdefghijklmnopq', 'x1', 5, true, {}, ['high']]) {
      expect(() => parseEffortSetting(bad), JSON.stringify(bad)).toThrow('无效的推理强度');
    }
  });

  it('readEffort: only a plausible effort name survives', () => {
    expect(readEffort(' high ')).toBe('high');
    for (const none of ['', '  ', null, undefined, 3, 'very high', 'HIGH']) expect(readEffort(none)).toBe('');
  });

  it('pickEffort: first supported wish, else first supported fallback, else nothing', () => {
    const warn = quietWarn();
    const supported = ['low', 'medium'];
    expect(pickEffort({ scope: 't', supported, wanted: ['', 'low', 'medium'] })).toBe('low');
    expect(pickEffort({ scope: 't', supported, wanted: ['xhigh', 'medium'] })).toBe('medium');
    expect(warn).toHaveBeenCalledTimes(1);
    expect(pickEffort({ scope: 't', supported, wanted: ['xhigh'], fallbacks: ['high', 'low'] })).toBe('low');
    expect(pickEffort({ scope: 't', supported, wanted: [] })).toBeUndefined();
    expect(pickEffort({ scope: 't', wanted: ['max'] })).toBe('max'); // nothing known about the model → nothing filtered
    expect(pickEffort({ scope: 't', supported: [], wanted: ['max'] })).toBe('max');
  });
});

describe('model catalog carries efforts', () => {
  it('mergeModelOptions: efforts and defaultEffort come from the Codex model; Sol is added with defaultEffort medium', () => {
    const merged = mergeModelOptions(CATALOG as any);
    expect(merged.find((m) => m.id === 'gpt-main')).toMatchObject({ efforts: ['low', 'medium', 'high', 'xhigh'], defaultEffort: 'medium', isDefault: true });
    expect(merged.find((m) => m.id === 'gpt-lite')).toMatchObject({ efforts: ['low', 'high'], defaultEffort: 'high' });
    expect(merged.find((m) => m.id === 'gpt-bare')).toMatchObject({ efforts: [], defaultEffort: undefined });
    expect(merged.find((m) => m.id === GPT_6_1_SOL_OPTION.id)).toMatchObject({ efforts: ['low', 'medium', 'high', 'xhigh', 'max'], defaultEffort: 'medium', isDefault: false });
  });

  it('a Sol the server lists keeps its own efforts and default; one it lists without them gets the manual ones', () => {
    const own = mergeModelOptions([codexModel(GPT_6_1_SOL_OPTION.id, ['minimal', 'high'], { defaultReasoningEffort: 'high' })] as any);
    expect(own).toHaveLength(1);
    expect(own[0]).toMatchObject({ efforts: ['minimal', 'high'], defaultEffort: 'high' });
    const bare = mergeModelOptions([{ ...codexModel(GPT_6_1_SOL_OPTION.id, []), defaultReasoningEffort: undefined }] as any);
    expect(bare[0]).toMatchObject({ efforts: GPT_6_1_SOL_OPTION.efforts, defaultEffort: 'medium' });
  });

  it('ModelCatalog.list: a failed fetch is not retried on every call, only after a minute (or when forced)', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    try {
      quietWarn();
      const models = vi.fn().mockRejectedValueOnce(new Error('codex is down')).mockResolvedValue(CATALOG as any);
      const catalog = new ModelCatalog({ models } as any);
      expect((await catalog.list()).map((m) => m.id)).toEqual([GPT_6_1_SOL_OPTION.id]); // stale (initial) cache
      await catalog.list();
      await catalog.list();
      expect(models).toHaveBeenCalledTimes(1);
      vi.setSystemTime(Date.now() + 61_000);
      expect((await catalog.list()).map((m) => m.id)).toContain('gpt-main');
      expect(models).toHaveBeenCalledTimes(2);
      await catalog.list();
      expect(models).toHaveBeenCalledTimes(2); // fetched: cached for an hour now
      await catalog.list(true);
      expect(models).toHaveBeenCalledTimes(3);
    } finally {
      vi.useRealTimers();
    }
  });

  it('ModelCatalog.peek reads the cache only: by id, or the default model', async () => {
    const models = vi.fn(async () => CATALOG as any);
    const catalog = new ModelCatalog({ models } as any);
    expect(catalog.peek(GPT_6_1_SOL_OPTION.id)?.efforts).toContain('max'); // before any fetch: just the manual option
    expect(catalog.peek()).toBeUndefined();
    await catalog.list();
    await catalog.list(); // cached for an hour
    expect(models).toHaveBeenCalledTimes(1);
    expect(catalog.peek('gpt-mini')).toMatchObject({ efforts: ['low', 'medium'], defaultEffort: 'medium' });
    expect(catalog.peek()?.id).toBe('gpt-main');
    expect(catalog.peek(null)?.id).toBe('gpt-main');
    expect(catalog.peek('nope')).toBeUndefined();
    expect(models).toHaveBeenCalledTimes(1); // peek never asks Codex
  });
});

describe('Host: settings.set and models.list', () => {
  const cleanups: (() => void)[] = [];
  afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

  function makeHost() {
    const bridge = new CodexBridge(new CodexRpc(process.execPath, []));
    vi.spyOn(bridge, 'models').mockResolvedValue(CATALOG as any);
    const db = new Db(':memory:');
    const host = new Host({ db, bridge });
    const events: any[] = [];
    host.ev.on('ev', (e) => { if (e.k === 'settings.changed') events.push(e); });
    cleanups.push(() => { host.butler.scheduler.stop(); bridge.rpc.stop(); db.sql.close(); });
    const set = (d: object) => host.handle('dev1', 'settings.set', d) as Promise<Settings>;
    const get = () => host.handle('dev1', 'settings.get', {}) as Promise<Settings>;
    return { host, db, events, set, get };
  }

  it('settings.set stores the three effort fields and later partial updates keep them', async () => {
    const { set, get, events, db } = makeHost();
    const saved = await set({ models: { butler: 'gpt-main', butlerEffort: 'high', heartbeatEffort: 'low', codexEffort: 'xhigh' } });
    expect(saved.models).toMatchObject({ butler: 'gpt-main', heartbeat: '', butlerEffort: 'high', heartbeatEffort: 'low', codexEffort: 'xhigh' });
    expect(events.at(-1).d.models.codexEffort).toBe('xhigh');

    const merged = await set({ models: { heartbeat: 'gpt-mini' }, heartbeatMinutes: 45 }); // deep merge: efforts stay
    expect(merged.models).toMatchObject({ butler: 'gpt-main', heartbeat: 'gpt-mini', butlerEffort: 'high', heartbeatEffort: 'low', codexEffort: 'xhigh' });
    expect((await get()).models).toEqual(merged.models);
    expect(db.get<any>('settings').models.codexEffort).toBe('xhigh'); // persisted, not just echoed
    await set({ proactivity: 'high' }); // no models key at all
    expect((await get()).models).toEqual(merged.models);

    const cleared = await set({ models: { butlerEffort: '', heartbeatEffort: null } }); // '' and null both mean 自动 (stored as '')
    expect(cleared.models).toMatchObject({ butlerEffort: '', heartbeatEffort: '', codexEffort: 'xhigh' });
  });

  it.each([
    ['uppercase', 'High'], ['dash', 'x-high'], ['inner space', 'x high'], ['padded', ' high'], ['too long', 'abcdefghijklmnopq'],
    ['digit', 'o1'], ['number', 5], ['boolean', true], ['object', {}], ['array', ['high']],
  ])('settings.set rejects an invalid effort (%s) and changes nothing', async (_name, bad) => {
    const { set, get, events } = makeHost();
    await set({ models: { butlerEffort: 'low' } });
    const before = await get();
    const seen = events.length;
    for (const key of ['butlerEffort', 'heartbeatEffort', 'codexEffort']) {
      await expect(set({ heartbeatMinutes: 99, models: { butler: 'other', [key]: bad } })).rejects.toThrow('无效的推理强度');
    }
    expect(await get()).toEqual(before); // not even the valid parts of the rejected request were applied
    expect(events).toHaveLength(seen);
  });

  it('models.list: both lists carry efforts and defaultEffort, Sol included', async () => {
    const { host } = makeHost();
    const res = await host.handle('dev1', 'models.list', {}) as { butler: any[]; codex: any[] };
    const json = JSON.parse(JSON.stringify(res)); // what actually goes over the wire
    for (const list of [json.butler, json.codex]) {
      expect(list.find((m: any) => m.id === 'gpt-main')).toMatchObject({ displayName: 'Model gpt-main', isDefault: true, efforts: ['low', 'medium', 'high', 'xhigh'], defaultEffort: 'medium' });
      expect(list.find((m: any) => m.id === 'gpt-lite')).toMatchObject({ efforts: ['low', 'high'], defaultEffort: 'high' });
      expect(list.find((m: any) => m.id === 'gpt-bare')).toMatchObject({ efforts: [] });
      expect(list.find((m: any) => m.id === 'gpt-bare')).not.toHaveProperty('defaultEffort');
      expect(list.find((m: any) => m.id === GPT_6_1_SOL_OPTION.id)).toMatchObject({ isDefault: false, efforts: ['low', 'medium', 'high', 'xhigh', 'max'], defaultEffort: 'medium' });
    }
    expect(json.codex.find((m: any) => m.id === 'gpt-mini')).toEqual({ id: 'gpt-mini', displayName: 'Model gpt-mini', isDefault: false, efforts: ['low', 'medium'], defaultEffort: 'medium' });
  });
});

describe('bot rounds: model and reasoning effort', () => {
  const cleanups: (() => void)[] = [];
  afterEach(() => { while (cleanups.length) cleanups.pop()!(); });

  /** A Butler whose brain is stubbed, so `round()` can be driven directly and its `turn(…, { model, effort })` read back. */
  function makeBot(models?: Partial<Settings['models']>) {
    const bridge = new CodexBridge(new CodexRpc(process.execPath, []));
    const catalog = vi.spyOn(bridge, 'models').mockResolvedValue(CATALOG as any);
    const db = new Db(':memory:');
    const gw = Object.assign(new EventEmitter(), { onlineDevices: [], push: () => 0 }) as any;
    const b = new Butler(db, new EventLog(db), bridge, gw);
    const ensure = vi.spyOn(b.brain, 'ensure').mockResolvedValue('thread-1');
    const turn = vi.spyOn(b.brain, 'turn').mockResolvedValue('completed');
    if (models) db.set('settings', { models });
    cleanups.push(() => { b.scheduler.stop(); bridge.rpc.stop(); db.sql.close(); });
    const round = (...types: string[]) => (b as any).round(types.map((type) => ({ type, body: type, ts: Date.now() }))) as Promise<void>;
    const lastTurn = () => turn.mock.calls.at(-1)![1];
    return { b, bridge, catalog, ensure, turn, round, lastTurn };
  }

  const SET = { butler: 'gpt-main', butlerEffort: 'high', heartbeat: 'gpt-mini', heartbeatEffort: 'low' };

  it('an ordinary batch runs on the bot model and effort', async () => {
    const t = makeBot(SET);
    await t.round('user_message');
    expect(t.lastTurn()).toEqual({ model: 'gpt-main', effort: 'high' });
    await t.round('schedule_fired', 'import_received');
    expect(t.lastTurn()).toEqual({ model: 'gpt-main', effort: 'high' });
  });

  it('a batch of nothing but heartbeats runs on the heartbeat model and effort; the thread is still the bot model\'s', async () => {
    const t = makeBot(SET);
    await t.round('heartbeat');
    expect(t.lastTurn()).toEqual({ model: 'gpt-mini', effort: 'low' });
    await t.round('heartbeat', 'heartbeat');
    expect(t.lastTurn()).toEqual({ model: 'gpt-mini', effort: 'low' });
    expect(t.ensure.mock.calls.map((c) => c[0].model)).toEqual(['gpt-main', 'gpt-main']); // never the heartbeat model: no new thread for it
  });

  it('a batch that mixes a heartbeat with anything else is a bot round', async () => {
    const t = makeBot(SET);
    await t.round('heartbeat', 'user_message');
    expect(t.lastTurn()).toEqual({ model: 'gpt-main', effort: 'high' });
    await t.round('schedule_fired', 'heartbeat');
    expect(t.lastTurn()).toEqual({ model: 'gpt-main', effort: 'high' });
  });

  it('after a heartbeat round the next chat goes back to the bot model and effort (nothing sticks)', async () => {
    const t = makeBot(SET);
    await t.round('heartbeat');
    await t.round('user_message');
    expect(t.turn.mock.calls.map((c) => c[1])).toEqual([{ model: 'gpt-mini', effort: 'low' }, { model: 'gpt-main', effort: 'high' }]);
  });

  it.each([
    { name: 'both on auto → the bot\'s model and effort', models: { butler: 'gpt-main', butlerEffort: 'xhigh' }, want: { model: 'gpt-main', effort: 'xhigh' } },
    { name: 'heartbeat model set, effort on auto → bot effort (if the model has it)', models: { butler: 'gpt-main', butlerEffort: 'low', heartbeat: 'gpt-mini' }, want: { model: 'gpt-mini', effort: 'low' } },
    { name: 'heartbeat effort set, model on auto → bot model', models: { butler: 'gpt-main', butlerEffort: 'low', heartbeatEffort: 'high' }, want: { model: 'gpt-main', effort: 'high' } },
    { name: 'everything on auto → default model, medium', models: {}, want: { model: 'gpt-main', effort: 'medium' } },
  ])('heartbeat settings left on auto follow the bot: $name', async ({ models, want }) => {
    const t = makeBot(models);
    await t.round('heartbeat');
    expect(t.lastTurn()).toEqual(want);
  });

  it('bot model "" resolves to Codex\'s default model id on every round, heartbeats included; the effort is medium', async () => {
    const t = makeBot();
    await t.round('user_message');
    await t.round('heartbeat');
    expect(t.turn.mock.calls.map((c) => c[1])).toEqual([{ model: 'gpt-main', effort: 'medium' }, { model: 'gpt-main', effort: 'medium' }]);
    expect(t.ensure.mock.calls[0]![0].model).toBeUndefined(); // the thread is made on the default itself
  });

  it('no model is passed when Codex cannot name a default', async () => {
    const t = makeBot();
    vi.spyOn(t.bridge, 'defaultModel').mockResolvedValue(null);
    await t.round('user_message');
    expect(t.lastTurn()).toEqual({ effort: 'medium' });
    expect(t.lastTurn()!.model).toBeUndefined();
  });

  it('drops an effort the model does not support, warns, and falls back to the group\'s default', async () => {
    const warn = quietWarn();
    const mini = makeBot({ butler: 'gpt-mini', butlerEffort: 'xhigh' });
    await mini.round('user_message');
    expect(mini.lastTurn()).toEqual({ model: 'gpt-mini', effort: 'medium' }); // bot default
    expect(warn).toHaveBeenCalledTimes(1);
    expect(warn.mock.calls[0]!.join(' ')).toMatch(/gpt-mini.*xhigh/);

    const lite = makeBot({ butler: 'gpt-lite', butlerEffort: 'xhigh' }); // no medium either → the model's own default
    await lite.round('user_message');
    expect(lite.lastTurn()).toEqual({ model: 'gpt-lite', effort: 'high' });

    // heartbeat: the heartbeat model lacks the heartbeat effort → the bot's effort, if that one is fine for it
    const hb = makeBot({ butler: 'gpt-main', butlerEffort: 'low', heartbeat: 'gpt-mini', heartbeatEffort: 'max' });
    await hb.round('heartbeat');
    expect(hb.lastTurn()).toEqual({ model: 'gpt-mini', effort: 'low' });
    expect(warn).toHaveBeenCalledTimes(3);
    // …and when the bot's effort is no good for the heartbeat model either, it is medium again
    const hb2 = makeBot({ butler: 'gpt-main', butlerEffort: 'xhigh', heartbeat: 'gpt-mini', heartbeatEffort: 'max' });
    await hb2.round('heartbeat');
    expect(hb2.lastTurn()).toEqual({ model: 'gpt-mini', effort: 'medium' });
    // the same setting is fine on a model that has it, and then nothing is dropped
    warn.mockClear();
    await hb2.round('user_message');
    expect(hb2.lastTurn()).toEqual({ model: 'gpt-main', effort: 'xhigh' });
    expect(warn).not.toHaveBeenCalled();
  });

  it('does not filter when the model is not in the catalog or the catalog lists no efforts for it', async () => {
    const warn = quietWarn();
    const custom = makeBot({ butler: 'my-own-model', butlerEffort: 'max' });
    await custom.round('user_message');
    expect(custom.lastTurn()).toEqual({ model: 'my-own-model', effort: 'max' });
    const bare = makeBot({ butler: 'gpt-bare', butlerEffort: 'max' });
    await bare.round('user_message');
    expect(bare.lastTurn()).toEqual({ model: 'gpt-bare', effort: 'max' });
    expect(warn).not.toHaveBeenCalled();
  });

  it('asks Codex for the model list at most once an hour, not once per round', async () => {
    const t = makeBot(SET);
    await t.round('user_message');
    await t.round('heartbeat');
    await t.round('user_message');
    expect(t.catalog).toHaveBeenCalledTimes(1);
  });

  it('ignores a stored effort that is not a plausible effort name', async () => {
    const t = makeBot({ butler: 'gpt-main', butlerEffort: 'Very High' as string, heartbeatEffort: 42 as unknown as string });
    await t.round('heartbeat');
    expect(t.lastTurn()).toEqual({ model: 'gpt-main', effort: 'medium' });
  });
});

describe('workerEffort', () => {
  const settingsOf = (models: Partial<Settings['models']> = {}) => () => ({ ...DEFAULT_SETTINGS, models: { ...DEFAULT_SETTINGS.models, ...models } }) as Settings;
  async function rtOf(models: Partial<Settings['models']> = {}) {
    const catalog = new ModelCatalog({ models: async () => CATALOG as any } as any);
    await catalog.list(true);
    return { settings: settingsOf(models), models: catalog };
  }

  it.each([
    { owner: 'high', bot: 'low', want: 'high', why: 'the owner\'s effort wins' },
    { owner: 'high', bot: undefined, want: 'high', why: 'owner set, bot silent' },
    { owner: '', bot: 'low', want: 'low', why: 'auto → the bot\'s effort' },
    { owner: undefined, bot: 'low', want: 'low', why: 'missing counts as auto' },
    { owner: null, bot: 'low', want: 'low', why: 'null counts as auto' },
    { owner: '', bot: undefined, want: undefined, why: 'neither → nothing is sent, Codex decides' },
    { owner: '', bot: '', want: undefined, why: 'blank everywhere' },
    { owner: '', bot: 'very high', want: undefined, why: 'a bot value that is no effort name is ignored' },
  ])('priority: $why', ({ owner, bot, want }) => {
    expect(workerEffort({ settings: settingsOf({ codexEffort: owner as any }) }, bot)).toBe(want);
  });

  it('drops an effort the target model does not support, with a warning, and falls to the next choice', async () => {
    const warn = quietWarn();
    const rt = await rtOf({ codexEffort: 'xhigh' });
    expect(workerEffort(rt, 'low', 'gpt-mini')).toBe('low'); // owner's xhigh is unsupported → as if auto → the bot's
    expect(warn).toHaveBeenCalledTimes(1);
    expect(warn.mock.calls[0]!.join(' ')).toMatch(/gpt-mini.*xhigh/);
    expect(workerEffort(rt, undefined, 'gpt-mini')).toBeUndefined(); // nothing left → Codex decides
    expect(workerEffort(rt, 'xhigh', 'gpt-main')).toBe('xhigh'); // fine on a model that has it
    const auto = await rtOf();
    warn.mockClear();
    expect(workerEffort(auto, 'high', 'gpt-mini')).toBeUndefined(); // the bot's own pick is checked too
    expect(warn).toHaveBeenCalledTimes(1);
    expect(workerEffort(auto, 'medium', 'gpt-mini')).toBe('medium');
    expect(warn).toHaveBeenCalledTimes(1);
  });

  it('no model given means Codex\'s default model; unknown models and models without a list are not filtered', async () => {
    const warn = quietWarn();
    const rt = await rtOf();
    expect(workerEffort(rt, 'xhigh')).toBe('xhigh'); // gpt-main supports it
    expect(workerEffort(rt, 'max')).toBeUndefined(); // …but not max
    expect(warn).toHaveBeenCalledTimes(1);
    expect(workerEffort(rt, 'max', 'my-own-model')).toBe('max');
    expect(workerEffort(rt, 'max', 'gpt-bare')).toBe('max');
    expect(workerEffort({ settings: settingsOf() }, 'max', 'gpt-mini')).toBe('max'); // no catalog at all
    expect(warn).toHaveBeenCalledTimes(1);
  });
});

describe('worker tools use workerEffort', () => {
  /** A runtime whose bridge only records what the tools hand it. */
  async function rtOf(models: Partial<Settings['models']> = {}) {
    const catalog = new ModelCatalog({ models: async () => CATALOG as any } as any);
    await catalog.list(true);
    const storedSessions = new Map<string, any>(); // what the host's state remembers about sessions
    const bridge = {
      sessions: new Map<string, any>(),
      createSession: vi.fn(async (o: any) => ({ threadId: 'thread-w', title: o.title, model: o.model ?? 'gpt-main', permission: 'manual', status: 'running', turns: 1 })),
      send: vi.fn(async (..._args: any[]) => 'started'),
    };
    const rt: any = {
      bridge, models: catalog, watches: new Map(), syncSession: vi.fn(),
      state: { sessions: () => [], updateTask: vi.fn(), session: (id: string) => storedSessions.get(id) },
      settings: () => ({ ...DEFAULT_SETTINGS, models: { ...DEFAULT_SETTINGS.models, ...models } }),
    };
    return { rt, bridge, storedSessions };
  }
  const create = { title: '查资料', prompt: '去查', effort: 'low' };

  it('codex_session_create: the owner\'s effort beats the bot\'s; on auto the bot\'s goes through', async () => {
    const owner = await rtOf({ codexEffort: 'high' });
    await TOOL_MAP.get('codex_session_create')!.run(create, owner.rt);
    expect(owner.bridge.createSession.mock.calls[0]![0]).toMatchObject({ effort: 'high' });

    const auto = await rtOf({ codexEffort: '' });
    await TOOL_MAP.get('codex_session_create')!.run(create, auto.rt);
    expect(auto.bridge.createSession.mock.calls[0]![0]).toMatchObject({ effort: 'low' });
    await TOOL_MAP.get('codex_session_create')!.run({ title: 't', prompt: 'p' }, auto.rt);
    expect(auto.bridge.createSession.mock.calls[1]![0].effort).toBeUndefined();
  });

  it('codex_session_create checks the effort against the model the session will run on', async () => {
    quietWarn();
    const { rt, bridge } = await rtOf({ codexDefault: 'gpt-mini', codexEffort: 'xhigh' });
    await TOOL_MAP.get('codex_session_create')!.run({ ...create, model: 'gpt-main' }, rt); // the owner's model wins: gpt-mini
    expect(bridge.createSession.mock.calls[0]![0]).toMatchObject({ model: 'gpt-mini', effort: 'low' });
  });

  it('computer_use_task and phone_task now pass the owner\'s effort (and nothing on auto)', async () => {
    for (const [tool, args] of [['computer_use_task', { title: '订座', goal: '去订' }], ['phone_task', { title: '查单', goal: '只查询，不要下单/付款' }]] as const) {
      const owner = await rtOf({ codexEffort: 'medium' });
      await TOOL_MAP.get(tool)!.run(args, owner.rt);
      expect(owner.bridge.createSession.mock.calls[0]![0], tool).toMatchObject({ effort: 'medium' });

      const auto = await rtOf();
      await TOOL_MAP.get(tool)!.run(args, auto.rt);
      expect(auto.bridge.createSession.mock.calls[0]![0].effort, tool).toBeUndefined();
    }
  });

  it('codex_session_send: a fresh turn takes the effort (checked against the session\'s model), a steer takes none', async () => {
    quietWarn();
    const { rt, bridge } = await rtOf({ codexEffort: 'xhigh' });
    bridge.sessions.set('s1', { threadId: 's1', model: 'gpt-mini', status: 'idle' });
    await TOOL_MAP.get('codex_session_send')!.run({ session_id: 's1', text: '继续', effort: 'low' }, rt);
    expect(bridge.send.mock.calls[0]![2]).toMatchObject({ effort: 'low' }); // xhigh is no good for gpt-mini → the bot's low

    bridge.sessions.set('s2', { threadId: 's2', model: 'gpt-main', status: 'idle' });
    await TOOL_MAP.get('codex_session_send')!.run({ session_id: 's2', text: '继续', effort: 'low' }, rt);
    expect(bridge.send.mock.calls[1]![2]).toMatchObject({ effort: 'xhigh' });

    bridge.sessions.set('s3', { threadId: 's3', model: 'gpt-main', status: 'running', activeTurnId: 'u1' });
    await TOOL_MAP.get('codex_session_send')!.run({ session_id: 's3', text: '补充', effort: 'low' }, rt);
    expect(bridge.send.mock.calls[2]![2].effort).toBeUndefined();
  });

  it('codex_session_send: a session the bridge has not loaded yet is checked against the model the host remembers for it', async () => {
    quietWarn();
    const { rt, bridge, storedSessions } = await rtOf({ codexEffort: 'xhigh' });
    storedSessions.set('s4', { id: 's4', model: 'gpt-mini' });
    await TOOL_MAP.get('codex_session_send')!.run({ session_id: 's4', text: '继续' }, rt);
    expect(bridge.send.mock.calls[0]![2].effort).toBeUndefined(); // gpt-mini has no xhigh
    storedSessions.set('s5', { id: 's5', model: 'gpt-main' });
    await TOOL_MAP.get('codex_session_send')!.run({ session_id: 's5', text: '继续' }, rt);
    expect(bridge.send.mock.calls[1]![2].effort).toBe('xhigh');
  });

  it('the effort parameter says it only counts while the owner\'s setting is on auto', () => {
    for (const name of ['codex_session_create', 'codex_session_send']) {
      const props = (TOOL_MAP.get(name)!.parameters as any).properties;
      expect(props.effort.description).toContain('设为「自动」时生效');
    }
  });
});

describe('end to end against a scripted codex app-server', () => {
  const cleanups: (() => void)[] = [];
  afterEach(() => {
    while (cleanups.length) cleanups.pop()!();
    for (const k of ['FAKE_CODEX_SCRIPT', 'FAKE_CODEX_LOG', 'FAKE_CODEX_MODELS']) delete process.env[k];
  });

  function makeBot(script: object[], settings: object, models?: object[]) {
    const dir = mkdtempSync(join(tmpdir(), 'opa-effort-'));
    const logPath = join(dir, 'codex.log');
    process.env.FAKE_CODEX_SCRIPT = JSON.stringify(script);
    process.env.FAKE_CODEX_LOG = logPath;
    if (models) process.env.FAKE_CODEX_MODELS = JSON.stringify(models);
    else delete process.env.FAKE_CODEX_MODELS;
    const bridge = new CodexBridge(new CodexRpc(process.execPath, [FAKE]));
    const db = new Db(':memory:');
    const gw = Object.assign(new EventEmitter(), { onlineDevices: ['d1'], push: () => 0 }) as any;
    const b = new Butler(db, new EventLog(db), bridge, gw);
    db.set('settings', { models: settings });
    b.start();
    cleanups.push(() => { b.stop(); bridge.rpc.stop(); rmSync(dir, { recursive: true, force: true }); });
    const calls = () => readFileSync(logPath, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
    const settle = async () => {
      await new Promise((r) => setTimeout(r, 100));
      await new Promise<void>((r) => { const t = setInterval(() => { if (!(b as any).running && !(b as any).inbox.length) { clearInterval(t); r(); } }, 20); });
    };
    return { b, calls, settle };
  }
  const brainTurns = (calls: any[]) => calls.filter((c) => c.method === 'turn/start' && c.params.input.at(-1).text.includes('<status_bar>')).map((c) => c.params);

  it('turn/start carries the heartbeat model and effort for a heartbeat round and the bot\'s for the chat after it, on one thread', async () => {
    const { b, calls, settle } = makeBot(
      [{ steps: [{ tool: 'yield' }] }, { steps: [{ tool: 'yield' }] }],
      { butler: 'gpt-main', butlerEffort: 'high', heartbeat: 'gpt-mini', heartbeatEffort: 'low' },
      CATALOG,
    );
    b.push({ type: 'heartbeat', body: '心跳检查：测试' });
    await settle();
    b.userMessage('你好', 'c1');
    await settle();
    const turns = brainTurns(calls());
    expect(turns.map((p) => [p.model, p.effort])).toEqual([['gpt-mini', 'low'], ['gpt-main', 'high']]);
    const starts = calls().filter((c) => c.method === 'thread/start');
    expect(starts).toHaveLength(1);
    expect(starts[0].params.model).toBe('gpt-main');
  });

  it('with everything on auto the turn gets the resolved default model id and medium', async () => {
    const { b, calls, settle } = makeBot([{ steps: [{ tool: 'yield' }] }], {});
    b.userMessage('你好', 'c1');
    await settle();
    const [turn] = brainTurns(calls());
    expect(turn).toMatchObject({ model: 'gpt-x', effort: 'medium' }); // fake-codex's one-model catalog
  });

  it.each([
    { owner: 'high', want: 'high', label: 'the owner\'s effort wins over the bot\'s' },
    { owner: '', want: 'low', label: 'on auto the bot\'s effort is used' },
  ])('a worker\'s first turn/start gets the effort ($label)', async ({ owner, want }) => {
    const { b, calls, settle } = makeBot(
      [{ steps: [{ tool: 'codex_session_create', args: { title: '查资料', prompt: 'WORKER-PROMPT', effort: 'low' } }, { tool: 'yield' }] }],
      { codexEffort: owner },
    );
    b.userMessage('帮我查', 'c1');
    await settle();
    const worker = calls().find((c) => c.method === 'turn/start' && c.params.input.some((i: any) => i.text === 'WORKER-PROMPT'));
    expect(worker.params.effort).toBe(want);
  });
});
