#!/usr/bin/env node
// Scripted stand-in for `codex app-server` used by tests. Script comes from FAKE_CODEX_SCRIPT (JSON):
// [{ "steps": [ {"say":"text"} | {"tool":"name","args":{…}} | {"wait":ms} ] }, …]  — one entry per brain turn.
// Any thread other than the first one created just answers "ok". Every request it receives is appended to FAKE_CODEX_LOG.
import { createInterface } from 'node:readline';

const script = JSON.parse(process.env.FAKE_CODEX_SCRIPT ?? '[]');
const log = process.env.FAKE_CODEX_LOG;
let n = 0, threadN = 0, brain;
const pending = new Map();
const out = (o) => process.stdout.write(JSON.stringify(o) + '\n');
const req = (method, params) => new Promise((r) => { const id = `s${++n}`; pending.set(id, r); out({ id, method, params }); });
const turns = new Map(); // turnId -> { interrupted, steered: [] }
import { appendFileSync } from 'node:fs';
const note = (o) => log && appendFileSync(log, JSON.stringify(o) + '\n');

async function runTurn(threadId, turnId, input) {
  out({ method: 'turn/started', params: { threadId, turn: { id: turnId, items: [], status: 'inProgress' } } });
  const st = turns.get(turnId);
  const plan = threadId === brain ? (script.shift() ?? { steps: [{ say: '（脚本结束）' }] }) : { steps: [{ say: 'ok' }] };
  let k = 0;
  for (const step of plan.steps) {
    if (st.interrupted) break;
    if (step.wait) await new Promise((r) => setTimeout(r, step.wait));
    if (step.say) {
      const itemId = `m${turnId}_${k++}`;
      for (const ch of step.say.match(/.{1,2}/gu) ?? []) {
        if (st.interrupted) break;
        out({ method: 'item/agentMessage/delta', params: { threadId, turnId, itemId, delta: ch } });
        await new Promise((r) => setTimeout(r, step.slow ?? 2));
      }
      if (!st.interrupted) out({ method: 'item/completed', params: { threadId, turnId, item: { type: 'agentMessage', id: itemId, text: step.say } } });
    }
    if (step.tool) {
      const r = await req('item/tool/call', { threadId, turnId, callId: `c${k++}`, namespace: null, tool: step.tool, arguments: step.args ?? {} });
      note({ tool: step.tool, result: r.result });
    }
  }
  out({ method: 'turn/completed', params: { threadId, turn: { id: turnId, items: [], status: st.interrupted ? 'interrupted' : 'completed', error: null } } });
}

createInterface({ input: process.stdin }).on('line', (line) => {
  const m = JSON.parse(line);
  if (m.id !== undefined && !m.method) { pending.get(m.id)?.(m); pending.delete(m.id); return; }
  if (!m.method || m.id === undefined) return;
  note({ method: m.method, params: m.params });
  const reply = (result) => out({ id: m.id, result });
  switch (m.method) {
    case 'initialize': return reply({ userAgent: 'fake' });
    // FAKE_CODEX_MODELS (JSON array of Model objects) replaces the one-model catalog.
    case 'model/list': return reply({ data: process.env.FAKE_CODEX_MODELS ? JSON.parse(process.env.FAKE_CODEX_MODELS) : [{ id: 'gpt-x', displayName: 'GPT X', description: '', hidden: false, isDefault: true }] });
    case 'thread/start': {
      const id = `t${++threadN}`;
      if (!brain && m.params?.dynamicTools) brain = id;
      return reply({ thread: { id }, model: m.params?.model ?? 'gpt-x' });
    }
    case 'thread/resume': return reply({ thread: { id: m.params.threadId }, model: 'gpt-x' });
    case 'turn/start': {
      const turnId = `u${++n}`;
      turns.set(turnId, { interrupted: false, steered: [] });
      reply({ turn: { id: turnId, items: [], status: 'inProgress' } });
      setTimeout(() => void runTurn(m.params.threadId, turnId, m.params.input), 5);
      return;
    }
    case 'turn/steer': turns.get(m.params.expectedTurnId)?.steered.push(m.params.input); return reply({});
    case 'turn/interrupt': { const t = turns.get(m.params.turnId); if (t) t.interrupted = true; return reply({}); }
    default: return reply({});
  }
});
