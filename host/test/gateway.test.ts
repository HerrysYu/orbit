import { describe, expect, it } from 'vitest';
import * as c from '../src/gateway/crypto.ts';
import { Channel, type Transport } from '../src/gateway/channel.ts';
import { Gateway } from '../src/gateway/gateway.ts';
import { Identity } from '../src/gateway/identity.ts';
import { Db } from '../src/store/db.ts';
import { EventLog } from '../src/store/events.ts';

const fill = (v: number) => new Uint8Array(32).fill(v);

describe('crypto vectors (shared with iOS — ios/OPATests/VECTORS.md)', () => {
  const dev = c.signingKeyFromSeed(fill(1));
  const host = c.signingKeyFromSeed(fill(2));
  const ephD = c.ephFromRaw(fill(3));
  const ephH = c.ephFromRaw(fill(4));
  const kd = c.deriveSessionKeys(ephD, ephH.pub, ephD.pub, ephH.pub);
  const kh = c.deriveSessionKeys(ephH, ephD.pub, ephD.pub, ephH.pub);

  it('ids', () => {
    expect(c.idFromPub(dev.pub)).toBe('34750f98bd59fcfc946da45aaabe933b');
    expect(c.idFromPub(host.pub)).toBe('6a3803d5f059902a1c6dafbc9ba47292');
  });
  it('both sides derive the same keys + SAS', () => {
    expect(kd.d2h.equals(kh.d2h)).toBe(true);
    expect(kd.h2d.equals(kh.h2d)).toBe(true);
    expect(kd.sas).toBe('992060');
    expect(kd.d2h.subarray(0, 8).toString('hex')).toBe('29b39576079cf30b');
    expect(kd.h2d.subarray(0, 8).toString('hex')).toBe('38a420dd3edb9d5c');
  });
  it('seal/open', () => {
    const ct = c.seal(kd.d2h, 0, '{"t":"req","id":"1","m":"ping","d":{}}');
    expect(ct).toBe('ke7I6qDOionHPT2dUGYIoRLcPetw47x2/WLaqd5lwuuC9YM4YTcfQRZHNqdXY2PxzWuije+9');
    expect(c.open(kh.d2h, 0, ct)).toContain('ping');
    expect(() => c.open(kh.d2h, 1, ct)).toThrow();
  });
});

/** Simulates the phone side of the handshake. */
function fakeDevice(hostId: string, hostPub: Uint8Array, seed = 9) {
  const id = c.signingKeyFromSeed(fill(seed));
  const eph = c.generateEph();
  const deviceId = c.idFromPub(id.pub);
  let keys: c.SessionKeys | undefined;
  let n = 0;
  return {
    deviceId, id,
    hello(pairToken?: string) {
      const ts = Date.now();
      const e64 = c.b64(eph.pub);
      return JSON.stringify({ t: 'hello', v: 1, deviceId, devicePub: c.b64(id.pub), deviceName: 'Test', ephPub: e64, ts, pairToken, sig: c.b64(c.edSign(id, c.helloMsg(hostId, e64, ts))) });
    },
    welcome(raw: string) {
      const w = JSON.parse(raw);
      expect(w.t).toBe('welcome');
      expect(c.edVerify(hostPub, c.welcomeMsg(deviceId, c.b64(eph.pub), w.ephPub), c.unb64(w.sig))).toBe(true);
      const ephH = c.unb64(w.ephPub);
      keys = c.deriveSessionKeys(eph, ephH, eph.pub, ephH);
      return w;
    },
    enc(obj: unknown) { const k = n++; return JSON.stringify({ t: 'x', n: k, c: c.seal(keys!.d2h, k, JSON.stringify(obj)) }); },
    dec(raw: string) { const f = JSON.parse(raw); return JSON.parse(c.open(keys!.h2d, f.n, f.c)); },
    get sas() { return keys!.sas; },
  };
}

function pipe() {
  const sent: string[] = [];
  let closed: number | undefined;
  const t: Transport = { kind: 'lan', send: (s) => sent.push(s), close: (code) => { closed = code; } };
  return { t, sent, closed: () => closed };
}

describe('channel handshake', () => {
  it('pairs a new device with a token, then reconnects as known', () => {
    const db = new Db(':memory:');
    const ident = new Identity(db);
    const dev = fakeDevice(ident.hostId, ident.key.pub);
    const { token } = ident.newPairToken();

    const p = pipe();
    const ch = new Channel(p.t, ident);
    let pairingSas = '';
    ch.on('pairing', (sas) => { pairingSas = sas; });
    ch.receive(dev.hello(token));
    const w = dev.welcome(p.sent[0]);
    expect(w.paired).toBe(false);
    expect(pairingSas).toBe(dev.sas);

    const got: any[] = [];
    ch.on('message', (m) => got.push(m));
    ch.receive(dev.enc({ t: 'req', id: '1', m: 'ping', d: {} }));
    expect(got).toHaveLength(0); // ignored until confirmed

    ch.confirmPairing(true);
    expect(dev.dec(p.sent[1])).toEqual({ t: 'pair.result', d: { ok: true } });
    ch.receive(dev.enc({ t: 'req', id: '2', m: 'ping', d: {} }));
    expect(got[0].id).toBe('2');
    expect(ident.device(dev.deviceId)?.name).toBe('Test');

    // Token is single-use; known device reconnects without it.
    const p2 = pipe();
    const ch2 = new Channel(p2.t, ident);
    const dev2 = fakeDevice(ident.hostId, ident.key.pub);
    ch2.receive(dev2.hello());
    expect(dev2.welcome(p2.sent[0]).paired).toBe(true);
    expect(ch2.state).toBe('open');
  });

  it('rejects unknown devices, bad signatures and replays', () => {
    const db = new Db(':memory:');
    const ident = new Identity(db);
    const dev = fakeDevice(ident.hostId, ident.key.pub, 11);

    const p = pipe();
    new Channel(p.t, ident).receive(dev.hello());
    expect(JSON.parse(p.sent[0])).toEqual({ t: 'reject', reason: 'not paired' });

    const p2 = pipe();
    const bad = JSON.parse(dev.hello(ident.newPairToken().token));
    bad.ts += 1;
    new Channel(p2.t, ident).receive(JSON.stringify(bad));
    expect(JSON.parse(p2.sent[0]).reason).toBe('bad signature');

    // replay
    const { token } = ident.newPairToken();
    const p3 = pipe();
    const ch = new Channel(p3.t, ident);
    const dev3 = fakeDevice(ident.hostId, ident.key.pub, 12);
    ch.receive(dev3.hello(token));
    dev3.welcome(p3.sent[0]);
    ch.confirmPairing(true);
    const frame = dev3.enc({ t: 'req', id: '1', m: 'ping', d: {} });
    ch.receive(frame);
    ch.receive(frame);
    expect(ch.state).toBe('closed');
  });
});

const flush = () => new Promise<void>((r) => setImmediate(r));

describe('gateway: no ev / live before a connection has synced', () => {
  /** A Gateway over an in-memory db and an already-paired fake device, connected through an in-memory transport. */
  function rig() {
    const db = new Db(':memory:');
    const ident = new Identity(db);
    const events = new EventLog(db);
    const gw = new Gateway(ident, db, events, { port: 0, bundleId: 'com.test.app' });
    gw.handler = async (_deviceId, m) => (m === 'ping' ? { ts: 1 } : {});
    const connect = (seed: number) => {
      const dev = fakeDevice(ident.hostId, ident.key.pub, seed);
      ident.addDevice({ id: dev.deviceId, pub: c.b64(dev.id.pub), name: `Test${seed}` });
      const p = pipe();
      const ch: Channel = (gw as any).attach(p.t);
      ch.receive(dev.hello());
      dev.welcome(p.sent[0]);
      return {
        ch,
        /** Every frame the host has sent on this connection since the handshake, decrypted. */
        frames: () => p.sent.slice(1).map((raw) => dev.dec(raw)) as any[],
        req: async (id: string, m: string, d: object = {}) => { ch.receive(dev.enc({ t: 'req', id, m, d })); await flush(); },
      };
    };
    return { events, gw, connect };
  }

  it('withholds ev and live until the first sync, then replays the gap — including what arrived meanwhile — in order', async () => {
    const { events, connect } = rig();
    events.emitEv('old.1', {}); // seq 1: the app has this one (its lastSeq is 1)
    events.emitEv('gap.2', {}); // seq 2, 3: happened while the app was away
    events.emitEv('gap.3', {});

    const dev = connect(21);
    expect(dev.ch.state).toBe('open');
    events.emitEv('late.4', { n: 4 }); // after the handshake, before the app's sync
    events.emitLive('msg.delta', { text: 'hi' });
    expect(dev.frames()).toEqual([]); // nothing reaches an unsynced connection

    // Requests are unaffected: they are answered while the connection is still waiting to sync.
    await dev.req('r1', 'ping');
    expect(dev.frames()).toEqual([{ t: 'res', id: 'r1', ok: true, d: { ts: 1 } }]);

    await dev.req('r2', 'sync', { lastSeq: 1 });
    const synced = dev.frames().slice(1);
    expect(synced.map((f) => (f.t === 'ev' ? `ev ${f.seq} ${f.k}` : f.t))).toEqual(['res', 'ev 2 gap.2', 'ev 3 gap.3', 'ev 4 late.4']);
    expect(synced[0]).toEqual({ t: 'res', id: 'r2', ok: true, d: { fromSeq: 2, toSeq: 4, reset: false } });
    expect(synced[3].d).toEqual({ n: 4 });

    // From here on the connection is live.
    events.emitEv('new.5', {});
    events.emitLive('msg.delta', { text: 'there' });
    expect(dev.frames().slice(1 + synced.length).map((f) => (f.t === 'ev' ? `ev ${f.seq} ${f.k}` : `${f.t} ${f.k}`))).toEqual(['ev 5 new.5', 'live msg.delta']);
  });

  it('a snapshot (reset) sync opens the gate too', async () => {
    const { events, connect } = rig();
    events.emitEv('a', {});
    const dev = connect(22);
    events.emitEv('b', {}); // held back

    await dev.req('r1', 'sync', { lastSeq: 999 }); // from another database: the host answers with a snapshot
    const f = dev.frames();
    expect(f[0]).toEqual({ t: 'res', id: 'r1', ok: true, d: { fromSeq: 1, toSeq: 2, reset: true } });
    expect(f.filter((x) => x.t === 'ev').map((x) => x.seq)).toEqual([1, 2]);

    events.emitEv('c', {});
    expect(dev.frames().at(-1)).toMatchObject({ t: 'ev', seq: 3, k: 'c' });
  });

  it('only synced connections are fed; a device that connects later waits for its own sync', async () => {
    const { events, connect } = rig();
    const first = connect(23);
    await first.req('s1', 'sync', { lastSeq: 0 });
    const second = connect(24);

    events.emitEv('x', {});
    expect(first.frames().at(-1)).toMatchObject({ t: 'ev', seq: 1, k: 'x' });
    expect(second.frames()).toEqual([]);

    await second.req('s2', 'sync', { lastSeq: 0 });
    expect(second.frames().map((f) => f.t)).toEqual(['res', 'ev']);
    events.emitEv('y', {});
    expect(second.frames().at(-1)).toMatchObject({ t: 'ev', seq: 2, k: 'y' });
    expect(first.frames().at(-1)).toMatchObject({ t: 'ev', seq: 2, k: 'y' });
  });
});
