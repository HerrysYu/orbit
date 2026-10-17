// Context management for the bot's long-lived brain thread: the status bar sends only what changed, memory travels in the
// status bar instead of the fixed instructions, and an idle bot compacts the thread once it has grown — never mid-job.
// Runs the real Butler / Brain / CodexBridge against an in-process stand-in for `codex app-server`.
import { EventEmitter } from 'node:events';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Brain } from '../src/butler/brain.ts';
import { Butler, STATUS_KEYS } from '../src/butler/butler.ts';
import { buildInstructions, loadSkillIndex } from '../src/butler/prompt.ts';
import { cancelPendingPhoneTask, isPhoneTaskStarting, TOOL_MAP } from '../src/butler/tools.ts';
import { CodexBridge } from '../src/codex/bridge.ts';
import { Db } from '../src/store/db.ts';
import { EventLog } from '../src/store/events.ts';
import { DEFAULT_SETTINGS } from '../src/types.ts';

// These tests cover the old way of running a phone task (a Codex worker thread), not the step-driven runner.
process.env.OPA_PHONE_MODE = 'codex';

// ───────────── the fake Codex ─────────────

/** How the fake answers `thread/compact/start`. */
type CompactMode =
  | 'turn'        // its own turn/started + turn/completed, nothing else
  | 'turn+marker' // turn/started, the deprecated thread/compacted, then turn/completed
  | 'item'        // only an item/completed of type contextCompaction
  | 'deprecated'  // only the deprecated thread/compacted
  | 'failed-turn' // a turn that ends failed
  | 'reject'      // the request itself is refused
  | 'silent'      // accepted, but nothing ever follows (a timeout)
  | 'hold';       // turn/started now, turn/completed when `releaseCompaction()` is called

const breakdown = (n: number) => ({ totalTokens: n, inputTokens: n, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0 });
/** A `thread/tokenUsage/updated` payload; `total` is deliberately larger than `last`, which is the one that counts. */
const usage = (threadId: string, inputTokens: number, window: number | null) => ({
  threadId, turnId: 'turn-x', tokenUsage: { total: breakdown(inputTokens * 3), last: breakdown(inputTokens), modelContextWindow: window },
});

class FakeCodex extends EventEmitter {
  readonly requests: { method: string; params: any }[] = [];
  /** Every request and every `butler.status` state in the order they happened (set by `makeBot`). */
  trace?: string[];
  /** What each brain turn reports as the size of its latest request. */
  inputTokens = 1_000;
  contextWindow: number | null = 200_000;
  compactMode: CompactMode = 'turn';
  /** The next N `turn/start` requests fail. */
  failTurnStarts = 0;
  releaseCompaction?: () => void;
  private threads = 0;
  private turns = 0;

  start() {}
  stop() {}
  notify() {}
  respond() {}
  respondError() {}

  notification(method: string, params: any) { this.emit('notification', method, params); }
  count(method: string) { return this.requests.filter((r) => r.method === method).length; }

  async request(method: string, params: any = {}): Promise<any> {
    this.requests.push({ method, params });
    this.trace?.push(`rpc:${method}`);
    switch (method) {
      case 'model/list': return { data: [{ id: 'gpt-x', displayName: 'GPT X', description: '', hidden: false, isDefault: true }] };
      case 'thread/start': return { thread: { id: `brain-${++this.threads}` }, model: 'gpt-x' };
      case 'turn/start': {
        if (this.failTurnStarts > 0) { this.failTurnStarts--; throw new Error('app-server unavailable'); }
        const id = `turn-${++this.turns}`;
        setTimeout(() => this.playBrainTurn(params.threadId, id), 2);
        return { turn: { id } };
      }
      case 'thread/compact/start': return this.startCompaction(params.threadId);
      default: return {};
    }
  }

  private playBrainTurn(threadId: string, turnId: string) {
    const turn = (status: string) => ({ id: turnId, items: [], status, error: null });
    this.notification('turn/started', { threadId, turn: turn('inProgress') });
    this.notification('thread/tokenUsage/updated', usage(threadId, this.inputTokens, this.contextWindow));
    setTimeout(() => this.notification('turn/completed', { threadId, turn: turn('completed') }), 2);
  }

  private startCompaction(threadId: string) {
    const turnId = `compact-${++this.turns}`;
    const turn = (status: string) => ({ id: turnId, items: [], status, error: null });
    const started = () => this.notification('turn/started', { threadId, turn: turn('inProgress') });
    const completed = (status = 'completed') => this.notification('turn/completed', { threadId, turn: turn(status) });
    const item = () => this.notification('item/completed', { threadId, turnId, item: { type: 'contextCompaction', id: 'cc-1' } });
    const marker = () => this.notification('thread/compacted', { threadId, turnId });
    const later = (fn: () => void) => void setTimeout(fn, 5);
    switch (this.compactMode) {
      case 'turn': later(() => { started(); later(() => completed()); }); break;
      case 'turn+marker': later(() => { started(); marker(); later(() => completed()); }); break;
      case 'item': later(item); break;
      case 'deprecated': later(marker); break;
      case 'failed-turn': later(() => { started(); later(() => completed('failed')); }); break;
      case 'reject': throw new Error('compaction is not supported');
      case 'silent': break;
      case 'hold': later(started); this.releaseCompaction = () => completed(); break;
    }
    return {};
  }
}

// ───────────── harness ─────────────

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function until(cond: () => boolean, what = 'condition') {
  for (let i = 0; i < 400; i++) { if (cond()) return; await sleep(5); }
  throw new Error(`timed out waiting for ${what}`);
}

const DEVICE = () => ({
  timezone: 'Asia/Shanghai', locale: 'zh-CN', now: Date.now(), deviceName: 'Test iPhone', network: 'wifi', battery: { level: 0.8, charging: false },
  upcomingEvents: [{ title: '周会', start: Date.now() + 3_600_000, end: Date.now() + 7_200_000 }],
  reminders: [{ title: '买牛奶', done: false }],
});

/** The label each status bar section starts its first line with. */
const LABELS: Record<(typeof STATUS_KEYS)[number], string> = {
  time: '现在：', presence: '主人在线：', phone: '手机自动化：', device: '主人手机上下文', calendar: '接下来的日程：', reminders: '未完成提醒：',
  tasks: '进行中的任务：', sessions: 'Codex sessions：', approvals: '待审批：', schedules: '闹钟：', imports: '未处理导入：', memory: '记忆（关于主人）：',
};
const NOTE = '只列出与上次相比有变化的部分；没列出的沿用之前的状态。';
/** Which sections a status bar text contains. */
const shown = (bar: string) => { const lines = bar.split('\n'); return STATUS_KEYS.filter((k) => lines.some((l) => l.startsWith(LABELS[k]))); };
/** The status bar inside a brain `turn/start`. */
const barOf = (turnStart: { params: any }): string => /<status_bar>\n([\s\S]*)\n<\/status_bar>/.exec(turnStart.params.input.at(-1).text)![1];

const cleanups: (() => void)[] = [];
beforeEach(() => {
  // The bot logs every compaction and failure; keep the test output readable.
  for (const m of ['log', 'warn', 'error'] as const) vi.spyOn(console, m).mockImplementation(() => {});
});
afterEach(() => {
  while (cleanups.length) cleanups.pop()!();
  vi.restoreAllMocks();
  delete process.env.OPA_BRAIN_COMPACT_TOKENS;
});

function makeBot(o: { db?: Db } = {}) {
  const rpc = new FakeCodex();
  const bridge = new CodexBridge(rpc as any);
  const db = o.db ?? new Db(':memory:');
  const ev = new EventLog(db);
  const gw = Object.assign(new EventEmitter(), { onlineDevices: ['d1'] as string[], push: () => 0 }) as any;
  const b = new Butler(db, ev, bridge, gw);
  const trace: string[] = [];
  rpc.trace = trace;
  ev.on('live', (e) => { if (e.k === 'butler.status') trace.push(`status:${e.d.state}`); });
  b.start();
  cleanups.push(() => b.stop());
  const priv = b as any;
  const settle = async () => { await sleep(30); await until(() => !priv.running && !priv.inbox.length, 'the bot to go idle'); };
  const say = async (text: string) => { b.userMessage(text, `c${rpc.count('turn/start') + 1}`); await settle(); };
  const turns = () => rpc.requests.filter((r) => r.method === 'turn/start');
  const bars = () => turns().map(barOf);
  const lastBar = () => bars().at(-1)!;
  /** A bot that has finished one quiet round and then hears from Codex that its context is `tokens` big. */
  const withContext = async (tokens: number) => {
    await say('hi');
    rpc.notification('thread/tokenUsage/updated', usage(b.brain.threadId!, tokens, 200_000));
    expect(b.brain.contextTokens).toBe(tokens);
  };
  const audits = () => (db.sql.prepare("SELECT detail FROM audit WHERE action = 'compact' ORDER BY id").all() as { detail: string }[]).map((r) => JSON.parse(r.detail));
  return { b, rpc, bridge, db, gw, trace, settle, say, turns, bars, lastBar, withContext, audits, priv };
}

// ───────────── the status bar ─────────────

describe('status bar: only what changed', () => {
  /** Fill every section of the status bar with something. */
  function fillEverything(t: ReturnType<typeof makeBot>) {
    t.db.set('device.context', DEVICE());
    t.b.memory.write('主人不吃香菜', 'preference');
    t.b.state.createTask('订餐', '订到晚饭', ['找店', '下单']);
    t.b.state.upsertSession({ id: 'sess-1', title: '查资料', status: 'idle' });
    const approval = t.b.state.requestApproval({ title: '付款', detail: '付 20 元', risk: 'high', kind: 'action', requireBiometric: true }).approval;
    cleanups.push(() => t.b.state.resolveApproval(approval.id, false)); // clears its 30 minute timer
    t.b.scheduler.add({ note: '看看快递', inMinutes: 60 });
    t.b.state.addImports([{ kind: 'text', title: '备忘', text: 'x' }]);
    return approval;
  }

  it('the first round gets every section; the next one only the time', async () => {
    const t = makeBot();
    fillEverything(t);
    await t.say('你好');
    const first = t.bars()[0];
    expect(shown(first)).toEqual([...STATUS_KEYS]);
    expect(first.split('\n')[0]).toContain(NOTE);
    expect(first.split('\n')[0]).toContain('完整状态栏');
    expect(first).toContain('主人不吃香菜');
    expect(first).toContain('订餐');

    await t.say('在吗');
    const second = t.bars()[1];
    expect(shown(second)).toEqual(['time']);
    expect(second.split('\n')[0]).toBe(NOTE);
  });

  it('a later round carries the time plus exactly the sections that changed', async () => {
    const t = makeBot();
    fillEverything(t);
    await t.say('你好');
    t.gw.onlineDevices = [];
    t.b.state.upsertSession({ id: 'sess-2', title: '写代码', status: 'idle' });
    await t.say('嗯');
    expect(shown(t.lastBar())).toEqual(['time', 'presence', 'sessions']);
    expect(t.lastBar()).toContain('未打开 App');
    expect(t.lastBar()).toContain('写代码');
    expect(t.lastBar()).toContain('查资料'); // a changed section is sent whole, not as a diff
    await t.say('好');
    expect(shown(t.lastBar())).toEqual(['time']);
  });

  it('a section that went empty is announced once as （无）', async () => {
    const t = makeBot();
    const approval = fillEverything(t);
    const task = t.b.state.tasks()[0];
    await t.say('你好');
    t.b.state.updateTask(task.id, { status: 'cancelled' });
    t.b.state.resolveApproval(approval.id, true); // the answer wakes the bot by itself
    await t.settle();
    expect(shown(t.lastBar())).toEqual(['time', 'tasks', 'approvals']);
    expect(t.lastBar()).toContain('进行中的任务：（无）');
    expect(t.lastBar()).toContain('待审批：（无）');
    await t.say('嗯');
    expect(shown(t.lastBar())).toEqual(['time']);
    // …and when something shows up again it is sent like any change
    t.b.state.createTask('新任务', '做点事', ['第一步']);
    await t.say('又来了');
    expect(shown(t.lastBar())).toEqual(['time', 'tasks']);
    expect(t.lastBar()).toContain('新任务');
  });

  it('nothing is said about a section that was always empty', async () => {
    const t = makeBot();
    await t.say('你好');
    expect(shown(t.bars()[0])).toEqual(['time', 'presence', 'phone', 'device', 'memory']);
    expect(t.bars()[0]).toContain('主人手机上下文：尚未上报');
    expect(t.bars()[0]).not.toContain('（无）');
  });

  it('a changed memory shows up as the memory section, and does not make the bot switch threads', async () => {
    const t = makeBot();
    t.b.memory.write('主人不吃香菜', 'preference');
    await t.say('你好');
    expect(t.bars()[0]).toContain('主人不吃香菜');
    t.b.memory.write('主人在望京上班', 'place');
    await t.say('我换工作了');
    expect(shown(t.lastBar())).toEqual(['time', 'memory']);
    expect(t.lastBar()).toContain('主人在望京上班');
    expect(t.lastBar()).toContain('主人不吃香菜');
    expect(t.rpc.count('thread/start')).toBe(1);
    expect(t.turns().every((r) => r.params.threadId === 'brain-1')).toBe(true);
    // the fixed instructions of the thread never held the memory
    const instructions = t.rpc.requests.find((r) => r.method === 'thread/start')!.params.baseInstructions as string;
    expect(instructions).not.toContain('主人不吃香菜');
  });

  it('the device report time alone does not make the context look new', async () => {
    const t = makeBot();
    t.db.set('device.context', DEVICE());
    await t.say('你好');
    expect(shown(t.lastBar())).toContain('device');
    t.db.set('device.context', { ...DEVICE(), now: Date.now() + 5 * 60_000 }); // a new report, same content
    await t.say('嗯');
    expect(shown(t.lastBar())).toEqual(['time']);
    t.db.set('device.context', { ...DEVICE(), now: Date.now() + 6 * 60_000, battery: { level: 0.2, charging: false } });
    await t.say('嗯');
    expect(shown(t.lastBar())).toEqual(['time', 'device']);
    expect(t.lastBar()).toContain('电量 20%');
  });

  it('a new brain thread is told everything again', async () => {
    const t = makeBot();
    fillEverything(t);
    await t.say('你好');
    await t.say('在吗');
    expect(shown(t.lastBar())).toEqual(['time']);
    t.db.set('settings', { butler: { persona: '换了一种说话方式' } }); // the fixed instructions change → a new thread
    await t.say('现在呢');
    expect(t.rpc.count('thread/start')).toBe(2);
    expect(t.rpc.requests.some((r) => r.method === 'thread/archive' && r.params.threadId === 'brain-1')).toBe(true);
    expect(t.turns().at(-1)!.params.threadId).toBe('brain-2');
    expect(shown(t.lastBar())).toEqual([...STATUS_KEYS]);
    await t.say('嗯');
    expect(shown(t.lastBar())).toEqual(['time']);
  });

  it('a Host restart starts with the full bar again, on the same thread', async () => {
    const first = makeBot();
    first.b.memory.write('主人不吃香菜', 'preference');
    await first.say('你好');
    await first.say('在吗');
    expect(shown(first.lastBar())).toEqual(['time']);

    const second = makeBot({ db: first.db }); // same database, new process: the brain thread is resumed
    await second.say('我回来了');
    expect(second.rpc.count('thread/start')).toBe(0);
    expect(second.rpc.count('thread/resume')).toBe(1);
    expect(second.turns()[0].params.threadId).toBe('brain-1');
    expect(shown(second.lastBar())).toEqual(['time', 'presence', 'phone', 'device', 'memory']);
  });

  it('a turn that never started does not use up the changes', async () => {
    const t = makeBot();
    t.rpc.failTurnStarts = 1;
    await t.say('你好');
    expect(t.turns()).toHaveLength(1); // the failed attempt
    await t.say('再试一次');
    expect(t.turns()).toHaveLength(2);
    expect(shown(t.lastBar())).toEqual(['time', 'presence', 'phone', 'device', 'memory']);
    expect(t.lastBar()).toContain('完整状态栏');
    await t.say('嗯');
    expect(shown(t.lastBar())).toEqual(['time']);
  });

  it('the full bar keeps working for callers that want everything (statusBar)', () => {
    const t = makeBot();
    t.db.set('device.context', DEVICE());
    t.b.memory.write('主人不吃香菜', 'preference');
    const bar = t.b.statusBar();
    expect(shown(bar)).toEqual(['time', 'presence', 'phone', 'device', 'calendar', 'reminders', 'memory']);
    expect(t.b.statusSections().map((s) => s.key)).toEqual([...STATUS_KEYS]);
  });
});

describe('instructions', () => {
  it('no longer hold the memory; they say where it is', () => {
    const p = buildInstructions(DEFAULT_SETTINGS, loadSkillIndex());
    expect(p).toContain(DEFAULT_SETTINGS.butler.name);
    expect(p).toContain('状态栏的「记忆」部分');
    expect(p).toContain('memory_search');
    expect(p).toContain('状态栏只给有变化的部分');
    expect(p).not.toContain('(id:'); // the memory summary's line format
    expect(p).not.toContain('暂无。随着相处慢慢了解主人');
  });
});

// ───────────── the Brain ─────────────

describe('Brain: context size, compaction, rotation', () => {
  async function makeBrain() {
    const rpc = new FakeCodex();
    const bridge = new CodexBridge(rpc as any);
    const db = new Db(':memory:');
    const brain = new Brain(bridge, db);
    const ensure = (instructions = 'fixed instructions') => brain.ensure({ instructions, tools: [], carryOver: async () => 'SUMMARY-OF-BEFORE' });
    await ensure();
    return { rpc, bridge, db, brain, ensure };
  }

  it('records the context size and window Codex reports for its own thread', async () => {
    const { rpc, brain, ensure } = await makeBrain();
    expect([brain.contextTokens, brain.contextWindow]).toEqual([0, null]);
    rpc.notification('thread/tokenUsage/updated', usage('brain-1', 12_345, 258_400));
    expect([brain.contextTokens, brain.contextWindow]).toEqual([12_345, 258_400]); // last.inputTokens, not the running total
    rpc.notification('thread/tokenUsage/updated', usage('some-worker', 99, 1_000));
    expect([brain.contextTokens, brain.contextWindow]).toEqual([12_345, 258_400]);
    rpc.notification('thread/tokenUsage/updated', usage('brain-1', 20_000, null));
    expect([brain.contextTokens, brain.contextWindow]).toEqual([20_000, null]);
    await ensure('different instructions'); // a new thread starts from an unknown size
    expect(brain.threadId).toBe('brain-2');
    expect(brain.contextTokens).toBe(0);
  });

  it.each<CompactMode>(['turn', 'turn+marker', 'item', 'deprecated'])('compact() finishes when Codex reports it as %s', async (mode) => {
    const { rpc, brain } = await makeBrain();
    rpc.compactMode = mode;
    rpc.notification('thread/tokenUsage/updated', usage('brain-1', 70_000, 258_400));
    expect(await brain.compact()).toBe(true);
    expect(rpc.requests.filter((r) => r.method === 'thread/compact/start').map((r) => r.params)).toEqual([{ threadId: 'brain-1' }]);
    expect(brain.contextTokens).toBe(0);
    expect(brain.busy).toBe(false);
  });

  it('compact() says the context was compacted even if the compaction turn then ends oddly', async () => {
    const { rpc, brain } = await makeBrain();
    const seen: string[] = [];
    brain.on('compacted', () => seen.push('compacted'));
    rpc.compactMode = 'turn+marker';
    expect(await brain.compact()).toBe(true);
    expect(seen).toEqual(['compacted']);
  });

  it.each<[CompactMode, string]>([
    ['failed-turn', 'the compaction turn fails'],
    ['reject', 'Codex refuses the request'],
    ['silent', 'nothing ever follows'],
  ])('compact() is false when %s', async (mode) => {
    const { rpc, brain } = await makeBrain();
    brain.compactTimeoutMs = 60;
    rpc.compactMode = mode;
    rpc.notification('thread/tokenUsage/updated', usage('brain-1', 70_000, 258_400));
    expect(await brain.compact()).toBe(false);
    expect(brain.contextTokens).toBe(70_000); // untouched: it was not compacted
    expect(brain.busy).toBe(false);
  });

  it('compact() asks for nothing without a thread, and throws when Codex cannot be reached', async () => {
    const { rpc, bridge, brain } = await makeBrain();
    const empty = new Brain(new CodexBridge(new FakeCodex() as any), new Db(':memory:'));
    expect(await empty.compact()).toBe(false);
    vi.spyOn(bridge, 'start').mockRejectedValueOnce(new Error('codex is down'));
    await expect(brain.compact()).rejects.toThrow('codex is down');
    expect(rpc.count('thread/compact/start')).toBe(0);
    expect(brain.threadId).toBe('brain-1');
  });

  it('a stop (or a late yield) during a compaction does not abort it', async () => {
    const { rpc, brain } = await makeBrain();
    rpc.compactMode = 'hold';
    const done = brain.compact();
    await until(() => brain.busy, 'the compaction turn to start');
    await brain.interrupt();
    expect(await brain.steer('hello')).toBe(false);
    expect(rpc.count('turn/interrupt')).toBe(0);
    expect(rpc.count('turn/steer')).toBe(0);
    rpc.releaseCompaction!();
    expect(await done).toBe(true);
  });

  it('a compaction that Codex starts on its own is noticed and resets the size', async () => {
    const { rpc, brain } = await makeBrain();
    const seen: string[] = [];
    brain.on('compacted', () => seen.push('compacted'));
    rpc.notification('thread/tokenUsage/updated', usage('brain-1', 200_000, 258_400));
    rpc.notification('item/completed', { threadId: 'brain-1', turnId: 't', item: { type: 'contextCompaction', id: 'cc' } });
    expect(seen).toEqual(['compacted']);
    expect(brain.contextTokens).toBe(0);
    rpc.notification('thread/compacted', { threadId: 'other-thread', turnId: 't' });
    expect(seen).toEqual(['compacted']); // someone else's thread
  });

  it('rotate(): the next ensure starts a fresh thread, archives the old one and carries a summary over', async () => {
    const { rpc, db, brain, ensure } = await makeBrain();
    rpc.notification('thread/tokenUsage/updated', usage('brain-1', 70_000, 258_400));
    brain.rotate();
    expect(brain.threadId).toBeUndefined();
    expect(brain.contextTokens).toBe(0);
    expect(db.get('brain.configKey')).toBe('');
    expect(await ensure()) .toBe('brain-2'); // the very same instructions as before: still a new thread
    expect(rpc.requests.some((r) => r.method === 'thread/archive' && r.params.threadId === 'brain-1')).toBe(true);
    expect(await brain.turn('hello')).toBe('completed');
    const input = rpc.requests.filter((r) => r.method === 'turn/start').at(-1)!.params.input;
    expect(input[0].text).toContain('<carry_over>');
    expect(input[0].text).toContain('SUMMARY-OF-BEFORE');
    expect(input.at(-1).text).toBe('hello');
    expect(db.get('brain.threadId')).toBe('brain-2');
  });

  it('rotate() survives a restart: the old thread is replaced, not resumed', async () => {
    const { db, brain } = await makeBrain();
    brain.rotate();
    const rpc2 = new FakeCodex();
    const reborn = new Brain(new CodexBridge(rpc2 as any), db);
    await reborn.ensure({ instructions: 'fixed instructions', tools: [], carryOver: async () => undefined });
    expect(rpc2.count('thread/start')).toBe(1);
    expect(rpc2.count('thread/resume')).toBe(0);
    expect(rpc2.requests.some((r) => r.method === 'thread/archive' && r.params.threadId === 'brain-1')).toBe(true);
  });

  it('a turn that never started keeps the carry-over for the next one', async () => {
    const { rpc, brain, ensure } = await makeBrain();
    brain.rotate();
    await ensure();
    rpc.failTurnStarts = 1;
    await expect(brain.turn('first try')).rejects.toThrow('unavailable');
    await brain.turn('second try');
    const input = rpc.requests.filter((r) => r.method === 'turn/start').at(-1)!.params.input;
    expect(input[0].text).toContain('SUMMARY-OF-BEFORE');
  });
});

// ───────────── compaction, driven by the bot ─────────────

describe('compaction by the bot', () => {
  beforeEach(() => { process.env.OPA_BRAIN_COMPACT_TOKENS = '5000'; });

  it('an idle bot whose context reached the threshold compacts its thread, quietly', async () => {
    const t = makeBot();
    t.rpc.inputTokens = 8_000;
    t.b.memory.write('主人不吃香菜', 'preference');
    await t.say('你好');
    expect(t.rpc.requests.filter((r) => r.method === 'thread/compact/start').map((r) => r.params)).toEqual([{ threadId: 'brain-1' }]);
    // the turn came first, and the app was never told the bot was thinking while it tidied up
    const trace = t.trace;
    const at = trace.indexOf('rpc:thread/compact/start');
    expect(trace.indexOf('rpc:turn/start')).toBeLessThan(at);
    expect(trace.slice(0, at)).toContain('status:thinking');
    expect(trace.slice(at)).not.toContain('status:thinking');
    expect(trace.at(-1)).toBe('status:idle');
    expect(t.audits()).toEqual([{ before: 8_000, window: 200_000, ok: true }]);
    expect(t.b.brain.contextTokens).toBe(0);
    expect(t.rpc.count('thread/start')).toBe(1); // compacted, not replaced

    // the compacted thread has lost the old status bars: the next one is complete again
    t.rpc.inputTokens = 1_000;
    await t.say('在吗');
    expect(shown(t.lastBar())).toEqual(['time', 'presence', 'phone', 'device', 'memory']);
    expect(t.turns().at(-1)!.params.threadId).toBe('brain-1');
    expect(t.rpc.count('thread/compact/start')).toBe(1);
  });

  it('leaves the thread alone while the context is below the threshold', async () => {
    const t = makeBot();
    t.rpc.inputTokens = 4_999;
    await t.say('你好');
    expect(t.rpc.count('thread/compact/start')).toBe(0);
    expect(t.audits()).toEqual([]);
    expect(t.b.brain.contextTokens).toBe(4_999);
  });

  it('the threshold: 60000 by default, OPA_BRAIN_COMPACT_TOKENS, and at most 60% of the context window', () => {
    const t = makeBot();
    const brain = t.b.brain;
    delete process.env.OPA_BRAIN_COMPACT_TOKENS;
    expect(t.b.compactThreshold()).toBe(60_000);
    for (const bad of ['', 'abc', '0', '-5']) { process.env.OPA_BRAIN_COMPACT_TOKENS = bad; expect(t.b.compactThreshold()).toBe(60_000); }
    process.env.OPA_BRAIN_COMPACT_TOKENS = '20000';
    expect(t.b.compactThreshold()).toBe(20_000);
    // once Codex has reported the window it caps the threshold (the brain only listens to its own thread)
    brain.threadId = 'brain-1';
    t.rpc.notification('thread/tokenUsage/updated', usage('brain-1', 1, 100_000));
    expect(t.b.compactThreshold()).toBe(20_000);
    process.env.OPA_BRAIN_COMPACT_TOKENS = '90000';
    expect(t.b.compactThreshold()).toBe(60_000);
    delete process.env.OPA_BRAIN_COMPACT_TOKENS;
    t.rpc.notification('thread/tokenUsage/updated', usage('brain-1', 1, 50_000));
    expect(t.b.compactThreshold()).toBe(30_000);
    t.rpc.notification('thread/tokenUsage/updated', usage('brain-1', 1, null));
    expect(t.b.compactThreshold()).toBe(60_000);
  });

  describe('not while something is going on', () => {
    // Each case starts something and returns how to end it again.
    const cases: [string, (t: ReturnType<typeof makeBot>) => () => void | Promise<void>][] = [
      ['a task is running', (t) => { const task = t.b.state.createTask('订餐', '订到晚饭', ['找店']); return () => { t.b.state.updateTask(task.id, { status: 'done' }); }; }],
      ['a task is being planned', (t) => { const task = t.b.state.createTask('想想', '先想想'); expect(task.status).toBe('planning'); return () => { t.b.state.updateTask(task.id, { status: 'cancelled' }); }; }],
      ['a worker session is running', (t) => {
        t.bridge.sessions.set('w1', { threadId: 'w1', title: '干活', permission: 'manual', status: 'running', turns: 1 } as any);
        return () => { t.bridge.sessions.delete('w1'); };
      }],
      ['a worker session is waiting for an approval', (t) => {
        t.bridge.sessions.set('w1', { threadId: 'w1', title: '干活', permission: 'manual', status: 'waiting_approval', turns: 1 } as any);
        return () => { t.bridge.sessions.delete('w1'); };
      }],
      ['a stored session says it is running', (t) => { t.b.state.upsertSession({ id: 'w2', title: '干活', status: 'running' }); return () => { t.b.state.upsertSession({ id: 'w2', status: 'idle' }); }; }],
      ['a stored session is waiting for an approval', (t) => { t.b.state.upsertSession({ id: 'w3', title: '干活', status: 'waiting_approval' }); return () => { t.b.state.upsertSession({ id: 'w3', status: 'idle' }); }; }],
      ['an approval is pending', (t) => {
        const { approval } = t.b.state.requestApproval({ title: '付款', detail: '付 20 元', risk: 'high', kind: 'action', requireBiometric: true });
        return () => { t.b.state.resolveApproval(approval.id, false); };
      }],
      ['events are waiting', (t) => { t.priv.inbox.push({ type: 'heartbeat', body: 'x', ts: Date.now() }); return () => { t.priv.inbox.splice(0); }; }],
      ['a phone task is starting', (t) => {
        vi.spyOn(t.bridge, 'createSession').mockImplementation(((o: any) => new Promise((_resolve, reject) => {
          o.signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')), { once: true });
        })) as any);
        const starting = TOOL_MAP.get('phone_task')!.run({ title: '查物流', goal: '只查询，不要下单/付款' }, t.b);
        expect(isPhoneTaskStarting(t.bridge)).toBe(true);
        return async () => { cancelPendingPhoneTask(t.bridge); await starting; expect(isPhoneTaskStarting(t.bridge)).toBe(false); };
      }],
    ];

    it.each(cases)('%s', async (_name, start) => {
      const t = makeBot();
      await t.withContext(9_000);
      const end = start(t);
      expect(await t.b.maybeCompact()).toBe(false);
      expect(t.rpc.count('thread/compact/start')).toBe(0);
      expect(t.b.brain.contextTokens).toBe(9_000);
      await end();
      expect(await t.b.maybeCompact()).toBe(true); // nothing else was in the way
      expect(t.rpc.count('thread/compact/start')).toBe(1);
    });

    it('work that is not in progress does not count', async () => {
      const t = makeBot();
      await t.withContext(9_000);
      const waiting = t.b.state.createTask('等主人', '等回复', ['问一句']);
      t.b.state.updateTask(waiting.id, { status: 'waiting_user' });
      const done = t.b.state.createTask('做完了', '好了', ['一步']);
      t.b.state.updateTask(done.id, { status: 'done' });
      t.b.state.upsertSession({ id: 's-idle', title: '空闲', status: 'idle' });
      t.b.state.upsertSession({ id: 's-err', title: '出错', status: 'error' });
      t.bridge.sessions.set('s-live', { threadId: 's-live', title: '空闲', permission: 'manual', status: 'idle', turns: 1 } as any);
      expect(await t.b.maybeCompact()).toBe(true);
    });

    it('not twice within five minutes', async () => {
      const t = makeBot();
      await t.withContext(9_000);
      expect(await t.b.maybeCompact()).toBe(true);
      t.rpc.notification('thread/tokenUsage/updated', usage('brain-1', 9_000, 200_000));
      expect(await t.b.maybeCompact()).toBe(false);
      expect(t.rpc.count('thread/compact/start')).toBe(1);
      const soon = Date.now() + 4 * 60_000;
      vi.spyOn(Date, 'now').mockReturnValue(soon);
      expect(await t.b.maybeCompact()).toBe(false);
      vi.spyOn(Date, 'now').mockReturnValue(Date.now() + 6 * 60_000);
      expect(await t.b.maybeCompact()).toBe(true);
      expect(t.rpc.count('thread/compact/start')).toBe(2);
      expect(t.audits().map((a) => a.ok)).toEqual([true, true]);
    });

    it('not in the middle of a turn', async () => {
      const t = makeBot();
      await t.withContext(9_000);
      t.rpc.notification('turn/started', { threadId: 'brain-1', turn: { id: 'turn-live', items: [], status: 'inProgress' } });
      expect(t.b.brain.busy).toBe(true);
      expect(await t.b.maybeCompact()).toBe(false);
    });

    it('not when the size is unknown', async () => {
      const t = makeBot();
      await t.say('hi');
      t.rpc.notification('thread/tokenUsage/updated', usage('brain-1', 0, 200_000));
      expect(await t.b.maybeCompact()).toBe(false);
    });
  });

  describe('while it compacts', () => {
    it('a user message queues instead of steering, and is answered once the compaction is done', async () => {
      const t = makeBot();
      t.rpc.compactMode = 'hold';
      t.rpc.inputTokens = 8_000;
      t.b.userMessage('你好', 'c1');
      await until(() => t.b.brain.busy && t.rpc.count('thread/compact/start') === 1, 'the compaction to start');
      expect(t.priv.compacting).toBe(true);
      expect(t.priv.running).toBe(true);

      t.rpc.inputTokens = 1_000;
      const steer = vi.spyOn(t.b.brain, 'steer');
      t.b.userMessage('在吗', 'c2');
      await sleep(40);
      expect(steer).not.toHaveBeenCalled(); // the brain looks busy, but a compaction takes no input
      expect(t.rpc.count('turn/steer')).toBe(0);
      expect(t.priv.inbox).toHaveLength(1);
      expect(t.rpc.count('turn/start')).toBe(1);

      t.rpc.releaseCompaction!();
      await t.settle();
      expect(t.rpc.count('turn/steer')).toBe(0);
      expect(t.priv.compacting).toBe(false);
      expect(t.turns()).toHaveLength(2);
      expect(t.turns()[1].params.input.at(-1).text).toContain('在吗');
      expect(t.turns()[1].params.threadId).toBe('brain-1'); // the same, compacted thread
      expect(shown(t.lastBar())).toEqual(['time', 'presence', 'phone', 'device', 'memory']); // and told everything again
      const methods = t.rpc.requests.map((r) => r.method);
      expect(methods.indexOf('thread/compact/start')).toBeLessThan(methods.lastIndexOf('turn/start'));
    });

    it('stopping the bot does not abort the compaction', async () => {
      const t = makeBot();
      t.rpc.compactMode = 'hold';
      t.rpc.inputTokens = 8_000;
      t.b.userMessage('你好', 'c1');
      await until(() => t.b.brain.busy && t.rpc.count('thread/compact/start') === 1, 'the compaction to start');
      t.b.interrupt();
      await sleep(20);
      expect(t.rpc.count('turn/interrupt')).toBe(0);
      t.rpc.releaseCompaction!();
      await t.settle();
      expect(t.audits()).toEqual([{ before: 8_000, window: 200_000, ok: true }]);
    });

    it('a compaction Codex starts on its own makes the next bar complete again', async () => {
      const t = makeBot();
      t.b.memory.write('主人不吃香菜', 'preference');
      await t.say('你好');
      await t.say('在吗');
      expect(shown(t.lastBar())).toEqual(['time']);
      t.rpc.notification('thread/compacted', { threadId: 'brain-1', turnId: 'auto' });
      await t.say('嗯');
      expect(shown(t.lastBar())).toEqual(['time', 'presence', 'phone', 'device', 'memory']);
    });
  });

  describe('when the compaction fails', () => {
    it.each<[CompactMode, string]>([
      ['reject', 'Codex refuses it'],
      ['failed-turn', 'the compaction turn fails'],
      ['silent', 'it times out'],
    ])('the bot moves to a fresh thread (%s: %s)', async (mode) => {
      const t = makeBot();
      t.rpc.compactMode = mode;
      t.b.brain.compactTimeoutMs = 60;
      t.rpc.inputTokens = 8_000;
      t.b.memory.write('主人不吃香菜', 'preference');
      await t.say('你好');
      expect(t.rpc.count('thread/compact/start')).toBe(1);
      expect(t.audits()).toEqual([{ before: 8_000, window: 200_000, ok: false }]);
      expect(t.b.brain.threadId).toBeUndefined(); // given up on; the next round makes a new one
      expect(t.db.get('brain.configKey')).toBe('');
      expect(t.rpc.count('thread/start')).toBe(1);

      t.rpc.inputTokens = 1_000;
      await t.say('在吗');
      expect(t.rpc.count('thread/start')).toBe(2);
      expect(t.rpc.requests.some((r) => r.method === 'thread/archive' && r.params.threadId === 'brain-1')).toBe(true);
      const second = t.turns().at(-1)!;
      expect(second.params.threadId).toBe('brain-2');
      expect(second.params.input[0].text).toContain('<carry_over>'); // what the old thread knew, in short
      expect(second.params.input[0].text).toContain('[user_message] 你好');
      expect(second.params.input.at(-1).text).toContain('在吗');
      expect(shown(barOf(second))).toEqual(['time', 'presence', 'phone', 'device', 'memory']);
      expect(barOf(second)).toContain('主人不吃香菜');
      expect(t.rpc.count('thread/compact/start')).toBe(1); // and not tried again right away
    });

    it('if Codex cannot even be asked, the thread is left as it is and the next chance tries again', async () => {
      const t = makeBot();
      await t.withContext(9_000);
      vi.spyOn(t.bridge, 'start').mockRejectedValueOnce(new Error('codex is down'));
      expect(await t.b.maybeCompact()).toBe(false);
      expect(t.priv.compacting).toBe(false);
      expect(t.priv.running).toBe(false);
      expect(t.b.brain.threadId).toBe('brain-1');
      expect(t.audits()).toEqual([]);
      expect(await t.b.maybeCompact()).toBe(true);
      expect(t.audits()).toEqual([{ before: 9_000, window: 200_000, ok: true }]);
    });
  });
});
