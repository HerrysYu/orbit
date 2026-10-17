# opa-relay

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

## ADB 隧道

把手机自带的 adbd（无线调试）经 Relay 接到 bot 的电脑。Relay 只转发字节，不解析二进制帧。这是实验功能，协议文档暂未公开；产品背景见 `../docs/design/adb-relay.md`。每个 `phoneId` 对应一个 `TunnelRelay` Durable Object（同样使用 WebSocket Hibernation API），与 `HostRelay` 互不影响。

### 路由

| 路由（都是 GET + WebSocket 升级） | 认证 | 状态码 |
|---|---|---|
| `/v1/tunnel/<phoneId>/phone?pub=&ts=&sig=` | 手机的 Ed25519 签名，原文 `opa-tunnel-phone-v1\|<phoneId>\|<ts>` | 400 参数或 phoneId 错误；401 ts 过期、id 与公钥不符、签名错误；403 不在 `ALLOWED_PHONE_IDS`；426 不是 WebSocket |
| `/v1/tunnel/<phoneId>/client` | 请求头 `Authorization: Bearer <token>`（`^[A-Za-z0-9_-]{32,128}$`） | 400 phoneId 错误、令牌缺失或格式错误；401 令牌未知或已过期；404 手机离线；426 不是 WebSocket |

- 其他 `/v1/tunnel/...` 路径一律 404。
- bot 端的检查顺序：先格式，再授权（401），最后在线（404）。
- Worker 对令牌做 `sha256hex(utf8(token))`，转给 Durable Object 的内部请求里去掉 `Authorization`，只带哈希。Relay 只保存令牌哈希（手机用 `{"t":"grants"}` 整表下发，最多 32 条，存在 DO storage 的 `grants` 键里）。
- 同一时间每台手机只接一个手机连接和一个 bot：新连接挤掉旧连接（旧连接收到 4000）。

### ALLOWED_PHONE_IDS

可选，逗号分隔的 phoneId 白名单，不在名单内的手机连接返回 403。默认不设置，此时任何签名正确的手机都可以连接。要启用，在 `wrangler.toml` 的 `[vars]` 里取消注释 `ALLOWED_PHONE_IDS` 并重新部署。它和 `ALLOWED_HOST_IDS` 一样是普通变量，不要再建同名 secret。

### 关闭码

| 关闭码 | 含义 | 谁收到 |
|---|---|---|
| 4000 `replaced` | 被新连接替换 | 旧的手机或 bot 连接 |
| 4001 `revoked` | 授权已不在表里、被吊销或已过期 | bot |
| 4003 `phone reconnected` | 手机重新连接，上一次会话作废 | bot |
| 4004 `phone offline` | 手机断开 | bot |
| 4008 `rate limit` | 每台手机每 60 秒窗口内双向二进制字节合计超过 100 MiB | bot |
| 1009 `frame too large` | 单个二进制帧超过 65536 字节 | 发送方 |

对端不在时二进制帧直接丢弃。每个窗口的字节数只在 Durable Object 内存里统计，休眠后清零。

### 本地冒烟测试

部署前用本地模式验证 Durable Object（不连 Cloudflare，状态不会写进仓库）：

```sh
# 终端 1
cd relay && npx wrangler dev --local --port 8787 --ip 127.0.0.1 --persist-to /tmp/opa-relay-state

# 终端 2（在仓库根目录；需要 Python 3.11 以上，uv 会自动准备）
uv run --with websockets --with cryptography python relay/scripts/tunnel_smoke.py ws://127.0.0.1:8787
```

每个场景打印一行，任何一个失败就以退出码 1 结束。场景 1 到 10 对应契约的完整流程，11 到 13 覆盖授权过期、限流和手机端超大帧。加 `--hibernate` 会再空闲约 30 秒，验证 Durable Object 休眠后授权表和连接都能恢复。

### 注意

本地 workerd 里，Relay 主动关闭的连接如果从未发送过消息，关闭帧会立刻送达，但 TCP 连接要等 Durable Object 空闲（约 10 秒）才断开（`HostRelay` 也一样）。Python 的 `websockets` 要等 TCP 断开才会让 `recv()` 抛出 `ConnectionClosed`，所以 bot 端建议设置较小的 `close_timeout`，例如 `connect(url, close_timeout=2)`。
