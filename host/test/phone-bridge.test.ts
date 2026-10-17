import { EventEmitter } from 'node:events';
import { existsSync, mkdirSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { cancelPhoneTask, CodexBridge } from '../src/codex/bridge.ts';
import { OPA_HOME } from '../src/store/db.ts';

class FakeRpc extends EventEmitter {
  readonly requests: { method: string; params: any }[] = [];
  readonly responses: { id: number | string; result: any }[] = [];
  toolCallResult: any = {};
  private threadCount = 0;
  private turnCount = 0;

  start() {}
  stop() {}
  notify() {}
  respond(id: number | string, result: any) { this.responses.push({ id, result }); }
  respondError(id: number | string, code: number, message: string) { this.responses.push({ id, result: { error: { code, message } } }); }

  async request<T = any>(method: string, params: any = {}): Promise<T> {
    this.requests.push({ method, params });
    let result: any = {};
    if (method === 'thread/start') {
      result = { thread: { id: `phone-thread-${++this.threadCount}` }, model: params.model ?? 'resolved-model' };
    } else if (method === 'thread/resume') {
      result = { thread: { id: params.threadId, name: '🤵 📱 recovered phone task' }, model: 'resolved-model' };
    } else if (method === 'turn/start') {
      result = { turn: { id: `turn-${++this.turnCount}` } };
    } else if (method === 'mcpServer/tool/call') {
      result = this.toolCallResult;
    }
    return result as T;
  }
}

const oldEnv = new Map<string, string | undefined>();
function setEnv(key: string, value: string | undefined) {
  if (!oldEnv.has(key)) oldEnv.set(key, process.env[key]);
  if (value === undefined) delete process.env[key];
  else process.env[key] = value;
}
afterEach(() => {
  for (const [key, value] of oldEnv) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  oldEnv.clear();
});

describe('phone bridge', () => {
  it('injects orbit_phone and disables computer use only for phone sessions', async () => {
    setEnv('OPA_PHONE_CMD', 'python-test');
    const rpc = new FakeRpc();
    const bridge = new CodexBridge(rpc as any);

    const phone = await bridge.createSession({ title: '📱 read-only check', prompt: 'check', model: 'chosen-model', phone: true });
    const regular = await bridge.createSession({ title: 'ordinary worker', prompt: 'check', model: 'chosen-model' });
    const starts = rpc.requests.filter((request) => request.method === 'thread/start');

    expect(starts[0].params.model).toBe('chosen-model');
    expect(starts[0].params.config).toMatchObject({
      mcp_servers: { orbit_phone: { command: 'python-test', args: ['-m', 'orbit_phone.server'] } },
      features: { computer_use: false },
    });
    expect(starts[1].params.config).toBeUndefined();
    expect(phone.phone).toBe(true);
    expect(regular.phone).toBe(false);
  });

  it('archives a thread when a pending phone create is aborted during thread/start', async () => {
    setEnv('OPA_PHONE_CMD', 'python-test');
    const rpc = new FakeRpc();
    const originalRequest = rpc.request.bind(rpc);
    let announceStart!: () => void;
    let finishStart!: () => void;
    const started = new Promise<void>((resolve) => { announceStart = resolve; });
    const held = new Promise<void>((resolve) => { finishStart = resolve; });
    rpc.request = async function <T = any>(method: string, params: any = {}): Promise<T> {
      if (method === 'thread/start') {
        this.requests.push({ method, params });
        announceStart();
        await held;
        return { thread: { id: 'aborted-phone-thread' }, model: params.model } as T;
      }
      return originalRequest(method, params);
    };
    const bridge = new CodexBridge(rpc as any);
    const controller = new AbortController();
    const creating = bridge.createSession({
      title: '📱 delayed create', prompt: 'never start', model: 'selected-model', phone: true, signal: controller.signal,
    });

    await started;
    controller.abort();
    finishStart();
    await expect(creating).rejects.toMatchObject({ name: 'AbortError' });
    expect(rpc.requests.map(({ method }) => method)).toContain('thread/archive');
    expect(rpc.requests.map(({ method }) => method)).not.toContain('turn/start');
    expect(bridge.sessions.has('aborted-phone-thread')).toBe(false);
  });

  it('auto-accepts every orbit_phone elicitation and redacts text from audit entries', async () => {
    const rpc = new FakeRpc();
    const bridge = new CodexBridge(rpc as any);
    const audits: any[] = [];
    let policyCalls = 0;
    bridge.audit = (...args) => audits.push(args);
    bridge.approvalHandler = async () => { policyCalls++; return { approve: true }; };

    const request = {
      threadId: 'phone-thread',
      serverName: 'orbit_phone',
      message: 'Sensitive action',
      _meta: { tool_name: 'phone_type', tool_params_display: [{ name: 'text', display_name: 'text', value: 'do-not-log-this' }] },
    };
    await (bridge as any).onServerRequest(1, 'mcpServer/elicitation/request', request);
    await (bridge as any).onServerRequest(2, 'mcpServer/elicitation/request', request);

    expect(rpc.responses.map(({ result }) => result.action)).toEqual(['accept', 'accept']);
    expect(policyCalls).toBe(0);
    expect(audits).toHaveLength(2);
    expect(audits[0]).toEqual(['phone', 'auto-accept', {
      thread: 'phone-thread', tool: 'phone_type', params: [{ name: 'text', value: '[redacted]' }],
    }]);

    await (bridge as any).onServerRequest(3, 'mcpServer/elicitation/request', {
      threadId: 'other-thread', serverName: 'other_server', message: 'confirm', _meta: {},
    });
    expect(policyCalls).toBe(1);
  });

  it('audits phone tool calls and auto-approves only permissions tied to a phone MCP item', async () => {
    const rpc = new FakeRpc();
    const bridge = new CodexBridge(rpc as any);
    const audits: any[] = [];
    let policyCalls = 0;
    bridge.audit = (...args) => audits.push(args);
    bridge.approvalHandler = async () => { policyCalls++; return { approve: false }; };
    bridge.sessions.set('phone-thread', {
      threadId: 'phone-thread', title: '📱 task', model: 'model', permission: 'manual', activeTurnId: 'turn-1',
      status: 'running', turns: 1, phone: true, phoneMcpCalls: new Map(),
    });

    (bridge as any).onNotification('item/started', {
      threadId: 'phone-thread', turnId: 'turn-1',
      item: { type: 'mcpToolCall', id: 'phone-call', server: 'orbit_phone', tool: 'phone_type', arguments: { text: 'private text', x: 12 } },
    });
    await (bridge as any).onServerRequest(10, 'item/permissions/requestApproval', {
      threadId: 'phone-thread', turnId: 'turn-1', itemId: 'phone-call', permissions: { type: 'network' },
    });
    await (bridge as any).onServerRequest(11, 'item/permissions/requestApproval', {
      threadId: 'phone-thread', turnId: 'turn-1', itemId: 'shell-call', permissions: { type: 'filesystem' },
    });

    expect(audits[0]).toEqual(['phone', 'tool-call', {
      thread: 'phone-thread', tool: 'phone_type', params: '[redacted]',
    }]);
    expect(audits[1][0]).toBe('phone');
    expect(audits[1][1]).toBe('auto-accept');
    expect(rpc.responses.find(({ id }) => id === 10)?.result).toEqual({ permissions: { type: 'network' }, scope: 'turn' });
    expect(rpc.responses.find(({ id }) => id === 11)?.result).toEqual({ permissions: {}, scope: 'turn' });
    expect(policyCalls).toBe(1);
  });

  it('restores and re-injects phone config from a 📱 title', async () => {
    setEnv('OPA_PHONE_CMD', 'python-test');
    const rpc = new FakeRpc();
    const bridge = new CodexBridge(rpc as any);
    const session = await bridge.attach('resumed-phone-thread');
    const resumes = rpc.requests.filter((request) => request.method === 'thread/resume');
    expect(session.phone).toBe(true);
    expect(resumes).toHaveLength(2);
    expect(resumes[0].params.config).toBeUndefined();
    expect(resumes[1].params.config).toMatchObject({
      mcp_servers: { orbit_phone: { command: 'python-test' } },
      features: { computer_use: false },
    });
  });

  it('does not cancel an idle phone session without an owned lock and uses thread-scoped cancel for a known lock', async () => {
    const serial = 'device/with?unsafe chars';
    const safeSerial = 'device_with_unsafe_chars';
    const marker = join(OPA_HOME, 'phone', `${safeSerial}.cancel`);
    setEnv('OPA_PHONE_SERIAL', serial);
    try { unlinkSync(marker); } catch { /* no marker from a previous run */ }

    const bridge = new CodexBridge(new FakeRpc() as any);
    const session = await bridge.attach('resumed-phone-thread');
    expect(session.phone).toBe(true);
    await expect(bridge.interrupt(session.threadId)).resolves.toBe(false);
    expect(existsSync(marker)).toBe(false);
    session.phoneLockHeld = true;
    await expect(bridge.interrupt(session.threadId)).resolves.toBe(false);
    expect(existsSync(marker)).toBe(true);
    expect(session.phoneLockHeld).toBe(false);
    expect((bridge.rpc as any).requests.at(-1)).toEqual({
      method: 'mcpServer/tool/call',
      params: { threadId: session.threadId, server: 'orbit_phone', tool: 'phone_cancel', arguments: { only_owned: true } },
    });
    mkdirSync(join(OPA_HOME, 'phone'), { recursive: true });
    unlinkSync(marker);
  });

  it('falls back to the marker only when an owned-lock phone_cancel request fails', async () => {
    const marker = join(OPA_HOME, 'phone', 'known-lock.cancel');
    setEnv('OPA_PHONE_SERIAL', 'known-lock');
    try { unlinkSync(marker); } catch { /* no marker from a previous run */ }
    const rpc = new FakeRpc();
    rpc.toolCallResult = { isError: true };
    const bridge = new CodexBridge(rpc as any);
    const session = await bridge.attach('resumed-phone-thread');
    session.phoneLockHeld = true;
    await bridge.interrupt(session.threadId);
    expect(existsSync(marker)).toBe(true);
    unlinkSync(marker);
  });

  it('cancels an in-flight phone_begin through its own MCP thread before interrupting the turn', async () => {
    setEnv('OPA_PHONE_CMD', 'python-test');
    const rpc = new FakeRpc();
    const bridge = new CodexBridge(rpc as any);
    const session = await bridge.attach('resumed-phone-thread');
    session.activeTurnId = 'turn-beginning';
    session.status = 'running';
    (bridge as any).onNotification('item/started', {
      threadId: session.threadId, turnId: 'turn-beginning',
      item: { type: 'mcpToolCall', id: 'begin-call', server: 'orbit_phone', tool: 'phone_begin', arguments: { task: 'ongoing task' } },
    });
    expect(session.phoneBeginInFlight).toBe(true);
    await bridge.interrupt(session.threadId);
    const methods = rpc.requests.map(({ method }) => method);
    const turnInterrupt = methods.indexOf('turn/interrupt');
    const phoneCancels = rpc.requests.filter(({ method }) => method === 'mcpServer/tool/call');
    expect(phoneCancels.length).toBeGreaterThanOrEqual(1);
    expect(methods.indexOf('mcpServer/tool/call')).toBeLessThan(turnInterrupt);
    expect(phoneCancels.every(({ params }) => params.arguments.only_owned === true)).toBe(true);
  });

  it('cancels an acquired phone lock when a turn ends without phone_end', async () => {
    const serial = 'turn-without-end';
    const safeSerial = serial;
    const marker = join(OPA_HOME, 'phone', `${safeSerial}.cancel`);
    setEnv('OPA_PHONE_SERIAL', serial);
    try { unlinkSync(marker); } catch { /* no marker from a previous run */ }

    const rpc = new FakeRpc();
    const bridge = new CodexBridge(rpc as any);
    const session = await bridge.attach('resumed-phone-thread');
    session.status = 'running';
    session.activeTurnId = 'turn-owned';
    (bridge as any).onNotification('item/started', {
      threadId: session.threadId, turnId: 'turn-owned',
      item: { type: 'mcpToolCall', id: 'begin-call', server: 'orbit_phone', tool: 'phone_begin', arguments: { task: 'audit-safe task' } },
    });
    (bridge as any).onNotification('item/completed', {
      threadId: session.threadId, turnId: 'turn-owned',
      item: {
        type: 'mcpToolCall', id: 'begin-call', server: 'orbit_phone', tool: 'phone_begin', status: 'completed',
        arguments: { task: 'audit-safe task' }, result: { content: [{ text: '{"status":"started"}' }] },
      },
    });
    expect(session.phoneLockHeld).toBe(true);
    (bridge as any).onNotification('turn/completed', { threadId: session.threadId, turn: { id: 'turn-owned', status: 'completed', items: [] } });
    expect(session.phoneLockHeld).toBe(false);
    expect(existsSync(marker)).toBe(true);
    unlinkSync(marker);
  });
});
