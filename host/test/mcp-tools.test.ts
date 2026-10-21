import { EventEmitter } from 'node:events';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { TOOL_MAP, TOOLS } from '../src/butler/tools.ts';
import { Butler } from '../src/butler/butler.ts';
import { DEFAULT_SETTINGS } from '../src/types.ts';
import { setMcpServiceEnabled } from '../src/mcp/registry.ts';
import { Db } from '../src/store/db.ts';
import { EventLog } from '../src/store/events.ts';

let home: string;
let previousOpaHome: string | undefined;
let previousPhoneMode: string | undefined;
let previousAmapKey: string | undefined;

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), 'opa-mcp-tools-'));
  previousOpaHome = process.env.OPA_HOME;
  previousPhoneMode = process.env.OPA_PHONE_MODE;
  previousAmapKey = process.env.AMAP_MAPS_API_KEY;
  process.env.OPA_HOME = home;
  delete process.env.OPA_PHONE_MODE;
  delete process.env.AMAP_MAPS_API_KEY;
  mkdirSync(home, { recursive: true });
  writeFileSync(join(home, 'mcp.json'), JSON.stringify({ presets: {}, mcpServers: {} }));
  writeFileSync(join(home, 'mcp.env'), 'AMAP_MAPS_API_KEY=TOOL_TEST_SECRET\n');
});

afterEach(() => {
  if (previousOpaHome === undefined) delete process.env.OPA_HOME;
  else process.env.OPA_HOME = previousOpaHome;
  if (previousPhoneMode === undefined) delete process.env.OPA_PHONE_MODE;
  else process.env.OPA_PHONE_MODE = previousPhoneMode;
  if (previousAmapKey === undefined) delete process.env.AMAP_MAPS_API_KEY;
  else process.env.AMAP_MAPS_API_KEY = previousAmapKey;
  rmSync(home, { recursive: true, force: true });
  vi.restoreAllMocks();
});

function makeRuntime(created: any[] = []) {
  const bridge = {
    sessions: new Map(),
    createSession: vi.fn(async (options: any) => {
      created.push(options);
      return {
        threadId: 'new-thread', title: options.title, model: options.model, permission: options.permission,
        status: 'idle', turns: 1, mcpServices: options.mcpServices?.length ? [...options.mcpServices] : undefined,
      };
    }),
  };
  return {
    bridge,
    state: { sessions: () => [], updateTask: vi.fn() },
    settings: () => DEFAULT_SETTINGS,
    syncSession: vi.fn(),
  } as any;
}

describe('mcp_list', () => {
  it('returns a local safe catalog, supports filtering, and never contacts a service', async () => {
    const fetch = vi.spyOn(globalThis, 'fetch');
    const tool = TOOL_MAP.get('mcp_list')!;
    const full: any = await tool.run({}, {} as any);
    const serialized = JSON.stringify(full);
    expect(full.catalog.some((item: any) => item.id === 'amap' && item.configured)).toBe(true);
    expect(serialized).not.toContain('TOOL_TEST_SECRET');
    expect(serialized).not.toContain('mcpServers');
    expect(full.note).toContain('不代表登录或鉴权成功');
    expect((await tool.run({ query: '高德' }, {} as any) as any).catalog.map((item: any) => item.id)).toEqual(['amap']);
    expect(fetch).not.toHaveBeenCalled();
  });
});

describe('codex_session_create MCP selection', () => {
  it('defaults to no MCP services and passes an explicitly selected configured service through', async () => {
    const created: any[] = [];
    const rt = makeRuntime(created);
    const tool = TOOL_MAP.get('codex_session_create')!;

    await tool.run({ title: '普通任务', prompt: '完成普通任务' }, rt);
    expect(created[0].mcpServices).toEqual([]);
    expect(rt.syncSession).toHaveBeenLastCalledWith('new-thread', { taskId: undefined, title: '普通任务' });

    await tool.run({ title: '地图查询', prompt: '查路线', mcp_services: ['amap'] }, rt);
    expect(created[1].mcpServices).toEqual(['amap']);
    expect(rt.syncSession).toHaveBeenLastCalledWith('new-thread', { taskId: undefined, title: '地图查询', mcpServices: ['amap'] });
  });

  it('accepts an explicit empty selection without reading a damaged MCP config', async () => {
    writeFileSync(join(home, 'mcp.json'), '{invalid');
    const created: any[] = [];
    const rt = makeRuntime(created);

    await TOOL_MAP.get('codex_session_create')!.run({ title: '普通任务', prompt: '继续工作', mcp_services: [] }, rt);

    expect(created).toHaveLength(1);
    expect(created[0].mcpServices).toEqual([]);
  });

  it('has JSON Schema constraints and rejects malformed, duplicate, unknown, disabled, and unconfigured choices at runtime', async () => {
    const property = (TOOL_MAP.get('codex_session_create')!.parameters as any).properties.mcp_services;
    expect(property.type).toBe('array');
    expect(property.maxItems).toBe(8);
    expect(property.uniqueItems).toBe(true);
    expect(property.items).toMatchObject({ type: 'string', minLength: 1, maxLength: 64 });

    const created: any[] = [];
    const rt = makeRuntime(created);
    const tool = TOOL_MAP.get('codex_session_create')!;
    for (const mcp_services of [null, ['amap', 'amap'], ['unknown'], Array(9).fill('amap'), ['']]) {
      await expect(tool.run({ title: '任务', prompt: '目标', mcp_services }, rt)).rejects.toThrow();
    }

    setMcpServiceEnabled('amap', false);
    await expect(tool.run({ title: '任务', prompt: '目标', mcp_services: ['amap'] }, rt)).rejects.toThrow('不可用');
    setMcpServiceEnabled('amap', true);
    writeFileSync(join(home, 'mcp.env'), '');
    await expect(tool.run({ title: '任务', prompt: '目标', mcp_services: ['amap'] }, rt)).rejects.toThrow();
    expect(created).toHaveLength(0);
  });

  it('does not implicitly pass MCP services to phone or computer sessions', async () => {
    const created: any[] = [];
    const rt = makeRuntime(created);
    rt.state.sessions = () => [];

    await TOOL_MAP.get('computer_use_task')!.run({ title: '浏览器任务', goal: '查询公开网页', china: false }, rt);
    await TOOL_MAP.get('phone_task')!.run({ title: '手机任务', goal: '只查询，不要下单/付款', china: false }, rt);

    expect(created).toHaveLength(2);
    expect(created.every((options) => !Object.hasOwn(options, 'mcpServices'))).toBe(true);
  });
});

describe('session MCP selection persistence', () => {
  it('keeps the selection from LiveSession through persistence and supplies it when reattaching', async () => {
    const live: any = {
      threadId: 'thread-mcp', title: 'MCP task', model: 'gpt-test', permission: 'manual', status: 'idle', turns: 1,
      mcpServices: ['amap'],
    };
    const bridge: any = Object.assign(new EventEmitter(), {
      sessions: new Map([[live.threadId, live]]), rpc: new EventEmitter(), attach: vi.fn(async () => live),
    });
    const db = new Db(':memory:');
    const ev = new EventLog(db);
    const gw = Object.assign(new EventEmitter(), { onlineDevices: [], push: () => 0 });
    const butler = new Butler(db, ev, bridge, gw as any);
    try {
      expect(butler.syncSession(live.threadId)?.mcpServices).toEqual(['amap']);
      live.mcpServices = undefined;
      expect(butler.syncSession(live.threadId)?.mcpServices).toEqual(['amap']);
      await (butler as any).reattachSessions();
      expect(bridge.attach).toHaveBeenCalledWith('thread-mcp', 'MCP task', 'manual', ['amap']);
    } finally {
      butler.scheduler.stop();
      db.sql.close();
    }
  });

  it('forks inherit the source selection and pass it to attach', async () => {
    const attached: any[] = [];
    const source = { id: 'source', mcpServices: ['amap'] };
    const bridge: any = {
      sessions: new Map(),
      rpc: { request: vi.fn(async () => ({ thread: { id: 'fork' } })) },
      attach: vi.fn(async (...args: any[]) => {
        attached.push(args);
        return { threadId: 'fork', title: 'forked', status: 'idle', mcpServices: args[3] };
      }),
    };
    const rt: any = {
      bridge, state: { sessions: () => [source] }, syncSession: vi.fn(),
    };
    await TOOL_MAP.get('codex_sessions_fork')!.run({ session_id: 'source', title: 'forked' }, rt);
    expect(attached).toEqual([['fork', 'forked', 'manual', ['amap']]]);
    expect(rt.syncSession).toHaveBeenCalledWith('fork', { title: 'forked', mcpServices: ['amap'] });
  });

  it('reattaches a stored MCP selection before sending and does not send if its config is invalid', async () => {
    const stored = { id: 'thread-mcp', title: 'MCP task', permission: 'manual', model: 'gpt-test', mcpServices: ['amap'] };
    const bridge: any = Object.assign(new EventEmitter(), {
      sessions: new Map(),
      isSubscribed: vi.fn(() => false),
      attach: vi.fn(async () => { throw new Error('selected MCP service is not configured'); }),
      send: vi.fn(),
    });
    const rt: any = {
      bridge,
      state: { session: vi.fn(() => stored) },
      settings: () => DEFAULT_SETTINGS,
    };

    await expect(TOOL_MAP.get('codex_session_send')!.run({ session_id: stored.id, text: '继续' }, rt)).rejects.toThrow('not configured');

    expect(bridge.attach).toHaveBeenCalledWith(stored.id, stored.title, stored.permission, ['amap']);
    expect(bridge.send).not.toHaveBeenCalled();
  });
});
