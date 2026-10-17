// HostRelay: one Durable Object per hostId. Uses the WebSocket Hibernation API so idle
// connections cost nothing; all durable state (allowlist, pairing window) is in DO storage.
import { DurableObject } from "cloudflare:workers";
import { sendPush } from "./apns";
import { utf8ByteLength } from "./encoding";
import type { Env } from "./env";
import {
  CLOSE_NOT_ALLOWED,
  CLOSE_RATE_LIMIT,
  CLOSE_REPLACED,
  HOST_OFFLINE,
  HOST_ONLINE,
  MAX_DEVICE_FRAME_BYTES,
  type PushRequest,
  type RelayState,
  type TokenBucket,
  deviceConnectedFrame,
  deviceDisconnectedFrame,
  isDeviceAllowed,
  newBucket,
  normalizeAllowList,
  parseHostFrame,
  pushResultFrame,
  takeToken,
  wrapDeviceFrame,
} from "./protocol";

type Attachment =
  | { role: "host"; replaced?: boolean }
  | { role: "device"; deviceId: string; pub: string; pair: boolean; replaced?: boolean };

const HOST_TAG = "host";
const deviceTag = (id: string) => `device:${id}`;
const STATE_KEY = "state";

function safeSend(ws: WebSocket, msg: string): boolean {
  try {
    ws.send(msg);
    return true;
  } catch {
    return false;
  }
}

function safeClose(ws: WebSocket, code: number, reason: string): void {
  try {
    ws.close(code, reason);
  } catch {
    // already closed
  }
}

export class HostRelay extends DurableObject<Env> {
  private state: RelayState = { allow: [], pairingUntil: 0 };
  /** In-memory only; resets to a full bucket after hibernation, which is acceptable. */
  private buckets = new Map<string, TokenBucket>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      const s = await ctx.storage.get<RelayState>(STATE_KEY);
      if (s) this.state = s;
    });
  }

  private async saveState(): Promise<void> {
    await this.ctx.storage.put(STATE_KEY, this.state);
  }

  private attachment(ws: WebSocket): Attachment | null {
    return (ws.deserializeAttachment() as Attachment | null) ?? null;
  }

  private liveSockets(tag: string, except?: WebSocket): WebSocket[] {
    return this.ctx.getWebSockets(tag).filter((w) => {
      if (w === except) return false;
      const a = this.attachment(w);
      return a !== null && !a.replaced;
    });
  }

  private hostSocket(): WebSocket | undefined {
    return this.liveSockets(HOST_TAG)[0];
  }

  /** Mark old sockets as replaced (so their close is silent) and close them with 4000. */
  private replace(tag: string, except: WebSocket): void {
    for (const old of this.ctx.getWebSockets(tag)) {
      if (old === except) continue;
      const a = this.attachment(old);
      if (a) old.serializeAttachment({ ...a, replaced: true });
      safeClose(old, CLOSE_REPLACED, "replaced");
    }
  }

  private allDeviceSockets(): WebSocket[] {
    return this.ctx.getWebSockets().filter((w) => {
      const a = this.attachment(w);
      return a?.role === "device" && !a.replaced;
    });
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/host") return this.acceptHost();
    if (url.pathname === "/device") {
      const deviceId = url.searchParams.get("deviceId") ?? "";
      const pub = url.searchParams.get("pub") ?? "";
      const pair = url.searchParams.get("pair") === "1";
      return this.acceptDevice(deviceId, pub, pair);
    }
    return new Response("not found", { status: 404 });
  }

  private acceptHost(): Response {
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server, [HOST_TAG]);
    server.serializeAttachment({ role: "host" } satisfies Attachment);
    this.replace(HOST_TAG, server);

    // Tell the new host which devices are currently connected, and tell devices the host is (back) online.
    for (const d of this.allDeviceSockets()) {
      const a = this.attachment(d);
      if (a?.role === "device") safeSend(server, deviceConnectedFrame(a.deviceId));
      safeSend(d, HOST_ONLINE);
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  private acceptDevice(deviceId: string, pub: string, pair: boolean): Response {
    if (!isDeviceAllowed(this.state, { deviceId, pub, pair }, Date.now())) {
      return new Response("device not allowed", { status: 403 });
    }
    const tag = deviceTag(deviceId);
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server, [tag]);
    server.serializeAttachment({ role: "device", deviceId, pub, pair } satisfies Attachment);
    this.replace(tag, server);
    this.buckets.set(deviceId, newBucket(Date.now()));

    const host = this.hostSocket();
    if (host) {
      safeSend(host, deviceConnectedFrame(deviceId));
      safeSend(server, HOST_ONLINE);
    } else {
      safeSend(server, HOST_OFFLINE);
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const a = this.attachment(ws);
    if (!a || a.replaced) return;
    if (a.role === "device") this.onDeviceMessage(ws, a.deviceId, message);
    else await this.onHostMessage(ws, message);
  }

  private onDeviceMessage(ws: WebSocket, deviceId: string, message: string | ArrayBuffer): void {
    let bucket = this.buckets.get(deviceId);
    if (!bucket) {
      bucket = newBucket(Date.now());
      this.buckets.set(deviceId, bucket);
    }
    if (!takeToken(bucket, Date.now())) {
      safeClose(ws, CLOSE_RATE_LIMIT, "rate limit");
      return;
    }
    // Protocol frames are JSON text only; drop binary and oversized frames.
    if (typeof message !== "string") return;
    if (message.length > MAX_DEVICE_FRAME_BYTES || utf8ByteLength(message) > MAX_DEVICE_FRAME_BYTES) return;

    const host = this.hostSocket();
    if (!host) {
      safeSend(ws, HOST_OFFLINE);
      return;
    }
    safeSend(host, wrapDeviceFrame(deviceId, message));
  }

  private async onHostMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string") return;
    const f = parseHostFrame(message);
    switch (f.kind) {
      case "forward": {
        const dev = this.liveSockets(deviceTag(f.to))[0];
        if (dev) safeSend(dev, f.data);
        else safeSend(ws, deviceDisconnectedFrame(f.to));
        return;
      }
      case "allow":
        this.state = { ...this.state, allow: await normalizeAllowList(f.devices) };
        await this.saveState();
        this.evictRevoked();
        return;
      case "pairing":
        this.state = { ...this.state, pairingUntil: f.until };
        await this.saveState();
        return;
      case "push":
        await this.handlePush(ws, f.push);
        return;
      case "push_invalid":
        safeSend(ws, pushResultFrame(f.id, 400, f.reason));
        return;
      case "invalid":
        return;
    }
  }

  /**
   * After an allowlist change, drop devices that were admitted via the allowlist and are no
   * longer on it (revocation). Devices admitted through the pairing window (pair=1) are left
   * alone: the host owns the pairing outcome and closes them end-to-end if it rejects them.
   */
  private evictRevoked(): void {
    const now = Date.now();
    for (const d of this.allDeviceSockets()) {
      const a = this.attachment(d);
      if (a?.role !== "device" || a.pair) continue;
      if (!isDeviceAllowed(this.state, { deviceId: a.deviceId, pub: a.pub, pair: false }, now)) {
        safeClose(d, CLOSE_NOT_ALLOWED, "not allowed");
      }
    }
  }

  private async handlePush(ws: WebSocket, push: PushRequest): Promise<void> {
    const { APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID } = this.env;
    if (!APNS_KEY_P8 || !APNS_KEY_ID || !APNS_TEAM_ID) {
      safeSend(ws, pushResultFrame(push.id, 500, "ApnsNotConfigured"));
      return;
    }
    try {
      const r = await sendPush(push, { keyP8: APNS_KEY_P8, keyId: APNS_KEY_ID, teamId: APNS_TEAM_ID }, Date.now());
      safeSend(ws, pushResultFrame(push.id, r.status, r.reason));
    } catch (e) {
      safeSend(ws, pushResultFrame(push.id, 502, e instanceof Error ? e.message : "push failed"));
    }
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    // Complete the close handshake (no-op if the runtime already auto-replied).
    safeClose(ws, code === 1005 || code === 1006 || code === 1015 ? 1000 : code, reason);
    this.onGone(ws);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.onGone(ws);
  }

  private onGone(ws: WebSocket): void {
    const a = this.attachment(ws);
    if (!a || a.replaced) return;
    // Mark so a later close/error event for the same socket is a no-op.
    ws.serializeAttachment({ ...a, replaced: true });

    if (a.role === "host") {
      if (this.liveSockets(HOST_TAG, ws).length > 0) return;
      for (const d of this.allDeviceSockets()) safeSend(d, HOST_OFFLINE);
    } else {
      if (this.liveSockets(deviceTag(a.deviceId), ws).length > 0) return;
      this.buckets.delete(a.deviceId);
      const host = this.hostSocket();
      if (host) safeSend(host, deviceDisconnectedFrame(a.deviceId));
    }
  }
}
