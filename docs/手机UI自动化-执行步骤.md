# 手机 UI 自动化接入：执行步骤（交接给实施 agent）

[English](phone-ui-automation.md) | **简体中文**

日期：2026-10-15，修订版 v2。仓库在 `/Users/herrysyu/Documents/OpenPersonalAgent`；参考项目是 `/Users/herrysyu/Documents/ChatGPT/OpenMuse`，只读，不要修改。

## 0. 背景与目标

- 微信 Mac 端会拦截 computer use，所以原先「微信小程序 / 公众号走 Mac 微信」的方案行不通。
- 新方案：把 OpenMuse 的手机自动化能力迁移过来，做成 **Codex 能调用的 MCP 工具**。凡是电脑上做不了的事，比如微信小程序、公众号、只有手机 App 的服务、需要手机登录状态的操作，都交给手机 UI 自动化完成。
- 用户的手机目前**没有连上**。本轮先把代码写完，并让离线测试全部通过；真机测试由用户回去做，见第 7 节。

开始前请先阅读以下文件：
- `docs/方案.md`
- `skills/china-services/SKILL.md`
- `host/src/codex/bridge.ts`
- `host/src/butler/{butler,brain,tools,prompt}.ts`
- OpenMuse 的 `loong/skills/autoglm.py`
- OpenMuse 的 `loong/devices/android.py`（只需看 `_parse_foreground_activity` 和相关正则）
- `phone/.venv` 安装好以后的 `phone_agent/config/prompts_zh.py`

## 1. 用户已确认的决策（必须照做）

1. **敏感点击自动放行**。用户明确同意保留 OpenMuse 的 `confirm=lambda _: True` 语义：手机上的支付、隐私类按钮不再请用户审批，直接执行。代价是每一次敏感点击都要写审计日志（见步骤 2.4）。**登录、验证码、扫码这类操作依然交还给人**，因为自动化本来就完成不了，不属于审批。
2. **设备**：用户的小米 Android 手机专门给 agent 使用，具体信息为：
   - 型号 `23116PN5BC`，序列号 `e7fe2f2a`
   - Android 17 / API 37，分辨率 1440×3200，密度 560
   - 前台识别要读 `topResumedActivity`，`mCurrentFocus` 在这台机器上不存在

   默认 `OPA_PHONE_SERIAL=e7fe2f2a`。V1 只支持 Android（ADB）。因为是专用机，不需要考虑「会打扰用户的主力机」。
3. **手机子 agent 的模型与 Codex agent 设置保持一致，不再使用智谱 autoglm-phone，也不需要额外的 API Key**。做法是由一个 Codex worker session 充当手机子 agent：
   - 模型沿用现有 Codex session 的规则：优先取 `settings.models.codexDefault`，否则用 `bridge.defaultModel()`，计费走 ChatGPT 订阅。
   - MCP server 只负责底层的「看屏幕 / 点 / 滑 / 输入」原语，**不调用任何模型**。
   - 视觉理解和决策循环由 Codex worker 完成：截图通过 MCP 的 `ImageContent` 交给模型，模型再回调 tap、swipe 等工具。
   - OpenMuse 和 Open-AutoGLM 里关于动作的经验（坐标网格、动作规则、`_DECISIVE_RULES`）改写成 skill，挂给这个 worker 使用。

## 2. 现状要点（已核实）

- Host 是 TypeScript，测试命令为 `cd host && npx tsc --noEmit && OPA_HOME=/tmp/opa-test npx vitest run`，当前 19 个用例全部通过。
- 大脑本身也是一个 Codex thread（`brain.ts`），关闭了 shell、apps、plugins 这些内置能力，我们的工具以 dynamic tools 的形式注册给它。真正干活的是 worker session，由 `bridge.createSession` 创建，`thread/start` 的 `config` 可以按 thread 覆盖配置（大脑就是用这种方式关闭内置功能的）。
- 审批路由在 `butler.ts` 的 `onApprovalAsk`，MCP elicitation 由 `bridge.ts` 中处理 `mcpServer/elicitation/request` 的分支负责。目前 Codex 在调用 MCP 工具时也可能发起 elicitation（`_meta.codex_approval_kind = "mcp_tool_call"`），之前测试 computer use 时就见过。
- OpenMuse 对 Open-AutoGLM 的 ADB 层做过几处修复，都要迁移过来：
  - 前台 App 识别：读 `topResumedActivity`
  - 支持用包名启动 App
  - 截图压缩为 JPEG（边长不超过 1280），同时保留原始像素尺寸，用于坐标换算
  - 坐标采用 0–999 网格（`_to_device_point`），数值超过 999 时视为真实像素
- 依赖情况：`mcp==2.3.0` 可从 PyPI 安装，已验证包含 `mcp.server.fastmcp`。上游 ADB 工具库是 `phone-agent @ git+https://github.com/zai-org/Open-AutoGLM.git@86f55382982fb054e8fc98ca80609dff8a2cdc3c`（`phone_agent.adb.*`、`phone_agent.config.apps.APP_PACKAGES`）。本机已有 `uv` 0.11.6 和 Python 3.12。

## 3. 架构

```
大脑(Codex thread) ──phone_task──▶ host 创建「📱 手机子 agent」worker session
                                   （模型 = Codex 默认/设置；thread/start 时注入 orbit_phone MCP + phone-automation skill）
手机子 agent(Codex) ──MCP tools/call──▶ orbit-phone（Python，stdio，无模型）──ADB──▶ 小米手机
          ▲  observe 返回截图(ImageContent)+前台App+可选UI树摘要         │
          └──────────── tap/swipe/type/back/home/launch… ◀──────────────┘
```

- 新建 Python 包 `phone/`，它是一个独立的 MCP stdio server，名字叫 `orbit_phone`。
- **只**在手机子 agent 的 worker session 里注入：通过 `thread/start` 参数中的 `config.mcp_servers.orbit_phone` 按 thread 注入，**不要**写进全局 `~/.codex/config.toml`，否则大脑和其他 session 也会拿到手机工具。
- 这个 worker 要关掉 computer use（`config.features.computer_use=false`），避免它去操作 Mac。shell 保留，方便它读写工作区文件。
- 每个 Codex session 都会拉起自己的 MCP 进程，所以设备锁和取消信号必须**跨进程**生效，用文件锁加取消标记文件实现。

## 4. 实施步骤

### 步骤 1：Python 包 `phone/`（MCP server，不调用模型）

```
phone/
  pyproject.toml        # name=orbit-phone, requires-python>=3.11
  orbit_phone/__init__.py
  orbit_phone/adb.py    # 迁移 OpenMuse 的 ADB 修复：前台解析、包名启动、截图压缩、坐标换算
  orbit_phone/lock.py   # 跨进程设备锁 + 取消标记
  orbit_phone/server.py # FastMCP stdio 入口：python -m orbit_phone.server
  tests/test_*.py
```
依赖必须精确固定版本：`mcp==2.3.0`、`phone-agent @ git+…@86f55382982fb054e8fc98ca80609dff8a2cdc3c`（只用它的 `phone_agent.adb` 和 `config.apps`，**不用** `PhoneAgent` / `ModelClient`）、`Pillow==12.3.0`。dev 依赖为 `pytest==9.1.1`、`pytest-asyncio==1.4.0`。用 `uv sync` 生成 `uv.lock`，venv 放在 `phone/.venv`。

**adb.py**：
- `list_devices()`：解析 `adb devices -l`。
- `pick_serial()`：优先用 `OPA_PHONE_SERIAL`（默认 `e7fe2f2a`），否则取唯一一台状态为 `device` 的设备；找不到时返回明确错误。
- `status(serial)`：返回亮屏/锁屏状态、前台包名和 Activity（从 OpenMuse 的 `_parse_foreground_activity` 及其正则迁移）、ADB Keyboard 是否已安装、屏幕尺寸。
- `screenshot(serial)`：返回压缩后的 JPEG base64，以及原始宽高。迁移自 OpenMuse 的 `_install_screenshot_fix`；遇到 `is_sensitive`（例如密码页黑屏）时要如实标注。
- `ui_tree(serial, max_nodes=120)`：可选，调用 `uiautomator dump`，只保留可点击或带文字的节点，坐标换算成 0–999 网格。密码框和输入框里的内容要**打码**（参照 OpenMuse `android.py` 的 `_SENSITIVE_WORDS`）。如果 dump 失败，返回空列表，不要报错。
- `to_device_point()`：迁移 `_to_device_point`。
- 其余动作直接调用 `phone_agent.adb` 的 tap、double_tap、long_press、swipe、back、home、type_text、clear_text、detect_and_set_adb_keyboard、restore_keyboard，以及打过「包名启动」补丁的 launch_app。
- 所有 adb 调用都用参数数组，不经过 shell 字符串。

**lock.py**：
- 锁文件为 `~/.opa/phone/<serial>.lock`（`fcntl.flock`），持有者把任务描述写进文件。
- 取消标记文件为 `~/.opa/phone/<serial>.cancel`。
- 提供 `acquire(task) / release()`。

**server.py**：用 FastMCP 实现。以下工具描述要写清楚用途、何时使用、参数含义和坐标约定（0–999 网格，左上角为 0,0）：
- `phone_begin(task: str)`：获取设备锁、清除取消标记，返回 `status` 和第一次 `observe` 的结果。拿不到锁时返回 `busy` 和当前持有者。
- `phone_observe(include_tree: bool = True)`：返回 `ImageContent`（截图）加 `TextContent`（JSON 格式，包含前台 App、屏幕尺寸、是否敏感页面，以及可选的 UI 树摘要）。
- `phone_tap(x, y)`、`phone_double_tap`、`phone_long_press(x, y, ms=800)`、`phone_swipe(x1, y1, x2, y2, ms=300)`、`phone_type(text)`（输入前自动切到 ADB Keyboard，输入后恢复原输入法）、`phone_clear_text`、`phone_back`、`phone_home`、`phone_launch(app)`（接受 `APP_PACKAGES` 里的中文名或包名）、`phone_wait(seconds≤10)`。
  - 每个动作执行后等待约 0.6 秒，再**自动附带一张新截图**返回，省掉一次 observe 往返。
  - 每个动作执行前检查取消标记，发现已取消就返回 `cancelled`。
  - 没有持锁（没调用 begin）时直接拒绝执行。
- `phone_end(summary: str)`：保存一张最终截图到 `~/.opa/phone/evidence/<ts>.jpg`，释放锁，返回截图路径。
- `phone_devices()`、`phone_cancel()`：只读或控制类工具，标注 `readOnlyHint`。
- 不调用任何模型，所以不需要 API Key。
- **stdout 是 MCP 协议通道**：`phone_agent.adb` 部分函数会 `print`，因此启动时要把 `sys.stdout` 重定向到 stderr，只把真正的 stdout 留给 MCP transport。另外加一个测试，证明 stdout 没有被污染。
- 进程退出时，如果还持有锁，要释放掉。

**测试**（全部离线，mock 掉 `subprocess.run` / `phone_agent.adb`）：
- 坐标换算的边界情况
- 前台 Activity 解析（使用 OpenMuse 里 Android 17 的 dump 样例）
- 设备锁互斥：两个进程或线程
- 取消标记生效
- 未 begin 就调用动作时被拒绝
- UI 树打码
- 用 MCP 内存 client 调用 `phone_devices` 和 `phone_observe`，验证 `ImageContent` 结构
- stdout 未被污染

### 步骤 2：Host 接线（TypeScript）

1. 新增 `host/src/phone/config.ts`，提供 `phoneMcpConfig()`，返回值为 `{ command: <repo>/phone/.venv/bin/python, args: ['-m','orbit_phone.server'], env: { OPA_PHONE_SERIAL, OPA_HOME }, startup_timeout_sec: 30, tool_timeout_sec: 120 }`。
   - `OPA_PHONE_CMD` 可以覆盖 command。
   - venv 不存在时返回 `undefined`，同时给出原因。
   - 字段名用 Codex `config.toml` 中 `mcp_servers` 的写法。**动手前**先用 `codex app-server generate-json-schema --experimental` 或 `config/read` 核对字段名。
   - 再用一次真实的 `thread/start` 加 `mcpServerStatus/list` 验证：注入 `config.mcp_servers.orbit_phone` 之后，该 thread 上能看到这个 server。验证可以用 `host/scripts` 下的脚本，不需要真机。
2. `bridge.ts` 的 `CreateSessionOpts` 增加 `phone?: boolean`。为 true 时，`thread/start.config` 合并 `{ mcp_servers: { orbit_phone: phoneMcpConfig() }, features: { computer_use: false } }`。模型选择不变：`o.model ?? defaultModel()`，与其他 Codex session 一致。phone 不可用时抛错，错误信息里给出 `opa phone setup` 提示。
3. `tools.ts`：
   - 新增 `phone_task(title, goal, china=true, task_id, step_id, deliverable)`。它创建 `phone: true` 的 session，标题前缀 `📱`，挂上 skill `phone-automation`，`china` 为 true 时再加 `china-services`，模型取 `settings.models.codexDefault`。
     - 任务单模板写明：必须用 orbit_phone 工具在手机上完成；先调用 `phone_begin`，最后调用 `phone_end`；不要操作 Mac；结尾输出结构化 JSON。
     - 同一时间只允许一个 📱 session，判断方式参照 `computer_use_task` 的 🖥。
   - `computer_use_task` 的描述里去掉微信相关内容，改为「微信 / 手机 App 一律用 phone_task」。
   - 新增只读工具 `phone_status`，返回 `phoneMcpConfig()` 是否可用以及原因。
4. 审批（敏感点击自动放行）：在 `bridge.ts` 的 elicitation 分支里，`serverName === 'orbit_phone'` 时**直接 accept，不经过 `onApprovalAsk`**。每次都要执行 `db.audit('phone', 'auto-accept', {thread, tool: meta.tool_name, params: meta.tool_params_display})`，所以 bridge 需要一个 `audit` 回调，由 Butler 注入。同理，如果 Codex 对 orbit_phone 的 MCP 工具调用发起 `item/permissions/requestApproval` 之类的审批，也一律自动通过。
   - 可选：如果 Codex 支持在 `mcp_servers` 里配置工具审批模式（例如 `default_tools_approval_mode` / `approval_mode`），就在注入配置时设为不询问。请核对 schema 后再决定。
   - **登录、验证码、扫码不在放行范围内**：skill 要求子 agent 遇到这些情况时调用 `phone_end`，并返回 `status:"needs_human"`；大脑收到后用 `notify` 和 `ask_user` 通知用户去手机上处理。
5. `prompt.ts`：在资源说明里加入「**手机（phone_task）**」一节，说明以下几点：
   - 电脑做不了的事交给手机；微信小程序和公众号一律走手机。
   - 手机是专用的小米，可以放心操作。
   - 手机上的敏感点击（支付等）会自动执行，所以**派单前要确认用户意图**：用户明确要下单、付款时才写进任务单，否则任务单里必须写「只查询，不要下单 / 付款」。
   - 被占用时等待前一个任务完成。
   - 结果要验收。
6. `butler.ts` 的 `statusBar()` 增加一行「手机：可用 / 未配置（原因）」。
7. `cli.ts`：
   - 新增 `opa phone setup`：在 `phone/` 下执行 `uv sync`。
   - 新增 `opa phone status`：打印配置、执行 `adb devices -l`，检查 ADB Keyboard 和「USB 调试（安全设置）」是否就绪。后者的检查方法：尝试一次 `input keyevent 0`，失败则提示用户开启。
   - **不需要** `set-key`。
8. 测试：
   - `phoneMcpConfig` 的单元测试。
   - 扩展 `test/fake-codex.mjs`，记录 `thread/start` 的 config。在 `loop.test.ts` 里断言：大脑调用 `phone_task` 之后，worker 的 `config.mcp_servers.orbit_phone` 存在、`features.computer_use === false`、所用模型与其他 session 相同；大脑 thread 的 config 里**没有** `orbit_phone`。
   - orbit_phone 的 elicitation 会被自动 accept 并写入 audit，其他 server 仍然走原有审批流程。

### 步骤 3：Skills 与文档

1. 新建 `skills/phone-automation/SKILL.md`（给手机子 agent 用，也同步一份到 Codex 侧，方法同 `opa install-skills`）。内容改写自 Open-AutoGLM 的 `prompts_zh.py` 动作规范和 OpenMuse 的 `_DECISIVE_RULES`：
   - 工作循环：`phone_begin` → 看截图与 UI 树 → 每次只做一个动作 → 根据返回的新截图判断效果 → … → `phone_end`。
   - 坐标约定：0–999 网格；优先点 UI 树里给出的元素中心点，没有 UI 树时再按截图估算。
   - 打开 App 用 `phone_launch`。输入文字前先点中输入框，再调用 `phone_type`。
   - 查询类任务在当前屏幕已能回答时立刻结束，不要为了补全信息反复点进详情。同一位置最多点两次，没反应就换别的方式。
   - 弹窗处理：广告和更新提示直接关掉；系统权限弹窗中，定位类授权，手机号、隐私类按任务需要授权。
   - 遇到登录、验证码、扫码、人脸识别时，立即 `phone_end` 并返回 `needs_human`，说清楚需要用户做什么。
   - 支付、下单：只在任务单明确授权时执行，否则停在确认页，返回订单信息并标记 `needs_approval`。
   - 结尾以 JSON 返回，字段与 GenUI 卡片（order_card / ticket_card / booking_card / table）对齐，并附上 evidence 截图路径。
2. 改写 `skills/china-services/SKILL.md`：
   - 微信小程序、公众号、服务一律走手机，通过 `phone_task`。手机上的路径是：打开微信 → 顶部搜索 → 搜一搜 → 筛选「小程序 / 公众号 / 服务」→ 打开目标。
   - 删除 Mac 微信的 computer use 流程，并注明原因。
   - 有网页端的服务继续用浏览器；只有 App 的服务用手机。
   - 结构化 JSON 结尾的要求不变。
   - 「不付款」改为「仅在任务单明确授权时付款」。
3. 更新 `docs/方案.md`：§5.1 和 §3 加入 orbit_phone，并注明手机子 agent 与 Codex 共用模型和计费。同步更新 `README.md` 和 `host/README.md` 的上手步骤。

### 步骤 4：一次性设备准备（写进 README，供用户照做）

1. 小米手机：在开发者选项里打开「USB 调试」和「**USB 调试（安全设置）**」。不打开后者，无法注入点击和输入。用 USB 连接 Mac，在手机上授权。
2. 安装 ADB Keyboard（从 https://github.com/senzhk/ADBKeyBoard 的 release 下载 apk）：执行 `adb install ADBKeyboard.apk`，然后在手机设置里启用它。
3. 手机上装好并登录微信、美团等 App；在开发者选项里开启「充电时不锁屏」或设置较长的息屏时间；关闭锁屏密码，或保持解锁状态。
4. 依次执行 `opa phone setup`、`opa phone status`。
5. 可选的无线连接：`adb pair` → `adb connect`，然后设置 `OPA_PHONE_SERIAL=<ip:port>`。

## 5. 约束（必须遵守）

- 不修改 OpenMuse 仓库，只复制代码。
- 不把 `orbit_phone` 写进全局 `~/.codex/config.toml`；大脑 thread 不能拿到手机工具。
- 手机子 agent 不单独配置模型，也不引入新的 API Key，与 Codex session 使用同一套模型选择逻辑。
- 敏感点击自动放行，但每一次都要记录审计日志。登录、验证码依旧交还给人。
- 依赖版本精确固定；adb 调用不经过 shell 字符串；UI 树和日志里的输入框内容要打码。
- 不改动 iOS 工程和 `docs/protocol.md`。
- 不做 git commit，除非用户要求。

## 6. 验收（离线，本轮必须全部通过）

```bash
cd phone && uv sync && .venv/bin/python -m pytest -q
cd host && npx tsc --noEmit && OPA_HOME=/tmp/opa-test npx vitest run
```

另外需要手动冒烟：
- 不连接手机，直接运行 `phone/.venv/bin/python -m orbit_phone.server`，用一个小的 MCP client 调用 `phone_devices`。预期返回空列表和一段清楚的提示，进程不崩溃。
- 用真实 Codex 创建一个 `phone: true` 的 session，调用 `mcpServerStatus/list`，确认能看到 `orbit_phone` 及其工具列表。

最后提交报告，写明改了哪些文件、测试结果，以及哪些项必须在真机上验证。

## 7. 用户真机测试清单（实施 agent 不执行，只写进报告）

1. `opa phone status`：能看到 `e7fe2f2a`，状态为 `device`，ADB Keyboard 和 USB 调试（安全设置）都已就绪。
2. 只读任务：「在手机微信里搜一下"瑞幸咖啡"小程序，告诉我附近门店」。预期依次出现任务卡、📱 session 和结构化结果，期间不会下单。
3. 授权下单：「用美团帮我点一杯 xx 咖啡，直接付款」。预期手机子 agent 自动点击支付，audit 里留下 `auto-accept` 记录，最后返回 order_card。（请在可以接受真实扣款的前提下测试。）
4. 未授权下单：「用美团看看 xx 咖啡多少钱」。预期停在确认页之前，返回价格，不付款。
5. 登录或验证码：遇到时返回 `needs_human`，iPhone 收到通知。
6. 取消：任务进行中点停止或在任务页中止，手机在下一步停下，并释放设备锁。
7. 占用：同时下达两个手机任务，第二个提示设备正忙，等第一个完成后再执行。

