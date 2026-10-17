// Gateway: LAN WebSocket server + Relay client + Bonjour; routes encrypted app frames — protocol.md §3–4.
import { EventEmitter } from 'node:events';
import { createServer } from 'node:http';
import { WebSocketServer, WebSocket } from 'ws';
import { Bonjour } from 'bonjour-service';
import { Channel, type Transport } from './channel.ts';
import { Identity } from './identity.ts';
import { b64url, edSign, relayHostMsg } from './crypto.ts';
import type { EventLog, Ev, Live } from '../store/events.ts';
import type { Db } from '../store/db.ts';
import { log } from '../util/log.ts';

export type ReqHandler = (deviceId: string, m: string, d: any) => Promise<unknown>;

export interface PushRequest {
  pushType: 'alert' | 'liveactivity' | 'background';
  kind?: 'alert' | 'liveactivity' | 'pushToStart';
  payload: Record<string, unknown>;
  collapseId?: string;
  priority?: 5 | 10;
  taskId?: string;
}

export interface GatewayOpts { port: number; relayUrl?: string; bundleId: string }

/** Sent pushes remembered (push id → device token) while the relay's `push_result` is outstanding; the oldest go first. */
const MAX_PENDING_PUSHES = 1000;
/** APNs `reason`s (besides any 410) that mean the device token is dead for good. */
const DEAD_TOKEN_REASONS = new Set(['BadDeviceToken', 'Unregistered', 'ExpiredToken']);

/** Events: 'pairing' (channel) — the CLI shows the SAS prompt; 'device_open' (deviceId) */
export class Gateway extends EventEmitter {
  readonly channels = new Set<Channel>();
  handler: ReqHandler = async () => { throw new Error('no handler'); };
  private relay?: WebSocket;
  private relayChannels = new Map<string, Channel>();
  private relayBackoff = 1000;
  private relayConnected = false;
  private bonjour?: Bonjour;
  private wss?: WebSocketServer;
  private pushSeq = 0;
  /** The relay's `push_result` carries the push id but not the token, so remember which token each push went to. */
  private pendingPushes = new Map<string, { token: string; topic: string }>();
  private warnedPushReasons = new Set<string>();

  constructor(readonly id: Identity, private db: Db, private log_: EventLog, readonly opts: GatewayOpts) {
    super();
    log_.on('ev', (ev: Ev) => this.broadcast(ev));
    log_.on('live', (lv: Live) => this.broadcast(lv));
  }

  get onlineDevices(): string[] {
    return [...this.channels].filter((c) => c.state === 'open').map((c) => c.deviceId!);
  }

  start() {
    const http = createServer((req, res) => {
      if (req.url === '/healthz') { res.writeHead(200).end('ok'); return; }
      res.writeHead(404).end();
    });
    this.wss = new WebSocketServer({ server: http, path: '/v1/ws', maxPayload: 16 * 1024 * 1024 });
    this.wss.on('connection', (ws) => {
      const t: Transport = { kind: 'lan', send: (s) => ws.send(s), close: (c, r) => ws.close(c, r) };
      const ch = this.attach(t);
      ws.on('message', (data) => ch.receive(data.toString()));
      ws.on('close', () => ch.dropped());
      ws.on('error', () => ch.dropped());
    });
    http.listen(this.opts.port, () => log.info('gateway', `LAN listening on :${this.opts.port}`));
    try {
      this.bonjour = new Bonjour();
      this.bonjour.publish({ name: `OPA-${this.id.hostId.slice(0, 8)}`, type: 'opa', port: this.opts.port, txt: { hostId: this.id.hostId } });
    } catch (e) { log.warn('gateway', 'bonjour failed', e); }
    if (this.opts.relayUrl) this.connectRelay();
  }

  stop() {
    this.relay?.close();
    this.bonjour?.unpublishAll();
    this.wss?.close();
  }

  private attach(t: Transport): Channel {
    const ch = new Channel(t, this.id);
    this.channels.add(ch);
    ch.on('pairing', () => { this.syncRelayAllow(); this.emit('pairing', ch); });
    ch.on('open', () => {
      log.info('gateway', `device ${ch.deviceName} (${ch.deviceId?.slice(0, 8)}) connected via ${t.kind}`);
      this.syncRelayAllow();
      this.emit('device_open', ch.deviceId);
    });
    ch.on('message', (m) => void this.onMessage(ch, m));
    ch.on('close', () => this.channels.delete(ch));
    return ch;
  }

  private async onMessage(ch: Channel, m: any) {
    if (m?.t !== 'req' || typeof m.m !== 'string') return;
    try {
      const d = await this.handler(ch.deviceId!, m.m, m.d ?? {});
      if (m.m === 'sync') return this.doSync(ch, m.id, m.d?.lastSeq ?? 0);
      ch.send({ t: 'res', id: m.id, ok: true, d: d ?? {} });
    } catch (e: any) {
      log.warn('gateway', `req ${m.m} failed:`, e?.message ?? e);
      ch.send({ t: 'res', id: m.id, ok: false, err: String(e?.message ?? e) });
    }
  }

  private doSync(ch: Channel, reqId: string, lastSeq: number) {
    const evs = this.log_.since(lastSeq);
    const top = this.log_.lastSeq();
    if (evs) {
      ch.send({ t: 'res', id: reqId, ok: true, d: { fromSeq: lastSeq + 1, toSeq: top, reset: false } });
      for (const ev of evs) ch.send(ev);
    } else {
      // Snapshot: replay the most recent window only; handler-level state (tasks/settings) is re-emitted by the app layer.
      const from = Math.max(0, top - 500);
      ch.send({ t: 'res', id: reqId, ok: true, d: { fromSeq: from + 1, toSeq: top, reset: true } });
      for (const ev of this.log_.since(from) ?? []) ch.send(ev);
    }
    // Same synchronous stretch as the replay: no new `ev` can land between the replay and going live.
    ch.synced = true;
  }

  /**
   * Only connections that have synced get `ev` / `live`. Before its first `sync` an app still has a gap to fill, and a
   * fresh `ev` would move its lastSeq past that gap. What a connection misses meanwhile is in the event log, which its
   * `sync` replays; `live` is ephemeral anyway.
   */
  private broadcast(frame: Ev | Live) {
    for (const ch of this.channels) if (ch.state === 'open' && ch.synced) ch.send(frame);
  }

  // ───────────── relay ─────────────

  private connectRelay() {
    const ts = Date.now();
    const sig = b64url(edSign(this.id.key, relayHostMsg(this.id.hostId, ts)));
    const url = `${this.opts.relayUrl!.replace(/\/$/, '')}/v1/host/${this.id.hostId}?pub=${b64url(this.id.key.pub)}&ts=${ts}&sig=${sig}`;
    const ws = new WebSocket(url);
    this.relay = ws;
    ws.on('open', () => {
      log.info('gateway', 'relay connected');
      this.relayConnected = true;
      this.relayBackoff = 1000;
      this.syncRelayAllow();
    });
    ws.on('message', (data) => this.onRelayFrame(data.toString()));
    ws.on('close', (code) => {
      this.relayConnected = false;
      for (const ch of this.relayChannels.values()) ch.dropped();
      this.relayChannels.clear();
      const wait = Math.min(this.relayBackoff, 60_000) * (0.75 + Math.random() * 0.5);
      this.relayBackoff *= 2;
      log.warn('gateway', `relay closed (${code}); retry in ${Math.round(wait / 1000)}s`);
      setTimeout(() => this.connectRelay(), wait);
    });
    ws.on('error', (e) => log.debug('gateway', 'relay error', e.message));
  }

  private onRelayFrame(raw: string) {
    let f: any;
    try { f = JSON.parse(raw); } catch { return; }
    if (f.relay === 'device_connected') {
      this.relayChannels.get(f.deviceId)?.dropped();
      this.relayChannels.delete(f.deviceId);
      return;
    }
    if (f.relay === 'device_disconnected') {
      this.relayChannels.get(f.deviceId)?.dropped();
      this.relayChannels.delete(f.deviceId);
      return;
    }
    if (f.relay === 'push_result') { this.onPushResult(f); return; }
    if (typeof f.from === 'string' && typeof f.data === 'string') {
      let ch = this.relayChannels.get(f.from);
      if (!ch || ch.state === 'closed') {
        const deviceId = f.from;
        const t: Transport = {
          kind: 'relay',
          send: (s) => this.relay?.readyState === WebSocket.OPEN && this.relay.send(JSON.stringify({ to: deviceId, data: s })),
          close: () => this.relayChannels.delete(deviceId),
        };
        ch = this.attach(t);
        this.relayChannels.set(deviceId, ch);
      }
      ch.receive(f.data);
    }
  }

  syncRelayAllow() {
    if (!this.relayConnected || !this.relay) return;
    this.relay.send(JSON.stringify({ relay: 'allow', devices: this.id.devices().map((d) => ({ id: d.id, pub: d.pub })) }));
    const until = this.id.pairingOpenUntil();
    if (until > Date.now()) this.relay.send(JSON.stringify({ relay: 'pairing', until }));
  }

  // ───────────── push ─────────────

  /** Send an APNs push to every registered device token of `kind` (via the relay). No-op without relay. */
  push(p: PushRequest): number {
    if (!this.relayConnected || !this.relay) return 0;
    const kind = p.kind ?? (p.pushType === 'liveactivity' ? 'liveactivity' : 'alert');
    const rows = this.db.sql.prepare('SELECT token, env, task_id, bundle_id FROM push_tokens WHERE kind = ?').all(kind) as any[];
    let n = 0;
    for (const r of rows) {
      if (kind === 'liveactivity' && p.taskId && r.task_id !== p.taskId) continue;
      // The topic is the bundle id of the app the token belongs to: the one it reported, else the configured default.
      const bundleId: string = r.bundle_id ?? this.opts.bundleId;
      const topic = kind === 'alert' ? bundleId : `${bundleId}.push-type.liveactivity`;
      const id = `p${++this.pushSeq}`;
      this.pendingPushes.set(id, { token: r.token, topic });
      while (this.pendingPushes.size > MAX_PENDING_PUSHES) this.pendingPushes.delete(this.pendingPushes.keys().next().value!);
      this.relay.send(JSON.stringify({
        relay: 'push', id, deviceToken: r.token, env: r.env,
        pushType: p.pushType, topic, priority: p.priority ?? 10, collapseId: p.collapseId, expiration: 0, payload: p.payload,
      }));
      n++;
    }
    return n;
  }

  /** `{relay:'push_result', id, status, reason?}` — the answer to one `push`; drops tokens APNs says are dead. */
  private onPushResult(f: { id?: unknown; status?: unknown; reason?: unknown }) {
    const sent = typeof f.id === 'string' ? this.pendingPushes.get(f.id) : undefined;
    if (typeof f.id === 'string') this.pendingPushes.delete(f.id);
    const status = Number(f.status);
    const reason = typeof f.reason === 'string' ? f.reason : '';
    if (status === 200) return;

    // Configuration problems, not dead tokens: keep the token, and say what to fix once rather than on every push.
    if (reason === 'ApnsNotConfigured') {
      this.warnPushOnce(reason, `APNs ${status} ${reason}：Relay 还没配置 APNs 密钥（APNS_KEY_P8 / APNS_KEY_ID / APNS_TEAM_ID），见 relay/README.md`);
      return;
    }
    if (reason === 'DeviceTokenNotForTopic') {
      this.warnPushOnce(reason, `APNs ${status} ${reason}：推送 topic${sent ? `「${sent.topic}」` : ''}和 App 的 bundle id 对不上，token 已保留。` +
        'topic 取 App 在 push.register 里上报的 bundleId，没上报时取 `opa config bundle-id`（默认 com.haoyuanyu.orbit）。');
      return;
    }

    log.warn('push', `APNs ${f.status} ${reason}`);
    if (sent && (status === 410 || DEAD_TOKEN_REASONS.has(reason))) {
      const r = this.db.sql.prepare('DELETE FROM push_tokens WHERE token = ?').run(sent.token);
      if (r.changes) log.info('push', `removed dead push token …${sent.token.slice(-6)}`);
    }
  }

  private warnPushOnce(key: string, msg: string) {
    if (this.warnedPushReasons.has(key)) return log.debug('push', msg);
    this.warnedPushReasons.add(key);
    log.warn('push', msg);
  }
}
