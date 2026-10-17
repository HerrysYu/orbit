// Worker entry: routing + stateless auth. Everything stateful lives in a Durable Object:
// HostRelay (one per hostId) for Mac/iPhone, TunnelRelay (one per phoneId) for the ADB tunnel.
import { ID_RE, parseAllowedHostIds, verifyDeviceAuth, verifyHostAuth, verifyPhoneAuth } from "./auth";
import { bytesToBase64 } from "./encoding";
import type { Env } from "./env";
import { matchRoute } from "./routes";
import { parseBearerToken, sha256hex } from "./tunnel-protocol";

export { HostRelay } from "./relay";
export { TunnelRelay } from "./tunnel";
export type { Env } from "./env";

function text(status: number, body: string): Response {
  return new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8" } });
}

/**
 * ADB tunnel routes (docs/design/adb-relay-protocol.md §3). The phone authenticates with an Ed25519
 * signature; the bot with a bearer token, which is hashed here so the Durable Object (and storage)
 * only ever see the hash. The Authorization header is not forwarded.
 */
async function tunnelFetch(
  request: Request,
  url: URL,
  route: { kind: "tunnel_phone" | "tunnel_client"; phoneId: string },
  env: Env,
  now: number,
): Promise<Response> {
  const internal = new URL("https://relay.internal/");
  let headers: Headers | undefined;

  if (route.kind === "tunnel_phone") {
    const r = await verifyPhoneAuth(route.phoneId, url.searchParams, now, parseAllowedHostIds(env.ALLOWED_PHONE_IDS));
    if (!r.ok) return text(r.status, r.reason);
    internal.pathname = "/phone";
  } else {
    if (!ID_RE.test(route.phoneId)) return text(400, "bad phoneId");
    const t = parseBearerToken(request.headers.get("Authorization"));
    if (!t.ok) return text(t.status, t.reason);
    internal.pathname = "/client";
    internal.searchParams.set("h", await sha256hex(t.token));
    headers = new Headers(request.headers);
    headers.delete("Authorization");
  }

  const stub = env.TUNNEL_RELAY.get(env.TUNNEL_RELAY.idFromName(route.phoneId));
  return stub.fetch(new Request(internal.toString(), { headers: headers ?? request.headers }));
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const route = matchRoute(request.method, url.pathname);

    if (route.kind === "healthz") return text(200, "ok");
    if (route.kind === "not_found") return text(404, "not found");

    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return text(426, "expected websocket");

    const now = Date.now();
    if (route.kind === "tunnel_phone" || route.kind === "tunnel_client") {
      return tunnelFetch(request, url, route, env, now);
    }

    // Internal request to the DO carrying the verified identity. The DO is only reachable via this Worker.
    const internal = new URL("https://relay.internal/");

    if (route.kind === "host") {
      const r = await verifyHostAuth(route.hostId, url.searchParams, now, parseAllowedHostIds(env.ALLOWED_HOST_IDS));
      if (!r.ok) return text(r.status, r.reason);
      internal.pathname = "/host";
    } else {
      const r = await verifyDeviceAuth(route.hostId, url.searchParams, now);
      if (!r.ok) return text(r.status, r.reason);
      internal.pathname = "/device";
      internal.searchParams.set("deviceId", r.value.deviceId);
      internal.searchParams.set("pub", bytesToBase64(r.value.pub));
      if (r.value.pair) internal.searchParams.set("pair", "1");
    }

    const stub = env.HOST_RELAY.get(env.HOST_RELAY.idFromName(route.hostId));
    return stub.fetch(new Request(internal.toString(), { headers: request.headers }));
  },
} satisfies ExportedHandler<Env>;
