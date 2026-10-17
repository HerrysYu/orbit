// One authenticated, encrypted device connection — protocol.md §2. Transport-agnostic.
import { EventEmitter } from 'node:events';
import {
  b64, deriveSessionKeys, edSign, edVerify, generateEph, helloMsg, idFromPub, open, seal, unb64, welcomeMsg,
  type SessionKeys,
} from './crypto.ts';
import type { Identity } from './identity.ts';
import { log } from '../util/log.ts';

export interface Transport { send(s: string): void; close(code?: number, reason?: string): void; kind: 'lan' | 'relay' }

const MAX_SKEW = 5 * 60_000;

/**
 * Lifecycle: 'handshake' → 'pairing' (new device, waiting for SAS confirm on the Mac) → 'open'.
 * Events: 'pairing' (sas, deviceName) | 'open' | 'message' (obj) | 'close'
 */
export class Channel extends EventEmitter {
  state: 'handshake' | 'pairing' | 'open' | 'closed' = 'handshake';
  deviceId?: string;
  deviceName?: string;
  devicePub?: string;
  sas?: string;
  /**
   * True once the host has answered this connection's first `sync` (replay included). Until then the gateway pushes no
   * `ev` / `live` to it: a fresh `ev` arriving before `sync` would advance the app's lastSeq past the gap it still has to fill.
   */
  synced = false;
  private keys?: SessionKeys;
  private sendN = 0;
  private recvN = -1;

  constructor(readonly transport: Transport, private id: Identity) { super(); }

  /** Feed one raw text frame from the transport. */
  receive(raw: string) {
    let f: any;
    try { f = JSON.parse(raw); } catch { return this.fail('bad json'); }
    if (this.state === 'handshake') return this.onHello(f);
    if (f.t !== 'x' || typeof f.n !== 'number' || typeof f.c !== 'string') return this.fail('expected encrypted frame');
    if (f.n <= this.recvN) return this.fail('replayed nonce');
    let plain: string;
    try { plain = open(this.keys!.d2h, f.n, f.c); } catch { return this.fail('decrypt failed'); }
    this.recvN = f.n;
    let msg: any;
    try { msg = JSON.parse(plain); } catch { return this.fail('bad inner json'); }
    if (this.state === 'pairing') return; // nothing accepted until the Mac user confirms
    this.emit('message', msg);
  }

  private onHello(f: any) {
    if (f.t !== 'hello' || f.v !== 1) return this.fail('expected hello');
    const devicePub = unb64(String(f.devicePub ?? ''));
    const ephD = unb64(String(f.ephPub ?? ''));
    if (devicePub.length !== 32 || ephD.length !== 32) return this.fail('bad keys');
    if (idFromPub(devicePub) !== f.deviceId) return this.fail('deviceId mismatch');
    if (Math.abs(Date.now() - Number(f.ts)) > MAX_SKEW) return this.fail('clock skew');
    if (!edVerify(devicePub, helloMsg(this.id.hostId, f.ephPub, f.ts), unb64(String(f.sig ?? '')))) return this.fail('bad signature');

    const known = this.id.device(f.deviceId);
    let paired: boolean;
    if (known && known.pub === f.devicePub) paired = true;
    else if (this.id.consumePairToken(f.pairToken)) paired = false;
    else return this.fail(known ? 'device key changed' : 'not paired');

    const eph = generateEph();
    this.keys = deriveSessionKeys(eph, ephD, ephD, eph.pub);
    this.deviceId = f.deviceId;
    this.devicePub = f.devicePub;
    this.deviceName = String(f.deviceName ?? 'iPhone').slice(0, 64);
    this.sas = this.keys.sas;
    const ephH64 = b64(eph.pub);
    this.transport.send(JSON.stringify({
      t: 'welcome', v: 1, ephPub: ephH64, paired, hostName: this.id.hostName,
      sig: b64(edSign(this.id.key, welcomeMsg(f.deviceId, f.ephPub, ephH64))),
    }));
    if (paired) {
      this.state = 'open';
      this.id.touch(f.deviceId);
      this.emit('open');
    } else {
      this.state = 'pairing';
      this.emit('pairing', this.sas, this.deviceName);
    }
  }

  /** Called after the Mac user confirms (or rejects) the SAS. */
  confirmPairing(ok: boolean) {
    if (this.state !== 'pairing') return;
    this.send({ t: 'pair.result', d: { ok } });
    if (!ok) return this.close(4003, 'pairing rejected');
    this.id.addDevice({ id: this.deviceId!, pub: this.devicePub!, name: this.deviceName! });
    this.state = 'open';
    this.emit('open');
  }

  send(obj: unknown) {
    if (!this.keys || this.state === 'closed') return;
    const n = this.sendN++;
    this.transport.send(JSON.stringify({ t: 'x', n, c: seal(this.keys.h2d, n, JSON.stringify(obj)) }));
  }

  private fail(reason: string) {
    log.warn('gateway', `channel rejected (${this.transport.kind}): ${reason}`);
    if (this.state === 'handshake') {
      try { this.transport.send(JSON.stringify({ t: 'reject', reason })); } catch { /* ignore */ }
    }
    this.close(4001, reason);
  }

  close(code = 1000, reason = '') {
    if (this.state === 'closed') return;
    this.state = 'closed';
    try { this.transport.close(code, reason); } catch { /* ignore */ }
    this.emit('close');
  }

  /** Transport went away underneath us. */
  dropped() {
    if (this.state === 'closed') return;
    this.state = 'closed';
    this.emit('close');
  }
}
