// TunnelRelay: one Durable Object per phoneId (docs/design/adb-relay-protocol.md §3-§5).
// It pairs the phone with at most one bot ("client") and forwards binary frames between them verbatim.
// Binary frames are never parsed: only their size is checked and counted. Uses the WebSocket Hibernation
// API so idle sockets cost nothing; the grants table lives in DO storage and is mirrored in memory.
import { DurableObject } from "cloudflare:workers";
import type { Env } from "./env";
import {
  BAD_GRANTS_FRAME,
  type ByteWindow,
  CLOSE_FRAME_TOO_LARGE,
  CLOSE_PHONE_OFFLINE,
  CLOSE_PHONE_RECONNECTED,
  CLOSE_RATE_LIMIT,
  CLOSE_REPLACED,
  CLOSE_REVOKED,
  type Grant,
  MAX_BINARY_FRAME_BYTES,
  clientClosedFrame,
  clientOpenFrame,
  grantsOkFrame,
  isExpired,
  newByteWindow,
  parsePhoneText,
  takeBytes,
} from "./tunnel-protocol";

type ClientAttachment = { role: "client"; grant: string; name: string; hash: string; replaced?: boolean };
type Attachment = { role: "phone"; replaced?: boolean } | ClientAttachment;

const PHONE_TAG = "phone";
const CLIENT_TAG = "client";
const GRANTS_KEY = "grants";

function safeSend(ws: WebSocket, msg: string | ArrayBuffer): boolean {
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

export class TunnelRelay extends DurableObject<Env> {
  private grants: Grant[] = [];
  /** In-memory only; resets after hibernation, which is acceptable. Start 0 = begins at the first counted frame. */
  private window: ByteWindow = newByteWindow(0);

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      const g = await ctx.storage.get<Grant[]>(GRANTS_KEY);
      if (g) this.grants = g;
    });
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

  private phoneSocket(): WebSocket | undefined {
    return this.liveSockets(PHONE_TAG)[0];
  }

  private clientSocket(): WebSocket | undefined {
    return this.liveSockets(CLIENT_TAG)[0];
  }

  /** Mark sockets under `tag` as replaced (so their close event is silent) and close them. */
  private evict(tag: string, code: number, reason: string, except?: WebSocket): void {
    for (const old of this.ctx.getWebSockets(tag)) {
      if (old === except) continue;
      const a = this.attachment(old);
      if (a?.replaced) continue;
      if (a) old.serializeAttachment({ ...a, replaced: true });
      safeClose(old, code, reason);
    }
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/phone") return this.acceptPhone();
    if (url.pathname === "/client") return this.acceptClient(url.searchParams.get("h") ?? "");
    return new Response("not found", { status: 404 });
  }

  private acceptPhone(): Response {
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server, [PHONE_TAG]);
    server.serializeAttachment({ role: "phone" } satisfies Attachment);
    // Newest phone wins. A bot still attached belonged to the old phone session and its channels are
    // void, so it is closed too. Both are marked replaced: the new phone never saw that bot open and
    // must not be told it closed.
    this.evict(PHONE_TAG, CLOSE_REPLACED, "replaced", server);
    this.evict(CLIENT_TAG, CLOSE_PHONE_RECONNECTED, "phone reconnected");
    return new Response(null, { status: 101, webSocket: client });
  }

  /** `hash` is sha256hex(token), computed by the Worker; the token itself never reaches this object. */
  private acceptClient(hash: string): Response {
    const grant = this.grants.find((g) => g.hash === hash);
    if (!grant || isExpired(grant, Date.now())) return new Response("unauthorized", { status: 401 });
    const phone = this.phoneSocket();
    if (!phone) return new Response("phone offline", { status: 404 });

    const prev = this.clientSocket();
    const prevAtt = prev ? this.attachment(prev) : null;

    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server, [CLIENT_TAG]);
    server.serializeAttachment({
      role: "client",
      grant: grant.id,
      name: grant.name,
      hash: grant.hash,
    } satisfies Attachment);
    this.evict(CLIENT_TAG, CLOSE_REPLACED, "replaced", server);

    // On a replacement the phone hears about the old bot leaving before the new one arriving.
    if (prevAtt?.role === "client") safeSend(phone, clientClosedFrame(prevAtt.grant));
    safeSend(phone, clientOpenFrame(grant.id, grant.name));
    return new Response(null, { status: 101, webSocket: client });
  }

  // ---- Grants ----

  /** True while the grant a live bot connected with is still in the table (same id and hash) and unexpired. */
  private grantHolds(a: ClientAttachment, now: number): boolean {
    const g = this.grants.find((x) => x.id === a.grant && x.hash === a.hash);
    return g !== undefined && !isExpired(g, now);
  }

  /** Close the bot with 4001 if its grant no longer holds. Returns whether it is still good. */
  private checkClient(ws: WebSocket, a: ClientAttachment): boolean {
    if (this.grantHolds(a, Date.now())) return true;
    this.closeSocket(ws, CLOSE_REVOKED, "revoked");
    return false;
  }

  // ---- Messages ----

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const a = this.attachment(ws);
    if (!a || a.replaced) return;
    if (a.role === "phone") await this.onPhoneMessage(ws, message);
    else this.onClientMessage(ws, a, message);
  }

  private async onPhoneMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string") {
      this.phoneBinary(ws, message);
      return;
    }
    const f = parsePhoneText(message);
    switch (f.kind) {
      case "grants": {
        await this.ctx.storage.put(GRANTS_KEY, f.grants);
        this.grants = f.grants;
        safeSend(ws, grantsOkFrame(f.grants.length));
        // The table was replaced wholesale: a bot whose grant is gone (or expired) must go.
        const c = this.clientSocket();
        const ca = c ? this.attachment(c) : null;
        if (c && ca?.role === "client") this.checkClient(c, ca);
        return;
      }
      case "bad_grants":
        safeSend(ws, BAD_GRANTS_FRAME);
        return;
      case "ignore":
        return;
    }
  }

  private onClientMessage(ws: WebSocket, a: ClientAttachment, message: string | ArrayBuffer): void {
    if (!this.checkClient(ws, a)) return;
    if (typeof message === "string") return; // text frames from the bot are ignored
    if (message.byteLength > MAX_BINARY_FRAME_BYTES) {
      this.closeSocket(ws, CLOSE_FRAME_TOO_LARGE, "frame too large");
      return;
    }
    const phone = this.phoneSocket();
    if (phone) this.deliver(ws, phone, message);
  }

  private phoneBinary(ws: WebSocket, data: ArrayBuffer): void {
    if (data.byteLength > MAX_BINARY_FRAME_BYTES) {
      this.closeSocket(ws, CLOSE_FRAME_TOO_LARGE, "frame too large");
      return;
    }
    const client = this.clientSocket();
    const ca = client ? this.attachment(client) : null;
    if (!client || ca?.role !== "client") return; // no bot: drop
    if (this.checkClient(client, ca)) this.deliver(client, client, data);
  }

  /** Count the frame against the 60 s byte budget and send it on; over budget the bot is closed instead. */
  private deliver(client: WebSocket, to: WebSocket, data: ArrayBuffer): void {
    if (!takeBytes(this.window, Date.now(), data.byteLength)) {
      this.closeSocket(client, CLOSE_RATE_LIMIT, "rate limit");
      return;
    }
    safeSend(to, data);
  }

  // ---- Closing ----

  /** Close a socket on our own initiative, with the same bookkeeping as a peer-initiated close. */
  private closeSocket(ws: WebSocket, code: number, reason: string): void {
    this.onGone(ws);
    safeClose(ws, code, reason);
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

    if (a.role === "phone") {
      if (this.liveSockets(PHONE_TAG, ws).length > 0) return;
      this.evict(CLIENT_TAG, CLOSE_PHONE_OFFLINE, "phone offline");
    } else {
      const phone = this.phoneSocket();
      if (phone) safeSend(phone, clientClosedFrame(a.grant));
    }
  }
}
