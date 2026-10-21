import { EventEmitter } from 'node:events';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

class FakeRpc extends EventEmitter {
  readonly requests: { method: string; params: any; timeoutMs?: number }[] = [];
  readonly responses: { id: number | string; result: any }[] = [];
  resumeTitle = '🤵 ordinary worker';
  statusPage: (params: any) => any = () => ({ data: [], nextCursor: null });
  statusError?: Error;
  private threadCount = 0;
  private turnCount = 0;

  start() {}
  stop() {}
  notify() {}
  respond(id: number | string, result: any) { this.responses.push({ id, result }); }
  respondError(id: number | string, code: number, message: string) { this.responses.push({ id, result: { error: { code, message } } }); }

  async request<T = any>(method: string, params: any = {}, timeoutMs?: number): Promise<T> {
    this.requests.push({ method, params, timeoutMs });
    let result: any = {};
    if (method === 'thread/start') {
      result = { thread: { id: `thread-${++this.threadCount}` }, model: params.model ?? 'resolved-model' };
    } else if (method === 'thread/resume') {
      result = { thread: { id: params.threadId, name: this.resumeTitle }, model: 'resolved-model' };
    } else if (method === 'config/read') {
      result = { config: { mcp_servers: { inherited_server: { command: 'inherited' } } } };
    } else if (method === 'mcpServerStatus/list') {
      if (this.statusError) throw this.statusError;
      result = this.statusPage(params);
    } else if (method === 'turn/start') {
      result = { turn: { id: `turn-${++this.turnCount}` } };
    }
    return result as T;
  }
}

const originalOpaHome = process.env.OPA_HOME;
let testHome = '';
let CodexBridge: typeof import('../src/codex/bridge.ts').CodexBridge;

function writeRegistry(mcpServers: Record<string, unknown>, envFile = '') {
  mkdirSync(testHome, { recursive: true });
  writeFileSync(join(testHome, 'mcp.json'), JSON.stringify({ presets: {}, mcpServers }));
  writeFileSync(join(testHome, 'mcp.env'), envFile);
}

function commandConfig(command: string) { return { command, args: [] }; }

beforeEach(async () => {
  vi.resetModules();
  testHome = mkdtempSync(join(tmpdir(), 'opa-mcp-bridge-'));
  process.env.OPA_HOME = testHome;
  delete process.env.OPA_MCP_BRIDGE_TEST_SECRET;
  ({ CodexBridge } = await import('../src/codex/bridge.ts'));
});

afterEach(() => {
  if (originalOpaHome === undefined) delete process.env.OPA_HOME;
  else process.env.OPA_HOME = originalOpaHome;
  delete process.env.OPA_MCP_BRIDGE_TEST_SECRET;
  if (testHome) rmSync(testHome, { recursive: true, force: true });
  testHome = '';
});

describe('MCP bridge', () => {
  it('injects and records only explicitly selected services', async () => {
    writeRegistry({ alpha: commandConfig('alpha-cmd'), beta: commandConfig('beta-cmd') });
    const rpc = new FakeRpc();
    const bridge = new CodexBridge(rpc as any);

    const selected = await bridge.createSession({ title: 'selected worker', prompt: 'go', model: 'test-model', mcpServices: ['alpha', 'alpha'] });
    const ordinary = await bridge.createSession({ title: 'ordinary worker', prompt: 'go', model: 'test-model' });
    const starts = rpc.requests.filter((request) => request.method === 'thread/start');

    expect(starts[0].params.config.mcp_servers).toEqual({ orbit_mcp_alpha: expect.objectContaining({ command: 'alpha-cmd' }) });
    expect(starts[0].params.config.mcp_servers).not.toHaveProperty('orbit_mcp_beta');
    expect(starts[1].params.config).toBeUndefined();
    expect(selected.mcpServices).toEqual(['alpha']);
    expect(ordinary.mcpServices).toBeUndefined();
  });

  it('rejects invalid selections, phone selections, and missing credentials before thread/start', async () => {
    writeRegistry({
      alpha: commandConfig('alpha-cmd'),
      secret_server: { type: 'http', url: 'https://mcp.example.test', http_headers: { Authorization: 'Bearer ${OPA_MCP_BRIDGE_TEST_SECRET}' } },
    });
    const rpc = new FakeRpc();
    const bridge = new CodexBridge(rpc as any);

    await expect(bridge.createSession({ title: 'bad input', prompt: 'go', mcpServices: ['alpha', 4] as any })).rejects.toThrow('mcpServices');
    await expect(bridge.createSession({ title: '📱 phone task', prompt: 'go', mcpServices: ['alpha'] })).rejects.toThrow('手机会话');
    await expect(bridge.createSession({ title: 'secret config', prompt: 'go', mcpServices: ['secret_server'] })).rejects.toThrow('配置不可用');
    expect(rpc.requests.map(({ method }) => method)).not.toContain('thread/start');
    expect(rpc.requests.map(({ method }) => method)).not.toContain('turn/start');
  });

  it('restores MCP selection through attach and after a live session needs resume', async () => {
    writeRegistry({ alpha: commandConfig('alpha-cmd') });
    const rpc = new FakeRpc();
    const bridge = new CodexBridge(rpc as any);

    const attached = await bridge.attach('saved-thread', 'ordinary worker', 'manual', ['alpha', 'alpha']);
    const resumes = rpc.requests.filter((request) => request.method === 'thread/resume');
    expect(resumes).toHaveLength(2);
    expect(resumes[0].params.config).toBeUndefined();
    expect(resumes[1].params.config.mcp_servers).toHaveProperty('orbit_mcp_alpha');
    expect(attached.mcpServices).toEqual(['alpha']);

    const persisted = {
      threadId: 'recovered-thread', title: 'ordinary worker', permission: 'manual' as const,
      status: 'idle' as const, turns: 0, phone: false, mcpServices: ['alpha'],
    };
    bridge.sessions.set(persisted.threadId, persisted);
    await bridge.send(persisted.threadId, 'next turn');
    const recoveryResume = rpc.requests.filter((request) => request.method === 'thread/resume').at(-1)!;
    expect(recoveryResume.params.config.mcp_servers).toHaveProperty('orbit_mcp_alpha');
  });

  it('rejects changing MCP selection on an already loaded thread without changing its saved selection', async () => {
    writeRegistry({ alpha: commandConfig('alpha-cmd'), beta: commandConfig('beta-cmd') });
    const rpc = new FakeRpc();
    const bridge = new CodexBridge(rpc as any);
    const live = {
      threadId: 'already-loaded', title: 'ordinary worker', permission: 'manual' as const,
      status: 'idle' as const, turns: 0, phone: false, mcpServices: ['alpha'],
    };
    bridge.sessions.set(live.threadId, live);
    bridge.markSubscribed(live.threadId);

    await expect(bridge.attach(live.threadId, undefined, 'manual', ['beta'])).rejects.toThrow('请新建会话');
    expect(live.mcpServices).toEqual(['alpha']);
    expect(rpc.requests.map(({ method }) => method)).not.toContain('thread/resume');
  });

  it('identifies an unknown phone thread before MCP injection and keeps it isolated', async () => {
    writeRegistry({ alpha: commandConfig('alpha-cmd') });
    const rpc = new FakeRpc();
    rpc.resumeTitle = '🤵 📱 recovered phone task';
    const bridge = new CodexBridge(rpc as any);

    await expect(bridge.attach('unknown-phone', undefined, 'manual', ['alpha'])).rejects.toThrow('手机会话');
    const resumes = rpc.requests.filter((request) => request.method === 'thread/resume');
    expect(resumes).toHaveLength(1);
    expect(resumes[0].params.config).toBeUndefined();
    expect(rpc.requests.map(({ method }) => method)).toContain('thread/unsubscribe');
    expect(rpc.requests.map(({ method }) => method)).not.toContain('turn/start');
  });

  it('paginates thread-scoped status, checks selected servers only, rejects empty tools, and unloads without a turn', async () => {
    writeRegistry({
      alpha: commandConfig('alpha-cmd'), beta: commandConfig('beta-cmd'), empty: commandConfig('empty-cmd'),
    });
    const rpc = new FakeRpc();
    rpc.statusPage = (params) => params.cursor === 'next-page'
      ? {
        data: [
          { name: 'orbit_mcp_alpha', runtimeStatus: 'connected', tools: { lookup: {}, search: {} }, toolsError: null, authStatus: 'unknown' },
          { name: 'orbit_mcp_beta', runtimeStatus: 'failed', tools: {}, toolsError: 'secret-bearing upstream error', authStatus: 'unknown' },
          { name: 'orbit_mcp_empty', runtimeStatus: 'connected', tools: {}, toolsError: null, authStatus: 'bearerToken' },
        ], nextCursor: null,
      }
      : {
        data: [{ name: 'unrelated_global', runtimeStatus: 'connected', tools: { unrelated: {} }, toolsError: null, authStatus: 'unknown' }],
        nextCursor: 'next-page',
      };
    const bridge = new CodexBridge(rpc as any);

    const result = await bridge.checkMcpServices(['alpha', 'beta', 'empty']);

    expect(result).toEqual([
      { id: 'alpha', server: 'orbit_mcp_alpha', connected: true, toolCount: 2, auth: 'unknown' },
      { id: 'beta', server: 'orbit_mcp_beta', connected: false, toolCount: 0, auth: 'unknown', error: '服务连接失败' },
      { id: 'empty', server: 'orbit_mcp_empty', connected: false, toolCount: 0, auth: 'bearerToken', error: '服务已连接但没有可用工具' },
    ]);
    expect(JSON.stringify(result)).not.toContain('secret-bearing');
    const statusCalls = rpc.requests.filter((request) => request.method === 'mcpServerStatus/list');
    expect(statusCalls).toHaveLength(2);
    expect(statusCalls.every(({ params }) => params.threadId === 'thread-1')).toBe(true);
    expect(statusCalls[0].params).toMatchObject({ limit: 100, detail: 'toolsAndAuthOnly' });
    expect(statusCalls[1].params.cursor).toBe('next-page');

    const start = rpc.requests.find((request) => request.method === 'thread/start')!;
    expect(start.params).toMatchObject({ ephemeral: true, approvalPolicy: 'never', sandbox: 'read-only' });
    expect(start.params.config.features).toMatchObject({ shell_tool: false, computer_use: false, apps: false, plugins: false, multi_agent: false });
    expect(start.params.config.mcp_servers.inherited_server).toEqual({ enabled: false });
    expect(start.params.config.mcp_servers.orbit_mcp_alpha).toMatchObject({ command: 'alpha-cmd' });
    expect(rpc.requests.map(({ method }) => method)).toContain('thread/unsubscribe');
    expect(rpc.requests.map(({ method }) => method)).not.toContain('turn/start');
    expect(rpc.requests.map(({ method }) => method)).not.toContain('mcpServer/tool/call');
  });

  it('turns status RPC failures into controlled errors and still unloads the temporary thread', async () => {
    writeRegistry({ alpha: commandConfig('alpha-cmd') });
    const rpc = new FakeRpc();
    rpc.statusError = new Error('authorization secret should not escape');
    const bridge = new CodexBridge(rpc as any);

    await expect(bridge.checkMcpServices(['alpha'])).resolves.toEqual([
      { id: 'alpha', server: 'orbit_mcp_alpha', connected: false, toolCount: 0, auth: 'unknown', error: '服务连接状态查询失败' },
    ]);
    expect(rpc.requests.map(({ method }) => method)).toContain('thread/unsubscribe');
    expect(rpc.requests.map(({ method }) => method)).not.toContain('turn/start');
  });

  it('does not auto-approve an elicitation from a selected non-phone MCP', async () => {
    writeRegistry({ alpha: commandConfig('alpha-cmd') });
    const rpc = new FakeRpc();
    const bridge = new CodexBridge(rpc as any);
    let policyCalls = 0;
    bridge.approvalHandler = async () => { policyCalls++; return { approve: false }; };
    bridge.sessions.set('ordinary-thread', {
      threadId: 'ordinary-thread', title: 'ordinary worker', permission: 'manual', status: 'idle', turns: 0,
      mcpServices: ['alpha'], phone: false,
    });

    await (bridge as any).onServerRequest(7, 'mcpServer/elicitation/request', {
      threadId: 'ordinary-thread', serverName: 'orbit_mcp_alpha', message: 'Confirm this action', _meta: {},
    });

    expect(policyCalls).toBe(1);
    expect(rpc.responses).toEqual([{ id: 7, result: { action: 'decline', content: null, _meta: null } }]);
  });
});
