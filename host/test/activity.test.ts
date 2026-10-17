// Friendly `butler.status` detail (protocol.md §4.4): pure label mapping + the bot loop actually emitting it.
import { EventEmitter } from 'node:events';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { FALLBACK_ACTIVITY, toolActivityLabel } from '../src/butler/activity.ts';
import { Butler } from '../src/butler/butler.ts';
import { TOOLS } from '../src/butler/tools.ts';
import { CodexBridge } from '../src/codex/bridge.ts';
import { CodexRpc } from '../src/codex/rpc.ts';
import { Db } from '../src/store/db.ts';
import { EventLog } from '../src/store/events.ts';

describe('toolActivityLabel', () => {
  it('uses the agreed phrases', () => {
    const expected: Record<string, string> = {
      codex_session_create: '派出任务',
      computer_use_task: '操作电脑',
      phone_task: '在手机上操作',
      codex_session_send: '给执行会话补充指令',
      codex_session_steer: '给执行会话补充指令',
      codex_session_status: '查看执行进度',
      connector_call: '查询服务',
      connectors_list: '查看可用服务',
      ui_render: '整理结果',
      ui_patch: '整理结果',
      ask_user: '准备问题',
      request_approval: '请求你确认',
      memory_write: '记下',
      memory_search: '回想',
      schedule: '设提醒',
      task_create: '建立任务',
      task_update: '更新任务',
    };
    for (const [tool, label] of Object.entries(expected)) expect(toolActivityLabel(tool), tool).toBe(label);
  });

  it('has a specific phrase for every tool the bot can call (TOOLS plus codex_answer, phone tools included)', () => {
    const names = [...TOOLS.map((t) => t.name), 'codex_answer'];
    expect(names).toEqual(expect.arrayContaining(['phone_task', 'phone_status', 'yield', 'request_approval']));
    for (const name of names) {
      const label = toolActivityLabel(name);
      expect(label, `${name} falls back to the generic phrase`).not.toBe(FALLBACK_ACTIVITY);
      expect(label, name).toMatch(/[\u4e00-\u9fff]/); // Chinese, not the raw tool name
      expect(label.length, `${name}: "${label}" is too long for a status line`).toBeLessThanOrEqual(12);
      expect(label, name).not.toContain('管家'); // the product calls itself Orbit
      expect(label, name).not.toMatch(/[_a-z]{4,}/); // no leaked identifiers
    }
  });

  it('falls back to 处理中 for anything else, including names that exist on Object.prototype', () => {
    expect(FALLBACK_ACTIVITY).toBe('处理中');
    for (const name of ['web_search', 'web.run', 'some_future_tool', '', 'constructor', 'toString', '__proto__', 'hasOwnProperty']) {
      expect(toolActivityLabel(name), JSON.stringify(name)).toBe('处理中');
    }
  });
});

// ───────── through the bot loop, against the scripted fake `codex app-server` ─────────
const FAKE = join(import.meta.dirname, 'fake-codex.mjs');

function makeBot(script: object[]) {
  process.env.FAKE_CODEX_SCRIPT = JSON.stringify(script);
  delete process.env.FAKE_CODEX_LOG;
  const bridge = new CodexBridge(new CodexRpc(process.execPath, [FAKE]));
  const db = new Db(':memory:');
  const ev = new EventLog(db);
  const gw = Object.assign(new EventEmitter(), { onlineDevices: ['d1'], push: () => 0 }) as any;
  const b = new Butler(db, ev, bridge, gw);
  const status: any[] = [];
  ev.on('live', (e) => { if (e.k === 'butler.status') status.push(e.d); });
  b.start();
  return { b, status, stop: () => { b.scheduler.stop(); bridge.rpc.stop(); } };
}

const idle = (b: any) => new Promise<void>((r) => { const t = setInterval(() => { if (!b.running && !b.inbox.length) { clearInterval(t); r(); } }, 20); });
const settle = async (b: any) => { await new Promise((r) => setTimeout(r, 100)); await idle(b); };

describe('butler.status while tools run', () => {
  it('sends a Chinese phrase as detail and the raw tool name as tool; yield stays idle', async () => {
    const { b, status, stop } = makeBot([
      { steps: [
        { tool: 'memory_write', args: { text: '主人不吃香菜', kind: 'preference', source: 'explicit' } },
        { tool: 'task_create', args: { title: '订餐', goal: '订到周六的位子', show_card: false } },
        { tool: 'web_search', args: {} }, // not one of our tools
        { tool: 'codex_answer', args: { question_id: 'q_none', answers: {} } },
        { tool: 'yield' },
      ] },
    ]);
    try {
      b.userMessage('记住我不吃香菜，再帮我订餐', 'c1');
      await settle(b);

      expect(status.filter((s) => s.state === 'acting')).toEqual([
        { state: 'acting', detail: '记下', tool: 'memory_write' },
        { state: 'acting', detail: '建立任务', tool: 'task_create' },
        { state: 'acting', detail: '处理中', tool: 'web_search' },
        { state: 'acting', detail: '回答执行会话的提问', tool: 'codex_answer' },
      ]);
      // yield never shows up as "acting"; the stream ends idle.
      expect(status.some((s) => s.tool === 'yield')).toBe(false);
      expect(status.at(-1)).toEqual({ state: 'idle' });
      // Only acting carries detail / tool.
      expect(status.filter((s) => s.state !== 'acting').every((s) => s.detail === undefined && s.tool === undefined)).toBe(true);
    } finally {
      stop();
    }
  });
});
