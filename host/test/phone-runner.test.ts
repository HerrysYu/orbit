// The step-driven phone runner against a fake bridge: no real Codex, no adb.
import { EventEmitter } from 'node:events';
import { afterEach, describe, expect, it } from 'vitest';
import { CodexBridge, type StepTurnOpts, type StepTurnResult } from '../src/codex/bridge.ts';
import { PhoneRunner } from '../src/phone/runner.ts';
import { STEP_OUTPUT_SCHEMA } from '../src/phone/step-prompt.ts';

/** A model answer shaped like STEP_OUTPUT_SCHEMA. */
const act = (action: string, f: Record<string, unknown> = {}) => JSON.stringify({
  action, x: null, y: null, x2: null, y2: null, ms: null, seconds: null, text: null, app: null, note: '', result: null, ...f,
});

type Scripted = string | ((o: StepTurnOpts) => Promise<StepTurnResult>);

class FakeBridge extends EventEmitter {
  readonly inputs: any[][] = [];
  readonly calls: { tool: string; args: any }[] = [];
  readonly emitted: { event: string; payload: any }[] = [];
  readonly closed: string[] = [];
  readonly stepStarted: Promise<void>;
  private markStarted!: () => void;
  private shots = 0;

  constructor(private script: Scripted[]) {
    super();
    this.stepStarted = new Promise((resolve) => { this.markStarted = resolve; });
  }

  emit(event: string | symbol, ...args: any[]): boolean {
    this.emitted.push({ event: String(event), payload: args[0] });
    return super.emit(event, ...args);
  }

  async openPhoneExecutor() { return 'exec-1'; }
  closePhoneExecutor(id: string) { this.closed.push(id); }

  async stepTurn(o: StepTurnOpts): Promise<StepTurnResult> {
    this.inputs.push(o.input as any[]);
    this.markStarted();
    const next = this.script.shift();
    if (typeof next === 'function') return next(o);
    return {
      status: 'completed', text: next ?? '', model: 'gpt-test',
      usage: { totalTokens: 1100, inputTokens: 1000, cachedInputTokens: 800, cacheWriteInputTokens: 0, outputTokens: 100, reasoningOutputTokens: 0 },
    };
  }

  async phoneTool(_threadId: string, tool: string, args: Record<string, unknown> = {}) {
    this.calls.push({ tool, args });
    if (tool === 'phone_end') return { content: [{ type: 'text', text: JSON.stringify({ status: 'ended', evidence: '/evidence/final.jpg', summary: args.summary }) }] };
    if (tool === 'phone_cancel') return { content: [{ type: 'text', text: JSON.stringify({ status: 'cancel_requested' }) }] };
    const i = this.shots++;
    return {
      content: [
        { type: 'image', data: `SHOT_${i}`, mimeType: 'image/jpeg' },
        { type: 'text', text: JSON.stringify({
          status: tool === 'phone_begin' ? 'started' : 'ok', foreground: { package: 'com.demo', activity: 'Main' },
          screen: { width: 1080, height: 2400 }, ui_tree: [{ text: `tree-${i}`, center: { x: 500, y: 200 } }],
        }) },
      ],
    };
  }

  tools() { return this.calls.map((c) => c.tool); }
  imagesOf(input: any[]) { return input.filter((x) => x.type === 'image'); }
  delivered() {
    const e = this.emitted.filter((x) => x.event === 'turn_completed');
    expect(e).toHaveLength(1);
    const text: string = e[0].payload.text;
    const body = /^```json\n([\s\S]*)\n```$/.exec(text);
    expect(body).not.toBeNull();
    return { ...e[0].payload, json: JSON.parse(body![1]) };
  }
}

function setup(script: Scripted[]) {
  const bridge = new FakeBridge(script);
  const synced: { id: string; patch: any }[] = [];
  const audits: { actor: string; action: string; detail: any }[] = [];
  let t = 1_000;
  const runner = new PhoneRunner({
    bridge,
    resolve: () => ({ model: 'gpt-test', effort: 'medium' }),
    syncSession: (id, patch) => { synced.push({ id, patch }); },
    audit: (actor, action, detail) => { audits.push({ actor, action, detail }); },
    now: () => (t += 10),
    maxSteps: 10,
  });
  return { bridge, runner, synced, audits };
}

describe('PhoneRunner', () => {
  it('sends one image per step — the newest — with earlier steps only as notes, then delivers done', async () => {
    const { bridge, runner, synced, audits } = setup([
      act('launch', { app: '美团', note: 'N1 打开美团，首页有搜索框' }),
      act('tap', { x: 500, y: 120, note: 'N2 点开搜索框，键盘弹出' }),
      act('done', { note: 'N3 看到瑞幸 12.9 元', result: '{"price":12.9}' }),
    ]);
    const { id } = runner.start({ title: '查瑞幸价格', goal: '查瑞幸美式的价格，只查询', china: true, taskId: 't_1' });
    expect(id).toMatch(/^phone_/);
    await runner.finished(id);

    // Every model call: exactly one image, and it is the newest screenshot.
    expect(bridge.inputs).toHaveLength(3);
    bridge.inputs.forEach((input, i) => {
      const images = bridge.imagesOf(input);
      expect(images).toHaveLength(1);
      expect(images[0].url).toBe(`data:image/jpeg;base64,SHOT_${i}`);
      const all = JSON.stringify(input);
      for (let old = 0; old < i; old++) {
        expect(all).not.toContain(`SHOT_${old}`);
        expect(all).not.toContain(`tree-${old}`); // old trees are not re-sent either
      }
      expect(all).toContain(`tree-${i}`); // the current UI tree, as the tool returned it
    });
    // History = the notes of earlier steps, in order.
    const text = (i: number) => bridge.inputs[i].filter((x) => x.type === 'text').map((x) => x.text).join('\n');
    expect(text(0)).not.toContain('N1');
    expect(text(1)).toContain('N1 打开美团');
    expect(text(2)).toContain('N1 打开美团');
    expect(text(2)).toContain('N2 点开搜索框');
    expect(text(2)).toContain('第 3 / 10 步');
    expect(text(2).indexOf('N1')).toBeLessThan(text(2).indexOf('N2'));

    // Tools are called with the server.py signature plus include_tree.
    expect(bridge.tools()).toEqual(['phone_begin', 'phone_launch', 'phone_tap', 'phone_end']);
    expect(bridge.calls[1].args).toEqual({ app: '美团', include_tree: true });
    expect(bridge.calls[2].args).toEqual({ x: 500, y: 120, include_tree: true });
    expect(bridge.closed).toEqual(['exec-1']);

    // Each action is audited with redacted params.
    const steps = audits.filter((a) => a.action === 'step');
    expect(steps.map((s) => s.detail.tool)).toEqual(['phone_launch', 'phone_tap']);
    expect(JSON.stringify(steps[0].detail.params)).not.toContain('美团');
    expect(steps[0].detail.run).toBe(id);

    // Delivery.
    const d = bridge.delivered();
    expect(d.threadId).toBe(id);
    expect(d.status).toBe('completed');
    expect(d.json).toMatchObject({ status: 'done', result: { price: 12.9 }, evidence: '/evidence/final.jpg', steps: 3, model: 'gpt-test' });
    expect(bridge.emitted.filter((e) => e.event === 'activity').map((e) => e.payload.text)).toEqual([
      'N1 打开美团，首页有搜索框', 'N2 点开搜索框，键盘弹出', 'N3 看到瑞幸 12.9 元',
    ]);
    expect(synced[0].patch).toMatchObject({ title: '📱 查瑞幸价格', status: 'running', permission: 'manual', taskId: 't_1', model: 'gpt-test' });
    expect(synced[synced.length - 1].patch.status).toBe('idle');
    const info = runner.status(id)!;
    expect(info).toMatchObject({ status: 'done', steps: 3 });
    expect(info.notes).toHaveLength(2);
    expect(info.usage.inputTokens).toBe(3000);
    expect(runner.history(id).map((h) => h.kind)).toEqual(['userMessage', 'mcpToolCall', 'mcpToolCall', 'mcpToolCall', 'agentMessage']);
  });

  it('hands a login wall back as needs_human, still ending the phone task', async () => {
    const { bridge, runner, synced } = setup([
      act('needs_human', { note: 'N1 美团弹出登录页，需要验证码', result: '请在手机上登录美团账号' }),
    ]);
    const { id } = runner.start({ title: '点咖啡', goal: '登录后查看订单', china: true });
    await runner.finished(id);

    expect(bridge.tools()).toEqual(['phone_begin', 'phone_end']);
    const d = bridge.delivered();
    expect(d.status).toBe('completed');
    expect(d.json).toMatchObject({ status: 'needs_human', needs: '请在手机上登录美团账号', evidence: '/evidence/final.jpg', steps: 1 });
    expect(synced[synced.length - 1].patch.status).toBe('idle');
    expect(runner.status(id)!.status).toBe('needs_human');
  });

  it('cancel interrupts the model wait, cancels the phone first, then ends it', async () => {
    const waits: Scripted[] = [(o) => new Promise((resolve) => {
      o.signal!.addEventListener('abort', () => resolve({ status: 'interrupted', text: '' }), { once: true });
    })];
    const { bridge, runner, synced } = setup(waits);
    const { id } = runner.start({ title: '慢任务', goal: '随便看看', china: false });
    await bridge.stepStarted;
    expect(runner.cancel(id)).toBe(true);
    await runner.finished(id);

    const tools = bridge.tools();
    expect(tools[0]).toBe('phone_begin');
    expect(tools.indexOf('phone_cancel')).toBeGreaterThan(0);
    expect(tools.indexOf('phone_cancel')).toBeLessThan(tools.indexOf('phone_end'));
    expect(bridge.calls.find((c) => c.tool === 'phone_cancel')!.args).toEqual({ only_owned: true });
    expect(bridge.inputs).toHaveLength(1); // no second model call after the cancel
    const d = bridge.delivered();
    expect(d.status).toBe('interrupted');
    expect(d.json.status).toBe('cancelled');
    expect(synced[synced.length - 1].patch.status).toBe('idle');
    expect(runner.status(id)!.status).toBe('cancelled');
    expect(runner.cancel(id)).toBe(false); // already over
  });
});

// ───────────── the bridge half: one throwaway thread per model call ─────────────

class FakeRpc extends EventEmitter {
  readonly requests: { method: string; params: any; timeoutMs?: number }[] = [];
  start() {}
  stop() {}
  notify() {}
  respond() {}
  respondError() {}
  async request(method: string, params: any = {}, timeoutMs?: number): Promise<any> {
    this.requests.push({ method, params, timeoutMs });
    switch (method) {
      case 'model/list': return { data: [{ id: 'default-model', isDefault: true, hidden: false }] };
      case 'config/read': return { config: { mcp_servers: { csqaq: { command: 'x' }, node_repl: { command: 'y' } } } };
      case 'thread/start': return { thread: { id: `th-${this.requests.filter((r) => r.method === 'thread/start').length}` }, model: params.model ?? 'resolved' };
      case 'turn/start':
        queueMicrotask(() => {
          const threadId = params.threadId;
          this.emit('notification', 'turn/started', { threadId, turn: { id: 't1' } });
          this.emit('notification', 'item/completed', { threadId, turnId: 't1', item: { type: 'agentMessage', text: '{"action":"back"}', phase: 'final_answer' } });
          this.emit('notification', 'thread/tokenUsage/updated', { threadId, turnId: 't1', tokenUsage: { last: { inputTokens: 1000, cachedInputTokens: 800, outputTokens: 50 }, total: {} } });
          this.emit('notification', 'turn/completed', { threadId, turn: { id: 't1', status: 'completed', items: [], error: null } });
        });
        return { turn: { id: 't1' } };
      default: return {};
    }
  }
}

const savedCmd = process.env.OPA_PHONE_CMD;
afterEach(() => {
  if (savedCmd === undefined) delete process.env.OPA_PHONE_CMD;
  else process.env.OPA_PHONE_CMD = savedCmd;
});

describe('CodexBridge phone steps', () => {
  it('stepTurn runs one tool-less ephemeral thread and collects text, usage and status', async () => {
    const rpc = new FakeRpc();
    const bridge = new CodexBridge(rpc as any);
    const baseline = rpc.listenerCount('notification');
    const input = [{ type: 'text' as const, text: 'hi', text_elements: [] }];
    const r = await bridge.stepTurn({ baseInstructions: 'SYSTEM', input, outputSchema: STEP_OUTPUT_SCHEMA, effort: 'medium' });

    expect(r).toMatchObject({ status: 'completed', text: '{"action":"back"}', usage: { inputTokens: 1000, cachedInputTokens: 800 } });
    const thread = rpc.requests.find((x) => x.method === 'thread/start')!.params;
    expect(thread).toMatchObject({
      ephemeral: true, approvalPolicy: 'never', sandbox: 'read-only', baseInstructions: 'SYSTEM', serviceName: 'orbit-phone-step', model: 'default-model',
    });
    expect(thread.config.features).toEqual({
      shell_tool: false, apps: false, plugins: false, multi_agent: false, skill_search: false, computer_use: false, goals: false, sleep_tool: false,
    });
    expect(thread.config.web_search).toBe('disabled');
    expect(thread.config.mcp_servers).toEqual({ csqaq: { enabled: false }, node_repl: { enabled: false } }); // the user's own MCP servers stay off
    const turn = rpc.requests.find((x) => x.method === 'turn/start')!.params;
    expect(turn).toMatchObject({
      threadId: 'th-1', input, effort: 'medium', outputSchema: STEP_OUTPUT_SCHEMA, approvalPolicy: 'never',
      sandboxPolicy: { type: 'readOnly', networkAccess: false },
    });
    expect(rpc.requests.some((x) => x.method === 'thread/unsubscribe' && x.params.threadId === 'th-1')).toBe(true);
    expect(rpc.listenerCount('notification')).toBe(baseline); // its listener is gone
  });

  it('openPhoneExecutor mounts only orbit_phone, and phoneTool calls it directly', async () => {
    process.env.OPA_PHONE_CMD = 'python-test';
    const rpc = new FakeRpc();
    const bridge = new CodexBridge(rpc as any);
    const threadId = await bridge.openPhoneExecutor();
    const { config } = rpc.requests.find((x) => x.method === 'thread/start')!.params;
    expect(config.mcp_servers.orbit_phone).toMatchObject({ command: 'python-test', args: ['-m', 'orbit_phone.server'] });
    expect(config.mcp_servers.csqaq).toEqual({ enabled: false });
    expect(config.features).toMatchObject({ shell_tool: false, apps: false, plugins: false, computer_use: false });
    expect(rpc.requests.some((x) => x.method === 'turn/start')).toBe(false); // never runs a turn

    await bridge.phoneTool(threadId, 'phone_tap', { x: 1, y: 2 });
    const call = rpc.requests.find((x) => x.method === 'mcpServer/tool/call')!;
    expect(call.params).toEqual({ threadId, server: 'orbit_phone', tool: 'phone_tap', arguments: { x: 1, y: 2 } });
    expect(call.timeoutMs).toBe(150_000);
  });
});
