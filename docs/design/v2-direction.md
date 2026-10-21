# Orbit Direction v2: Restrained and Systematic (Implementation Specification)

**English** | [简体中文](v2-direction.zh-CN.md)

Status: Design proposal; do not change the App until the owner confirms. Reference images: `mockups/export/orbit-v2-light.png` and `orbit-v2-dark.png`; source: `mockups/src/screens-v2.js` and `styles-v2.css`;
Preview: `mockups/index.html?board=v2-light|v2-dark` (add `&g=welcome|empty|chat|tasks|approval|settings` to view one group). iPhone Air size: 420 × 912 pt.

## 0. Scope

- **Keep unchanged**: centered layout of the welcome screen and empty chat; greeting, subtitle, and explanatory copy (preserve the current App wording exactly); all 3D characters (welcome, empty chat, chat-header avatar, settings header, approval-sheet header); stage glow; flat OrbitMark used only on the thinking row.
- **Change**: colors, typography (no rounded font), shapes (cards / buttons / statuses / counts / icons), remove shadows and colored blocks nested inside cards; remove the three selling points from welcome; remove the three suggestion buttons from empty chat; change composer placeholder to “给 Orbit 发消息”; change approval-sheet header to “需要你确认”.
- Review items: 3-point selling list · 5 nested card shadows · 8 colors · 9 suggestion buttons · 10 copy · 11 large task card. Items 1, 2, 7, and 14 were cancelled; leave them as they are.

## 1. Color tokens (change values in same-named colorsets under Assets.xcassets)

| Token | Light | Dark | Use |
|---|---|---|---|
| Canvas | #F7F6F4 | #121110 | Page background |
| Surface | #FFFFFF | #1C1B19 | Cards, grouped lists, composer, sheets, secondary buttons |
| Ink | #1D1B19 | #F2F0EC | Titles, body |
| InkSecondary | #5F5B55 | #A8A49D | Secondary text, section headings, line icons |
| InkTertiary | #736F69 | #8C8882 | Placeholders, supporting text, arrows (Canvas / Surface only) |
| Hairline | #E6E3DE | #2E2C29 | 0.5pt outline, divider, progress track |
| Accent | #A9521A | #F0A15E | Only tappable text links, 6pt in-progress dots, and 2pt progress lines |
| PrimaryFill / OnPrimary | #1D1B19 / #FFFFFF | #F2F0EC / #121110 | Primary button |
| UserBubble | #ECEAE6 | #2A2826 | User message (only Ink / InkSecondary text on it) |
| Success / Warning / Danger | #1F7A4A / #8A6100 / #B3261E | #5FC48A / #E8C14E / #FF8A80 | Text and 6pt dots only; no colored backgrounds |

Merge AccentText and AccentColor into Accent. Delete SurfaceInset, all *Soft tokens, OrbitBubble, OnUserBubble (= Ink), and GlassEdge. Do not use BrandApricot / BrandSoft as interface colors anymore (change in-progress indicators such as `OrbitSpinner` to Accent).

**Character-only colors** (not tokens; keep their current values): glow #FFF3E6 / #2A221C, avatar background circle #FCE9D8 / #453022, OrbitMark cream body + apricot ring + orange satellite; the tab-bar badge remains system red.

**Contrast** (WCAG 2.x; text must be ≥ 4.5:1; each value was calculated)

| Text color | Light Canvas | Light Surface | Dark Canvas | Dark Surface |
|---|---:|---:|---:|---:|
| Ink | 15.90 | 17.17 | 16.57 | 15.12 |
| InkSecondary | 6.24 | 6.74 | 7.60 | 6.94 |
| InkTertiary | 4.62 | 4.99 | 5.35 | 4.88 |
| Accent | 4.97 | 5.37 | 8.95 | 8.17 |
| Success / Warning / Danger | 4.93 / 5.13 / 6.05 | 5.33 / 5.54 / 6.54 | 8.76 / 10.93 / 8.26 | 7.99 / 9.97 / 7.54 |

OnPrimary / PrimaryFill: 17.17 in light mode and 16.57 in dark mode. Every specified value passes; no fine-tuning is needed. Values not previously specified (dark InkTertiary and both light/dark Success / Warning / Danger) are newly set in this proposal and also pass.

Limits: InkTertiary on UserBubble is only 4.15 / 4.17 (light / dark); light Accent is 4.47 there. Use only Ink / InkSecondary on UserBubble. InkTertiary on the dark glow is 4.43, so apply the same rule there.

## 2. Typography (system fonts only; no rounded design)

| Use | Specification |
|---|---|
| Top-level page title (Tasks, welcome title) | 30 / 36 bold |
| Sheet title, empty-chat title, Settings header name | 22 / 28 semibold |
| Section title | 13 / 18 semibold InkSecondary; no uppercase or letter spacing; 6pt left indent; count format “等你处理 · 2” |
| Body | 17 / 25 regular; list title 17 / 22 medium |
| Secondary | 15 / 21 InkSecondary (goal, explanation, hint row) |
| Supporting | 13 / 18 InkSecondary; time/count uses InkTertiary; numbers use tabular figures |
| Button / text link | Button 17 semibold; standalone text link 17 medium; inline text button 15 medium |

## 3. Shape and component rules

- **Cards / grouped lists**: Surface, 12 continuous radius, 0.5pt Hairline outline, no shadow, 14 padding (group row 12 × 14, 48 minimum height). Do not nest colored rounded blocks inside cards; use 0.5pt Hairline separators.
- **Buttons**: radius 12, height 48, not capsule-shaped. Primary uses PrimaryFill / OnPrimary; secondary uses Surface + 0.5pt Hairline + Ink; text buttons use Accent and no background.
- **Composer**: Surface, radius 12, height 48, 0.5pt outline, no shadow; “+” on left in InkSecondary; send arrow on right in InkTertiary when empty and Ink when non-empty.
- **Bubbles**: user message uses UserBubble, radius 16, 9 × 14 padding, 80% max width, no tail; Orbit replies have no bubble.
- **Status / count**: no capsules. Status = 6pt dot + text: Success for “待命中” (Standing by) / “已连接” (Connected) / “已完成” (Completed), Accent for “进行中” (In progress), Warning for “需要你” (Needs you) / “中风险” (Medium risk), Danger for “遇到阻碍” (Blocked) / “离线” (Offline), and InkTertiary for “已取消” (Cancelled). Count = text “· 2”.
- **Icons**: linear SF Symbols in InkSecondary, inline at 20pt, no colored background (only selected tab item uses fill). Connection entry = unfilled computer icon (24pt); reconnecting / offline = icon + 13pt text (Warning), no capsule.
- **Progress**: 2pt line, Hairline track, Accent fill, 10pt below the text; no percentage.
- **Tap targets** ≥ 44 × 44 pt: expand inline text buttons and hint rows (38pt visible height) with `contentShape` without changing their visual size.
- **Tab bar**: keep system TabView (floating style on iOS 26), selected item Ink and unselected InkSecondary; keep its system badge.
- **Copy**: short functional phrases, no self-introductions or cutesy lines (except the welcome and empty-chat greetings explicitly retained above); product name is Orbit, never “管家”; no technical terms (tool names, model names, IDs, device models).
- **Unillustrated states** (offline, failed, expired, large text): use the same rules: status = dot + text; hint = one line of text; no capsules or colored blocks.
- **Dark mode**: same token set; primary button is inverted; separate cards with Surface + Hairline; glow #2A221C.
- **Shadows**: remove all (delete Elevation); use Surface and Hairline for dark-mode hierarchy. Spacing: page edge 16 (large title 20), section gaps 22, card gaps 12, sheet side margins 22.

## 4. Six screen specifications

1. **Welcome / pairing**: Canvas + glow; centered column: character 178 (waves once), title “你好，我是 Orbit” at 30 bold, subtitle “连接你的 Mac，把想做的事交给我。” at 17 InkSecondary; move the group down to visual center (character top ≈ 200). Remove the three `points` items. Bottom controls (20 side margins): primary button “连接我的 Mac” with scan icon; below, “粘贴配对链接” on the left in Accent (with icon), “体验演示” on the right in InkSecondary, both 17 medium.
2. **Empty chat**: Keep centered stage: character 140, “● Orbit · 待命中” at 13, title at 22 semibold, description at 15 (keep wording unchanged); remove suggestion buttons. Top-right unfilled computer icon. Above composer, optionally add “最近”: 13 semibold heading + up to three rows (title 17 / “昨天 · 已完成” 13 / InkTertiary arrow), with 0.5pt dividers above and below rows. Hide it when there is not enough room (keyboard or large text). Placeholder: “给 Orbit 发消息”.
3. **Chat stream**: Header aligned left: 36 avatar (3D, no apricot ring) + name at 17 semibold + status row (6pt dot + 13; use Accent dot while working); connection icon on right. Body text 17 / 25, no bubbles. Cards follow §3. **Comparison card**: each row has name 17 (recommended item semibold) | score/distance 13 InkSecondary | price 17 tabular, right aligned (such as “¥280/人”); Hairline between rows; Hairline at card bottom followed by one 13pt pro line. **Booking card**: key 15 InkSecondary (width 64) / value 17, Hairline between rows. **Task progress card**: title 17 semibold + “● 3/4 步 · 正在确认空位” 13 + 2pt progress line. **Hint row**: memory “已记住：…” in InkSecondary + “撤销”; confirmation “● 需要你确认：…” in Ink (Warning dot) + “查看”; one line, 38 minimum height, Hairline between rows and above/below, action text Accent 15 medium. **Thinking row**: OrbitMark 16 (with outline in light mode) + “正在想办法…” 15 InkSecondary; remove skeleton card.
4. **Tasks**: large “任务” title at 30 bold; three grouped lists (card specification): “等你处理 · 2” (title 17 / subtitle 13, “中风险” in Warning / Accent “查看” or “回答” on right); “进行中 · 3” (title / one-line goal 15 / “● 2/4 步 · 3 分钟前” 13 InkTertiary / 2pt progress line at bottom); “已结束 · 5” (one row “显示已结束的任务” + Accent “清除”, keep the existing confirm-count behavior). No left color stripe and no capsules.
5. **Approval sheet** (detents unchanged): header: avatar 26 (3D) + “需要你确认” 15 InkSecondary + “✕” (no background); title 22 semibold; next line 13 “中风险（Warning）· 28 分钟后过期”; key-value rows (label 15 / value 17, Hairline above first row, between rows, and below last row); a 15 InkSecondary paragraph with no background or icon: “批准后：…不会在线付款。”; buttons: primary “批准” (with Face ID icon when biometrics are required), secondary “拒绝”, gap 10. Do not add a separate “需要 Face ID” line.
6. **Settings home**: one left-aligned header row: avatar 40 (3D) + “Orbit” 22 semibold + “● 已连接 · Herry 的 MacBook” 15. Then three grouped lists “我的 Orbit / 连接与设备 / 记忆与通知” (keep existing row labels); 20pt linear icon at row start (no colored block, dividers start at 46); right value 17 InkSecondary + arrow 14 InkTertiary. Keep device model and other technical information off the home screen.

## 5. Mapping to existing code

| Existing | Change to |
|---|---|
| `Tokens.swift` + each colorset | Apply §1 values and remove retired colors; `Radius.card` 22→12, input 26→12, bubble 20→16; delete Elevation |
| `Typography.swift` | Remove `.rounded`; welcome / large title 30 bold, empty-chat title 22 semibold |
| `Surfaces.swift` | Remove shadow from `OrbitCardSurface`; remove SurfaceInset from `KeyValueList` and use Hairline; remove `NoteBlock` background; change `SectionHeader` count capsule to “· N” |
| `Buttons.swift`, `Status.swift` | `.capsule` → radius 12, height 48; remove `.soft` / `.inset`, add secondary; `StatusChip` → dot + text |
| `Glass.swift`, `Connection.swift` | Remove glass background from connection entry; use an unfilled icon |
| `ChatStage` / `ChatHeader` / `ComposerView` / `MessageViews` / `ThinkingRow` | Remove suggestion buttons, add “最近”; left-align header and remove avatar ring; composer 12 / 48; remove Orbit reply bubbles; delete `SkeletonCard` |
| `CardChrome` / `BoundCards` / `ContentCards` | Update card appearance, comparison, booking, progress, and hint rows per §4.3 |
| `TasksView` / `TaskPresentation` | Update row styles and section headings; remove color stripes and chips |
| `ApprovalSheet`, `SettingsView` / `SettingsComponents`, `PairingWelcomePage`, `MainTabView` | Follow §4.5, §4.6, §4.1; delete `SettingsIconTile` and `WelcomePoint`; set TabView tint to Ink (set page links and Toggle to Accent separately) |

## 6. Open questions / differences from the initial specification

- The welcome screen has no numbered steps (only the agreed changes); button and link wording stays as currently used: “连接我的 Mac”, “粘贴配对链接”, “体验演示”.
- The chat header changes from centered to left-aligned to match the initial specification; the avatar remains 3D at 36pt. To keep a centered header instead, change only the header line in §4.3.
- After changing the approval-sheet header to “需要你确认”, remove the repeated “需要你确认 ·” from the line under the title, leaving only “中风险 · 28 分钟后过期”.
- The tab badge (system red) is the only capsule retained because it is a system component.
- The design does not show the existing “遇到问题” section. Recommendation: merge it into “等你处理” (Danger dot + “遇到阻碍” in the row); if it must remain separate, use the same grouped-list style.
- For “before” task screenshots, use `wp4/01-tasks-third.png` (light) and `wp4/list-dark-top.png` (dark); they are closer to the current version than `00-baseline-tasks.png`.
