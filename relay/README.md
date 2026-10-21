# opa-relay

**English** | [简体中文](README.zh-CN.md)

Cloudflare Worker + Durable Object relay for OpenPersonalAgent (see `../docs/protocol.md` §3.2).
One `HostRelay` Durable Object per hostId, using the WebSocket Hibernation API. The relay only routes
end-to-end encrypted frames; it never sees plaintext and never buffers messages.

Routes: `GET /v1/host/:hostId` (WS), `GET /v1/device/:hostId` (WS), `GET /healthz`.

## Develop

```sh
npm install
npm run typecheck
npm test
npx wrangler dev
```

## Deploy

```sh
npx wrangler login
npx wrangler deploy

# APNs secrets: see "APNs setup" below
```

To restrict which hosts may register, set `ALLOWED_HOST_IDS` (comma-separated hostIds) under `[vars]` in
`wrangler.toml` and deploy again. It is a plain var there, so don't also create a secret with the same name.

The deployed URL (`wss://opa-relay.<account>.workers.dev`) is what goes into the pairing QR code `relay` field.

## APNs setup

Every push (alerts and Live Activity updates) goes host → relay → Apple; the host never calls Apple itself,
so pushes only work while the host is connected to the relay. Without the three secrets below, every push
comes back as `500 ApnsNotConfigured`.

1. In the Apple Developer portal, open Certificates, Identifiers & Profiles → Keys → "+", and enable
   "Apple Push Notifications service (APNs)". Download `AuthKey_<KEYID>.p8` (Apple only lets you download it
   once) and note the 10-character Key ID. The Team ID appears at the top right of the portal. One key works
   for both the sandbox and production environments.
2. The App ID (`com.haoyuanyu.orbit`) needs the Push Notifications capability. Xcode's automatic signing adds it
   from the `aps-environment` entitlement.
3. Store the key on the worker, then check that all three names are listed:

   ```sh
   npx wrangler secret put APNS_KEY_P8 < AuthKey_<KEYID>.p8
   npx wrangler secret put APNS_KEY_ID      # the 10-character Key ID
   npx wrangler secret put APNS_TEAM_ID     # the Team ID, e.g. 6K6QZX2QN7
   npx wrangler secret list
   ```

4. Host: configure the relay (`opa config relay wss://…`) and make sure the host log shows `relay connected`. The
   APNs topic is the bundle id that the app sends in `push.register`. If the app doesn't send one, the host
   falls back to `opa config bundle-id`, which defaults to `com.haoyuanyu.orbit`.
5. iPhone: allow notifications when Orbit asks. Builds installed from Xcode use the sandbox APNs environment, and
   TestFlight / App Store builds use production. The app detects which one applies and reports it with its
   token.

When a push fails, the host log shows `APNs <status> <reason>`:

| Log | Meaning |
|---|---|
| `500 ApnsNotConfigured` | Step 3 is missing |
| `403 InvalidProviderToken` | Wrong Key ID, Team ID or `.p8` contents |
| `400 BadDeviceToken` | Sandbox / production mismatch; reinstall the current app build |
| `400 DeviceTokenNotForTopic` | Bundle id mismatch between the app and the topic |
| `410 Unregistered` | The app was removed from the phone; the host drops that token |

## Limits and close codes

- Device frames over 1 MiB, and binary frames, are dropped.
- More than 120 frames/s per device (token bucket, burst 120) closes the socket with 4008.
- 4000: replaced by a newer connection with the same deviceId / host.
- 4001: device removed from the allowlist by the host.

## ADB tunnel

The phone's built-in adbd (wireless debugging) can be routed through Relay to the bot's computer. Relay only forwards bytes; it does not parse binary frames. This is an experimental feature, and the protocol document is not yet public. See `../docs/design/adb-relay.md` for product background. Each `phoneId` maps to a `TunnelRelay` Durable Object (also using the WebSocket Hibernation API), independent of `HostRelay`.

### Routes

| Route (all are GET + WebSocket upgrade) | Authentication | Status codes |
|---|---|---|
| `/v1/tunnel/<phoneId>/phone?pub=&ts=&sig=` | Phone's Ed25519 signature over `opa-tunnel-phone-v1`\|`<phoneId>`\|`<ts>` | 400 invalid parameters or phoneId; 401 expired ts, ID/public-key mismatch, or invalid signature; 403 not in `ALLOWED_PHONE_IDS`; 426 not a WebSocket |
| `/v1/tunnel/<phoneId>/client` | `Authorization: Bearer <token>` header (`^[A-Za-z0-9_-]{32,128}$`) | 400 invalid phoneId or missing/malformed token; 401 unknown or expired token; 404 phone offline; 426 not a WebSocket |

- All other `/v1/tunnel/...` paths return 404.
- On the bot side, checks run in this order: format, authorization (401), then online status (404).
- The Worker computes `sha256hex(utf8(token))`. Its internal request to the Durable Object removes `Authorization` and carries only the hash. Relay stores only token hashes. The phone sends the complete grants table as `{"t":"grants"}` (up to 32 entries), stored under the `grants` key in DO storage.
- Each phone accepts one phone connection and one bot connection at a time. A new connection replaces the old one (the old connection receives 4000).

### ALLOWED_PHONE_IDS

Optional, comma-separated phoneId allowlist. A phone not on the list receives 403. It is unset by default, so any phone with a valid signature may connect. To enable it, uncomment `ALLOWED_PHONE_IDS` under `[vars]` in `wrangler.toml` and deploy again. Like `ALLOWED_HOST_IDS`, it is a plain variable; do not create a secret with the same name.

### Close codes

| Code | Meaning | Recipient |
|---|---|---|
| 4000 `replaced` | Replaced by a new connection | Old phone or bot connection |
| 4001 `revoked` | Authorization is absent from the table, revoked, or expired | Bot |
| 4003 `phone reconnected` | Phone reconnected; the previous session is invalid | Bot |
| 4004 `phone offline` | Phone disconnected | Bot |
| 4008 `rate limit` | Bidirectional binary traffic exceeds 100 MiB in a 60-second window for a phone | Bot |
| 1009 `frame too large` | A single binary frame exceeds 65536 bytes | Sender |

Binary frames are dropped when the peer is absent. Per-window byte counts are kept only in Durable Object memory and reset when it sleeps.

### Local smoke test

Before deployment, test the Durable Object in local mode (no Cloudflare connection; state is not written into the repository):

```sh
# Terminal 1
cd relay && npx wrangler dev --local --port 8787 --ip 127.0.0.1 --persist-to /tmp/opa-relay-state

# Terminal 2 (from the repository root; Python 3.11 or later is required, uv will prepare it)
uv run --with websockets --with cryptography python relay/scripts/tunnel_smoke.py ws://127.0.0.1:8787
```

Each scenario prints one line; any failure exits with code 1. Scenarios 1–10 cover the full contract flow, and 11–13 cover expired authorization, rate limiting, and an oversized phone-side frame. Adding `--hibernate` waits idle for about 30 seconds and checks that the Durable Object can restore its authorization table and connections after sleeping.

### Note

In local workerd, when Relay actively closes a connection that has never sent a message, the close frame arrives immediately, but the TCP connection may not close until the Durable Object becomes idle (about 10 seconds; `HostRelay` behaves the same way). Python `websockets` waits for TCP to close before `recv()` raises `ConnectionClosed`, so the bot should use a short `close_timeout`, for example `connect(url, close_timeout=2)`.
