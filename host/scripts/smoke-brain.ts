// Live smoke test of the bot brain on real Codex (uses the logged-in ChatGPT plan).
// Usage: OPA_HOME=/tmp/opa-brain npx tsx scripts/smoke-brain.ts "记住我不吃香菜"
import { EventEmitter } from 'node:events';
import { Db } from '../src/store/db.ts';
import { EventLog } from '../src/store/events.ts';
import { Butler } from '../src/butler/butler.ts';
import { CodexBridge } from '../src/codex/bridge.ts';

const db = new Db();
const ev = new EventLog(db);
const gw = Object.assign(new EventEmitter(), { onlineDevices: ['cli'], push: () => 0 }) as any;
const bridge = new CodexBridge();
const b = new Butler(db, ev, bridge, gw);
db.set('settings', { ...b.settings(), models: { butler: process.env.BOT_MODEL ?? 'gpt-6-luna', heartbeat: '' } });
ev.on('live', (e) => {
  if (e.k === 'msg.delta') process.stdout.write(e.d.text);
  if (e.k === 'butler.status' && e.d.state === 'acting') console.log(`\n  · tool ${e.d.detail}`);
});
ev.on('ev', (e) => {
  if (e.k === 'msg.assistant') console.log(`\n[msg.assistant] ${e.d.text}`);
  else if (e.k !== 'session.upsert' && e.k !== 'task.upsert') console.log(`[${e.k}] ${JSON.stringify(e.d).slice(0, 300)}`);
  // SMOKE_APPROVE=1 plays the user and approves every approval request after 1s.
  if (e.k === 'approval.request' && process.env.SMOKE_APPROVE) setTimeout(() => b.approvalResponse(e.d.id, true), 1000);
});
b.start();
b.userMessage(process.argv[2] ?? '你好，你是谁？能做什么？', 'cli');
const t0 = Date.now();
await new Promise((r) => setTimeout(r, 1000));
while (((b as any).running || (b as any).inbox.length || [...bridge.sessions.values()].some((s) => s.status === "running")) && Date.now() - t0 < Number(process.env.SMOKE_MS ?? 180_000)) await new Promise((r) => setTimeout(r, 500));
console.log(`\n done in ${Math.round((Date.now() - t0) / 1000)}s`);
bridge.rpc.stop();
process.exit(0);
