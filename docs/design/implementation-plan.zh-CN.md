# Orbit iOS 重设计：实施计划（给实施子 agent 的共同约定）

[English](implementation-plan.md) | **简体中文**

状态：设计已获用户批准（2026-10-15）。额外需求：任务列表支持「清除已完成」。
设计稿：`docs/design/mockups/export/*.png`（实现时用 Read 打开对照）
- `orbit-key-light.png` / `orbit-key-dark.png`：对话空状态、执行中、任务、需要你确认
- `orbit-chat-more.png`：结果交付、附件托盘、键盘 + 有新回复、Mac 离线
- `orbit-connect.png`：欢迎、扫码、校验码、连接成功
- `orbit-detail.png`：任务详情、执行详情 Sheet、活动与权限 Sheet、任务空状态
- `orbit-settings.png`：设置、记忆、锁屏 Live Activity、灵动岛
- `orbit-system.png`：token、对比度、组件、角色尺度、动效
- `orbit-flows.png`：导航结构、停止/补充/中止/取消、审批生命周期、三种状态
- 原始 HTML：`docs/design/mockups/src/*.js`（像素与文案以它为准，可直接读源码取尺寸、文案）
- 设计简报：`docs/design/orbit-app-design.zh-CN.md`；线协议：`docs/protocol.zh-CN.md`（必须遵守）

## 1. 全局规则（每个子 agent 都必须遵守）

1. **纯 SwiftUI，禁止 UIKit**：不得 `import UIKit`，不得用 `UIViewRepresentable`、`UIApplication`、`UIImage`、`UIColor`、`UIDevice`。相机用 AVFoundation + CoreImage 渲染到 SwiftUI `Image`。
2. 最低 iOS 18；Swift 6 + `SWIFT_STRICT_CONCURRENCY=complete`；**构建零警告**。iOS 26 才有的 API（如 `glassEffect`）必须 `if #available(iOS 26, *)` 并提供 iOS 18 回退。
3. 文案中文；产品与角色都叫 **Orbit**，泛称“bot”，**不得出现“管家”**。
4. 不做没有后端能力支持的按钮（语音、暂停、下载、分享、重试执行等）；进度只用步骤计数，不用百分比/预计时间。
5. 无障碍：支持 Dynamic Type（不锁死文字高度）、VoiceOver 标签、Reduce Motion（去掉位移/旋转/弹跳，换 0.15s 淡变）、Reduce Transparency（材质换实色）、深色模式。装饰性角色 `accessibilityHidden(true)`。
6. 只改自己负责的文件（见第 5 节）。需要别人的接口时按第 4 节约定调用；确实需要改共享文件时停止并在报告里说明。
7. 不 git commit；不改加密、握手、协议语义；不删除已有功能。
8. 并行开发：同一工作区里还有其他 agent。**用自己的 derivedDataPath 和自己的模拟器**（见第 6 节）。如果编译错误出在你不负责的文件里，等 60 秒重试，不要去改别人的文件。新增 Swift 文件后运行 `xcodegen generate`（在 `ios/` 下）。

## 2. Design tokens（最终值）

在 `Assets.xcassets` 中以 color set 实现（Any/Dark 两套），通过生成的符号使用（`Color.canvas` 等）。

| token | 浅色 | 深色 | 用途 |
|---|---|---|---|
| Canvas | #FAF7F2 | #191715 | 页面背景 |
| Surface | #FFFFFF | #24211E | 卡片、Sheet、列表 |
| SurfaceInset | #F1EBE3 | #302B26 | 次按钮、键值块、输入区内按钮 |
| Ink | #302B27 | #F6EFE6 | 主文字 |
| InkSecondary | #6D6259 | #C4B8AA | 次要文字 |
| InkTertiary | **#7A6E64** | #A99B8D | 辅助文字（浅色值已从简报的 #7E7268 调整以达到 4.5:1；不要放在 SurfaceInset 上，那里用 InkSecondary） |
| Hairline | #DED5CA | #51473E | 分隔线、描边 |
| BrandApricot | #F2A15F | #F2AD73 | 星环、进行中标记、分段进度、选中 |
| BrandSoft | #FCE9D8 | #453022 | 用户气泡、进行中标签底、推荐项底 |
| AccentText | #8C471B | #F2AD73 | 链接、强调文字、Tab 选中色（AccentColor 也设为此值） |
| PrimaryFill | #302B27 | #F2AD73 | 主按钮底 |
| OnPrimary | #FFFDF9 | #241A13 | 主按钮文字/图标 |
| UserBubble | #FCE9D8 | #453022 | 你的气泡 |
| OnUserBubble | #302B27 | #F6EFE6 | 你的气泡文字 |
| OrbitBubble | #FFFFFF | #24211E | Orbit 气泡（浅色加 0.5pt Hairline 描边，深色不描边） |
| Success / SuccessSoft | #326447 / #E9F2E9 | #91C7A2 / #23362A | 已完成 |
| Warning / WarningSoft | #875015 / #FFF0D6 | #E7BA73 / #3E301D | 等你、离线 |
| Danger / DangerSoft | #AC3932 / #FBE9E5 | #F39C91 / #412724 | 阻碍、失败、删除 |

规则：浅杏橙底上不放白色小字；主按钮浅色是深棕底奶白字、深色是杏橙底深棕字；状态色总是配图标或文字。

字体：系统字体。欢迎标题 30pt semibold rounded；对话空状态标题 24pt semibold rounded；大标题 `.largeTitle.bold()`；页面标题 23pt bold；卡片标题 17pt semibold；正文 17pt（气泡行高约 1.5）；次要 15pt；辅助 13pt；标签 12.5pt semibold。全部用 `Font.system(size:weight:design:)` 配 `relativeTo:` 以支持 Dynamic Type。

间距 4pt 节奏：页面边距 16–20；区块 24–32；组件内 12–16；相关信息 4–8。圆角（全部 `.continuous`）：小组件 12、提示块 16、卡片 22、输入区 26、Sheet 由系统决定。按钮高 50（常规）/ 36（小）/ 32（迷你），可点区域 ≥ 44。

动效：按下缩放 0.97（spring 0.18s, bounce 0）；小状态切换 spring 0.26s bounce 0；布局/卡片 spring 0.38s bounce 0；仅手势释放后可用 bounce 0.18。角色飞入头像用 `matchedGeometryEffect`（spring 0.4s）。不默认循环漂浮/呼吸；进度提示（思考时小卫星绕环）可以循环，Reduce Motion 下静止。

## 3. 角色与图标素材（已就绪，勿替换）

- `Assets.xcassets/Mascot/`：`MascotWave`（欢迎/空状态）、`MascotAttentive`（等你、任务空状态、校验码页）、`MascotThinking`（思考/受阻占位）、`MascotFocused`（执行/离线占位）、`MascotHappy`（完成/连接成功）、`MascotSide`、`MascotAvatar`（头像构图）。均为设定图临时抠图（透明 PNG），代码里统一经 `OrbitMascot` / `OrbitAvatar` 组件使用，便于以后整体替换为正式素材。
- `OPAWidgets/Assets.xcassets/MascotAvatar`：灵动岛/Live Activity 用。
- AppIcon：浅色/深色/着色三张 1024（挥手悬浮版，用户已选定）。
- 小尺寸（16–24pt）一律用矢量 `OrbitMarkShape`（WP1a 实现，放 `Shared/` 供 Widget 共用）。

## 4. 跨模块接口（WP1 定义，其他 WP 只调用）

### 4.1 设计系统（WP1a，`ios/OPA/Design/`、`ios/Shared/OrbitMark.swift`）
- 颜色：上表全部 token 的 `Color` 符号。
- `Font.orbitWelcome / .orbitEmptyTitle / .orbitPageTitle / .orbitCardTitle / .orbitBody / .orbitSecondary / .orbitMeta / .orbitChip`
- `enum Space`、`enum Radius`、`enum Motion`、`struct MotionAware`（保留现有名字，更新取值）。
- 按钮样式：`.orbitPrimary`、`.orbitSoft`、`.orbitInset`、`.orbitPlain`、`.orbitDestructive`（文字型红色），尺寸 `OrbitButtonSize.regular/.small/.mini`，例如 `.buttonStyle(.orbit(.primary, size: .small))`。按下缩放 0.97 + 立即反馈。
- `StatusChip(kind: StatusKind, text: String, dot: Bool = false)`；`StatusKind`：`.planning .running .waiting .blocked .done .failed .cancelled .draft .ok`。并提供 `OPATask.Status.chipKind`、`OPATask.Status.label`（文案见 4.2）。
- `StepMarker(status: TaskStep.Status)`（20pt：完成=SuccessSoft 底勾；进行中=杏橙描边环+小卫星；待开始=Hairline 空环；失败=DangerSoft 底叉；跳过=SurfaceInset 底横线）。
- `SegmentedStepBar(total:done:currentIndex:)`（每步一段，4pt 高，杏橙；当前步半填充）。
- `OrbitCard { … }` 卡片容器（Surface、22 圆角、浅色 0.5pt 描边 + 轻阴影、深色只描边）。
- `NoteBlock(kind: .info/.warn/.danger/.good, systemImage:, content)`。
- `KeyValueList(rows: [(String, String)])`（SurfaceInset 底、行间 Hairline）。
- `SectionHeader(title:, count: Int? = nil, trailing: AnyView? = nil)`（13pt semibold InkSecondary，count 用 WarningSoft 小胶囊）。
- `GlassCircleButton(systemImage:, accessibilityLabel:, action:)`（44pt；iOS 26 `glassEffect`，否则 `.ultraThinMaterial` + 描边）。
- `ConnectionIndicator(state: ConnectionState, action:)`：已连接=玻璃圆钮（laptopcomputer + 右上 8pt 绿点）；连接中/恢复中=玻璃胶囊“恢复中”；Mac 离线/失败=WarningSoft 胶囊“Mac 离线”。
- `OrbitAvatar(size: CGFloat, ring: Bool = false)`：BrandSoft 圆底 + `MascotAvatar`；`ring` 时 1.5pt 杏橙内描边。
- `OrbitMascot(pose: MascotPose, size: CGFloat, greet: Bool = false)`：`MascotPose`：`.wave .attentive .thinking .focused .happy .side`；含柔和投影；`greet` 出现时做一次轻微挥手（旋转 ±6° 两次）后静止；`.happy` 出现时单次 squash 弹跳；Reduce Motion 全部静止。
- `OrbitMarkShape` + `OrbitMark(size:, outlined: Bool, orbiting: Bool)`：矢量身体（奶白，浅底时 1.5pt #C9AE95 描边）+ 倾斜 -14° 的杏橙星环（前后遮挡）+ 单颗卫星；`orbiting` 时卫星沿星环循环（Reduce Motion 静止）。坐标可参照 `docs/design/mockups/src/icons.js` 的 `orbitMark()`（64×64 网格）。
- 旧 token/组件若被现有视图引用，保留为**同名转发别名**（指向新 token），并在文件末尾集中标注 `// MIGRATION:`，等各功能模块改完后由收尾 WP 删除。

### 4.2 核心状态与动作（WP1b，`ios/OPA/Core/`、`ios/OPA/App/OPAApp.swift`）
- 文案：`OPATask.Status.label`：规划中 / 进行中 / 等你补充 / 遇到阻碍 / 已完成 / 未完成 / 已取消；`TaskStep.Status.label`：待开始 / 进行中 / 完成 / 失败 / 跳过。
- 时间线：`model.timeline: [TimelineItem]` 改为**按到达顺序**（服务端 seq；本地先显示的消息与流式消息取当时 `lastSeq + ε`，收到正式事件后保持原位）缓存数组，不在每次访问时排序；同一 id 不重复。
- 消息发送状态：`UserMessage.delivery: .sending / .queued（离线排队）/ .sent / .failed(String)`；`model.retry(clientId:)`。
- 流式：`AssistantMessage.streaming` 在重连完成、`butler.status` 变为 idle 且 3 秒无 delta、或收到同 id 的 `msg.assistant` 时结束，避免发送键卡在“停止”。
- `model.isReplying: Bool`（Orbit 正在思考/执行/流式输出，用于输入框 ■ 停止回复）；`model.stopReply()`（`chat.interrupt`）。
- 在场状态：`model.presence: Presence`（`text: String`、`tone: .neutral/.live/.warn`、`mood: MascotPose`），优先级：Mac 离线 → 有待确认审批（“等你确认 N 件事”）→ 流式中（“正在回复…”）→ 执行中（`butler.status` 的 detail 或运行中会话的最新 `session.progress`）→ 思考中（“正在想办法…”）→ 待命（“待命中”）。
- 连接信息：`model.connectionInfo`（hostName、path `.lan/.relay`、lastConnectedAt、lastSeenOnlineAt、state）。
- 审批：`Approval.isExpired(now:)`；`model.pendingApprovals` 排除已过期/已处理；`model.approvalStatus(id) -> .pending/.submitting/.approved/.denied/.expired/.failed(String)`；`model.respond(approval:approve:)` 防重复提交；`Approval.detailRows: [(String, String)]` 与 `Approval.detailNote: String?`（把 detail 中「标签：内容」/「标签:内容」行解析为表格，其余文字作为说明）。
- 任务：`model.activeTasks`、`model.attentionItems`（待确认审批 + `waiting_user` 任务）、`model.blockedTasks`、`model.finishedTasks`；`model.clearFinishedTasks() async -> Int`、`model.clearTask(id:) async`（调用 `tasks.clear`，处理 `task.remove` 事件）；`model.cancelTask(id:) async`、`model.taskSessions(taskId)`。
- 导航/呈现（根视图负责挂载，功能模块只改状态）：`model.selectedTab: AppTab (.chat/.tasks/.settings)`、`model.tasksPath: [String]`（任务详情 push）、`model.presentedApprovalId: String?`（全局确认 Sheet）、`model.showActivity: Bool`（活动与权限 Sheet）、`model.showConnection: Bool`（连接详情 Sheet）、`model.openTask(_ id:)`、`model.openApproval(_ id:)`。根视图 `RootView/MainTabView` 用占位视图挂载这些 Sheet，具体内容由对应 WP 替换（占位文件见第 5 节）。
- 设置同步：`model.settingsSync: .idle/.saving/.saved/.failed(String)`；失败时回滚到服务端值，不保留乐观值。
- 连接健壮性（ConnectionManager）：已连接时每 15 秒 `ping`（8 秒超时），连续 2 次失败即断开重连；`NWPathMonitor` 网络变化时立即重连；LAN 地址排序：Bonjour 解析结果 → 私有网段（10/8、172.16/12、192.168/16）→ 其他；排除 198.18.0.0/15 和 169.254.0.0/16。
- 演示模式：`MockHost` 覆盖新设计里的所有状态（执行中任务卡、待确认审批、对比卡、预订卡、阻碍任务、已完成任务、记忆），并支持 `tasks.clear`。

### 4.3 协议增量（WP0 实现到 Host 与 `docs/protocol.md`）
- `req tasks.clear {ids?: string[]}` → 删除指定/全部**已结束**任务（done/failed/cancelled），归档其执行会话；返回 `{removed: string[]}`；广播 `ev task.remove {ids: string[]}`。
- `chat.send` 以 `clientId` 幂等：重复的 clientId 返回已有 `msgId`，不重复交给 bot。
- `live butler.status` 的 `detail` 改为给人看的中文短语（如“派出任务”“在手机上操作”“整理结果”），新增可选 `tool` 字段保留原工具名。
- `request_approval` 工具说明要求 detail 写成多行「标签：内容」+ 最后一行「批准后：…」。App 只做显示层解析。
- Host 的局域网地址过滤同 4.2。

## 5. 工作包与文件归属

| WP | 内容 | 可写文件 |
|---|---|---|
| WP0 Host | 4.3 全部 + 测试 | `host/src/**`、`host/test/**`、`docs/protocol.md` |
| WP1a 设计系统 | 4.1 全部；颜色资产；删掉/改名冲突的 `Link` 颜色 | `ios/OPA/Design/**`、`ios/OPA/Resources/Assets.xcassets/**`（不动 Mascot、AppIcon）、`ios/OPAWidgets/Assets.xcassets/**`（不动 MascotAvatar）、新建 `ios/Shared/OrbitMark.swift` |
| WP1b 核心逻辑 | 4.2 全部；占位视图 | `ios/OPA/Core/**`、`ios/OPA/App/OPAApp.swift`、`ios/OPATests/**`、新建占位 `ios/OPA/Features/Approval/ApprovalSheet.swift`、`ios/OPA/Features/Chat/ActivitySheet.swift`、`ios/OPA/Features/Chat/ConnectionSheet.swift`、`ios/OPA/Features/Tasks/TaskDetailView.swift`（各自只放最小可编译占位） |
| WP2 对话 | 空状态舞台角色 + 飞入头像、在场头部、气泡、任务卡位置、输入框（■/↑）、附件托盘、有新回复、离线横幅、活动与权限 Sheet、连接详情 Sheet | `ios/OPA/Features/Chat/**` |
| WP3 卡片 | 全部 GenUI 卡片换新样式；对话内紧凑审批卡（打开全局 Sheet）；任务卡（查看任务 → `openTask`；⋯ → 取消任务确认） | `ios/OPA/Features/GenUI/**` |
| WP4 任务与确认 | 任务列表（分区、清除已完成、左滑清除单条）、任务详情、执行详情 Sheet、全局确认 Sheet | `ios/OPA/Features/Tasks/**`、`ios/OPA/Features/Approval/**` |
| WP5 配对 | 欢迎、扫码（AVFoundation，含权限被拒）、粘贴链接、校验码、成功、演示入口 | `ios/OPA/Features/Pairing/**` |
| WP6 设置与系统表面 | 设置首页与二级页、记忆页、Live Activity / 灵动岛 | `ios/OPA/Features/Settings/**`、`ios/OPAWidgets/**`（Swift 文件）、`ios/Shared/TaskActivityAttributes.swift` |
| WP7 收尾 | 删除 MIGRATION 别名与死代码、全局走查、构建测试 | 全部（主 agent 指定） |

## 6. 构建与验证

```bash
cd ios && xcodegen generate
xcodebuild -scheme OPA -destination 'platform=iOS Simulator,name=<你的模拟器名>' -derivedDataPath build-<WP> build
xcodebuild -scheme OPA -destination 'platform=iOS Simulator,name=<你的模拟器名>' -derivedDataPath build-<WP> test
```
- 自建模拟器：`xcrun simctl create "OPA <WP>" "iPhone Air" com.apple.CoreSimulator.SimRuntime.iOS-26-5`。不要动 `OPA iPhone 17 Pro (27.0)`（用户在用）和 `OPA Design Check`（主 agent 用）。
- 视觉核对：装到自己的模拟器，`-OPADemo YES` 启动演示模式，`-OPATab tasks|settings` 切 Tab，`xcrun simctl io <udid> screenshot` 截图，并用 Read 与设计稿 PNG 对照（浅色、深色各一次：`xcrun simctl ui <udid> appearance dark`）。截图保存到 `ios/screenshots/<WP>/`。
- 报告必须写：改了哪些文件、实现与设计稿的差异及原因、构建/测试结果（警告数）、截图路径、发现但未处理的问题。
