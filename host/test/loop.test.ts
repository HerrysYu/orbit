// Bot loop against a scripted fake `codex app-server` (test/fake-codex.mjs).
// Verifies: brain thread with dynamic tools, streaming → msg events, tool round-trips, yield, steering, GenUI validation.
import { describe, expect, it } from 'vitest';
import { EventEmitter } from 'node:events';
import { readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { Db } from '../src/store/db.ts';
import { EventLog } from '../src/store/events.ts';
import { Butler } from '../src/butler/butler.ts';
import { CodexBridge } from '../src/codex/bridge.ts';
import { CodexRpc } from '../src/codex/rpc.ts';

// These tests cover the old way of running a phone task (a Codex worker thread), not the step-driven runner.
process.env.OPA_PHONE_MODE = 'codex';

const FAKE = join(import.meta.dirname, 'fake-codex.mjs');
let runN = 0;

function makeBot(script: object[]) {
  const logPath = `/tmp/opa-fake-codex-${process.pid}-${++runN}.log`;
  rmSync(logPath, { force: true });
  process.env.FAKE_CODEX_SCRIPT = JSON.stringify(script);
  process.env.FAKE_CODEX_LOG = logPath;
  const bridge = new CodexBridge(new CodexRpc(process.execPath, [FAKE]));
  const db = new Db(':memory:');
  const ev = new EventLog(db);
  const gw = Object.assign(new EventEmitter(), { onlineDevices: ['d1'], push: () => 0 }) as any;
  const b = new Butler(db, ev, bridge, gw);
  const evs: any[] = [];
  ev.on('ev', (e) => evs.push(e));
  ev.on('live', (e) => evs.push(e));
  b.start();
  const calls = () => readFileSync(logPath, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  return { b, evs, calls, stop: () => { b.scheduler.stop(); bridge.rpc.stop(); } };
}

const idle = (b: any) => new Promise<void>((r) => { const t = setInterval(() => { if (!b.running && !b.inbox.length) { clearInterval(t); r(); } }, 20); });
const settle = async (b: any) => { await new Promise((r) => setTimeout(r, 100)); await idle(b); };
/** Resolves once the brain is inside a turn (a message sent now can be steered into it). */
const inTurn = (b: any) => new Promise<void>((r) => { const t = setInterval(() => { if (b.brain.busy) { clearInterval(t); r(); } }, 5); });

describe('bot loop (brain on Codex)', () => {
  it('streams text, runs a dynamic tool, yields', async () => {
    const { b, evs, calls, stop } = makeBot([
      { steps: [{ say: '好的，我记下了。' }, { tool: 'memory_write', args: { text: '主人不吃香菜', kind: 'preference', source: 'explicit' } }, { tool: 'yield' }, { wait: 300 }, { say: '不该出现' }] },
    ]);
    b.userMessage('记住我不吃香菜', 'c1');
    await settle(b);
    const start = calls().find((c) => c.method === 'thread/start');
    expect(start.params.baseInstructions).toContain('Orbit');
    expect(start.params.dynamicTools.map((t: any) => t.name)).toContain('codex_session_create');
    expect(start.params.config.features.shell_tool).toBe(false);
    const turn = calls().find((c) => c.method === 'turn/start');
    expect(turn.params.input.at(-1).text).toContain('<status_bar>');
    expect(evs.some((e) => e.k === 'msg.delta')).toBe(true);
    expect(evs.find((e) => e.k === 'msg.assistant').d.text).toBe('好的，我记下了。');
    expect(evs.find((e) => e.k === 'ui.render').d.card.component).toBe('memory_saved');
    expect(b.memory.list()[0].text).toBe('主人不吃香菜');
    expect(calls().some((c) => c.method === 'turn/interrupt')).toBe(true); // yield ends the turn
    expect(evs.filter((e) => e.k === 'msg.assistant').some((e) => e.d.text.includes('不该出现') || e.d.interrupted)).toBe(false);
    stop();
  });

  it('a user message during a turn is steered into it', async () => {
    const { b, calls, stop } = makeBot([
      { steps: [{ say: '这是一段很长很长很长很长的回答', slow: 30 }, { tool: 'yield' }] },
    ]);
    b.userMessage('讲个故事', 'c1');
    await inTurn(b); // not a fixed delay: on a busy machine the fake codex needs longer than that to start the turn
    await new Promise((r) => setTimeout(r, 30));
    b.userMessage('换个话题', 'c2');
    await settle(b);
    const steer = calls().find((c) => c.method === 'turn/steer');
    expect(steer.params.input[0].text).toContain('换个话题');
    stop();
  });

  it('invalid GenUI props are returned to the brain as an error', async () => {
    const { b, calls, stop } = makeBot([
      { steps: [{ tool: 'ui_render', args: { component: 'order_card', props: { merchant: 'x' } } }, { tool: 'yield' }] },
    ]);
    b.push({ type: 'heartbeat', body: 'test' });
    await settle(b);
    const r = calls().find((c) => c.tool === 'ui_render');
    expect(r.result.contentItems[0].text).toContain('不合法');
    stop();
  });

  it('the brain thread is reused across rounds', async () => {
    const { b, calls, stop } = makeBot([
      { steps: [{ say: '一' }, { tool: 'yield' }] },
      { steps: [{ say: '二' }, { tool: 'yield' }] },
    ]);
    b.userMessage('a', 'c1');
    await settle(b);
    b.userMessage('b', 'c2');
    await settle(b);
    expect(calls().filter((c) => c.method === 'thread/start').length).toBe(1);
    expect(calls().filter((c) => c.method === 'turn/start').length).toBe(2);
    stop();
  });

  it.each([
    { configuredModel: 'gpt-configured', expectedModel: 'gpt-configured', label: 'settings model' },
    { configuredModel: '', expectedModel: 'gpt-x', label: 'Codex default model' },
  ])('isolates phone tools and shares the $label selection', async ({ configuredModel, expectedModel }) => {
    const previousCmd = process.env.OPA_PHONE_CMD;
    process.env.OPA_PHONE_CMD = process.execPath;
    const { b, calls, stop } = makeBot([
      { steps: [
        { tool: 'phone_task', args: { title: '查门店', goal: '只查询附近门店，不要下单/付款', china: true } },
        { tool: 'codex_session_create', args: { title: '普通查询', prompt: '查询同一服务的网页资料' } },
        { tool: 'yield' },
      ] },
    ]);
    b.db.set('settings', { models: { codexDefault: configuredModel } });
    try {
      b.userMessage('查附近门店', 'phone-model-test');
      await settle(b);
      const starts = calls().filter((c) => c.method === 'thread/start');
      const brain = starts.find((c) => c.params.dynamicTools);
      const phone = starts.find((c) => c.params.config?.mcp_servers?.orbit_phone);
      const regular = starts.find((c) => !c.params.dynamicTools && !c.params.config?.mcp_servers?.orbit_phone);
      expect(brain).toBeDefined();
      expect(brain.params.config.mcp_servers?.orbit_phone).toBeUndefined();
      expect(phone).toBeDefined();
      expect(phone.params.config.features.computer_use).toBe(false);
      expect(phone.params.model).toBe(expectedModel);
      expect(regular.params.model).toBe(expectedModel);
      const phoneTurn = calls().find((c) => c.method === 'turn/start' && c.params.input.some((item: any) => item.type === 'text' && item.text.includes('必须使用本 session 专属的 orbit_phone')));
      const phoneInput = phoneTurn.params.input;
      expect(phoneInput.filter((item: any) => item.type === 'skill').map((item: any) => item.name)).toEqual(['phone-automation', 'china-services']);
      expect(phoneInput.find((item: any) => item.type === 'text').text).toContain('只查询，不要下单/付款');
    } finally {
      stop();
      if (previousCmd === undefined) delete process.env.OPA_PHONE_CMD;
      else process.env.OPA_PHONE_CMD = previousCmd;
    }
  });
});
