// request_approval's `detail` convention (protocol.md §4.5): multi-line「标签：内容」+ a final「批准后：…」line.
import { describe, expect, it } from 'vitest';
import { State } from '../src/butler/state.ts';
import { TOOL_MAP } from '../src/butler/tools.ts';
import { Db } from '../src/store/db.ts';
import { EventLog } from '../src/store/events.ts';

describe('request_approval tool', () => {
  const tool = TOOL_MAP.get('request_approval')!;

  it('tells the model how to write detail', () => {
    for (const text of [tool.description, (tool.parameters as any).properties.detail.description]) {
      expect(text).toContain('标签：内容');
      expect(text).toContain('批准后：');
      expect(text).toMatch(/最后(单独再写)?一行以「批准后：」开头/); // the instruction itself, not only an example
    }
    // The agreed examples are in the description, and the rest of it is still there.
    for (const example of ['餐厅：鮨 · 静安店', '时间：10月18日 周六 19:00', '费用：人均约 ¥280，到店付款']) expect(tool.description).toContain(example);
    expect(tool.description).toContain('高风险动作');
    expect(tool.description).toContain('approval_result');
    expect(tool.description).toContain('非阻塞');
    expect((tool.parameters as any).required).toEqual(['title', 'detail']);
  });

  it('stores a multi-line detail verbatim and puts it on the approval.request event', async () => {
    const db = new Db(':memory:');
    const ev = new EventLog(db);
    const state = new State(db, ev);
    const rt: any = {
      state,
      notifier: { notify: () => '' },
      currentMsgId: () => undefined,
    };
    const detail = ['餐厅：鮨 · 静安店', '时间：10月18日 周六 19:00', '费用：人均约 ¥280，到店付款', '批准后：我会向餐厅提交预订，并把结果告诉你'].join('\n');

    const out = await tool.run({ title: '预订周六晚餐', detail }, rt) as { approval_id: string };

    const request = ev.since(0)!.find((e) => e.k === 'approval.request')!;
    expect(request.d).toMatchObject({ id: out.approval_id, title: '预订周六晚餐', detail, kind: 'action', risk: 'high' });
    expect(state.pendingApprovals().find((a) => a.id === out.approval_id)!.detail).toBe(detail);
  });
});
