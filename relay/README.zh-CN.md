# opa-relay

[English](README.md) | **简体中文**

OpenPersonalAgent 的 Cloudflare Worker + Durable Object Relay（见 `../docs/protocol.zh-CN.md` §3.2）。每个 hostId 对应一个使用 WebSocket Hibernation API 的 `HostRelay` Durable Object。Relay 只路由端到端加密帧；它看不到明文，也不缓存消息。

路由：`GET /v1/host/:hostId`（WS）、`GET /v1/device/:hostId`（WS）、`GET /healthz`。

## 开发

```sh
npm install
npm run typecheck
npm test
npx wrangler dev
```

## 部署

```sh
npx wrangler login
npx wrangler deploy

# APNs 密钥：见下方“APNs 设置”
```

要限制哪些 Host 可以注册，在 `wrangler.toml` 的 `[vars]` 中设置 `ALLOWED_HOST_IDS`（逗号分隔的 hostIds），然后重新部署。它在这里是普通变量，因此不要再创建同名 secret。

部署后的 URL（`wss://opa-relay.<account>.workers.dev`）应填入配对二维码的 `relay` 字段。

## APNs 设置

每条推送（提醒和 Live Activity 更新）都从 Host 发往 Relay，再由 Relay 发给 Apple；Host 本身不会直接调用 Apple。因此只有 Host 连接 Relay 时推送才可用。未设置下面三个 secret 时，每次推送都会返回 `500 ApnsNotConfigured`。

1. 在 Apple Developer 门户打开 Certificates, Identifiers & Profiles → Keys → “+”，启用 “Apple Push Notifications service (APNs)”。下载 `AuthKey_<KEYID>.p8`（Apple 只允许下载一次），并记下 10 位 Key ID。Team ID 显示在门户右上角。同一个 Key 可用于 sandbox 和 production 环境。
2. App ID（`com.haoyuanyu.orbit`）需要启用 Push Notifications capability。Xcode 自动签名会根据 `aps-environment` entitlement 添加它。
3. 将 Key 存到 Worker，然后确认下面三个名称都已列出：

   ```sh
   npx wrangler secret put APNS_KEY_P8 < AuthKey_<KEYID>.p8
   npx wrangler secret put APNS_KEY_ID      # 10 位 Key ID
   npx wrangler secret put APNS_TEAM_ID     # Team ID，例如 6K6QZX2QN7
   npx wrangler secret list
   ```

4. Host：配置 Relay（`opa config relay wss://…`），并确认 Host 日志显示 `relay connected`。APNs topic 是 App 在 `push.register` 中发送的 bundle id。如果 App 没有发送，Host 会回退到 `opa config bundle-id`，其默认值是 `com.haoyuanyu.orbit`。
5. iPhone：Orbit 询问时允许通知。从 Xcode 安装的构建使用 sandbox APNs 环境；TestFlight / App Store 构建使用 production。App 会检测适用环境，并随 token 一起报告。

推送失败时，Host 日志会显示 `APNs <status> <reason>`：

| 日志 | 含义 |
|---|---|
| `500 ApnsNotConfigured` | 缺少第 3 步配置 |
| `403 InvalidProviderToken` | Key ID、Team ID 或 `.p8` 内容错误 |
| `400 BadDeviceToken` | sandbox / production 不匹配；重新安装当前 App 构建 |
| `400 DeviceTokenNotForTopic` | App 的 bundle id 与 topic 不一致 |
| `410 Unregistered` | App 已从手机移除；Host 会丢弃该 token |

## 限制与关闭码

- 超过 1 MiB 的设备帧，以及二进制帧，都会被丢弃。
- 每台设备每秒超过 120 帧（令牌桶，突发上限 120）时，会以 4008 关闭 socket。
- 4000：被使用相同 deviceId / host 的较新连接替换。
- 4001：设备已被 Host 从白名单移除。

## ADB 隧道

将手机自带的 adbd（无线调试）经 Relay 接到 bot 的电脑。Relay 只转发字节，不解析二进制帧。这是实验功能，协议文档暂未公开；产品背景见 `../docs/design/adb-relay.md`。每个 `phoneId` 对应一个 `TunnelRelay` Durable Object（同样使用 WebSocket Hibernation API），与 `HostRelay` 互不影响。

### 路由

| 路由（都是 GET + WebSocket 升级） | 认证 | 状态码 |
|---|---|---|
| `/v1/tunnel/<phoneId>/phone?pub=&ts=&sig=` | 手机对原文 `opa-tunnel-phone-v1`\|`<phoneId>`\|`<ts>` 的 Ed25519 签名 | 400 参数或 phoneId 错误；401 ts 过期、ID 与公钥不符、签名错误；403 不在 `ALLOWED_PHONE_IDS`；426 不是 WebSocket |
| `/v1/tunnel/<phoneId>/client` | 请求头 `Authorization: Bearer <token>`（`^[A-Za-z0-9_-]{32,128}$`） | 400 phoneId 错误、令牌缺失或格式错误；401 令牌未知或已过期；404 手机离线；426 不是 WebSocket |

- 其他 `/v1/tunnel/...` 路径一律返回 404。
- bot 端的检查顺序：先检查格式，再检查授权（401），最后检查在线状态（404）。
- Worker 对令牌计算 `sha256hex(utf8(token))`。转给 Durable Object 的内部请求会移除 `Authorization`，只带哈希。Relay 只保存令牌哈希。手机用 `{"t":"grants"}` 下发完整授权表，最多 32 条，存储在 DO storage 的 `grants` 键中。
- 同一时间每台手机只接一个手机连接和一个 bot 连接。新连接会挤掉旧连接（旧连接收到 4000）。

### ALLOWED_PHONE_IDS

可选的 phoneId 白名单，逗号分隔。不在名单内的手机连接返回 403。默认不设置，此时任何签名正确的手机都可以连接。要启用，在 `wrangler.toml` 的 `[vars]` 里取消注释 `ALLOWED_PHONE_IDS` 并重新部署。它和 `ALLOWED_HOST_IDS` 一样是普通变量，不要再建同名 secret。

### 关闭码

| 关闭码 | 含义 | 谁收到 |
|---|---|---|
| 4000 `replaced` | 被新连接替换 | 旧的手机或 bot 连接 |
| 4001 `revoked` | 授权已不在表里、被吊销或已过期 | bot |
| 4003 `phone reconnected` | 手机重新连接，上一次会话作废 | bot |
| 4004 `phone offline` | 手机断开 | bot |
| 4008 `rate limit` | 每台手机每 60 秒窗口内双向二进制字节合计超过 100 MiB | bot |
| 1009 `frame too large` | 单个二进制帧超过 65536 字节 | 发送方 |

对端不在线时二进制帧直接丢弃。每个窗口的字节数只在 Durable Object 内存里统计，休眠后清零。

### 本地冒烟测试

部署前用本地模式验证 Durable Object（不连接 Cloudflare，状态不会写进仓库）：

```sh
# 终端 1
cd relay && npx wrangler dev --local --port 8787 --ip 127.0.0.1 --persist-to /tmp/opa-relay-state

# 终端 2（在仓库根目录；需要 Python 3.11 以上，uv 会自动准备）
uv run --with websockets --with cryptography python relay/scripts/tunnel_smoke.py ws://127.0.0.1:8787
```

每个场景打印一行，任何一个失败就以退出码 1 结束。场景 1 到 10 对应契约的完整流程，11 到 13 覆盖授权过期、限流和手机端超大帧。加 `--hibernate` 会再空闲约 30 秒，验证 Durable Object 休眠后授权表和连接都能恢复。

### 注意

在本地 workerd 中，如果 Relay 主动关闭从未发送过消息的连接，关闭帧会立刻送达，但 TCP 连接要等 Durable Object 空闲（约 10 秒）才断开（`HostRelay` 也一样）。Python `websockets` 要等 TCP 断开才会让 `recv()` 抛出 `ConnectionClosed`，所以 bot 端建议设置较小的 `close_timeout`，例如 `connect(url, close_timeout=2)`。
