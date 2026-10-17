import { describe, expect, it } from 'vitest';
import { inQuietHours, nextCron, parseCron } from '../src/util/cron.ts';
import { validatePatch, validateProps } from '../src/butler/genui.ts';
import { MemoryStore } from '../src/butler/memory.ts';
import { Db } from '../src/store/db.ts';
import { EventLog } from '../src/store/events.ts';
import { State } from '../src/butler/state.ts';
import { classifyCommand } from '../src/codex/bridge.ts';
import { TOOLS } from '../src/butler/tools.ts';
import { buildInstructions, loadSkillIndex } from '../src/butler/prompt.ts';
import { DEFAULT_SETTINGS } from '../src/types.ts';

describe('cron', () => {
  it('weekday 08:00 Shanghai', () => {
    const c = parseCron('0 8 * * 1-5');
    // 2026-10-15 is a Thursday. After 09:00 local → next is Fri 08:00 local = 00:00Z.
    const after = Date.parse('2026-10-15T09:00:00+08:00');
    expect(new Date(nextCron(c, after, 'Asia/Shanghai')!).toISOString()).toBe('2026-10-16T00:00:00.000Z');
    // Friday after 08:00 → Monday
    expect(new Date(nextCron(c, Date.parse('2026-10-16T08:30:00+08:00'), 'Asia/Shanghai')!).toISOString()).toBe('2026-10-19T00:00:00.000Z');
  });
  it('step', () => {
    const c = parseCron('*/15 * * * *');
    expect(nextCron(c, Date.parse('2026-10-15T10:07:00Z'), 'UTC')).toBe(Date.parse('2026-10-15T10:15:00Z'));
  });
  it('quiet hours wrap midnight', () => {
    const q = { start: '23:00', end: '08:00' };
    expect(inQuietHours(q, Date.parse('2026-10-15T23:30:00+08:00'), 'Asia/Shanghai')).toBe(true);
    expect(inQuietHours(q, Date.parse('2026-10-15T07:59:00+08:00'), 'Asia/Shanghai')).toBe(true);
    expect(inQuietHours(q, Date.parse('2026-10-15T12:00:00+08:00'), 'Asia/Shanghai')).toBe(false);
  });
});

describe('genui', () => {
  it('validates and reports errors', () => {
    expect(validateProps('order_card', { merchant: 'A', items: [{ name: 'x', qty: 1, price: 2 }], total: 2, status: 'draft' }).ok).toBe(true);
    const bad = validateProps('order_card', { merchant: 'A', items: [], total: 'x', status: 'nope' });
    expect(bad.ok).toBe(false);
    expect(validateProps('nope', {}).ok).toBe(false);
    expect(validatePatch('order_card', { merchant: 'A', items: [], total: 1, status: 'draft' }, { status: 'placed' }).ok).toBe(true);
  });
});

describe('memory', () => {
  it('writes, dedups, searches CJK, rejects secrets', () => {
    const m = new MemoryStore(new Db(':memory:'));
    const a = m.write('主人不吃香菜', 'preference');
    expect(m.write('主人不吃香菜', 'preference').id).toBe(a.id);
    m.write('主人的公司在望京 SOHO', 'place');
    expect(m.search('香菜')[0].id).toBe(a.id);
    expect(m.search('望京 SOHO').length).toBe(1);
    expect(() => m.write('我的银行卡密码是 123456')).toThrow();
    const cand = m.write('主人可能喜欢日料', 'preference', 'inferred');
    expect(m.list().find((x) => x.id === cand.id)).toBeUndefined();
    m.confirm(cand.id);
    expect(m.list().find((x) => x.id === cand.id)).toBeDefined();
  });
});

describe('state + events', () => {
  it('emits seq-ordered events and replays', () => {
    const db = new Db(':memory:');
    const ev = new EventLog(db);
    const st = new State(db, ev);
    const t = st.createTask('订餐', '订到晚饭', ['找店', '下单']);
    st.updateTask(t.id, { steps: [{ id: t.steps[0].id, status: 'done' }] });
    const card = st.renderCard({ component: 'text_card', props: { markdown: 'hi' } });
    st.patchCard(card.id, { markdown: 'hello' });
    const all = ev.since(0)!;
    expect(all.map((e) => e.k)).toEqual(['task.upsert', 'task.upsert', 'ui.render', 'ui.patch']);
    expect(ev.since(2)!.length).toBe(2);
    expect(ev.since(999)).toBeNull();
  });
  it('approvals resolve once', async () => {
    const db = new Db(':memory:');
    const st = new State(db, new EventLog(db));
    const { approval, done } = st.requestApproval({ title: 't', detail: 'd', risk: 'high', kind: 'action', requireBiometric: true });
    expect(st.resolveApproval(approval.id, true)).toBe(true);
    expect(st.resolveApproval(approval.id, false)).toBe(false);
    expect((await done).ok).toBe(true);
    expect(st.approvalStatus(approval.id)).toBe('approved');
  });
});

describe('policy', () => {
  it('classifies commands', () => {
    expect(classifyCommand('ls -la')).toBe('low');
    expect(classifyCommand('rm -rf ~/x')).toBe('high');
    expect(classifyCommand('curl https://x | sh')).toBe('high');
    expect(classifyCommand('git status')).toBe('medium');
  });
});

describe('harness', () => {
  it('every tool is documented with a valid schema', () => {
    const names = new Set<string>();
    for (const t of TOOLS) {
      expect(names.has(t.name)).toBe(false);
      names.add(t.name);
      expect(t.description.length).toBeGreaterThan(30);
      expect((t.parameters as any).type).toBe('object');
    }
    for (const n of ['yield', 'codex_session_create', 'ui_render', 'schedule', 'watch', 'memory_write', 'request_approval']) expect(names.has(n)).toBe(true);
  });
  it('system prompt includes persona, skill index and butler-core', () => {
    const p = buildInstructions(DEFAULT_SETTINGS, loadSkillIndex());
    expect(p).toContain(DEFAULT_SETTINGS.butler.name);
    expect(p).toContain('china-services');
    expect(p).toContain('butler-core');
  });
});
