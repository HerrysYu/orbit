# Wave 2 实施简报（WP2–WP6，并行）

前置：WP0（Host）、WP1a（设计系统）、WP1b（核心状态）已完成。先完整阅读：
1. `docs/design/implementation-plan.md`（全局规则 §1、token §2、素材 §3、接口 §4、构建 §6）
2. 本文件中**你的 WP 小节** + 「跨 WP 约定」
3. 设计稿 PNG（用 Read 打开）和 `docs/design/mockups/src/screens.js`（文案、尺寸以此为准）
4. 设计系统公开 API：`ios/OPA/Design/*.swift`、`ios/Shared/OrbitMark.swift`（`DesignGallery.swift` 有每个组件的用法示例）
5. 核心状态公开 API：`ios/OPA/Core/Store/*.swift`（`AppModel*.swift`、`AppState.swift`、`Timeline.swift`）、`ios/OPA/Core/Protocol/*.swift`。**只调用，不修改**。缺接口时先在自己的文件里用 `model.request(...)` 等现有能力实现；做不到就在报告里写明。

## 跨 WP 约定

- 呈现入口（由根视图挂载，你只改状态）：`model.openTask(id)`（切到任务 Tab 并 push 详情）、`model.openApproval(id)`（全局确认 Sheet）、`model.showActivity = true`（活动与权限）、`model.showConnection = true`（连接详情）、`model.selectedTab = .chat/.tasks/.settings`。
- 共用视图归属：`TaskProgressCard`、`ApprovalCardView` 等卡片属于 WP3（GenUI）；`SessionDetailSheet` 属于 WP4（Tasks）；`ApprovalSheet` 属于 WP4（Approval）；`ActivitySheet`、`ConnectionSheet` 属于 WP2（Chat）。别人的视图只调用、不改。
- `Features/Tasks/TasksView.swift` 里原私有 `SectionHeader` 已被改名为 `TaskSectionHeader`；新代码用设计系统的 `SectionHeader`。`GenUI/BoundCards.swift` 里已有 `StepRow`，不要重名。
- 旧组件（`ButlerAvatar`、`cardSurface`、`CapsuleButtonStyle`、`.accentFill` 等）都是 MIGRATION 别名：**你的文件里一律换成新 API**，收尾时会删除别名。注意深色模式下主按钮是杏橙底深棕字（`.primaryFill` + `.onPrimary`），不要再写死白字。
- 并行构建：只在自己的 `build-<wp>` 目录、自己的模拟器上构建（`xcrun simctl create "OPA <WP>" "iPhone Air" com.apple.CoreSimulator.SimRuntime.iOS-26-5`，构建目标写 `id=<udid>`）。加 `COMPILER_INDEX_STORE_ENABLE=NO`。新增文件后运行 `xcodegen generate`；若构建报工程文件错误，再运行一次。编译错误若出自别人的文件，等 60 秒重试，不要改别人的文件；保持自己的文件**随时可编译**（小步提交式修改）。磁盘有限：结束时 `xcrun simctl shutdown <udid>`。
- 演示模式 `-OPADemo YES` 覆盖了所有状态（见 `Core/Demo/MockHost.swift`），视觉核对用它；对照设计稿 PNG 浅色、深色各截图一次，存 `ios/screenshots/<wp>/`。
- 报告：改动文件、与设计稿的差异和原因、构建警告数（必须 0）、测试结果、截图路径、发现但未处理的问题（尤其逻辑 bug）。

## WP2 对话（`ios/OPA/Features/Chat/**`）

设计稿：`orbit-key-light.png` 第 1–2 屏、`orbit-chat-more.png` 全部、`orbit-detail.png` 第 3 屏（活动与权限）、`orbit-flows.png`。

1. **在场头部**（参考 Muse）：顶部居中 `OrbitAvatar(size: 42, ring: 正在工作时)` + 「Orbit ›」+ 一行状态（`model.presence.text`，tone → 颜色：live=AccentText 带杏橙小点，warn=Warning，neutral=InkSecondary）。点头像/名字 → `model.showActivity = true`。右上 `ConnectionIndicator` → `model.showConnection = true`。头部背景从 Canvas 渐隐到透明，内容在下面滚动。
2. **空状态**：舞台渐晕背景 + `OrbitMascot(.wave, size: 140, greet: true)` + 「Orbit · 待命中」+ 「今天想把什么交给我？」+ 说明（“我在你的 Mac 上动手。花钱、对外发送这类事，只在你明确要求或批准后才做。”）+ 最多 3 条建议胶囊（贴近输入框；点按只填入草稿）。出现第一条消息或键盘弹出时，角色用 `matchedGeometryEffect` 缩小飞入头部头像位置（Reduce Motion 时淡变）。
3. **消息流**：按 `model.timeline` 顺序；你的气泡 UserBubble 底 + OnUserBubble 字，最大宽度 82%，右下角 7pt；Orbit 气泡 OrbitBubble 底（浅色 0.5pt Hairline 描边），左下 7pt；新回复组开头才显示 20pt 头像 +「Orbit · HH:mm」；主动消息带「主动」小标签；被打断的回复标注「已停止」。发送状态行：`.queued`「待发送 · Mac 连上后自动发出」、`.failed`「没有送达」+「重试」（`model.retry(clientId:)`），`.sending` 不显示文字。卡片（`CardHost`，WP3）全宽显示在对应位置。长按气泡复制文本。
4. **思考/执行指示**：Orbit 在想但还没有文字时，消息流末尾显示 `OrbitMark(size: 22, orbiting: true)` +「正在想办法…」（或 presence 的执行文字）；流式文字整段追加，不逐字淡入，末尾杏橙小圆点光标。
5. **滚动**：只有原本在底部时才跟随新内容；上翻时新内容到达显示「↓ 有新回复」胶囊，点按回到底部。
6. **输入框**：浮动圆角 26 的 Surface 条：左「+」（打开附件托盘）、多行输入（最多 6 行后内部滚动）、右侧：`isReplying && 草稿空` → ■（`stopReply()`，无障碍标签“停止回复”）；`isReplying && 有草稿` → ■ + ↑ 两个按钮；否则 ↑（空时禁用）。占位文字：空闲「把想做的事交给 Orbit…」，工作中「补充要求，或交给 Orbit 新的事…」，离线「可以继续输入，连上后发送」。已选附件条在输入框内上方：缩略图/文件名胶囊、右上 × 移除、处理中显示进度且禁用发送。
7. **附件托盘**：替代键盘区域的面板：4 个入口（照片、文件、链接/文本、提醒事项）+ 内嵌 `PhotosPicker`（`.photosPickerStyle(.inline)`，多选）；复用现有 `ComposerDraft`/`AttachmentTray` 逻辑与 Sheet。
8. **离线横幅**：连接为离线/失败/重连等待时，头部下方 WarningSoft 横幅「Mac 暂时离线」+「消息会排队，连上后发送。正在重试…」+「详情」→ `showConnection`。
9. **ActivitySheet**（替换占位）：`OrbitAvatar(54, ring)`、「Orbit 正在做」、副标题（N 件事在进行 · Mac 连接路径）；「执行中」：运行中的会话（标题、所属任务、最新 `sessionProgress`/`lastActivity`、状态标签），点按 → `openTask(taskId)`；「最近的动作」：若模型有最近活动列表就用，否则用会话 `lastActivity` 按 `updatedAt` 取最近 5 条（只显示真实数据）；「我能做什么」：Mac 上的操作（按 `settings.defaultPermission`：manual「沙箱外的命令逐项问你」/ auto「完全访问，不再逐项询问」）、安卓手机上的操作（「敏感点击自动执行，并记录在案」），点按 → 关闭 Sheet 并 `selectedTab = .settings`。支持 `.presentationDetents([.medium, .large])`。
10. **ConnectionSheet**（替换占位）：Mac 名称、状态、连接路径（局域网/外网中继）、上次连接时间、离线时说明“消息会排队；Mac 离线不代表任务停止”、「重新连接」（用核心层现有的重连方法）、「管理设备」→ 设置。

## WP3 卡片（`ios/OPA/Features/GenUI/**`）

设计稿：`orbit-key-light.png` 第 2 屏任务卡、`orbit-chat-more.png` 第 1 屏（对比卡、紧凑审批卡）、`orbit-system.png` 组件区。

1. 所有组件统一用 `OrbitCard` + 标题/内容/元信息/操作区节奏；状态一律 `StatusChip`（ui.patch 状态变化时用设计系统的过渡动画原位更新）；按钮用 `.orbit(...)` 样式；`CardActionBar` 中 `requiresApproval` 的按钮先 Face ID 再发送，发送中禁用防重复。
2. **TaskProgressCard**：标题 + 状态标签 + ⋯ 菜单（仅进行中任务：「取消任务」→ 确认对话框说明“停止进行中的步骤，已完成的不撤销”→ `model.cancelTask`；已结束任务：「从列表清除」→ `model.clearTask`）；步骤用 `StepMarker` + 竖线，当前步骤加粗并附该步骤会话的最新进度；页脚「已完成 x / y 步 · 更新时间」+「查看任务 ›」→ `openTask`。任务已被清除时显示紧凑占位「这个任务已从列表清除」。
3. **ApprovalCardView**（对话内紧凑卡）：举手图标 +「需要你确认：<title>」+ 状态标签（待确认 / 提交中 / 已批准 · 等执行结果 / 已拒绝 / 已过期 / 提交失败）+ 一行摘要（detailRows 拼接，最多 2 行）+「查看并确认」（`openApproval`）与「拒绝」。过期或已处理后按钮隐藏并说明。
4. **对比卡**：窄屏纵向列表；推荐项 BrandSoft 底 +「推荐」标签；每项右侧「选这家」→ `sendAction(cardId, actionId: "select", value: [itemId])`；选择后本地记住选中项（按 cardId 持久在内存即可），卡上显示「已选择」，其他项按钮隐藏。**不要**伪造用户气泡。
5. choice_list / form：明确单选/多选/必填；提交后保留选择、按钮变「已提交」。
6. 订单 / 票务 / 预订：金额、时间、对象、状态突出；草稿 / 待确认 / 已确认 用不同标签样式；金额用等宽数字。
7. 其余（text、link、table、document、calendar、video、gallery、map、memory_saved、unknown）换新样式：表格横向滚动只在卡内；图片统一比例、加载失败有占位；链接卡显示站点名。
8. 修正 `InteractiveCards.swift` 里写死的白字（深色模式对比度）。

## WP4 任务与确认（`ios/OPA/Features/Tasks/**`、`ios/OPA/Features/Approval/**`）

设计稿：`orbit-key-light.png` 第 3–4 屏、`orbit-detail.png` 第 1、2、4 屏、`orbit-flows.png`。

1. **TasksView**：大标题「任务」+ 右上 `ConnectionIndicator`。分区：
   - 「需要你处理」（`attentionItems`，带数量）：审批行（举手图标、标题、所属任务 · 过期时间、「查看」→ `openApproval`）；等你补充的任务（问号气泡图标、问题摘要、「回答」→ `selectedTab = .chat`）。
   - 「进行中」：左侧 3pt 杏橙条、标题 + 状态标签、当前真实动作（该任务运行中会话的 `sessionProgress`，没有就当前步骤标题）、`SegmentedStepBar` +「已完成 x / y 步 · 相对时间」。
   - 「遇到问题」：危险图标、原因（`summary` 或当前步骤）、相对时间。
   - 「最近完成」：紧凑行（勾 / 叉 / 横线图标 + 标题 + 时间）；分区头右侧「清除」→ `confirmationDialog`「清除 N 个已结束的任务？对应的执行会话会一并归档。」→ `clearFinishedTasks()`，完成后 toast「已清除 N 个任务」；单条左滑「清除」→ `clearTask(id)`。
   - 点行 → push `TaskDetailView`（`model.tasksPath`）。空状态：`OrbitMascot(.attentive, 96)` +「这里会记录我替你做的事」+ 说明 +「去聊聊」（`.orbit(.soft)` → `selectedTab = .chat`）。下拉刷新（重新 sync 或请求最新状态，用核心层现有方法）。
2. **TaskDetailView**（替换占位）：玻璃返回/⋯ 按钮；状态标签 + 开始/更新时间；标题（26pt bold）；目标；「现在等你…」提示块（有待确认审批 → 「查看」；等你补充 → 「回到对话」）；步骤时间线（当前步骤高亮卡片，已完成步骤可展开看细节/关联会话）；「结果」：有 `summary` 显示摘要；「执行详情」列出该任务的会话（`taskSessions`）→ 打开 `SessionDetailSheet`；底部「回到对话」+「取消任务」（仅进行中，确认后显示“正在取消…”直到状态变为已取消）；已结束任务 ⋯ 里「从列表清除」（清除后 pop 回列表）。
3. **SessionDetailSheet**（重做）：图标（标题以 📱 开头 → 安卓手机，🖥 → Mac 图形界面，否则 Mac）、标题、状态 · 用时；标签：模型、权限（manual「逐项确认」/ auto「完全访问」）；动作记录（`model.sessionDetail`：时间 + 图标 + 一句话，按 kind 选 SF Symbol）；操作：「补充指令」（输入框 → `task.cmd steer`）、运行中「中止这一轮」（`task.cmd interrupt`）、「归档」。加载中/失败状态。
4. **ApprovalSheet**（全局，替换占位）：小头像「Orbit 请你确认」+ 关闭（关闭≠拒绝）；标题（23pt bold）；`KeyValueList(detailRows)`；`NoteBlock(.info, detailNote)`；风险提示（high：WarningSoft「这个操作无法撤销」类说明仅在 risk == high 时）；`requireBiometric` 时「需要 Face ID」+ 过期倒计时；主按钮动词：kind=command「允许执行」、fileChange「允许修改」、permissions「授予权限」、elicitation「允许」、action「批准」（requireBiometric 时带 Face ID 图标）；「拒绝」；来源「来自任务「…」」（通过 sessionId → 任务）。状态：提交中（禁用 + 进度）、已批准「已批准 · 等执行结果」、已拒绝、已过期（按钮禁用 + 原因）、提交失败（保留内容 + 重试）。审批 id 找不到时显示“这个确认已失效”。

## WP5 连接 Mac（`ios/OPA/Features/Pairing/**`）

设计稿：`orbit-connect.png`。

1. **欢迎**：舞台背景 + `OrbitMascot(.wave, 178, greet: true)` +「你好，我是 Orbit」+「连接你的 Mac，把想做的事交给我。」+ 三行说明（图标块 BrandSoft 底 AccentText 图标）+ 主按钮「连接我的 Mac」（→ 扫码）+ 文字按钮「粘贴配对链接」「体验演示」。
2. **扫码**：全屏相机（AVFoundation `AVCaptureSession` + `AVCaptureVideoDataOutput`，在后台队列把帧转 `CGImage`，约 15–20fps 发布到 SwiftUI `Image` 显示；用 CoreImage `CIDetector`(QR) 或 Vision `VNDetectBarcodesRequest` 识别；**不用** `AVCaptureVideoPreviewLayer`/UIKit）。取景框四角、顶部「扫描 Mac 上的二维码」+「在 Mac 终端运行 opa pair」；识别到有效链接后显示 Mac 名称并进入核对；无效/过期二维码给提示；相机未授权：说明 +「去设置开启相机」（`openURL(URL(string: "app-settings:")!)`）；底部玻璃条「粘贴链接」「从相册识别」（复用现有 QR 图片识别）。离开页面停止相机。
3. **核对校验码**：`OrbitMascot(.attentive, 104)`、「核对校验码」、说明「确认 Mac 上显示的是同样的 6 位数字，然后在 Mac 上输入 y 并回车。」、大号 6 位数字（rounded、等宽、分 3+3）+ Mac 名称 · 连接路径、「等待 Mac 确认…」小指示、底部「数字不一致，取消连接」（`cancelPairing`）。失败（过期/被拒/断开）说明原因 +「重试」。
4. **连接成功**：`OrbitMascot(.happy, 168)`（单次弹跳）+「连上了」+ Mac 名称 + 标签（已加密 / 局域网 + 外网中继）+「开始和 Orbit 聊聊 →」进入主界面。
5. 演示模式入口保持「体验演示」，进入后各页面显示「演示」标记（若核心层已有 isDemo 显示则复用）。

## WP6 设置与系统表面（`ios/OPA/Features/Settings/**`、`ios/OPAWidgets/**`（Swift 文件）、`ios/Shared/TaskActivityAttributes.swift`）

设计稿：`orbit-settings.png`、`orbit-system.png`。

1. **SettingsView**：顶部 `OrbitAvatar(76)`（用户自定义头像时显示自定义）+ 名字 + 连接状态行。原生 inset grouped 列表（SF Symbol 圆角方块图标）：
   - 我的 Orbit：名字和形象 / 怎么称呼你 / 性格 → 编辑页（保留现有头像选择能力，默认头像 = 角色）。
   - 连接与设备：Mac（状态 · 路径 → `showConnection`）；安卓执行手机（调用 Host 新接口 `phone.status`，见 `docs/protocol.md`；显示型号/序列号/就绪状态或不可用原因；接口不存在时显示“需要更新 Mac 端”）；已配对设备列表。
   - 记忆、主动与通知：记忆（条数 → MemoryView）、主动程度、安静时段、每日通知上限。
   - 权限与隐私：执行权限（逐项确认 / 完全访问，切到完全访问前 Face ID + 说明“Mac 上的命令不再逐项询问”）、手机敏感点击说明（只读）、设备信息（位置、日历、提醒授权）。
   - 高级：bot 模型、执行模型（显示 displayName，「自动（最新）」为空串）、Host ID、中继地址、本机名称、解除配对（确认）。
   - 保存状态：用 `settingsSync` 显示保存中 / 已保存 / 失败（失败时值已回滚，提示原因）。
2. **MemoryView**：右上 + 添加（Sheet：文本 + 类别）；分段筛选「全部 / 你告诉我的 / 我推断的」（`source`）；按类别分区；每行「你告诉我的 / 我推断的 · 日期」；左滑删除前确认；说明文字；监听 `memoryRevision` 自动刷新；空状态。
3. **Live Activity / 灵动岛**（OPAWidgets）：锁屏：Orbit 头像（`MascotAvatar`）+ 任务名 + 当前步骤/detail + 状态标签 + 分段进度 +「已完成 x / y 步」；等你确认时显示举手图标与「需要你确认」。灵动岛展开：头像 44、标题、副标题、分段进度、等你时「打开 Orbit 确认」；紧凑：左 `OrbitMark(24)`、右「x/y」或举手 +「待确认」；最小：`OrbitMark`。`ContentState` 字段不得改名（Host 推送依赖它：title/status/done/total/detail），可新增可选字段。状态色用 widget 资产里的 token。
