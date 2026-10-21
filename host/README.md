# OPA Host（Mac 端管家）

管家大脑、Codex 控制层和 iPhone 网关，常驻在 Mac 上。要求 Node ≥ 22.13，并已安装、登录 `codex` CLI。大脑与 worker 使用 Codex，不需要单独 OpenAI API Key；所有 worker（普通 session、computer use、手机 worker，以及复用 session 新开的一轮）优先使用设置里的「执行模型」`settings.models.codexDefault`，该设置为空（自动）时才用 bot 自己选的模型，再没有就沿用 Codex 的默认模型。

```bash
cd host
npm install
npx tsx src/cli.ts config relay wss://<你的-worker>.workers.dev  # 外网访问时配置
npx tsx src/cli.ts install-skills          # 链接 china-services 与 phone-automation
npx tsx src/cli.ts start
npx tsx src/cli.ts pair                    # 另开终端，显示二维码并核对 SAS
npx tsx src/cli.ts chat                    # 终端和管家对话
npx tsx src/cli.ts launchd                 # 生成登录自启的 LaunchAgent
```

安装了 Host 的 `opa` 命令后，可用 `opa <命令>` 代替 `npx tsx src/cli.ts <命令>`。

## 启动、关闭和重启

本机已安装 `opa`。在终端启动电脑端，并保持该窗口打开：

```bash
opa start
```

- 关闭：回到启动窗口，按 **Control+C**。
- 重启：先按 **Control+C**，进程退出后再执行 `opa start`。
- 查看状态：另开终端执行 `opa status`。

本机现有的 `~/.local/bin/opa` 是测试实例入口，默认数据目录为 `/tmp/opa-live`、端口为 `7488`。直接在 `host/` 执行 `npm start` 使用的默认目录为 `~/.opa`、端口为 `7420`；继续使用已配对的实例时保持同一入口与环境变量。以上关闭 / 重启方法适用于终端前台启动；若另行启用了 LaunchAgent，应通过 launchctl 管理该后台服务。

模型列表在 Host 的动态目录基础上补充 `GPT-6.1 Sol`（`gpt-6.1-sol`），bot、心跳与 Codex 默认模型均可选。服务器已返回该模型时保留其元数据，不重复添加，也不自动改变已保存的选择。补充目录选项并不等于已验证当前账号能完成该模型的推理请求。

## 清除聊天记录

iPhone App 的聊天页右上角菜单提供「清除聊天记录」，确认后清空聊天并开始新的对话上下文。长期记忆、任务、执行会话和配对信息保留，独立任务继续运行。需要连接 Mac；清除成功后同步到其他已配对设备，离线设备在重连时更新。更新此功能需要同时使用新版 Host 和重新构建的 App。

| 目录 | 内容 |
|---|---|
| `src/codex/` | app-server JSON-RPC 客户端与生成的协议类型 |
| `src/phone/` | 手机 MCP 配置、可用性、取消标记与通知监听 |
| `src/gateway/` | 配对、E2E 加密、LAN WebSocket、Bonjour、Relay、推送 |
| `src/butler/` | Codex 大脑、动态工具、任务调度、GenUI、记忆和通知 |
| `../phone/` | Python Android MCP 服务与离线测试 |

数据默认在 `~/.opa/`。设置 `OPA_HOME`、`OPA_PORT` 可运行隔离实例。

## Android 手机准备

V1 使用专用小米 Android 手机（`23116PN5BC`，默认序列号 `e7fe2f2a`）。服务 MCP / 已连接插件能完成的步骤优先使用接口，再考虑可行网页；只有确需手机 App 或手机登录态时才派手机 worker。这台专用手机不能用微信，Mac 微信也会拦截 computer use；没有其他可行入口时，由主人在自己的微信完成。

Mac 先准备 `uv`、Python ≥ 3.11 和 Android Platform Tools（`adb` 在 PATH 中），然后：

1. 在手机开发者选项开启「USB 调试」和「**USB 调试（安全设置）**」。只开前者可能能截图却不能点击、输入。USB 连接 Mac，在手机上信任此电脑。
2. 从 [ADB Keyboard releases](https://github.com/senzhk/ADBKeyBoard/releases) 下载 APK，执行 `adb -s e7fe2f2a install ADBKeyboard.apk`，在手机设置里启用该输入法。工具输入前临时切换，结束后恢复原输入法。
3. 装好并登录实际需要的独立服务 App（例如美团）；保持解锁，可开启「充电时不锁屏」或延长息屏时间。
4. 在 `host/` 执行：

```bash
npx tsx src/cli.ts phone setup             # 在 ../phone 执行 uv sync
npx tsx src/cli.ts phone status            # 配置、ADB 设备、输入法、安全调试诊断
npx tsx src/cli.ts install-skills
```

无线连接可使用 `adb pair <ip:配对端口>` → `adb connect <ip:调试端口>`，再为 Host 设置 `OPA_PHONE_SERIAL=<ip:调试端口>`。重启 Host 使环境变量生效。

## 手机配置与运行

- `OPA_PHONE_SERIAL`：目标设备，默认 `e7fe2f2a`。设备未连接或未授权时返回明确错误，不操作其他已连接设备。
- `OPA_PHONE_CMD`：覆盖 MCP 启动命令，默认 `../phone/.venv/bin/python`，参数仍为 `-m orbit_phone.server`。
- `OPA_HOME`：手机锁、取消标记、截图和 Host 数据的根目录，默认 `~/.opa`。

`phone_task` 创建标题为 `📱` 的 Codex worker，挂载 `phone-automation`，中国服务再挂 `china-services`。`orbit_phone` 经该线程的 `config.mcp_servers` 注入，关闭 computer use，保留 shell 供工作区文件使用。不要把它写进全局 `~/.codex/config.toml`，大脑和普通 worker 不应有手机工具。

MCP 服务固定依赖 `mcp==2.3.0`、`Pillow==12.3.0` 与指定提交的 `phone-agent`，不实例化 PhoneAgent / ModelClient、不调用模型。该 MCP 版本公开入口是 `MCPServer`，原执行文档中的 `FastMCP` 名称已迁移；服务行为仍为 stdio MCP。

worker 用 `phone_begin` 获取跨进程设备锁，每次动作后读取自动附带的新截图，最后 `phone_end` 保存证据并释放锁。锁与取消文件在 `OPA_HOME/phone/`，证据在 `OPA_HOME/phone/evidence/`。同一时间只运行一个手机任务；忙时等待已有 session 完成。停止聊天或取消任务会通知手机停止，已经执行的操作不会撤销。

手机的敏感点击自动放行并审计；只有任务单明确授权下单、付款才允许执行，否则必须只查询、不下单、不付款。登录、验证码、扫码、人脸识别需要人工时，worker 结束并释放锁，交回 `needs_human`，管家通知主人处理后再继续。UI 树与审计中的输入值脱敏，截图可能包含页面可见信息，保存在本机证据目录。

## 手机通知

专用手机收到的新通知会唤醒 bot，由它决定要不要告诉主人、怎么说（规则见 `skills/butler-core` 的「手机通知」一节）。Host 每 30 秒执行一次只读的 `adb -s <serial> shell dumpsys notification --noredact`，不占用手机设备锁，可与手机 worker 同时运行；只依赖 adb，`opa phone setup` 没做也会轮询。

- 过滤：跳过通知组汇总、常驻 / 前台服务通知、重要性 ≤ 1、标题和正文都为空的，以及 `android`、`com.android.systemui`、`com.miui.securitycenter` 等系统包。
- 去重：以 `key + when` 记一个已见集合（内存，最多 2000 条）。Host 启动后第一次成功轮询只记录、不唤醒：手机上已有的通知不算新通知。
- 合并限流：新通知先攒着，距上次唤醒不足 3 分钟（主人的勿扰时段内 15 分钟）就继续攒；每次最多带 8 条，标题截 40 字、正文截 120 字，其余写「另有 N 条」。
- 隐私：通知正文只交给 bot；日志和审计只记数量和包名（审计 `phone / notifications`）。
- 开关：默认开启。`opa config phone-notify on|off` 写入 `config.phoneNotify`，运行中的 Host 下一次轮询就会读到；环境变量 `OPA_PHONE_NOTIFY=0` 也能关闭。`OPA_PHONE_NOTIFY_POLL_MS` 改轮询间隔（毫秒，默认 30000，最小 1000），设备沿用 `OPA_PHONE_SERIAL`。
- 找不到 adb、手机离线或超时只记一条 debug 日志（`OPA_LOG=debug` 可见），下个周期再试，不会打扰 bot。

## 上下文管理

bot 的大脑是一个长期存在的 Codex thread，历史只增不减。Host 用两个办法控制它的大小：状态栏只发变化，空闲时自动压缩。

- **状态栏只发变化**：每一轮事件后面的状态栏按固定分段（`time`、`presence`、`phone`、`device`、`calendar`、`reminders`、`tasks`、`sessions`、`approvals`、`schedules`、`imports`、`memory`）拼装。`time` 每轮都发，其他分段只在内容和「上次发给当前这个 thread 的版本」不同时才发；某段从有变成没有，发一次「（无）」。状态栏开头有一句「只列出与上次相比有变化的部分；没列出的沿用之前的状态」。thread 换了、压缩完成后、Host 刚启动，下一轮发完整状态栏。
- **记忆在状态栏里**：记忆摘要放在 `memory` 分段，不在固定说明里，所以改记忆不会让 bot 换 thread。固定说明（身份、工具、技能、模型）变了才会新建 thread，升级到这个版本后的第一轮会新建一次。
- **自动压缩**：一轮处理完、收件箱空了、即将空闲时检查。最近一次请求的上下文达到阈值就让 Codex 把历史压缩成摘要（`thread/compact/start`，最长等 180 秒）。阈值由环境变量 `OPA_BRAIN_COMPACT_TOKENS` 设置，默认 60000；已知模型上下文窗口时，最多取窗口的 60%。
- **执行期间不压缩**：有 `planning` / `running` 的任务、有 `running` / `waiting_approval` 的 session、有待审批、手机任务正在启动、距上次压缩不足 5 分钟、收件箱里有排队的事件，这些情况下都不压缩，等下一轮结束再检查。
- **压缩期间**：新消息先排队、不会插入正在运行的 turn，压缩结束后立刻处理；App 不显示「思考中」，压缩前的 token 数记在日志和审计（`bot / compact`）里。
- **失败的退路**：压缩失败或超时，就换一个新 thread，把最近的对话摘要带过去，旧 thread 归档；下一轮发完整状态栏。

## 国内服务方法发现

国内生活 / 办事任务先由管家加载 `china-service-discovery`，搜索当前可行方法和官方入口，核对地区、登录与工具能力后再拆解、派单。技能内的服务地图提供 App / 网站候选，不固定平台；查到必须用手机的步骤才创建手机 worker。这条前置流程写在始终加载的 `butler-core`，Host 会自动读取仓库技能索引，无需额外安装到 worker。

## 内置 MCP 服务

国内外服务目录覆盖高德、12306、飞书、Playwright、网页 Fetch、Tavily、GitHub 和 Notion。大脑先 `mcp_list` 查配置，再在普通执行线程的 `mcp_services` 中选择服务；需要凭据的项不会被当成已连接。手机线程和现有 ChatGPT 插件保持各自接入方式。

用 `opa mcp init` 创建实例内配置，`opa mcp list` 查看状态，`opa mcp check rail_12306 fetch playwright` 检查无 Key 服务；ModelScope 标准配置可通过 `opa mcp import <json-path>` 导入。完整服务说明、凭据变量与配置示例见 [内置 MCP 服务](../docs/mcp-services.md)。

## 验证

在仓库根目录执行：

```bash
cd phone
uv sync
.venv/bin/python -m pytest -q
cd ../host
npx tsc --noEmit
OPA_HOME=/tmp/opa-test npx vitest run
OPA_HOME=/tmp/opa-phone-smoke npx tsx scripts/smoke-phone.ts
```

`smoke-phone.ts` 使用真实 app-server 创建手机线程并检查该线程的 MCP 工具列表，同时验证普通线程的隔离；仅进行设备枚举，不执行手机点击，也不需要模型推理。无手机时应返回空设备列表与清楚的提示。其他冒烟脚本：`scripts/smoke-host.ts`（模拟 iPhone 配对）、`scripts/smoke-bridge.ts`（真实 Codex session）。

手机接回后按顺序验证：

1. `opa phone status` 能看到 `e7fe2f2a` 为 `device`，ADB Keyboard 和安全调试就绪。
2. 查询「在手机微信搜索瑞幸咖啡，告诉我附近门店」：任务卡、手机 session 和结构化结果正常，过程中不下单。
3. 查询「用美团看看某杯咖啡多少钱」：返回价格，不下单、不付款。
4. 在愿意实际扣款时，明确授权指定商品与金额的下单、付款任务：验证支付结果、订单卡和手机审计记录。
5. 登录、验证码等场景返回 `needs_human`，iPhone 收到通知，设备锁已释放。
6. 停止聊天、取消任务后，手机在当前动作边界停止并释放锁；随后新任务能获取设备。
7. 同时下达两个手机任务，第二个等待第一个结束，设备不会被交叉操作。
8. 手机收到一条真人消息或外卖通知：约 30 秒内 bot 被唤醒并用一两句话告诉你；广告和系统通知不会打扰你。`opa config phone-notify off` 后不再唤醒。

离线测试和无设备冒烟不能证明真机的权限、输入、微信路径或支付已可用；这些必须接机后确认。
