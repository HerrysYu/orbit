# OPA Wire Protocol v1

[English](protocol.md) | **简体中文**

Host（Mac）、Relay（Cloudflare Worker）、iOS App 三方共享的协议。任何改动都要同步修改这三处实现。

## 1. 身份与密钥

- 双方各持有一把 **Ed25519 身份密钥**，公钥为 raw 32 字节，传输时使用 base64（标准字母表，带 padding）。
- `hostId = hex(sha256(hostPub))[0..32]`（32 个小写 hex 字符）；`deviceId` 的算法相同。
- 每次连接各自生成**临时 X25519 密钥**，公钥为 raw 32 字节。

## 2. 握手（明文 JSON 文本帧）

device → host
```json
{"t":"hello","v":1,"deviceId":"…","devicePub":"b64","deviceName":"Herry 的 iPhone",
 "ephPub":"b64","ts":1760000000000,"pairToken":"可选","sig":"b64"}
```
`sig = Ed25519(devicePriv, utf8("opa-hello-v1|" + hostId + "|" + ephPub + "|" + ts))`，其中 `ephPub` 取 base64 字符串，`ts` 取十进制字符串。

host 的检查项：`|now - ts| < 5min`；`deviceId == id(devicePub)`；签名有效；并且满足以下二者之一：(a) 设备已在白名单中，或 (b) `pairToken` 有效且未被使用过。

host → device
```json
{"t":"welcome","v":1,"ephPub":"b64","sig":"b64","paired":true,"hostName":"Herry 的 Mac"}
```
`sig = Ed25519(hostPriv, utf8("opa-welcome-v1|" + deviceId + "|" + ephPubD + "|" + ephPubH))`。设备用二维码中拿到的 `hostPub` 验签。
校验失败时 host 回 `{"t":"reject","reason":"…"}` 并关闭连接。

### 会话密钥
```
shared = X25519(myEphPriv, peerEphPub)
salt   = ephPubD_raw || ephPubH_raw          (64 字节)
kD2H   = HKDF-SHA256(shared, salt, info="opa-v1-d2h", 32)
kH2D   = HKDF-SHA256(shared, salt, info="opa-v1-h2d", 32)
SAS    = (u32be(sha256("opa-sas" || ephPubD_raw || ephPubH_raw)[0..4]) mod 1_000_000)，左侧补 0 到 6 位
```

### 加密帧
```json
{"t":"x","n":0,"c":"b64(ciphertext||tag16)"}
```
- 算法为 ChaCha20-Poly1305（IETF）。`nonce = 0x00000000 || u64be(n)`，`aad = utf8("opa-v1")`。
- 每个方向各自维护 `n`：从 0 开始，每发一帧加 1。接收方遇到 `n <= lastN` 必须断开连接。
- 明文是第 4 节定义的 App 消息（JSON，UTF-8）。

### 配对
1. Mac 上执行 `opa pair`，屏幕显示二维码。二维码内容是下面这段 JSON 的 base64url，前缀为 `opa://pair?d=`：
   ```json
   {"v":1,"hostId":"…","hostPub":"b64","hostName":"…","lan":[{"host":"192.168.1.5","port":7420}],
    "relay":"wss://opa-relay.example.workers.dev","pairToken":"…","exp":1760000300000}
   ```
2. 设备在 hello 中携带 `pairToken`。host 回 `welcome{paired:false}`，此时加密通道已经建立，但 host 只处理配对相关的帧。
3. 双方都显示 SAS。用户在 Mac 上确认后，host 发送加密消息 `{"t":"pair.result","d":{"ok":true}}`，把该设备写入白名单，之后进入正常会话。如果用户拒绝，host 发送 `{ok:false}` 后断开。

## 3. 传输

### 3.1 局域网
- `ws://<ip>:7420/v1/ws`。不需要 TLS，因为应用层已经端到端加密并做了双向认证。
- Bonjour 服务类型 `_opa._tcp`，TXT 记录中带 `hostId=…`。
- iOS 需要配置 `NSLocalNetworkUsageDescription` 和 `NSBonjourServices=[_opa._tcp]`，以及 ATS 的 `NSAllowsLocalNetworking`。

### 3.2 Relay（Cloudflare Worker + Durable Object，每个 hostId 一个 DO 实例）
host 连接：
`wss://RELAY/v1/host/<hostId>?pub=<b64url>&ts=<ms>&sig=<b64url>`
其中 `sig = Ed25519(hostPriv, "opa-relay-host-v1|" + hostId + "|" + ts)`。Relay 要校验 `id(pub) == hostId`；如果配置了 `ALLOWED_HOST_IDS`，还要检查 hostId 在列表中。

device 连接：
`wss://RELAY/v1/device/<hostId>?deviceId=…&pub=<b64url>&ts=<ms>&sig=<b64url>[&pair=1]`
其中 `sig = Ed25519(devicePriv, "opa-relay-device-v1|" + hostId + "|" + deviceId + "|" + ts)`。设备必须在 host 下发的白名单里；或者 `pair=1` 并且配对窗口处于打开状态。
（URL 查询参数里的 base64 一律用 base64url、不带 padding。）

帧格式（全部是 JSON 文本帧）：
| 方向 | 帧 |
|---|---|
| device→relay | 原样转发的数据字符串，即第 2 节定义的 hello / x 帧 |
| relay→host | `{"from":"<deviceId>","data":"<原字符串>"}` |
| host→relay | `{"to":"<deviceId>","data":"<字符串>"}` |
| relay→device | 原样的 `data` 字符串 |
| host→relay 控制 | `{"relay":"allow","devices":[{"id":"…","pub":"b64"}]}`（全量替换白名单） |
| | `{"relay":"pairing","until":<ms>}` |
| | `{"relay":"push","id":"…","deviceToken":"hex","env":"sandbox\|production","pushType":"alert\|liveactivity\|background","topic":"bundleId[.push-type.liveactivity]","priority":10,"collapseId":"可选","expiration":0,"payload":{…}}` |
| relay→host 控制 | `{"relay":"device_connected","deviceId":"…"}` / `{"relay":"device_disconnected","deviceId":"…"}` / `{"relay":"push_result","id":"…","status":200,"reason":"…"}` |
| relay→device 控制 | `{"relay":"host_online"}` / `{"relay":"host_offline"}` |

- 同一 deviceId 只保留一条连接，新连接会挤掉旧连接；host 同理。
- host 掉线后，Relay 向所有设备发送 `host_offline`；host 重新上线后发送 `host_online`，设备收到后需要重新握手。
- Relay **不缓存**消息。离线期间设备发不出去的消息由 App 本地 outbox 保存，重连后补发。
- APNs 凭据通过 Worker secrets 配置：`APNS_KEY_P8`、`APNS_KEY_ID`、`APNS_TEAM_ID`。
- `push_result` 只带推送的 `id`，不带 token：host 发 `push` 时自己记下 `id → token`。`status` 为 410，或 `reason` 为 `BadDeviceToken` / `Unregistered` / `ExpiredToken` 时，host 删除对应的 token；`DeviceTokenNotForTopic`（bundle id 对不上）和 `ApnsNotConfigured`（Relay 没配 APNs 密钥）不删 token，只在 host 日志里提示一次。

## 4. App 消息（加密帧的明文）

### 4.1 帧类型
| t | 方向 | 结构 | 说明 |
|---|---|---|---|
| `req` | D→H | `{t,id,m,d}` | 请求；`id` 由客户端生成 |
| `res` | H→D | `{t,id,ok,d?,err?}` | 对 req 的响应 |
| `ev` | H→D | `{t,seq,ts,k,d}` | **持久事件**。seq 单调递增，可重放 |
| `live` | H→D | `{t,k,d}` | 临时事件，不持久化，例如流式 delta、状态 |
| `pair.result` | H→D | `{t,d:{ok}}` | 配对结果 |

### 4.2 req 方法（m）
| m | d | res.d |
|---|---|---|
| `sync` | `{lastSeq}` | `{fromSeq,toSeq,reset,chatCleared?:{seq,clearedAt}}`。随后 host 按顺序推送 `ev`。`reset=true` 表示缺口太大，客户端应清空本地事件缓存，host 重放最近窗口。`chatCleared` 是最近一次清除聊天的持久标记，即使对应事件已超出重放窗口也返回；从未清除时省略。客户端在补发 outbox 前处理该标记。host 在处理某条连接的第一个 `sync` 之前不向它推送 `ev` / `live`（这段时间产生的 `ev` 由这次 `sync` 补发，`live` 不补发；`req` / `res` 不受影响），所以客户端每次（重新）连上后都要发 `sync` |
| `chat.send` | `{clientId,text,attachments?:[Attachment]}` | `{msgId,duplicate?:true}`。以 `clientId` 幂等，见下方说明 |
| `chat.clear` | `{}` | `{cleared:true,seq,clearedAt}`。清空聊天并重置管家对话上下文；`seq` 对应同次 `chat.cleared` 事件，`clearedAt` 为 Unix 毫秒 |
| `chat.interrupt` | `{}` | `{}` |
| `ui.action` | `{cardId,actionId,value?}` | `{}` |
| `approval.respond` | `{approvalId,decision:"approve"\|"deny",note?}` | `{}` |
| `task.cmd` | `{taskId?,sessionId?,cmd:"interrupt"\|"steer"\|"archive"\|"cancel",text?}` | `{}` |
| `tasks.clear` | `{ids?:string[]}` | `{removed:string[],skipped:string[]}`。清除**已结束**（`done`/`failed`/`cancelled`）的任务，见下方说明 |
| `session.detail` | `{sessionId}` | `{session,items:[{kind,text,ts}]}` |
| `context.update` | `DeviceContext` | `{}` |
| `import.add` | `{items:[ImportItem]}` | `{ids}` |
| `settings.get` | `{}` | `Settings` |
| `settings.set` | `Partial<Settings>`（深合并）。`models.butlerEffort` / `heartbeatEffort` / `codexEffort` 不合法时返回错误「无效的推理强度」，整次设置都不生效，见 §4.5 | `Settings` |
| `models.list` | `{}` | `{butler:[ModelOption],codex:[ModelOption]}`，`ModelOption = {id,displayName,isDefault,efforts:string[],defaultEffort?:string}`（`butler` 项另带 `description?`）。`efforts`：该模型支持的推理强度，来自 Codex 的 `supportedReasoningEfforts`，**可能是空数组**（host 不知道，不要因此隐藏已设置的强度）；`defaultEffort`：模型自己的默认强度，可能缺省。含手动补充的 `gpt-6.1-sol`（`defaultEffort:"medium"`，不代表账号已验证可调用） |
| `memory.list` | `{}` | `{items:[Memory]}` |
| `memory.add` | `{text,kind?}` | `Memory` |
| `memory.delete` | `{id}` | `{}` |
| `push.register` | `{kind:"alert"\|"liveactivity"\|"pushToStart",token,env,activityId?,taskId?,bundleId?}` | `{}`。`bundleId` 是 App 自己的 bundle id，host 发推送的 APNs topic 优先用它，见下方说明 |
| `devices.list` | `{}` | `{devices:[{id,name,pairedAt,lastSeen}]}` |
| `phone.status` | `{}` | `{available:boolean,reason?:string,serial:string,device?:{serial,state,model?},adbKeyboard?:boolean}`。专用 Android 手机的状态，只读，见下方说明 |
| `ping` | `{}` | `{ts}` |

**`chat.send` 幂等**：`clientId` 非空时，host 以它去重（记录持久保存，host 重启后仍有效）。同一个 `clientId` 再次到达时，host 不产生新的 `msg.user`、也不再交给 Orbit，直接返回第一次的 `{msgId,duplicate:true}`；即使这次的 `text` 或附件不同也一样，内容以第一次为准，所以新消息必须用新的 `clientId`。首次发送的响应不带 `duplicate`。`clientId` 为空或缺省时无法去重，每次都算新消息。因此 App 重连后可以放心补发本地 outbox，收到 `duplicate:true` 同样视为发送成功。

**`chat.clear`**：
- 清除 Host 的 `msg.user` / `msg.assistant` / `ui.render` / `ui.patch` 历史及聊天卡片，重置管家当前线程、短期上下文和旧用户输入队列。旧轮次的迟到回复不得重新写回；仅中止管家这轮对话，不取消独立 worker 或手机任务。
- 保留长期记忆、任务、执行会话、审批、设置、配对、导入资料、调度与审计。保留 `client_msgs` 去重元数据，因此已清除消息的旧 `clientId` 再次发送仍不会执行两次。全局事件序号继续递增。
- 删除聊天事件和插入 `chat.cleared` 在同一数据库事务内完成。事件可能先于 RPC 响应到达；客户端按清除 `seq` 幂等处理，迟到响应不能再次删除清除后产生的新消息。收到清除标记后还需清理本地旧聊天、旧待发消息和旧流式状态，并持久保存该标记。
- 最近一次 `{seq,clearedAt}` 另行持久保存并随 `sync` 返回，避免长时间离线的设备错过清除事件。处理标记不能回退全局 `lastSeq`，也不能删除 `seq` 大于标记的新聊天。
- App 提供二次确认；离线或请求失败时不先行清空。这个功能管理 Orbit 的聊天与上下文，不删除 Codex 等第三方服务保存的线程归档或诊断日志。

**`tasks.clear`**：
- 不带 `ids`：清除所有已结束的任务。带 `ids`：只清除其中已结束的；仍在进行的（`planning`/`running`/`waiting_user`/`blocked`）和不存在的 id 保持原样，放进 `skipped`。`ids:[]` 什么也不清除；`ids` 不是数组时返回错误。
- 被清除任务名下的 Codex session 会一并归档：host 先立即把它们标为已归档（广播 `session.upsert`，`status:"archived"`），再在后台通知 Codex 归档对应线程。响应不等待这一步，Codex 响应再慢也不会拖住请求。Codex 归档失败不影响清除结果，session 在 host 里仍是已归档；后台归档期间的状态变化（例如被中止的那一轮结束）也不会让它变回去。
- 每次调用最多广播一条 `task.remove {ids}`（没有任务被清除时不发）。`task.remove` 和上述 `session.upsert` 都在响应之前发出：客户端按事件从本地删除任务，响应里的 `removed` 只用来提示「已清除 N 项」。
- 可重复调用：已经清除的 id 再次出现时进入 `skipped`，不会报错。

**`push.register`**：
- `bundleId`（可选）：App 自己的 bundle id，须匹配 `^[A-Za-z0-9.-]{1,155}$`；缺省或不合法时忽略。它和 token 一起保存，同一个 token 再次注册时更新。
- host 发推送时，APNs topic 优先用这个 token 登记的 `bundleId`：`alert` 的 topic 是 `<bundleId>`，`liveactivity` / `pushToStart` 的 topic 是 `<bundleId>.push-type.liveactivity`。token 没登记 `bundleId` 时，用 host 配置的 bundle id（`opa config bundle-id`，默认 `com.haoyuanyu.orbit`）。

**`phone.status`**：给设置页显示 Orbit 专用 Android 手机的真实状态。只读：host 只向 adb 询问有哪些设备，不操作手机。
- `serial`：Orbit 绑定的手机，即 host 的 `OPA_PHONE_SERIAL`，默认 `e7fe2f2a`。始终返回。
- `device`：adb 对这台手机的说法，`state` 取 adb 的原值：`device`（可用）、`unauthorized`（手机还没允许这台 Mac 调试）、`offline` 等；`model` 是 adb 报告的型号（空格写成下划线），不一定有。adb 用不了，或没有列出这台手机时，整个 `device` 省略。
- `adbKeyboard`：ADB Keyboard 是否已安装。只在 `device.state` 为 `device` 且检查完成时才有；省略表示**不知道**，不要显示成「未安装」。
- `available`：adb 能用、手机在线且 `state` 为 `device`、host 的手机自动化环境已装好，三者同时成立才是 `true`。`reason` 当且仅当 `available` 为 `false` 时出现，是一句可以直接显示的中文，说明最先遇到的问题和怎么办：adb 找不到或超时 → 手机没连上或连的是别的手机 → 手机未授权或离线 → 自动化环境没装。
- 这个请求不会失败：adb 缺失、超时或报错都表现为 `available:false` 加 `reason`，不会返回 `ok:false`。`available:true` 不检查「USB 调试（安全设置）」（验证它要向手机发一个空按键事件，本请求不会这么做），也不检查 ADB Keyboard 输入法是否已启用；这两项只有在 Mac 上运行 `opa phone status` 才会检查，所以界面不要写成「全部就绪」。
- host 对 adb 的结果缓存 20 秒（失败也缓存），所以反复打开设置页不会每次都启动 adb；手机上刚点了「允许」，最多 20 秒后才会反映出来。自动化环境的检查不缓存。每次 adb 调用最多 3 秒，缓存未命中时响应最慢约 8 秒，请求超时应设得比这更长。

### 4.3 ev 事件（k）
| k | d |
|---|---|
| `msg.user` | `{id,clientId,text,attachments,ts}` |
| `msg.assistant` | `{id,text,interrupted?,proactive?,ts}`：完整消息，在流式结束时发送 |
| `chat.cleared` | `{clearedAt:number}`：清空聊天的持久标记；使用事件本身的 `seq` 作为幂等边界 |
| `ui.render` | `{card:Card}` |
| `ui.patch` | `{id,props}`：对 props 做浅合并 |
| `task.upsert` | `Task` |
| `task.remove` | `{ids:string[]}`：这些任务已被 `tasks.clear` 清除，客户端从本地删除（本地没有的 id 忽略）。找不到任务的 `task_progress` 卡片应隐藏或标为「已清除」 |
| `session.upsert` | `Session` |
| `approval.request` | `Approval` |
| `approval.resolved` | `{id,decision,by:"user"\|"butler"\|"timeout"}` |
| `memory.changed` | `{}` |
| `settings.changed` | `Settings` |

### 4.4 live 事件（k）
| k | d |
|---|---|
| `msg.delta` | `{id,text}`：追加文本 |
| `msg.start` | `{id,proactive?}` |
| `butler.status` | `{state:"idle"\|"thinking"\|"acting"\|"waiting",detail?,tool?}`，见下方说明 |
| `session.progress` | `{sessionId,text}`：Codex 当前在做什么 |

**`butler.status`**：`state:"acting"`（Orbit 正在调用工具）时带 `detail` 和 `tool`，其余 `state` 不带这两个字段。
- `detail`：给人看的中文短语，如「派出任务」「在手机上操作」「整理结果」「请求你确认」，客户端可直接显示，不要改写或拼接。没有专门短语的工具（网页检索等）统一为「处理中」。早期 host 把工具原名放在 `detail` 里，客户端遇到形如 `codex_session_create` 的 `detail` 时应显示「处理中」。
- `tool`（可选）：工具原名，如 `codex_session_create`、`phone_task`。只用于调试或选图标，不要展示给用户；遇到不认识的值忽略即可。
- 完整的「工具名 → 短语」对照表在 host 的 `src/butler/activity.ts`。`yield`（结束本轮）不会产生 `acting`，状态直接回到 `idle`。

### 4.5 数据结构
```ts
Attachment = {kind:"image"|"file"|"link", name?, mime?, dataB64?, url?}
ImportItem = {kind:"photo"|"link"|"text"|"file"|"reminder"|"note", title?, text?, url?, mime?, dataB64?, createdAt?}
DeviceContext = {timezone, locale, now, location?:{lat,lon,accuracy,placeName?}, battery?:{level,charging},
                 network?:"wifi"|"cellular"|"none", focus?:string, upcomingEvents?:[{title,start,end,location?}],
                 reminders?:[{title,due?,done}], deviceName}
Card = {id, component, props, actions?:[{id,label,style?:"primary"|"secondary"|"destructive",requiresApproval?}], msgId?, ts}
Task = {id,title,goal,status:"planning"|"running"|"waiting_user"|"blocked"|"done"|"failed"|"cancelled",
        steps:[{id,title,status:"pending"|"running"|"done"|"failed"|"skipped",sessionId?}],
        summary?, createdAt, updatedAt}
Session = {id,taskId?,title,model?,status:"running"|"idle"|"waiting_approval"|"error"|"archived",
           permission:"manual"|"auto",mcpServices?:string[],lastActivity?,createdAt,updatedAt}
Approval = {id,title,detail,risk:"low"|"medium"|"high",sessionId?,kind:"command"|"fileChange"|"permissions"|"elicitation"|"action",
            requireBiometric,createdAt,expiresAt?}
Memory = {id,text,kind:"profile"|"preference"|"fact"|"person"|"place"|"date",source:"explicit"|"inferred",confidence,createdAt,updatedAt}
Settings = {butler:{name,avatar?:string /* data:image/jpeg;base64 或 emoji:🐱 */,userTitle,persona},
            models:{butler,heartbeat,codexDefault?,butlerEffort?,heartbeatEffort?,codexEffort?},
            proactivity:"low"|"normal"|"high", heartbeatMinutes, quietHours:{start:"HH:mm",end:"HH:mm"},
            dailyNotifyBudget, defaultPermission:"manual"|"auto", allowAutoFullAccess}
```
所有 `ts`、`createdAt` 等时间字段均为 Unix 毫秒。

`Session.mcpServices` 是 Host 为恢复普通执行线程保存的可选 MCP 服务 ID 列表，不包含凭据或服务配置。旧客户端可忽略该字段；未选择 MCP 或旧版会话可以缺省。

**`Settings.models`（模型与推理强度）**：`butler` / `heartbeat` / `codexDefault` 是模型 id，`butlerEffort` / `heartbeatEffort` / `codexEffort` 是对应的推理强度，取 Codex 的名字（如 `minimal` `low` `medium` `high` `xhigh` `max`，某个模型能选哪些见 `models.list` 里它的 `efforts`）。模型 id 为空字符串表示「自动」；三个强度为空字符串、`null` 或缺省都表示「自动」。`settings.set` 里三个强度必须是 `""`（或 `null`，host 存成 `""`）或匹配 `^[a-z]{1,16}$`，否则返回错误「无效的推理强度」。三组设置各管一件事：
- **bot**：模型 = `butler`（空 = Codex 目录的默认模型）；强度 = `butlerEffort`（空 = `medium`）。
- **心跳**：只用于「这一批事件全部是心跳」的那一轮（混着别的事件就按 bot 的）。模型 = `heartbeat`（空 = 跟随 bot 模型）；强度 = `heartbeatEffort`（空 = 跟随 bot 强度）。bot 的 Codex 线程始终按 `butler` 模型建立，不会因为心跳模型不同而新建或切换。
- **执行任务**（Codex worker）：模型规则不变（`codexDefault` 非空就用它，空则由 bot 按任务选）。强度 = `codexEffort`：非空就一律用它；空则用 bot 创建任务时传的 `effort`；两者都没有就不指定，由 Codex 自己的默认值决定。

host 每轮都会明确指定模型（bot 模型为空时解析成 Codex 的默认模型 id），避免心跳那一轮的模型被 Codex 沿用到下一轮对话。host 还会用缓存的模型目录检查强度：目标模型的 `efforts` 非空而且不含所选强度时，这个强度不会发给 Codex（改按上面各组「空 = 自动」的规则处理），host 日志里记一条警告，那一轮不会因此失败。所以主人换了模型之后，旧的强度设置可以原样保留，App 不用替他清掉。

**`Approval.detail` 的写法**（`kind:"action"`，即 Orbit 的 `request_approval`）：多行文本，每行一项 `标签：内容`（全角冒号），最后单独一行以 `批准后：` 开头，说明批准之后会发生什么。例如：
```
餐厅：鮨 · 静安店
时间：10月18日 周六 19:00
费用：人均约 ¥280，到店付款
批准后：我会向餐厅提交预订，并把结果告诉你
```
这只是显示层约定：host 不校验，原样存储和转发。App 把形如「标签：内容」（全角或半角冒号）的行排成表格，`批准后：` 行单独作为说明，其余文字照原样显示。不符合约定的 `detail`（例如 Codex 命令审批里的命令原文）整段原样显示，不能因为解析失败而丢内容。

## 5. Generative UI 组件目录（Card.component → props）
| component | props |
|---|---|
| `text_card` | `{title?,markdown,icon?}` |
| `link_preview` | `{url,title,description?,imageUrl?,siteName?}` |
| `table` | `{title?,columns:[{key,label,align?}],rows:[{[key]:string\|number}],footnote?}` |
| `document` | `{title,markdown,attachments?:[{name,url}]}` |
| `calendar_events` | `{title?,events:[{id?,title,start,end,location?,calendar?,color?}]}` |
| `video` | `{url,title?,posterUrl?}` |
| `image_gallery` | `{title?,images:[{url,caption?}]}` |
| `map_place` | `{name,address?,lat,lon,rating?,phone?,url?}` |
| `choice_list` | `{question,options:[{id,label,detail?}],multi?}` 选中后回 `ui.action{actionId:"select",value:[ids]}` |
| `form` | `{title,fields:[{key,label,type:"text"\|"number"\|"date"\|"time"\|"select"\|"toggle",options?,placeholder?,required?,value?}],submitLabel?}` 提交后回 `ui.action{actionId:"submit",value:{…}}` |
| `order_card` | `{merchant,items:[{name,qty,price,note?}],fees?:[{label,amount}],total,currency:"CNY",eta?,status:"draft"\|"confirming"\|"placed"\|"delivering"\|"done"\|"failed",imageUrl?}` |
| `ticket_card` | `{kind:"train"\|"flight"\|"movie"\|"show"\|"bus",title,from?,to?,departAt?,arriveAt?,venue?,seat?,price?,currency?,status:"options"\|"holding"\|"booked"\|"failed",code?}` |
| `booking_card` | `{kind:"restaurant"\|"hotel"\|"appointment"\|"other",name,time,partySize?,address?,status:"draft"\|"pending"\|"confirmed"\|"failed",confirmation?,note?}` |
| `task_progress` | `{taskId}`：客户端根据 task.upsert 实时渲染 |
| `approval_card` | `{approvalId}`：客户端根据 approval.request 渲染 |
| `comparison` | `{title?,items:[{id,title,subtitle?,imageUrl?,price?,pros?:[],cons?:[],highlight?}],recommendedId?}` |
| `memory_saved` | `{memoryId,text}`：自带"撤销"按钮，回 `ui.action{actionId:"undo"}` |

客户端遇到未知 component 时，退化为 `text_card` 渲染 `props` 的 JSON 摘要。

