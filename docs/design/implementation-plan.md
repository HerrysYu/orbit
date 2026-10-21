# Orbit iOS Redesign: Implementation Plan (Shared Rules for Implementation Agents)

**English** | [简体中文](implementation-plan.zh-CN.md)

Status: Design approved by the user (2026-10-15). Additional requirement: the task list supports “清除已完成” (Clear completed).
Design files: `docs/design/mockups/export/*.png` (open them with Read while implementing)
- `orbit-key-light.png` / `orbit-key-dark.png`: chat empty state, active work, tasks, needs your confirmation
- `orbit-chat-more.png`: result delivery, attachment tray, keyboard with new reply, Mac offline
- `orbit-connect.png`: welcome, QR scan, verification code, connection success
- `orbit-detail.png`: task details, execution details sheet, activity and permissions sheet, empty task state
- `orbit-settings.png`: settings, memory, Lock Screen Live Activity, Dynamic Island
- `orbit-system.png`: tokens, contrast, components, character scale, motion
- `orbit-flows.png`: navigation structure, stop/add input/interrupt/cancel, approval lifecycle, three states
- Original HTML: `docs/design/mockups/src/*.js` (use this as the source of truth for pixels and copy; read source for sizes and text)
- Design brief: [Orbit App design brief](orbit-app-design.md); wire protocol: [protocol](../protocol.md) (must be followed)

## 1. Global rules (every agent must follow)

1. **Pure SwiftUI; UIKit is prohibited**: do not import UIKit or use `UIViewRepresentable`, UIApplication, UIImage, UIColor, or UIDevice. Render the camera with AVFoundation + CoreImage into a SwiftUI Image.
2. Minimum iOS 18; Swift 6 + `SWIFT_STRICT_CONCURRENCY=complete`; **zero build warnings**. APIs available only in iOS 26 (such as `glassEffect`) must be guarded with if #available(iOS 26, *) and have an iOS 18 fallback.
3. UI copy is Chinese; the product and character are both named **Orbit**. Use the generic term “bot”; **do not use “管家” (“butler”) in the App copy**.
4. Do not add buttons unsupported by backend capabilities (voice, pause, download, share, retry execution, etc.). Show progress only as step counts, never as a percentage or estimated time.
5. Accessibility: support Dynamic Type (do not lock text height), VoiceOver labels, Reduce Motion (remove translation/rotation/bounce and use a 0.15s fade instead), Reduce Transparency (replace materials with solid colors), and dark mode. Decorative characters use `accessibilityHidden(true)`.
6. Change only files assigned to you (see §5). Call other agents’ interfaces as agreed in §4. If a shared file truly needs changes, stop and report it.
7. Do not git commit; do not change encryption, handshake, protocol semantics, or remove existing features.
8. Parallel work: other agents share this workspace. **Use your own derivedDataPath and simulator** (see §6). If a build error is in a file you do not own, wait 60 seconds and retry; do not change someone else’s file. After adding a Swift file, run xcodegen generate from `ios/`.

## 2. Design tokens (final values)

Implement these as color sets in `Assets.xcassets` (Any/Dark variants) and use generated symbols (for example, `Color.canvas`).

| Token | Light | Dark | Use |
|---|---|---|---|
| Canvas | #FAF7F2 | #191715 | Page background |
| Surface | #FFFFFF | #24211E | Cards, sheets, lists |
| SurfaceInset | #F1EBE3 | #302B26 | Secondary buttons, key-value blocks, buttons inside composer |
| Ink | #302B27 | #F6EFE6 | Primary text |
| InkSecondary | #6D6259 | #C4B8AA | Secondary text |
| InkTertiary | **#7A6E64** | #A99B8D | Supporting text (light value was adjusted from #7E7268 in the brief to reach 4.5:1; do not use on SurfaceInset; use InkSecondary there) |
| Hairline | #DED5CA | #51473E | Dividers, outlines |
| BrandApricot | #F2A15F | #F2AD73 | Orbit ring, active marker, segmented progress, selection |
| BrandSoft | #FCE9D8 | #453022 | User bubbles, active chips, recommended item background |
| AccentText | #8C471B | #F2AD73 | Links, emphasized text, selected Tab color (also set AccentColor to this value) |
| PrimaryFill | #302B27 | #F2AD73 | Primary button background |
| OnPrimary | #FFFDF9 | #241A13 | Primary button text/icon |
| UserBubble | #FCE9D8 | #453022 | User bubble |
| OnUserBubble | #302B27 | #F6EFE6 | User bubble text |
| OrbitBubble | #FFFFFF | #24211E | Orbit bubble (light mode: 0.5pt Hairline outline; no outline in dark mode) |
| Success / SuccessSoft | #326447 / #E9F2E9 | #91C7A2 / #23362A | Completed |
| Warning / WarningSoft | #875015 / #FFF0D6 | #E7BA73 / #3E301D | Waiting for you, offline |
| Danger / DangerSoft | #AC3932 / #FBE9E5 | #F39C91 / #412724 | Blocked, failed, deleted |

Rules: Do not put small white text on a light apricot background. The light primary button uses a dark brown background with cream text; the dark primary button uses an apricot background with dark brown text. Always pair status colors with an icon or text.

Typography: system fonts. Welcome title 30pt semibold rounded; chat empty-state title 24pt semibold rounded; large title `.largeTitle.bold()`; page title 23pt bold; card title 17pt semibold; body 17pt (bubble line height about 1.5); secondary 15pt; supporting text 13pt; labels 12.5pt semibold. Use `Font.system(size:weight:design:)` with `relativeTo:` for Dynamic Type.

Spacing follows a 4pt rhythm: page margins 16–20; section spacing 24–32; component padding 12–16; related information 4–8. Continuous corner radii: small components 12, note blocks 16, cards 22, composer 26, sheets use system defaults. Button heights 50 (regular) / 36 (small) / 32 (mini); tappable areas ≥ 44.

Motion: press scale 0.97 (spring 0.18s, bounce 0); small state changes spring 0.26s, bounce 0; layout/card changes spring 0.38s, bounce 0; bounce 0.18 only after a gesture is released. Use `matchedGeometryEffect` for the character flying into the avatar (spring 0.4s). Do not use continuous floating/breathing by default; the progress indicator (small satellite orbiting while thinking) may loop, but remains still under Reduce Motion.

## 3. Character and icon assets (ready; do not replace)

- `Assets.xcassets/Mascot/`: `MascotWave` (welcome/empty state), `MascotAttentive` (waiting for you, empty task state, verification-code screen), `MascotThinking` (thinking/blocked placeholder), `MascotFocused` (working/offline placeholder), `MascotHappy` (complete/connection success), `MascotSide`, `MascotAvatar` (avatar composition). These are temporary cutouts from the concept image (transparent PNG); use them through the shared `OrbitMascot` / `OrbitAvatar` components so they can later be replaced together with final assets.
- `OPAWidgets/Assets.xcassets/MascotAvatar`: for Dynamic Island / Live Activity.
- AppIcon: three 1024 assets for light/dark/tinted appearance (floating waving version, selected by the user).
- Use the vector `OrbitMarkShape` at small sizes (16–24pt) (implemented in WP1a, placed under `Shared/` for Widget reuse).

## 4. Cross-module interfaces (defined by WP1; other WPs call them only)

### 4.1 Design system (WP1a, `ios/OPA/Design/`, `ios/Shared/OrbitMark.swift`)

- Colors: Color symbols for every token in the table above.
- Font.orbitWelcome / .orbitEmptyTitle / .orbitPageTitle / .orbitCardTitle / .orbitBody / .orbitSecondary / .orbitMeta / .orbitChip
- enum Space, enum Radius, enum Motion, struct MotionAware (keep existing names, update values).
- Button styles: `.orbitPrimary`, `.orbitSoft`, `.orbitInset`, `.orbitPlain`, `.orbitDestructive` (red text style); sizes `OrbitButtonSize.regular/.small/.mini`, for example .buttonStyle(.orbit(.primary, size: .small)). Press scale 0.97 with immediate feedback.
- `StatusChip(kind: StatusKind, text: String, dot: Bool = false)`; `StatusKind`: .planning .running .waiting .blocked .done .failed .cancelled .draft .ok. Also provide `OPATask.Status.chipKind` and `OPATask.Status.label` (copy in §4.2).
- StepMarker(status: TaskStep.Status) (20pt: completed = check on SuccessSoft; active = apricot outlined ring + small satellite; pending = empty Hairline ring; failed = cross on DangerSoft; skipped = dash on SurfaceInset).
- `SegmentedStepBar(total:done:currentIndex:)` (one segment per step, 4pt high, apricot; current step half-filled).
- OrbitCard { … } container (Surface, 22 radius, light mode 0.5pt outline + soft shadow, dark mode outline only).
- NoteBlock(kind: .info/.warn/.danger/.good, systemImage:, content).
- KeyValueList(rows: [(String, String)]) (SurfaceInset background, Hairline between rows).
- SectionHeader(title:, count: Int? = nil, trailing: AnyView? = nil) (13pt semibold InkSecondary; count uses a small WarningSoft capsule).
- GlassCircleButton(systemImage:, accessibilityLabel:, action:) (44pt; iOS 26 `glassEffect`, otherwise `.ultraThinMaterial` + outline).
- ConnectionIndicator(state: ConnectionState, action:): connected = glass circle button (laptopcomputer + 8pt green dot at upper right); connecting/reconnecting = glass capsule “恢复中” (Reconnecting); Mac offline/failed = WarningSoft capsule “Mac 离线” (Mac offline).
- `OrbitAvatar(size: CGFloat, ring: Bool = false)`: BrandSoft circular background + `MascotAvatar`; ring adds 1.5pt apricot inner outline.
- `OrbitMascot(pose: MascotPose, size: CGFloat, greet: Bool = false)`: `MascotPose` is `.wave`, `.attentive`, `.thinking`, `.focused`, `.happy`, or `.side`; soft shadow; greet performs one slight wave on appearance (two ±6° rotations), then stops; `.happy` performs one squash bounce on appearance; all remain still under Reduce Motion.
- `OrbitMarkShape` + `OrbitMark(size: CGFloat, outlined: Bool, orbiting: Bool)`: vector body (cream, 1.5pt #C9AE95 outline on light background) + apricot ring tilted -14° with front/back overlap + one satellite; orbiting loops the satellite around the ring (static under Reduce Motion). Geometry can follow `orbitMark()` in `docs/design/mockups/src/icons.js` (64×64 grid).
- If existing views reference legacy tokens/components, keep same-name forwarding aliases (pointing to new tokens), and collect // MIGRATION: markers at the end of the file. WP7 removes them after every feature module is updated.

### 4.2 Core state and actions (WP1b, `ios/OPA/Core/`, `ios/OPA/App/OPAApp.swift`)

- Copy: `OPATask.Status.label`: 规划中 (Planning) / 进行中 (In progress) / 等你补充 (Needs more input) / 遇到阻碍 (Blocked) / 已完成 (Completed) / 未完成 (Incomplete) / 已取消 (Cancelled); `TaskStep.Status.label`: 待开始 (Not started) / 进行中 (In progress) / 完成 (Complete) / 失败 (Failed) / 跳过 (Skipped).
- Timeline: change model.timeline: [TimelineItem] to a cache array in **arrival order** (server seq; locally shown-first messages and streaming messages use the current lastSeq + ε and keep their position when the formal event arrives); do not sort on every access; deduplicate by id.
- Message delivery: UserMessage.delivery: .sending / .queued (queued offline) / .sent / .failed(String); `model.retry(clientId:)`.
- Streaming: end `AssistantMessage.streaming` after reconnection completes, when `butler.status` becomes idle and there have been no deltas for 3 seconds, or when `msg.assistant` with the same id arrives; prevent the send key from getting stuck on “Stop.”
- model.isReplying: Bool (Orbit is thinking/executing/streaming; used for ■ “停止回复” (Stop reply) in the composer); `model.stopReply()` (`chat.interrupt`).
- Presence: model.presence: Presence (text: String, tone: .neutral/.live/.warn, mood: `MascotPose`), priority: Mac offline → pending approvals (“等你确认 N 件事”, N things need your confirmation) → streaming (“正在回复…”, Replying…) → executing (detail from `butler.status` or latest `session.progress` from a running session) → thinking (“正在想办法…”, Thinking of a way…) → idle (“待命中”, Standing by).
- Connection details: `model.connectionInfo` (hostName, path `.lan/.relay`, lastConnectedAt, lastSeenOnlineAt, state).
- Approval: `Approval.isExpired(now:)`; `model.pendingApprovals` excludes expired/handled; model.approvalStatus(id) -> .pending/.submitting/.approved/.denied/.expired/.failed(String); `model.respond(approval:approve:)` prevents duplicate submission; Approval.detailRows: [(String, String)] and Approval.detailNote: String? (parse detail lines of “label: content” / “label:content” into a table and treat remaining text as the note).
- Tasks: `model.activeTasks`, `model.attentionItems` (pending approvals + `waiting_user` tasks), `model.blockedTasks`, `model.finishedTasks`; model.clearFinishedTasks() async -> Int, model.clearTask(id:) async (calls `tasks.clear` and handles `task.remove` events); model.cancelTask(id:) async, `model.taskSessions(taskId)`.
- Navigation/presentation (root view mounts; feature modules change state only): model.selectedTab: AppTab (.chat/.tasks/.settings), model.tasksPath: [String] (push task details), model.presentedApprovalId: String? (global approval sheet), model.showActivity: Bool (activity and permissions sheet), model.showConnection: Bool (connection details sheet), `model.openTask(_ id:)`, `model.openApproval(_ id:)`. `RootView/MainTabView` mounts placeholder views for these sheets; each WP replaces its corresponding placeholder (see §5).
- Settings sync: model.settingsSync: .idle/.saving/.saved/.failed(String); on failure, roll back to the server value and do not keep an optimistic value.
- Connection robustness (ConnectionManager): ping every 15 seconds while connected (8-second timeout), disconnect and reconnect after two consecutive failures; reconnect immediately on `NWPathMonitor` network changes; order LAN addresses as Bonjour resolution → private ranges (10/8, 172.16/12, 192.168/16) → others; exclude 198.18.0.0/15 and 169.254.0.0/16.
- Demo mode: `MockHost` covers all states in the new design (active task card, pending approval, comparison card, booking card, blocked task, completed task, memory) and supports `tasks.clear`.

### 4.3 Protocol increments (WP0 implements in Host and `docs/protocol.md`)

- req `tasks.clear` {ids?: string[]} → delete the specified/all **finished** tasks (done/failed/cancelled) and archive their execution sessions; return {removed: string[]}; broadcast ev `task.remove` {ids: string[]}.
- `chat.send` is idempotent by `clientId`: a repeated `clientId` returns the existing `msgId` and is not sent to the bot again.
- live `butler.status` detail becomes a short Chinese phrase written for people (for example “派出任务” (Dispatched a task), “在手机上操作” (Working on the phone), “整理结果” (Preparing results)); add an optional tool field to preserve the original tool name.
- The `request_approval` tool description requires detail to use multiple “标签：内容” (Label: content) lines plus a final “批准后：…” (After approval: …) line. The App only parses this for display.
- Host LAN address filtering matches §4.2.

## 5. Work packages and file ownership

| WP | Scope | Writable files |
|---|---|---|
| WP0 Host | All of §4.3 + tests | `host/src/**`, `host/test/**`, `docs/protocol.md` |
| WP1a Design system | All of §4.1; color assets; remove/rename conflicting Link color | `ios/OPA/Design/**`, `ios/OPA/Resources/Assets.xcassets/**` (not Mascot or AppIcon), `ios/OPAWidgets/Assets.xcassets/**` (not `MascotAvatar`), new `ios/Shared/OrbitMark.swift` |
| WP1b Core logic | All of §4.2; placeholder views | `ios/OPA/Core/**`, `ios/OPA/App/OPAApp.swift`, `ios/OPATests/**`, new placeholders `ios/OPA/Features/Approval/ApprovalSheet.swift`, `ios/OPA/Features/Chat/ActivitySheet.swift`, `ios/OPA/Features/Chat/ConnectionSheet.swift`, `ios/OPA/Features/Tasks/TaskDetailView.swift` (each only a minimal compilable placeholder) |
| WP2 Chat | Empty-state stage + avatar fly-in, presence header, bubbles, task-card placement, composer (■/↑), attachment tray, new reply, offline banner, activity and permissions sheet, connection details sheet | `ios/OPA/Features/Chat/**` |
| WP3 Cards | Restyle all GenUI cards; compact in-chat approval card (opens global sheet); task card (view task → `openTask`; ⋯ → confirm cancel task) | `ios/OPA/Features/GenUI/**` |
| WP4 Tasks and approvals | Task list (sections, clear completed, swipe to clear one), task details, execution details sheet, global approval sheet | `ios/OPA/Features/Tasks/**`, `ios/OPA/Features/Approval/**` |
| WP5 Pairing | Welcome, QR scan (AVFoundation, including denied permissions), paste link, verification code, success, demo entry | `ios/OPA/Features/Pairing/**` |
| WP6 Settings and system surfaces | Settings home and detail pages, memory page, Live Activity / Dynamic Island | `ios/OPA/Features/Settings/**`, `ios/OPAWidgets/**` (Swift files), `ios/Shared/TaskActivityAttributes.swift` |
| WP7 Wrap-up | Remove MIGRATION aliases and dead code, global review, build and test | Everything (assigned by the main agent) |

## 6. Build and verification

    cd ios && xcodegen generate
    xcodebuild -scheme OPA -destination 'platform=iOS Simulator,name=<your simulator name>' -derivedDataPath build-<WP> build
    xcodebuild -scheme OPA -destination 'platform=iOS Simulator,name=<your simulator name>' -derivedDataPath build-<WP> test

- Create a dedicated simulator: xcrun simctl create "OPA <WP>" "iPhone Air" com.apple.CoreSimulator.SimRuntime.iOS-26-5. Do not use OPA iPhone 17 Pro (27.0) (the user uses it) or OPA Design Check (the main agent uses it).
- Visual review: install into your own simulator, launch demo mode with -OPADemo YES, and use -OPATab tasks|settings to switch tabs. Capture screenshots with xcrun simctl io <udid> screenshot and compare them with design PNGs using Read (capture light and dark; use xcrun simctl ui <udid> appearance dark). Save screenshots under `ios/screenshots/<WP>/`.
- The report must list changed files, differences from the design and reasons, build/test result (warning count), screenshot paths, and discovered issues left unresolved.
