---
name: codex-orchestration
description: 把工作派给 Codex session 时加载。规定任务单、模型、权限、复用、打断、验收和监控；优先选择当前可用且有权限的服务 MCP / 插件，电脑或手机 UI 仅在接口和可行网页无法覆盖时使用。
---

# codex-orchestration：派发与管理 Codex session

## 1. 先判断要不要开 session

每项外部服务任务在选路前，按相关性查看 `mcp_list` 和/或 `connectors_list`，只查与目标步骤有关的能力。目标步骤已被当前可用且有权限的服务 MCP / 插件覆盖时优先使用。`configured` 只表示本机配置齐备，不代表连接成功或账号有权访问；以实际暴露的工具和调用结果为准。单步 connector 操作用 `connector_call`；多步任务派给 Codex，并点名已列出的插件 / MCP；内置目录 MCP 需通过 `codex_session_create.mcp_services` 明确选择，不能假设已直接加载。缺少接口或权限时停止重试并说明所需连接 / 授权；若用户没有指定渠道且公开网页可行，再用搜索 / 浏览器。电脑或手机 UI 只作接口与网页均无法覆盖时的后备，并在任务单写出当次实际原因。不要自动安装、修改连接、获取凭据或调用未知服务。国内服务另先加载 `china-service-discovery` 检索当前官方方法。保留用户指定渠道、操作授权和同一会话里的 MCP 选择。

| 情况 | 做法 |
|---|---|
| 已连接 connector 能完成的单步查询 / 明确读写 | 直接 `connector_call`；写操作遵循现有授权 |
| 只有内置 MCP 覆盖单步操作 | 开执行会话并通过 `mcp_services` 选择它，在任务单里点名操作 |
| 多步操作、跨服务整合或需要专用 MCP | `codex_session_create`；点名当前列出的插件和所选 MCP |
| 服务接口未覆盖，但官方公开网页能完成 | 直接搜索回答，或用可行的浏览器路径；Playwright MCP 也须按需确认并选择 |
| 目标确实要求界面操作，且服务接口 / 网页无法覆盖 | Mac 图形界面用 `computer_use_task`；确实只有手机 App / 手机登录态时才用 `phone_task` |
| 用户指定渠道 | 按指定渠道执行；若其技术限制无法完成，说明原因再请主人选择，不静默换渠道 |
| 专用手机或 Mac 微信 | 该手机不能用微信，Mac 微信会拦截 computer use；若当前没有覆盖任务的已授权接口或独立网页，说明限制并让主人在自己的微信完成 |
| 和某个进行中 session 是同一件事的延续 | 复用该 session（`codex_session_send`） |

## 2. 新建 / 复用 / steer / interrupt

- 新建：新的独立目标；或者旧 session 上下文已经很长、方向完全变了；或者需要不同的模型 / 权限 / cwd。
- 复用（`codex_session_send`）：同一 Task 的下一步，且需要用到前一步的上下文（例如"刚才查到的三家，帮我看第二家的菜单"）。session 处于 idle 时才 send。
- Steer（`codex_session_steer`）：session 正在跑，用户补充或修正了要求（"预算改成 300 以内"、"只要靠窗"）。不打断，让它在当前 turn 里吸收。
- Interrupt（`codex_session_interrupt`）：用户取消；session 明显跑偏且 steer 无效；session 在做可能有害的事；超出预算。interrupt 后视情况重新 send 一条修正后的任务单。
- Fork（`codex_sessions_fork`）：要从同一个中间状态分头尝试两个方案时用。
- Archive：Task 完成且没有后续时归档，保持看板干净。

## 3. 任务单模板（每次 create 或 send 新任务都用）

~~~text
## 目标
<一句话，可验证的结果。例：在美团外卖找到 3 家 30 分钟内送达、人均 50 元以内的川菜，停在下单前。>

## 背景
<只放完成任务必需的信息：地点、时间、相关偏好（"不吃香菜"）、上一步结果摘要。不要放无关记忆。>

## 约束
- 不付款，到支付页停止
- 不给任何联系人发消息
- 预算 / 时间 / 渠道限制：<…>
- 只读 / 可写的范围：<…>

## 权限
<当前是 manual 还是 auto；哪些操作需要回报而不是直接做。>

## 工具
<需要用的插件或 skill，按名字写。例：使用 Google Calendar 插件；使用 Google Drive 插件；使用 china-services skill。>

## 交付格式
最后一条消息必须以 ```json 代码块结尾，字段：
<列出字段及类型，例如 {"status","items":[{"name","price","eta"}],"screenshots":[]}>
没拿到的字段填 null，不要编造。

## 遇阻怎么办
遇到登录、验证码、手机号授权、价格/商户与预期不符、需要付款或发消息：立即停止，按交付格式回报 status="blocked" 或 "needs_approval"，写明原因。不要猜测，不要绕过。
~~~

能用 `outputSchema` 时同时传结构化 schema，交付字段与 GenUI 组件 props 对齐（订单→`order_card`，票→`ticket_card`，预约→`booking_card`，多项比较→`comparison`/`table`），这样结果可以直接渲染。

手机任务使用 `phone_task` 的模板：必须 `orbit_phone`，先 `phone_begin`，结束 `phone_end`，不操作 Mac。只有用户明确授权下单、付款时才把授权范围写进任务单；否则保留「只查询，不要下单 / 付款」。手机号与隐私权限按任务需要处理，登录、验证码、扫码、人脸识别交还人，返回 `needs_human`。

## 4. 选模型和 effort

模型由主人设置里的「执行模型」（`models.codexDefault`）决定：

- 主人指定了执行模型（非空）：所有 worker 一律用它，包括 `codex_session_create`、`computer_use_task`、`phone_task`，以及 `codex_session_send` 在 session 空闲时新开的一轮（主人中途换了执行模型，下一轮就切到新的）。此时 `codex_session_create` 的 `model` 参数不生效，不用传，也不要为了换模型新开 session；`steer` 换不了模型。
- 主人把执行模型设为「自动」（空）：才由你选。`codex_session_create` 的 `model` 传 `codex_models` 列表里的 id；`computer_use_task`、`phone_task`、`codex_session_send` 没有 `model` 参数，沿用 Codex 默认档。

推理强度（effort）同理，由主人设置里的「执行任务推理强度」（`models.codexEffort`）决定：

- 主人指定了强度（非空）：所有 worker 的每一轮都用它，包括 `codex_session_create`、`computer_use_task`、`phone_task`，以及 `codex_session_send` 在 session 空闲时新开的一轮。此时 `codex_session_create`、`codex_session_send` 的 `effort` 参数不生效，不用传，也不要为了换强度新开 session；`steer` 换不了强度。
- 主人把强度设为「自动」（空）：才由你选。`codex_session_create`、`codex_session_send`（session 空闲、新开一轮时）的 `effort` 参数传 low / medium / high / xhigh；`computer_use_task`、`phone_task` 没有 `effort` 参数，沿用 Codex 默认强度。不传就是 Codex 默认。
- 你选的强度要是目标模型支持的（见 `codex_models` 的 `efforts`）；不支持的会被 host 丢弃，等于没传。

由你选的时候，先用 `codex_models` 拿当前可用列表，只使用列表里的名字，不要凭记忆写模型名：

| 任务 | 模型档位 | effort（强度为「自动」时才由你定） |
|---|---|---|
| 简单检索、查一个价格、填表、格式整理 | `isDefault` 或列表里标注快速 / mini 的档位（对应 `default_subagent_model`） | low |
| Mac computer use / 手机 UI 自动化 | Codex 默认档（不单独配置手机模型） | 无（这两个工具没有 `effort` 参数） |
| 多来源比价、行程规划、读长文档总结 | 默认档或高档 | medium |
| 复杂研究、编码、多步推理、出错代价高 | 列表中最强的档位 | high |

同一个 Task 内中途发现任务比预想复杂，可以新开一个高档 session 接手，而不是在低档 session 里反复重试（执行模型已由主人指定时无法换档，这时靠调高 effort 和任务单写清楚；执行任务推理强度也由主人指定时，两者都换不了，只能靠任务单写清楚）。

## 5. 权限

- 默认按设置 `defaultPermission`，通常是 manual（`untrusted`/`on-request` + workspaceWrite）。
- 只有在任务确实需要无人值守连续执行、且 manual 会频繁卡在审批时，才考虑升到 auto（`never` + dangerFullAccess）：
  - 设置 `allowAutoFullAccess = true` 时，可以 `codex_set_permission` 升级，并在汇报里告诉用户。
  - 否则必须先 `request_approval`，说明为什么需要、会做什么、持续多久，用户批准后再升级。
- 任务结束或阶段完成后降回 manual。
- 审批请求路由：低风险（只读命令、workspace 内写文件）自动批准；中风险自行判断并记日志；高风险（付款、发消息给他人、删除、对外发布、访问凭据）一律推给用户。
- `orbit_phone` 工具的敏感点击按用户已确认的手机策略自动放行并逐次审计，不因此升级 shell / 文件权限；派单前保证购买意图明确。手机 worker 与其他 Codex session 共用 `settings.models.codexDefault` / Bridge 默认模型和订阅计费，不需要额外 API Key。

## 6. Service MCP 与插件

- 每项外部服务任务都以当前 `connectors_list` 返回的工具和连接状态为准；只用已列出的名称。单步直接 connector 调用 `connector_call`，多步任务开 session 并在任务单点名实际工具。
- 内置目录中的服务先用 `mcp_list` 判断相关能力、启用与配置状态。`configured` 不是连接 / 鉴权证明；若只由内置 MCP 覆盖，创建 worker 时用 `mcp_services` 明确选择。工具未暴露、缺少授权或实际调用失败时停止反复尝试，说明主人需要完成的连接 / 授权；不自动安装、改配置或获取凭据。只有用户未指定渠道且公开网页方法可行时，才转网页搜索 / 浏览器。
- 如果合适的服务接口已覆盖目标步骤，不用 computer use / phone UI 做截图点击。用户指定了渠道时保留指定；只有确实无法完成时说明原因并询问替代。
- 写操作仍按原规则确认意图；付款、对外发消息、删除和发布仍走现有审批。任务单只写完成工作所需的信息。

## 7. Computer use 与手机任务

- `computer_use_task` 和 `phone_task` 是需要界面的后备路径，不是服务入口的默认选择。派发前确认相关 MCP / 插件与可行网页不能完成目标，并把当次实际原因写进任务单。用户指定设备 / 渠道时尊重指定；若它无法完成，先报告限制。
- Mac 桌面 App 或必须依赖登录态 UI 的步骤用 `computer_use_task`；只有确实只在手机 App / 手机登录态完成的步骤才用 `phone_task`。专用手机不能用微信，Mac 微信会拦截 computer use；若无可用授权接口或独立网页，就交给主人在自己的微信处理。
- 涉及中国本土服务时挂 `china-services` skill。任务单写清目标、选择界面的实际原因、停止条件；手机任务注明官方服务、预算与授权范围并挂 `phone-automation`。
- 同一时间只跑一个 computer use session：它们共享同一个屏幕和鼠标，并行会互相干扰。其他非 GUI session 可以并行。
- 用户正在用电脑时（状态栏可判断），GUI 任务先告诉用户"我需要用一下电脑大约 3 分钟"，或延后执行。
- 专用小米手机独立于 Mac，可与 Mac 任务并行；同一时间仅运行一个手机 session。忙时 `watch` 当前手机任务完成，不轮询、不抢设备锁。

## 8. 长任务与 thread goal

- 需要长时间自主推进的任务（持续一小时以上的研究、多轮编码、反复比价）用 `codex_session_goal` 设定目标和 token 预算，让 Codex 自主连续执行。
- goal 要写清完成标准和预算；同时 `watch` 它的 `thread/goal/updated` 和完成/阻塞事件。
- 不要把需要用户中途决策的任务设成 goal，拆成多段。

## 9. 监控

- 派出后立刻 `watch(session_id, "done | blocked | waiting_approval | error")`，然后 `yield`。
- 有时间预期的任务另加 `schedule`（例如预计 10 分钟，`schedule` 20 分钟后复查），防止 session 静默卡住。
- 不要在循环里反复调用 `codex_session_status`。只在被唤醒后读一次摘要；需要原文时用 `artifact_read` 读需要的范围。
- 用 `task_create` / `task_update` 同步 Task 和每个 Step 的状态，手机端的 `task_progress` 卡片依赖它。

## 10. 并行

- 互不依赖的 Step 同时开 session，例如"查高铁"和"查酒店"。
- 同时运行的 session 不超过 4 个（Mac computer use 最多 1 个，手机最多 1 个）。超出的排队。
- 并行结果回来后由你汇总成一张卡（`comparison` 或 `table`），不要每个 session 单独汇报一次。

## 11. 成本控制

- 能 `connector_call` 一步解决的不开 session；能低档模型做的不用高档。
- 任务单只带必要上下文，不要把整段对话历史塞进去。
- 复用 session 时只发增量指令。
- 给 goal 设 token 预算；session 明显绕圈（同一步失败 3 次以上、输出重复）就 interrupt，换思路或回报用户。
- 完成的 session 及时 archive。

## 12. 失败处理

| 情况 | 处理 |
|---|---|
| session 回报 blocked（登录、验证码） | 告诉用户需要做什么（"请在你自己手机的微信上确认登录"），`watch` 后续，用户完成后 `codex_session_send` 继续 |
| 手机 session 返回 needs_human | 验收已 `phone_end` 释放锁，用 `notify` 和 `ask_user` 写清人工步骤；用户完成后在同一 session 继续，重新 `phone_begin` |
| needs_approval（手机号授权、付款） | 推 `request_approval` 或审批卡，批准后继续 |
| error / 超时 / 缺权限 | 读最近产出并核实具体缺口；鉴权 / 工具缺失时不重复重试、不自动换到 GUI，说明需要的连接或授权。仅瞬时错误可做一次有依据的重试；其他渠道须用户未指定且当次能力确实支持 |
| 结果不满足完成标准 | 追问或补做，不要把不完整的结果当完成汇报 |
| 结果与用户预期冲突（价格翻倍、售罄） | 停下来给用户选项，不要自作主张换方案花钱 |

失败汇报要包括：卡在哪一步、已经尝试过什么、你推荐的下一步（用 `choice_list` 给 2–3 个选项）。
