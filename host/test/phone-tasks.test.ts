import { EventEmitter } from 'node:events';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { describe, expect, it, vi } from 'vitest';
import { Butler } from '../src/butler/butler.ts';
import { DEFAULT_SETTINGS } from '../src/types.ts';
import { TOOL_MAP } from '../src/butler/tools.ts';
import { phoneConfigStatus } from '../src/phone/config.ts';
import { CodexBridge } from '../src/codex/bridge.ts';
import { CodexRpc } from '../src/codex/rpc.ts';
import { Db } from '../src/store/db.ts';
import { EventLog } from '../src/store/events.ts';

// These tests cover the old way of running a phone task (a Codex worker thread), not the step-driven runner.
process.env.OPA_PHONE_MODE = 'codex';

describe('phone task host integration', () => {
  it('builds an isolated MCP config and explains a missing environment', () => {
    const missing = phoneConfigStatus({ phoneDir: '/tmp/opa-no-phone-venv' });
    expect(missing.available).toBe(false);
    expect(missing.reason).toContain('opa phone setup');

    const configured = phoneConfigStatus({ phoneDir: '/tmp/opa-phone-test', command: process.execPath, serial: 'test-serial', opaHome: '/tmp/opa-test' });
    expect(configured.available).toBe(true);
    expect(configured.config).toMatchObject({
      command: process.execPath,
      args: ['-m', 'orbit_phone.server'],
      cwd: '/tmp/opa-phone-test',
      env: { OPA_PHONE_SERIAL: 'test-serial', OPA_HOME: '/tmp/opa-test' },
      startup_timeout_sec: 30,
      tool_timeout_sec: 120,
    });
  });

  it('reserves the phone worker during async creation and preserves china=false skills', async () => {
    const created: any[] = [];
    const bridge = {
      sessions: new Map(),
      createSession: vi.fn(async (options: any) => {
        created.push(options);
        await new Promise((resolve) => setTimeout(resolve, 20));
        return { threadId: 'phone-thread', title: options.title, model: options.model, permission: 'manual', status: 'running', turns: 1 };
      }),
    };
    const rt: any = {
      bridge,
      state: { sessions: () => [] },
      settings: () => ({ ...DEFAULT_SETTINGS, models: { ...DEFAULT_SETTINGS.models, codexDefault: 'gpt-configured' } }),
      syncSession: vi.fn(),
    };
    const phoneTask = TOOL_MAP.get('phone_task')!;
    const args = { title: '查订单状态', goal: '只查询当前状态，不要下单/付款', china: false, deliverable: '附上简短中文摘要' };
    const results = await Promise.all([phoneTask.run(args, rt), phoneTask.run(args, rt)]);

    expect(created).toHaveLength(1);
    expect(results.some((result) => typeof result === 'string' && result.includes('正在启动'))).toBe(true);
    expect(created[0]).toMatchObject({ title: '📱 查订单状态', model: 'gpt-configured', permission: 'manual', phone: true, skills: ['phone-automation'] });
    expect(created[0].prompt).toContain('只查询，不要下单/付款');
    expect(created[0].prompt).toContain('附上简短中文摘要');
    expect(created[0].prompt).toContain('必须以一个 JSON 代码块结尾');
    expect(created[0].prompt).toContain('phone_end 返回的 evidence 截图路径');
  });

  it('refuses a second phone worker while one is active', async () => {
    const createSession = vi.fn();
    const bridge = {
      sessions: new Map([['phone-1', { threadId: 'phone-1', title: '📱 已在运行', status: 'running' }]]),
      createSession,
    };
    const rt: any = { bridge, state: { sessions: () => [] }, settings: () => DEFAULT_SETTINGS, syncSession: vi.fn() };
    const result = await TOOL_MAP.get('phone_task')!.run({ title: '第二个任务', goal: '查询' }, rt);
    expect(result).toContain('已有手机任务在运行');
    expect(createSession).not.toHaveBeenCalled();
  });

  it('cancels a phone worker while createSession is still pending', async () => {
    const bridge = new CodexBridge(new CodexRpc(process.execPath, []));
    let enteredCreate!: () => void;
    const createEntered = new Promise<void>((resolve) => { enteredCreate = resolve; });
    let observedSignal: AbortSignal | undefined;
    let phoneTurnsStarted = 0;
    vi.spyOn(bridge, 'createSession').mockImplementation(async (options: any) => {
      observedSignal = options.signal;
      enteredCreate();
      await new Promise<void>((_resolve, reject) => {
        const abort = () => reject(new DOMException('phone task startup aborted', 'AbortError'));
        if (options.signal.aborted) abort();
        else options.signal.addEventListener('abort', abort, { once: true });
      });
      phoneTurnsStarted++;
      return { threadId: 'must-not-be-created', title: options.title, model: options.model, permission: 'manual', status: 'running', turns: 1 } as any;
    });

    const db = new Db(':memory:');
    const ev = new EventLog(db);
    const gw = Object.assign(new EventEmitter(), { onlineDevices: [], push: () => 0 }) as any;
    const butler = new Butler(db, ev, bridge, gw);
    try {
      const dispatch = TOOL_MAP.get('phone_task')!.run({ title: '查物流', goal: '只查询，不要下单/付款' }, butler);
      await createEntered;
      butler.interrupt();

      const result = await dispatch;
      expect(observedSignal).toBeInstanceOf(AbortSignal);
      expect(observedSignal?.aborted).toBe(true);
      expect(phoneTurnsStarted).toBe(0);
      expect(result).toBe('手机任务启动已取消。');
      expect(bridge.sessions.has('must-not-be-created')).toBe(false);
      expect(butler.state.sessions()).toHaveLength(0);
    } finally {
      butler.scheduler.stop();
      bridge.rpc.stop();
      db.sql.close();
    }
  });

  it('global stop interrupts the active phone session through the bridge path', async () => {
    const bridge = new CodexBridge(new CodexRpc(process.execPath, []));
    const interrupted: string[] = [];
    (bridge as any).interrupt = async (threadId: string) => { interrupted.push(threadId); return true; };
    bridge.sessions.set('phone-live', {
      threadId: 'phone-live', title: '📱 查询', model: 'gpt-x', permission: 'manual',
      activeTurnId: 'turn-phone', status: 'running', turns: 1, phone: true,
    });
    const db = new Db(':memory:');
    const ev = new EventLog(db);
    const gw = Object.assign(new EventEmitter(), { onlineDevices: [], push: () => 0 }) as any;
    const b = new Butler(db, ev, bridge, gw);

    b.interrupt();
    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(interrupted).toEqual(['phone-live']);
    b.scheduler.stop();
    bridge.rpc.stop();
    db.sql.close();
  });

  it('returns a failure code when opa phone setup cannot start uv', () => {
    const hostDir = join(import.meta.dirname, '..');
    const cliPath = join(hostDir, 'src/cli.ts');
    const result = spawnSync(process.execPath, ['--import', 'tsx', cliPath, 'phone', 'setup'], {
      cwd: hostDir,
      env: { ...process.env, PATH: '/opa-test-empty-path', OPA_HOME: '/tmp/opa-test' },
      encoding: 'utf8',
      timeout: 10_000,
    });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('uv sync 启动失败');
  });

  it('reports the configured phone as missing when adb lists no devices', () => {
    const hostDir = join(import.meta.dirname, '..');
    const cliPath = join(hostDir, 'src/cli.ts');
    const fakePath = mkdtempSync(join(tmpdir(), 'opa-phone-empty-adb-'));
    writeFileSync(join(fakePath, 'adb'), '#!/bin/sh\nprintf "List of devices attached\\n"\n', { mode: 0o755 });
    try {
      const result = spawnSync(process.execPath, ['--import', 'tsx', cliPath, 'phone', 'status'], {
        cwd: hostDir,
        env: { ...process.env, PATH: fakePath, OPA_PHONE_CMD: process.execPath, OPA_HOME: '/tmp/opa-test' },
        encoding: 'utf8',
        timeout: 10_000,
      });
      expect(result.status).toBe(1);
      expect(result.stderr).toContain('未发现选定设备 e7fe2f2a');
    } finally {
      rmSync(fakePath, { recursive: true, force: true });
    }
  });

  it('marks USB security debugging unavailable when keyevent reports an injection denial with exit code zero', () => {
    const hostDir = join(import.meta.dirname, '..');
    const cliPath = join(hostDir, 'src/cli.ts');
    const fakePath = mkdtempSync(join(tmpdir(), 'opa-phone-cli-'));
    writeFileSync(join(fakePath, 'adb'), [
      '#!/bin/sh',
      'case "$*" in',
      '  "devices -l") printf "List of devices attached\\ne7fe2f2a device model:Xiaomi\\n" ;;',
      '  "-s e7fe2f2a shell pm list packages com.android.adbkeyboard") printf "package:com.android.adbkeyboard\\n" ;;',
      '  "-s e7fe2f2a shell ime list -s") printf "com.android.adbkeyboard/.AdbIME\\n" ;;',
  "  \"-s e7fe2f2a shell input keyevent 0\") printf \"java.lang.SecurityException: Injecting requires INJECT_EVENTS permission\\n\" >&2; exit 0 ;;",
      '  *) exit 1 ;;',
      'esac',
    ].join('\n'), { mode: 0o755 });
    try {
      const result = spawnSync(process.execPath, ['--import', 'tsx', cliPath, 'phone', 'status'], {
        cwd: hostDir,
        env: { ...process.env, PATH: fakePath, OPA_PHONE_CMD: process.execPath, OPA_HOME: '/tmp/opa-test' },
        encoding: 'utf8',
        timeout: 10_000,
      });
      expect(result.status).toBe(1);
      expect(result.stderr).toContain('USB 调试（安全设置）检查失败');
      expect(result.stderr).toContain('SecurityException');
    } finally {
      rmSync(fakePath, { recursive: true, force: true });
    }
  });
});
