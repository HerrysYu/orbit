// End-to-end smoke: start the host on a temp OPA_HOME, pair a simulated phone over LAN, exercise app methods.
// Usage: OPA_HOME=/tmp/opa-e2e OPA_PORT=7499 npx tsx scripts/smoke-host.ts
import WebSocket from 'ws';
import * as c from '../src/gateway/crypto.ts';
import { Host } from '../src/app.ts';

const host = new Host();
await host.start();
host.gw.on('pairing', (ch) => { console.log('pairing SAS', ch.sas); ch.confirmPairing(true); });

const { token } = host.id.newPairToken();
const id = c.generateSigningKey();
const eph = c.generateEph();
const deviceId = c.idFromPub(id.pub);
const ws = new WebSocket(`ws://127.0.0.1:${host.cfg.port}/v1/ws`);
let keys: c.SessionKeys;
let n = 0;
const pending = new Map<string, (v: any) => void>();
const events: any[] = [];
const req = (m: string, d: object = {}) => new Promise<any>((r) => {
  const rid = String(++n);
  pending.set(rid, r);
  const k = n - 1;
  ws.send(JSON.stringify({ t: 'x', n: k, c: c.seal(keys.d2h, k, JSON.stringify({ t: 'req', id: rid, m, d })) }));
});

await new Promise<void>((resolve) => {
  ws.on('open', () => {
    const ts = Date.now(), e64 = c.b64(eph.pub);
    ws.send(JSON.stringify({ t: 'hello', v: 1, deviceId, devicePub: c.b64(id.pub), deviceName: 'Smoke iPhone', ephPub: e64, ts, pairToken: token, sig: c.b64(c.edSign(id, c.helloMsg(host.id.hostId, e64, ts))) }));
  });
  ws.on('message', (raw) => {
    const f = JSON.parse(raw.toString());
    if (f.t === 'welcome') {
      if (!c.edVerify(host.id.key.pub, c.welcomeMsg(deviceId, c.b64(eph.pub), f.ephPub), c.unb64(f.sig))) throw new Error('bad welcome sig');
      const ephH = c.unb64(f.ephPub);
      keys = c.deriveSessionKeys(eph, ephH, eph.pub, ephH);
      console.log('welcome paired=', f.paired, 'SAS', keys.sas);
      return;
    }
    if (f.t !== 'x') { console.log('frame', f); return; }
    const m = JSON.parse(c.open(keys.h2d, f.n, f.c));
    if (m.t === 'pair.result') { console.log('pair.result', m.d); resolve(); return; }
    if (m.t === 'res') { pending.get(m.id)?.(m); pending.delete(m.id); return; }
    events.push(m);
  });
});

console.log('ping', (await req('ping')).ok);
console.log('settings', (await req('settings.get')).d.butler.name);
await req('context.update', { timezone: 'Asia/Shanghai', locale: 'zh-CN', now: Date.now(), deviceName: 'Smoke iPhone', network: 'wifi' });
const mem = await req('memory.add', { text: '主人不吃香菜', kind: 'preference' });
console.log('memory.add', mem.ok, mem.d?.id);
console.log('memory.list', (await req('memory.list')).d.items.length);
const models = await req('models.list');
console.log('models.list ok', models.ok, 'butler', models.d?.butler?.length, 'codex', models.d?.codex?.map((x: any) => x.id).join(','));
const sync = await req('sync', { lastSeq: 0 });
console.log('sync', sync.d);
await new Promise((r) => setTimeout(r, 300));
console.log('events', events.map((e) => `${e.t}:${e.k}`).join(' '));
const st = host.butler.statusBar();
console.log('--- status bar ---\n' + st);
if (process.env.OPENAI_API_KEY || process.argv.includes('--chat')) {
  await req('chat.send', { clientId: 'x1', text: process.argv[process.argv.indexOf('--chat') + 1] ?? '你好，你是谁？' });
  await new Promise((r) => setTimeout(r, 60_000));
  console.log('chat events', events.filter((e) => e.t === 'ev').map((e) => `${e.k}:${JSON.stringify(e.d).slice(0, 200)}`).join('\n'));
}
ws.close();
host.gw.stop();
host.bridge.rpc.stop();
process.exit(0);
