// Local control socket (~/.opa/control.sock, 0600): lets `opa pair` / `opa chat` talk to the running host.
// Newline-delimited JSON. Only reachable by the local user — it never leaves the machine.
import { createServer, createConnection, type Socket } from 'node:net';
import { chmodSync, existsSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { OPA_HOME } from './store/db.ts';
import type { Host } from './app.ts';
import type { Channel } from './gateway/channel.ts';
import { Identity } from './gateway/identity.ts';

export const CONTROL_SOCK = join(OPA_HOME, 'control.sock');

export function startControl(host: Host) {
  if (existsSync(CONTROL_SOCK)) unlinkSync(CONTROL_SOCK);
  const pendingPair = new Map<string, Channel>();
  const clients = new Set<Socket>();

  host.gw.on('pairing', (ch: Channel) => {
    const key = ch.sas!;
    pendingPair.set(key, ch);
    ch.once('close', () => pendingPair.delete(key));
    for (const c of clients) c.write(JSON.stringify({ t: 'pairing', sas: ch.sas, deviceName: ch.deviceName, deviceId: ch.deviceId }) + '\n');
  });
  const fwd = (f: unknown) => { for (const c of clients) if ((c as any).wantsEvents) c.write(JSON.stringify(f) + '\n'); };
  host.ev.on('ev', fwd);
  host.ev.on('live', fwd);

  const srv = createServer((sock) => {
    clients.add(sock);
    sock.setEncoding('utf8');
    let buf = '';
    sock.on('data', async (d: string) => {
      buf += d;
      let i: number;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i); buf = buf.slice(i + 1);
        let m: any;
        try { m = JSON.parse(line); } catch { continue; }
        const reply = (x: object) => sock.write(JSON.stringify({ id: m.id, ...x }) + '\n');
        try {
          if (m.cmd === 'pair') {
            const { token, exp } = host.id.newPairToken();
            host.gw.syncRelayAllow();
            const payload = {
              v: 1, hostId: host.id.hostId, hostPub: host.id.pubB64, hostName: host.id.hostName,
              lan: Identity.lanAddrs(host.cfg.port), relay: host.cfg.relayUrl ?? null, pairToken: token, exp,
            };
            reply({ ok: true, link: `opa://pair?d=${Buffer.from(JSON.stringify(payload)).toString('base64url')}`, payload });
          } else if (m.cmd === 'confirm') {
            const ch = pendingPair.get(m.sas);
            if (!ch) reply({ ok: false, err: 'no such pairing' });
            else { ch.confirmPairing(!!m.ok); pendingPair.delete(m.sas); reply({ ok: true }); }
          } else if (m.cmd === 'events') {
            (sock as any).wantsEvents = true;
            reply({ ok: true });
          } else if (m.cmd === 'req') {
            const d = await (host.gw.handler)('local-cli', m.m, m.d ?? {});
            reply({ ok: true, d });
          } else if (m.cmd === 'status') {
            reply({ ok: true, d: { hostId: host.id.hostId, devices: host.id.devices().length, online: host.gw.onlineDevices, relay: host.cfg.relayUrl } });
          } else if (m.cmd === 'unpair') {
            host.id.removeDevice(String(m.deviceId));
            host.gw.syncRelayAllow();
            for (const ch of host.gw.channels) if (ch.deviceId === m.deviceId) ch.close(4003, 'unpaired');
            reply({ ok: true });
          } else reply({ ok: false, err: 'unknown cmd' });
        } catch (e: any) {
          reply({ ok: false, err: String(e?.message ?? e) });
        }
      }
    });
    sock.on('close', () => clients.delete(sock));
    sock.on('error', () => clients.delete(sock));
  });
  srv.listen(CONTROL_SOCK, () => chmodSync(CONTROL_SOCK, 0o600));
  return srv;
}

/** Client side used by the CLI. */
export function controlClient(onFrame: (f: any) => void): Promise<{ send: (m: object) => Promise<any>; close: () => void }> {
  return new Promise((resolve, reject) => {
    const sock = createConnection(CONTROL_SOCK);
    let n = 0, buf = '';
    const pending = new Map<number, (v: any) => void>();
    sock.setEncoding('utf8');
    sock.on('error', reject);
    sock.on('data', (d: string) => {
      buf += d;
      let i: number;
      while ((i = buf.indexOf('\n')) >= 0) {
        const f = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1);
        if (f.id !== undefined && pending.has(f.id)) { pending.get(f.id)!(f); pending.delete(f.id); } else onFrame(f);
      }
    });
    sock.on('connect', () => resolve({
      send: (m) => new Promise((r) => { const id = ++n; pending.set(id, r); sock.write(JSON.stringify({ ...m, id }) + '\n'); }),
      close: () => sock.end(),
    }));
  });
}
