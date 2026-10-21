# Wave 2 Implementation Briefs (WP2–WP6, Parallel Work)

**English** | [简体中文](wave2-briefs.zh-CN.md)

Prerequisites: WP0 (Host), WP1a (design system), and WP1b (core state) are complete. Read these in full first:

1. [Implementation plan](implementation-plan.md) (global rules §1, tokens §2, assets §3, interfaces §4, build §6)
2. Your WP section in this file plus “Cross-WP agreements”
3. Design PNGs (open with Read) and `docs/design/mockups/src/screens.js` (source of truth for copy and dimensions)
4. Public design-system API: `ios/OPA/Design/*.swift`, `ios/Shared/OrbitMark.swift` (`DesignGallery.swift` has usage examples for every component)
5. Public core-state API: `ios/OPA/Core/Store/*.swift` (`AppModel*.swift`, `AppState.swift`, `Timeline.swift`), `ios/OPA/Core/Protocol/*.swift`. **Call these APIs; do not modify them.** If an interface is missing, first try to implement it in your own files using existing capabilities such as `model.request(...)`; if that cannot be done, explain it in your report.

## Cross-WP agreements

- Presentation entry points (mounted by the root view; change state only): `model.openTask(id)` (switch to Tasks tab and push details), `model.openApproval(id)` (global approval sheet), `model.showActivity = true` (activity and permissions), `model.showConnection = true` (connection details), `model.selectedTab = .chat/.tasks/.settings`.
- Shared-view ownership: cards such as `TaskProgressCard` and `ApprovalCardView` belong to WP3 (GenUI); `SessionDetailSheet` belongs to WP4 (Tasks); `ApprovalSheet` belongs to WP4 (Approval); `ActivitySheet` and `ConnectionSheet` belong to WP2 (Chat). Call another WP’s view; do not edit it.
- The former private `SectionHeader` in `Features/Tasks/TasksView.swift` has been renamed `TaskSectionHeader`; use the design system’s `SectionHeader` in new code. `GenUI/BoundCards.swift` already has `StepRow`; do not define a duplicate.
- Legacy components (`ButlerAvatar`, `cardSurface`, `CapsuleButtonStyle`, `.accentFill`, etc.) are MIGRATION aliases. **Replace them with the new API in your files**; the wrap-up WP will remove the aliases. In dark mode, remember the primary button uses an apricot background with dark-brown text (`.primaryFill` + `.onPrimary`); do not hard-code white text.
- Parallel builds: use only your own `build-<wp>` directory and simulator (xcrun simctl create "OPA <WP>" "iPhone Air" com.apple.CoreSimulator.SimRuntime.iOS-26-5; set the build destination to `id=<udid>`). Add `COMPILER_INDEX_STORE_ENABLE=NO`. After adding files, run xcodegen generate; if the build reports a project-file error, run it once more. If a compile error is in another person’s file, wait 60 seconds and retry; do not edit their file. Keep your own files **compilable at all times** (make small, incremental changes). Disk space is limited: run xcrun simctl shutdown <udid> when finished.
- Demo mode -OPADemo YES covers all states (see `Core/Demo/MockHost.swift`); use it for visual review. Capture light and dark screenshots against the design PNGs and save under `ios/screenshots/<wp>/`.
- Report: changed files, differences from the design and reasons, build warning count (must be 0), test results, screenshot paths, and discovered unresolved issues (especially logic bugs).

## WP2 Chat (`ios/OPA/Features/Chat/**`)

Design references: `orbit-key-light.png` screens 1–2, all of `orbit-chat-more.png`, `orbit-detail.png` screen 3 (activity and permissions), `orbit-flows.png`.

1. **Presence header** (inspired by Muse): centered at the top, OrbitAvatar(size: 42, ring: while working) + “Orbit ›” + one status line (`model.presence.text`; tone → color: live = AccentText with a small apricot dot, warn = Warning, neutral = InkSecondary). Tap avatar/name → `model.showActivity = true`. Top-right `ConnectionIndicator` → `model.showConnection = true`. Header background fades from Canvas to transparent; content scrolls below it.
2. **Empty state**: stage with fading glow + OrbitMascot(.wave, size: 140, greet: true) + “Orbit · 待命中” + “今天想把什么交给我？” + description (“我在你的 Mac 上动手。花钱、对外发送这类事，只在你明确要求或批准后才做。”) + up to three suggestion capsules near the composer (tap only fills a draft). When the first message appears or the keyboard opens, use `matchedGeometryEffect` to shrink the character into the header avatar (fade instead under Reduce Motion).
3. **Message stream**: follow `model.timeline` order; user bubble uses UserBubble fill + OnUserBubble text, max width 82%, 7pt bottom-right corner; Orbit bubble uses OrbitBubble fill (light mode has a 0.5pt Hairline outline), 7pt bottom-left corner; show 20pt avatar + “Orbit · HH:mm” only at the start of a new reply group; proactive messages have a small “主动” label; interrupted replies show “已停止”. Delivery row: `.queued` = “待发送 · Mac 连上后自动发出”; `.failed` = “没有送达” + “重试” (`model.retry(clientId:)`); `.sending` has no text. Cards (`CardHost`, WP3) span the available width at their timeline position. Long-press a bubble to copy text.
4. **Thinking / execution indicator**: when Orbit is thinking but has no text yet, show `OrbitMark(size: 22, orbiting: true)` + “正在想办法…” (or the execution text in presence) at the end of the message stream. Append streamed text as a whole; do not fade in character by character. Add a small apricot dot as the trailing cursor.
5. **Scrolling**: follow new content only when the user was already at the bottom. While the user is scrolled up, show a “↓ 有新回复” capsule when new content arrives; tapping it returns to the bottom.
6. **Composer**: floating Surface bar with radius 26. Left “+” opens attachment tray; multiline text input grows to six lines then scrolls internally. Right side: isReplying + empty draft → ■ (`stopReply()`, accessibility label “停止回复”); isReplying + draft → ■ and ↑ buttons; otherwise ↑ (disabled when empty). Placeholders: idle “把想做的事交给 Orbit…”; while working “补充要求，或交给 Orbit 新的事…”; offline “可以继续输入，连上后发送”. The selected-attachment row sits above the input inside the composer: thumbnail/filename capsule, × at top right to remove, processing shows progress and disables sending.
7. **Attachment tray**: a panel replacing the keyboard area with four entries (“照片” (Photos), “文件” (Files), “链接/文本” (Link/Text), “提醒事项” (Reminders)) and an embedded `PhotosPicker` (`.photosPickerStyle(.inline)`, multi-select); reuse existing `ComposerDraft` / `AttachmentTray` logic and sheet.
8. **Offline banner**: when connection is offline, failed, or waiting to reconnect, show a WarningSoft banner below the header: “Mac 暂时离线” + “消息会排队，连上后发送。正在重试…” + “详情” → `showConnection`.
9. **`ActivitySheet`** (replace placeholder): OrbitAvatar(54, ring), “Orbit 正在做”, subtitle (N tasks in progress · Mac connection path); “执行中”: running sessions (title, related task, latest `sessionProgress` / `lastActivity`, status label), tap → `openTask(taskId)`; “最近的动作”: use the model’s recent activity list if available, otherwise take the five most recent session `lastActivity` entries by `updatedAt` (real data only); “我能做什么”: Mac actions (based on `settings.defaultPermission`: manual = “沙箱外的命令逐项问你”; auto = “完全访问，不再逐项询问”), Android phone actions (“敏感点击自动执行，并记录在案”), tap → close sheet and selectedTab = .settings. Support .presentationDetents([.medium, .large]).
10. **`ConnectionSheet`** (replace placeholder): Mac name, status, connection path (LAN / external Relay), last-connected time, and when offline the explanation “消息会排队；Mac 离线不代表任务停止”; “重新连接” (use the core layer’s existing reconnect method); “管理设备” → Settings.

## WP3 Cards (`ios/OPA/Features/GenUI/**`)

Design references: `orbit-key-light.png` screen 2 task card, `orbit-chat-more.png` screen 1 (comparison and compact approval cards), `orbit-system.png` component area.

1. All components use `OrbitCard` and a consistent title/content/metadata/action rhythm; statuses always use `StatusChip` (on ui.patch status changes, update in place with the design-system transition); buttons use `.orbit(...)` styles. For `requiresApproval` buttons in `CardActionBar`, run Face ID before sending and disable while sending to prevent duplicates.
2. **`TaskProgressCard`**: title + status label + ⋯ menu (ongoing task only: “取消任务” → confirmation dialog explaining “停止进行中的步骤，已完成的不撤销” → `model.cancelTask`; ended task: “从列表清除” → `model.clearTask`); steps use `StepMarker` + vertical line, bold the current step and include that step’s latest session progress; footer “已完成 x / y 步 · 更新时间” + “查看任务 ›” → `openTask`. If the task has been cleared, show compact placeholder “这个任务已从列表清除”.
3. **`ApprovalCardView`** (compact in-chat card): raised-hand icon + “需要你确认：<title>” + status label (“待确认” pending / “提交中” submitting / “已批准 · 等执行结果” approved · waiting for execution result / “已拒绝” denied / “已过期” expired / “提交失败” submission failed) + one-line summary (join detailRows, up to two lines) + “查看并确认” (`openApproval`) and “拒绝”. Hide buttons and explain after expiry or handling.
4. **Comparison card**: vertical list on narrow screens; recommended item has BrandSoft background + “推荐” label; each item has “选这家” on the right → sendAction(cardId, actionId: "select", value: [itemId]); remember the selection locally in memory keyed by cardId; show “已选择” on the card and hide other item buttons. **Do not** fake a user bubble.
5. choice_list / form: make single-select, multi-select, and required fields clear; after submission keep the selection and change the button to “已提交”.
6. Orders / tickets / bookings: emphasize amount, time, object, and status; use different status labels for draft / awaiting confirmation / confirmed; amounts use tabular figures.
7. Restyle the rest (text, link, table, document, calendar, video, gallery, map, memory_saved, unknown): horizontal scrolling for tables stays inside the card; images use consistent aspect ratio and a loading-failure placeholder; link cards show the site name.
8. Fix hard-coded white text in `InteractiveCards.swift` so it has proper dark-mode contrast.

## WP4 Tasks and approvals (`ios/OPA/Features/Tasks/**`, `ios/OPA/Features/Approval/**`)

Design references: `orbit-key-light.png` screens 3–4, `orbit-detail.png` screens 1, 2, and 4, `orbit-flows.png`.

1. **TasksView**: large “任务” title + `ConnectionIndicator` at upper right. Sections:
   - “需要你处理” (`attentionItems`, with count): approval row (raised-hand icon, title, related task · expiry, “查看” → `openApproval`); task waiting for user input (question bubble icon, question summary, “回答” → selectedTab = .chat).
   - “进行中”: 3pt apricot stripe on left, title + status label, current truthful action (`sessionProgress` from a running session for that task; if none, current step title), `SegmentedStepBar` + “已完成 x / y 步 · 相对时间”.
   - “遇到问题”: danger icon, reason (summary or current step), relative time.
   - “最近完成”: compact row (check / cross / dash icon + title + time); section header action “清除” → `confirmationDialog` “清除 N 个已结束的任务？对应的执行会话会一并归档。” → `clearFinishedTasks()`, then toast “已清除 N 个任务”; swipe one row to “清除” → `clearTask(id)`.
   - Tap a row → push `TaskDetailView` (`model.tasksPath`). Empty state: OrbitMascot(.attentive, 96) + “这里会记录我替你做的事” + description + “去聊聊” (`.orbit(.soft)` → selectedTab = .chat). Pull to refresh (sync or request latest status using an existing core method).
2. **`TaskDetailView`** (replace placeholder): glass back / ⋯ buttons; status label + start/update time; title (26pt bold); goal; “现在等你…” note block (pending approval → “查看”; waiting for user input → “回到对话”); step timeline (highlight current-step card, completed steps can expand for details / related session); “结果”: show summary when present; “执行详情” lists sessions for that task (`taskSessions`) → open `SessionDetailSheet`; bottom “回到对话” + “取消任务” (ongoing only; after confirmation show “正在取消…” until state becomes cancelled); ended-task ⋯ menu has “从列表清除” (after clearing, pop to list).
3. **`SessionDetailSheet`** (redesign): icon based on title prefix (📱 → Android phone, 🖥 → Mac graphical interface, otherwise Mac), title, status · duration; tags for model and permission (manual “逐项确认” / auto “完全访问”); action log (`model.sessionDetail`: time + icon + one sentence, choose SF Symbol by kind); actions: “补充指令” (input → task.cmd steer), running task “中止这一轮” (task.cmd interrupt), “归档”. Loading and failure states.
4. **`ApprovalSheet`** (global, replace placeholder): small avatar “Orbit 请你确认” + close (close ≠ deny); title (23pt bold); `KeyValueList(detailRows)`; NoteBlock(.info, detailNote); risk hint for high risk only (WarningSoft explanation such as “这个操作无法撤销”); when `requireBiometric` is true, show “需要 Face ID” + expiry countdown; primary verb by kind: command “允许执行”, fileChange “允许修改”, permissions “授予权限”, elicitation “允许”, action “批准” (add Face ID icon when `requireBiometric`); “拒绝”; source “来自任务「…」” (resolve sessionId → task). States: submitting (disabled + progress), approved (“已批准 · 等执行结果”), denied, expired (disabled button + reason), submission failed (retain content + retry). If the approval id cannot be found, show “这个确认已失效”.

## WP5 Mac pairing (`ios/OPA/Features/Pairing/**`)

Design reference: `orbit-connect.png`.

1. **Welcome**: stage background + OrbitMascot(.wave, 178, greet: true) + “你好，我是 Orbit” + “连接你的 Mac，把想做的事交给我。” + three explanatory rows (icon block with BrandSoft fill and AccentText icon) + primary “连接我的 Mac” (→ scan) + text buttons “粘贴配对链接” and “体验演示”.
2. **QR scan**: full-screen camera (AVFoundation `AVCaptureSession` + `AVCaptureVideoDataOutput`; convert frames to CGImage on a background queue and publish to SwiftUI Image at about 15–20fps; recognize with CoreImage CIDetector(QR) or Vision `VNDetectBarcodesRequest`; **do not use** `AVCaptureVideoPreviewLayer` / UIKit). Viewfinder corners, top copy “扫描 Mac 上的二维码” + “在 Mac 终端运行 opa pair”. After a valid link is recognized, show Mac name and move to verification; show a hint for invalid/expired QR. If camera permission is denied, explain and show “去设置开启相机” (openURL(URL(string: "app-settings:")!)). Bottom glass bar: “粘贴链接”, “从相册识别” (reuse existing QR image recognition). Stop the camera when leaving the page.
3. **Verify code**: OrbitMascot(.attentive, 104), “核对校验码”, explanation “确认 Mac 上显示的是同样的 6 位数字，然后在 Mac 上输入 y 并回车。”, large six-digit code (rounded, monospaced, spaced 3+3) + Mac name · connection path, small “等待 Mac 确认…” indicator, bottom “数字不一致，取消连接” (`cancelPairing`). On failure (expired / rejected / disconnected), explain the reason + “重试”.
4. **Connected**: OrbitMascot(.happy, 168) (one bounce) + “连上了” + Mac name + labels (encrypted / LAN + external Relay) + “开始和 Orbit 聊聊 →” to enter the main interface.
5. Keep the demo entry “体验演示”; after entering, each page shows a “演示” marker if the core layer already exposes isDemo.

## WP6 Settings and system surfaces (`ios/OPA/Features/Settings/**`, `ios/OPAWidgets/**` Swift files, `ios/Shared/TaskActivityAttributes.swift`)

Design references: `orbit-settings.png` and `orbit-system.png`.

1. **SettingsView**: `OrbitAvatar(76)` at top (show a custom avatar if the user set one) + name + connection status row. Native inset-grouped list (rounded-square SF Symbol icons):
   - My Orbit: name and appearance / what to call the user / personality → edit pages (keep existing avatar selection; default avatar = character).
   - Connection and devices: Mac (status · path → `showConnection`); Android execution phone (call the Host’s new `phone.status` endpoint, see `docs/protocol.md`; show model/serial/ready status or reason unavailable; if interface is absent, show “需要更新 Mac 端”); paired-device list.
   - Memory, proactivity, and notifications: memory count → MemoryView, proactivity level, quiet hours, daily notification limit.
   - Permissions and privacy: execution permission (per-action confirmation / full access; Face ID before switching to full access + explanation “Mac 上的命令不再逐项询问”); read-only explanation of sensitive phone taps; device information (location, calendar, reminder authorization).
   - Advanced: bot model, execution model (show displayName; an empty string means “自动（最新）”), Host ID, Relay address, local machine name, unpair (confirmation).
   - Save status: use `settingsSync` to show saving / saved / failed (value rolls back on failure; explain the reason).
2. **MemoryView**: upper-right + Add (sheet: text + category); segmented filters “全部 / 你告诉我的 / 我推断的” (source); group by category; each row “你告诉我的 / 我推断的 · 日期”; confirm before swipe-to-delete; explanatory copy; automatically refresh on `memoryRevision`; empty state.
3. **Live Activity / Dynamic Island** (OPAWidgets): Lock Screen: Orbit avatar (`MascotAvatar`) + task name + current step/detail + status label + segmented progress + “已完成 x / y 步”; while waiting for user confirmation show raised-hand icon + “需要你确认”. Expanded Dynamic Island: avatar 44, title, subtitle, segmented progress, “打开 Orbit 确认” while waiting. Compact: `OrbitMark(24)` on left; “x/y” or raised hand + “待确认” on right. Minimal: `OrbitMark`. Do not rename `ContentState` fields (Host push depends on title/status/done/total/detail); optional fields may be added. Use tokens from Widget assets for status colors.
