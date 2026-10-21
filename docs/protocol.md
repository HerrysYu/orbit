# OPA Wire Protocol v1

**English** | [简体中文](protocol.zh-CN.md)

Shared by the Host (Mac), Relay (Cloudflare Worker), and iOS app. Any protocol change must be reflected in all three implementations.

## 1. Identity and keys

- Each side holds an **Ed25519 identity key**. The public key is 32 raw bytes and is transmitted as base64 (standard alphabet, with padding).
- `hostId = hex(sha256(hostPub))[0..32]` (32 lowercase hex characters); `deviceId` uses the same algorithm.
- Each connection generates an **ephemeral X25519 key**; its public key is 32 raw bytes.

## 2. Handshake (plaintext JSON text frames)

device → host
```json
{"t":"hello","v":1,"deviceId":"…","devicePub":"b64","deviceName":"Herry 的 iPhone",
 "ephPub":"b64","ts":1760000000000,"pairToken":"可选","sig":"b64"}
```
`sig = Ed25519(devicePriv, utf8("opa-hello-v1|" + hostId + "|" + ephPub + "|" + ts))`, where `ephPub` is the base64 string and `ts` is a decimal string.

Host checks: `|now - ts| < 5min`; `deviceId == id(devicePub)`; the signature is valid; and either (a) the device is allowlisted, or (b) `pairToken` is valid and has not been used.

host → device
```json
{"t":"welcome","v":1,"ephPub":"b64","sig":"b64","paired":true,"hostName":"Herry 的 Mac"}
```
`sig = Ed25519(hostPriv, utf8("opa-welcome-v1|" + deviceId + "|" + ephPubD + "|" + ephPubH))`. The device verifies it using `hostPub` from the QR code.
On validation failure, the Host sends `{"t":"reject","reason":"…"}` and closes the connection.

### Session keys
```
shared = X25519(myEphPriv, peerEphPub)
salt   = ephPubD_raw || ephPubH_raw          (64 bytes)
kD2H   = HKDF-SHA256(shared, salt, info="opa-v1-d2h", 32)
kH2D   = HKDF-SHA256(shared, salt, info="opa-v1-h2d", 32)
SAS    = (u32be(sha256("opa-sas" || ephPubD_raw || ephPubH_raw)[0..4]) mod 1_000_000), zero-padded on the left to 6 digits
```

### Encrypted frames
```json
{"t":"x","n":0,"c":"b64(ciphertext||tag16)"}
```
- Algorithm: ChaCha20-Poly1305 (IETF). `nonce = 0x00000000 || u64be(n)`, `aad = utf8("opa-v1")`.
- Each direction maintains its own `n`, starting at 0 and incremented after every sent frame. The receiver must close the connection when `n <= lastN`.
- Plaintext is an app message defined in §4 (JSON, UTF-8).

### Pairing
1. Run `opa pair` on the Mac to display a QR code. Its content is the following JSON encoded as base64url, with prefix `opa://pair?d=`:
   ```json
   {"v":1,"hostId":"…","hostPub":"b64","hostName":"…","lan":[{"host":"192.168.1.5","port":7420}],
    "relay":"wss://opa-relay.example.workers.dev","pairToken":"…","exp":1760000300000}
   ```
2. The device includes `pairToken` in `hello`. The Host sends `welcome{paired:false}`. The encrypted channel is now established, but the Host processes pairing-related frames only.
3. Both sides display the SAS. After the user confirms on the Mac, the Host sends encrypted message `{"t":"pair.result","d":{"ok":true}}`, adds the device to the allowlist, and enters a normal session. If the user rejects, the Host sends `{ok:false}` and disconnects.

## 3. Transport

### 3.1 Local network

- `ws://<ip>:7420/v1/ws`. TLS is unnecessary because the application layer already provides end-to-end encryption and mutual authentication.
- Bonjour service type `_opa._tcp`, with `hostId=…` in its TXT record.
- iOS must configure `NSLocalNetworkUsageDescription` and `NSBonjourServices=[_opa._tcp]`, and ATS `NSAllowsLocalNetworking`.

### 3.2 Relay (Cloudflare Worker + Durable Object, one DO instance per hostId)

Host connection:
`wss://RELAY/v1/host/<hostId>?pub=<b64url>&ts=<ms>&sig=<b64url>`
where `sig = Ed25519(hostPriv, "opa-relay-host-v1|" + hostId + "|" + ts)`. Relay must verify `id(pub) == hostId`; if `ALLOWED_HOST_IDS` is configured, it must also check that `hostId` is in the list.

Device connection:
`wss://RELAY/v1/device/<hostId>?deviceId=…&pub=<b64url>&ts=<ms>&sig=<b64url>[&pair=1]`
where `sig = Ed25519(devicePriv, "opa-relay-device-v1|" + hostId + "|" + deviceId + "|" + ts)`. The device must be in the allowlist sent by the Host, or `pair=1` must be set while the pairing window is open.
(All base64 in URL query parameters uses base64url without padding.)

Frame format (all are JSON text frames):
| Direction | Frame |
|---|---|
| device→relay | Forward the data string unchanged: the `hello` / `x` frames defined in §2 |
| relay→host | `{"from":"<deviceId>","data":"<原字符串>"}` |
| host→relay | `{"to":"<deviceId>","data":"<字符串>"}` |
| relay→device | Forward `data` unchanged |
| host→relay control | `{"relay":"allow","devices":[{"id":"…","pub":"b64"}]}` (replace the full allowlist) |
|  | `{"relay":"pairing","until":<ms>}` |
|  | `{"relay":"push","id":"…","deviceToken":"hex","env":"sandbox\|production","pushType":"alert\|liveactivity\|background","topic":"bundleId[.push-type.liveactivity]","priority":10,"collapseId":"可选","expiration":0,"payload":{…}}` |
| relay→host control | `{"relay":"device_connected","deviceId":"…"}` / `{"relay":"device_disconnected","deviceId":"…"}` / `{"relay":"push_result","id":"…","status":200,"reason":"…"}` |
| relay→device control | `{"relay":"host_online"}` / `{"relay":"host_offline"}` |

- Only one connection is kept per `deviceId`; a new connection replaces the old one. The same applies to the Host.
- After the Host disconnects, Relay sends `host_offline` to all devices. When the Host reconnects, Relay sends `host_online`; devices must perform a new handshake after receiving it.
- Relay **does not cache** messages. Messages the app cannot send while offline are stored in its local outbox and sent after reconnecting.
- Configure APNs credentials as Worker secrets: `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`.
- `push_result` contains only the push `id`, not a token: when sending `push`, the Host records `id → token`. If `status` is 410, or `reason` is `BadDeviceToken` / `Unregistered` / `ExpiredToken`, the Host deletes the corresponding token. For `DeviceTokenNotForTopic` (bundle ID mismatch) and `ApnsNotConfigured` (Relay has no APNs key), it keeps the token and logs a notice once.

## 4. App messages (plaintext inside encrypted frames)

### 4.1 Frame types

| t | Direction | Shape | Description |
|---|---|---|---|
| `req` | D→H | `{t,id,m,d}` | Request; `id` is generated by the client |
| `res` | H→D | `{t,id,ok,d?,err?}` | Response to a request |
| `ev` | H→D | `{t,seq,ts,k,d}` | **Persistent event**. `seq` increases monotonically and events can be replayed |
| `live` | H→D | `{t,k,d}` | Temporary, non-persistent event, such as streaming delta or status |
| `pair.result` | H→D | `{t,d:{ok}}` | Pairing result |

### 4.2 Request methods (`m`)

| m | d | res.d |
|---|---|---|
| `sync` | `{lastSeq}` | `{fromSeq,toSeq,reset,chatCleared?:{seq,clearedAt}}`. The Host then sends `ev` events in order. `reset=true` means the gap is too large; the client should clear its local event cache and the Host replays the recent window. `chatCleared` is the persistent marker for the most recent chat clear and is returned even if its event is outside the replay window; omitted if chat has never been cleared. The client processes this marker before replaying its outbox. Before processing the first `sync` for a connection, the Host sends no `ev` / `live` to it (any `ev` generated during this interval is sent by this `sync`; `live` is not replayed; `req` / `res` are unaffected), so the client must send `sync` after every (re)connection |
| `chat.send` | `{clientId,text,attachments?:[Attachment]}` | `{msgId,duplicate?:true}`. Idempotent by `clientId`; see below |
| `chat.clear` | `{}` | `{cleared:true,seq,clearedAt}`. Clears chat and resets the butler conversation context; `seq` is for the corresponding `chat.cleared` event and `clearedAt` is Unix milliseconds |
| `chat.interrupt` | `{}` | `{}` |
| `ui.action` | `{cardId,actionId,value?}` | `{}` |
| `approval.respond` | `{approvalId,decision:"approve"\|"deny",note?}` | `{}` |
| `task.cmd` | `{taskId?,sessionId?,cmd:"interrupt"\|"steer"\|"archive"\|"cancel",text?}` | `{}` |
| `tasks.clear` | `{ids?:string[]}` | `{removed:string[],skipped:string[]}`. Clears **ended** (`done`/`failed`/`cancelled`) tasks; see below |
| `session.detail` | `{sessionId}` | `{session,items:[{kind,text,ts}]}` |
| `context.update` | `DeviceContext` | `{}` |
| `import.add` | `{items:[ImportItem]}` | `{ids}` |
| `settings.get` | `{}` | `Settings` |
| `settings.set` | `Partial<Settings>` (deep merge). If `models.butlerEffort` / `heartbeatEffort` / `codexEffort` is invalid, returns error `"无效的推理强度"`, and the entire settings update is rejected; see §4.5 |
| `models.list` | `{}` | `{butler:[ModelOption],codex:[ModelOption]}`, where `ModelOption = {id,displayName,isDefault,efforts:string[],defaultEffort?:string}` (`butler` items also have `description?`). `efforts` are reasoning efforts supported by that model, from Codex `supportedReasoningEfforts`, and **may be empty** (the Host does not know; do not hide an effort already set for this reason). `defaultEffort` is that model's default and may be omitted. Includes the manually added `gpt-6.1-sol` (`defaultEffort:"medium"`; this does not mean the account is verified as able to call it) |
| `memory.list` | `{}` | `{items:[Memory]}` |
| `memory.add` | `{text,kind?}` | `Memory` |
| `memory.delete` | `{id}` | `{}` |
| `push.register` | `{kind:"alert"\|"liveactivity"\|"pushToStart",token,env,activityId?,taskId?,bundleId?}` | `{}`. `bundleId` is the app's own bundle ID; the Host prefers it for the APNs topic, as described below |
| `devices.list` | `{}` | `{devices:[{id,name,pairedAt,lastSeen}]}` |
| `phone.status` | `{}` | `{available:boolean,reason?:string,serial:string,device?:{serial,state,model?},adbKeyboard?:boolean}`. Status of the dedicated Android phone; read-only, see below |
| `ping` | `{}` | `{ts}` |

**`chat.send` idempotency**: When `clientId` is non-empty, the Host deduplicates on it (the record is persistent and survives Host restarts). If the same `clientId` arrives again, the Host does not create another `msg.user` or send it to Orbit again; it directly returns the original `{msgId,duplicate:true}`. This remains true even if `text` or attachments differ; the first content wins, so a new message must use a new `clientId`. The first response does not include `duplicate`. An empty or missing `clientId` cannot be deduplicated, so each request is treated as new. Thus, after reconnecting, the app can safely replay its local outbox; `duplicate:true` also counts as successful delivery.

**`chat.clear`**:
- Clears Host history for `msg.user` / `msg.assistant` / `ui.render` / `ui.patch` and chat cards, resets the butler's current thread, short-term context, and old user-input queue. Late replies from an old turn must not be written back. It interrupts only the butler's current conversation; it does not cancel an independent worker or phone task.
- Keeps long-term memory, tasks, execution sessions, approvals, settings, pairing, imported data, scheduling, and audit records. Keeps `client_msgs` deduplication metadata so an old `clientId` from a cleared message still cannot execute twice. The global event sequence continues increasing.
- Deletion of chat events and insertion of `chat.cleared` happen in the same database transaction. The event may arrive before the RPC response. The client handles it idempotently by the clear `seq` boundary; a late response must not delete new messages created after the clear. After receiving a clear marker, the client must also clear old local chat, old pending messages, and old streaming state, and persist the marker.
- Persist the most recent `{seq,clearedAt}` separately and return it from `sync`, so a device offline for a long time cannot miss a clear event. Processing the marker must not roll back global `lastSeq` or delete new chat with a `seq` greater than the marker.
- The app requires a second confirmation; when offline or a request fails, it must not clear optimistically. This feature manages Orbit chat and context; it does not delete thread archives or diagnostic logs held by Codex or other third-party services.

**`tasks.clear`**:
- Without `ids`, clear every ended task. With `ids`, clear only ended tasks among them; active tasks (`planning`/`running`/`waiting_user`/`blocked`) and nonexistent IDs remain unchanged and go in `skipped`. `ids:[]` clears nothing; if `ids` is not an array, return an error.
- Codex sessions belonging to cleared tasks are also archived: the Host immediately marks them archived (broadcast `session.upsert` with `status:"archived"`), then notifies Codex in the background to archive the corresponding threads. The response does not wait, so a slow Codex response does not delay the request. Codex archive failure does not change the clear result; the session remains archived in Host. Status changes during background archival (for example, an interrupted turn ending) must not unarchive it.
- At most one `task.remove {ids}` is broadcast per call (none if no tasks were cleared). Both `task.remove` and the `session.upsert` above are emitted before the response. The client removes tasks locally based on the event; `removed` in the response is only for a message such as "已清除 N 项".
- Calls are repeatable: an ID already cleared is placed in `skipped` on a later call; it is not an error.

**`push.register`**:
- Optional `bundleId` is the app's own bundle ID and must match `^[A-Za-z0-9.-]{1,155}$`; omit it if missing or invalid. Store it with the token and update it if that token is registered again.
- When sending a push, the Host prefers the `bundleId` registered for that token as the APNs topic: `alert` uses `<bundleId>`, and `liveactivity` / `pushToStart` uses `<bundleId>.push-type.liveactivity`. If no `bundleId` is registered for the token, use the Host's configured bundle ID (`opa config bundle-id`, default `com.haoyuanyu.orbit`).

**`phone.status`**: Used to show the real status of Orbit's dedicated Android phone in Settings. Read-only: the Host asks adb what devices exist and does not operate the phone.
- `serial`: Orbit's bound phone, from Host `OPA_PHONE_SERIAL`, default `e7fe2f2a`. Always returned.
- `device`: adb's view of this phone; `state` is the raw adb value: `device` (available), `unauthorized` (the phone has not allowed this Mac to debug), `offline`, etc. `model` is the model reported by adb (spaces replaced with underscores) and may be absent. If adb is unavailable or does not list this phone, omit the entire `device` field.
- `adbKeyboard`: whether ADB Keyboard is installed. Present only when `device.state` is `device` and the check completed; omission means **unknown**, not "not installed".
- `available`: `true` only when adb works, the phone is online with `state` equal to `device`, and the Host phone-automation environment is installed. `reason` is present if and only if `available` is `false`; it is a Chinese sentence suitable for direct display that explains the first issue encountered and what to do: adb missing or timed out → phone not connected or a different phone is connected → phone unauthorized or offline → automation environment not installed.
- This request does not fail: missing adb, timeout, or error is represented by `available:false` and `reason`, not `ok:false`. `available:true` does not check "USB debugging (Security settings)" (verifying it requires sending an empty key event, which this request does not do), or whether ADB Keyboard is enabled as an input method. Only `opa phone status` on the Mac checks those two things, so the UI must not say "全部就绪".
- The Host caches adb results for 20 seconds, including failures, so repeatedly opening Settings does not start adb every time; an approval tapped on the phone may take up to 20 seconds to appear. The automation-environment check is not cached. Each adb call takes at most 3 seconds; on a cache miss the response may take about 8 seconds, so request timeouts must be longer.

### 4.3 Persistent events (`ev`, `k`)

| k | d |
|---|---|
| `msg.user` | `{id,clientId,text,attachments,ts}` |
| `msg.assistant` | `{id,text,interrupted?,proactive?,ts}`: complete message, sent at the end of streaming |
| `chat.cleared` | `{clearedAt:number}`: persistent marker for clearing chat; use the event's own `seq` as the idempotency boundary |
| `ui.render` | `{card:Card}` |
| `ui.patch` | `{id,props}`: shallow merge into props |
| `task.upsert` | `Task` |
| `task.remove` | `{ids:string[]}`: these tasks were cleared by `tasks.clear`; the client removes them locally (ignore IDs absent locally). Hide or mark as "已清除" any `task_progress` card whose task is missing |
| `session.upsert` | `Session` |
| `approval.request` | `Approval` |
| `approval.resolved` | `{id,decision,by:"user"\|"butler"\|"timeout"}` |
| `memory.changed` | `{}` |
| `settings.changed` | `Settings` |

### 4.4 Live events (`live`, `k`)

| k | d |
|---|---|
| `msg.delta` | `{id,text}`: append text |
| `msg.start` | `{id,proactive?}` |
| `butler.status` | `{state:"idle"\|"thinking"\|"acting"\|"waiting",detail?,tool?}`, see below |
| `session.progress` | `{sessionId,text}`: what Codex is currently doing |

**`butler.status`**: When `state:"acting"` (Orbit is calling a tool), include `detail` and `tool`. For every other `state`, omit both fields.
- `detail`: a short Chinese phrase for people, such as "派出任务", "在手机上操作", "整理结果", or "请求你确认". Display it directly; do not rewrite or concatenate it. Use "处理中" for tools without a dedicated phrase (such as web search). Earlier Hosts put the tool's original name in `detail`; when a client sees a value like `codex_session_create`, it should display "处理中".
- Optional `tool`: original tool name, such as `codex_session_create` or `phone_task`. For debugging or choosing an icon only; do not display it to the user. Unknown values can be ignored.
- The full "tool name → phrase" map is in Host `src/butler/activity.ts`. `yield` (ending a turn) does not produce `acting`; status returns directly to `idle`.

### 4.5 Data structures

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
Settings = {butler:{name,avatar?:string /* data:image/jpeg;base64 or emoji:🐱 */,userTitle,persona},
            models:{butler,heartbeat,codexDefault?,butlerEffort?,heartbeatEffort?,codexEffort?},
            proactivity:"low"|"normal"|"high", heartbeatMinutes, quietHours:{start:"HH:mm",end:"HH:mm"},
            dailyNotifyBudget, defaultPermission:"manual"|"auto", allowAutoFullAccess}
```
All `ts`, `createdAt`, and similar time fields are Unix milliseconds.

`Session.mcpServices` is an optional list of MCP service IDs the Host stores for restoring an ordinary execution thread. It contains no credentials or service configuration. Older clients can ignore it; sessions without selected MCP services or from older versions can omit it.

**`Settings.models` (models and reasoning effort)**: `butler` / `heartbeat` / `codexDefault` are model IDs; `butlerEffort` / `heartbeatEffort` / `codexEffort` are reasoning efforts using Codex names (such as `minimal`, `low`, `medium`, `high`, `xhigh`, `max`; see `efforts` in `models.list` for the values a model supports). An empty model ID means "automatic". Each of the three effort values means "automatic" when empty, `null`, or omitted. In `settings.set`, each effort must be `""` (or `null`, stored by Host as `""`) or match `^[a-z]{1,16}$`; otherwise it returns `"无效的推理强度"`. The three groups of settings have separate roles:
- **bot**: model = `butler` (empty means the default model in the Codex catalog); effort = `butlerEffort` (empty means `medium`).
- **heartbeat**: used only for a turn where the whole batch of events consists of heartbeats (if mixed with other events, use the bot settings). Model = `heartbeat` (empty follows the bot model); effort = `heartbeatEffort` (empty follows the bot effort). The bot's Codex thread is always created with model `butler`; a different heartbeat model does not create or switch threads.
- **execution task** (Codex worker): model behavior is unchanged (`codexDefault` when non-empty, otherwise the bot chooses based on the task). Effort = `codexEffort`: when non-empty, always use it; when empty, use `effort` passed by the bot when creating the task; if neither exists, omit it and let Codex use its default.

The Host explicitly specifies the model on every turn (resolving an empty bot model to the Codex default model ID) so Codex does not carry the heartbeat model into the next conversation turn. The Host also checks effort against its cached model catalog: when the target model's `efforts` is non-empty and does not include the chosen effort, it omits that effort to Codex (handling it according to the "empty = automatic" rule for the relevant group) and logs a warning; the turn does not fail. Thus, after the owner changes models, old effort settings can remain unchanged and the app need not clear them.

**Writing `Approval.detail`** (`kind:"action"`, i.e. Orbit's `request_approval`): use multiline text with one `标签：内容` item per line (full-width colon), followed by a final separate line beginning with `批准后：` that explains what will happen after approval. For example:
```
餐厅：鮨 · 静安店
时间：10月18日 周六 19:00
费用：人均约 ¥280，到店付款
批准后：我会向餐厅提交预订，并把结果告诉你
```
This is a display-layer convention: Host does not validate it and stores / forwards it unchanged. The app lays out lines matching `标签：内容` (full-width or half-width colon) as a table and shows the `批准后：` line separately as a note; it shows all other text as-is. If `detail` does not follow the convention (for example, the command text in a Codex command approval), display the entire text unchanged; do not discard it if parsing fails.

## 5. Generative UI component catalog (`Card.component` → props)

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
| `choice_list` | `{question,options:[{id,label,detail?}],multi?}`. After selection, returns `ui.action{actionId:"select",value:[ids]}` |
| `form` | `{title,fields:[{key,label,type:"text"\|"number"\|"date"\|"time"\|"select"\|"toggle",options?,placeholder?,required?,value?}],submitLabel?}`. On submit, returns `ui.action{actionId:"submit",value:{…}}` |
| `order_card` | `{merchant,items:[{name,qty,price,note?}],fees?:[{label,amount}],total,currency:"CNY",eta?,status:"draft"\|"confirming"\|"placed"\|"delivering"\|"done"\|"failed",imageUrl?}` |
| `ticket_card` | `{kind:"train"\|"flight"\|"movie"\|"show"\|"bus",title,from?,to?,departAt?,arriveAt?,venue?,seat?,price?,currency?,status:"options"\|"holding"\|"booked"\|"failed",code?}` |
| `booking_card` | `{kind:"restaurant"\|"hotel"\|"appointment"\|"other",name,time,partySize?,address?,status:"draft"\|"pending"\|"confirmed"\|"failed",confirmation?,note?}` |
| `task_progress` | `{taskId}`: rendered live by the client from `task.upsert` |
| `approval_card` | `{approvalId}`: rendered by the client from `approval.request` |
| `comparison` | `{title?,items:[{id,title,subtitle?,imageUrl?,price?,pros?:[],cons?:[],highlight?}],recommendedId?}` |
| `memory_saved` | `{memoryId,text}`: includes an "undo" button; returns `ui.action{actionId:"undo"}` |

When the client encounters an unknown component, fall back to rendering a JSON summary of `props` as `text_card`.
