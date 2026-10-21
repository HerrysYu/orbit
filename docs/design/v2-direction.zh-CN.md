# Orbit 新方向 v2：克制、系统化（实现规格）

[English](v2-direction.md) | **简体中文**

状态：设计稿，待主人确认后再改 App。对照图 `mockups/export/orbit-v2-light.png`、`orbit-v2-dark.png`；源码 `mockups/src/screens-v2.js`、`styles-v2.css`；
预览 `mockups/index.html?board=v2-light|v2-dark`（加 `&g=welcome|empty|chat|tasks|approval|settings` 只看一组）。尺寸 iPhone Air 420 × 912 pt。

## 0 范围
- **保持不变**：欢迎页、空对话的居中布局，问候语、副标题、说明文字（逐字保持现有 App）；所有 3D 角色（欢迎页、空对话、对话头部头像、设置头部、审批弹窗头部）；舞台光晕；扁平 OrbitMark 只用在思考行。
- **要改**：配色、字体（不用 rounded）、形状（卡片 / 按钮 / 状态 / 数量 / 图标）、去掉阴影和卡片内套的色块；欢迎页删三条卖点；空对话删三个建议按钮；输入框占位改「给 Orbit 发消息」；审批弹窗头部改「需要你确认」。
- 审查条目：3 卖点列表 · 5 卡片阴影嵌套 · 8 配色 · 9 建议按钮 · 10 文案 · 11 任务大卡。1、2、7、14 已取消，保持现状。

## 1 配色 token（Assets.xcassets 同名 colorset 改值）
| token | 浅色 | 深色 | 用途 |
|---|---|---|---|
| Canvas | #F7F6F4 | #121110 | 页面底 |
| Surface | #FFFFFF | #1C1B19 | 卡片、分组列表、输入框、Sheet、次按钮 |
| Ink | #1D1B19 | #F2F0EC | 标题、正文 |
| InkSecondary | #5F5B55 | #A8A49D | 次要文字、分区标题、线性图标 |
| InkTertiary | #736F69 | #8C8882 | 占位符、辅助信息、箭头（只放在 Canvas / Surface 上） |
| Hairline | #E6E3DE | #2E2C29 | 0.5pt 描边、分隔线、进度线轨道 |
| Accent | #A9521A | #F0A15E | 只用于：可点的文字链接、进行中 6pt 圆点、2pt 进度线 |
| PrimaryFill / OnPrimary | #1D1B19 / #FFFFFF | #F2F0EC / #121110 | 主按钮 |
| UserBubble | #ECEAE6 | #2A2826 | 你的消息（上面只放 Ink / InkSecondary） |
| Success / Warning / Danger | #1F7A4A / #8A6100 / #B3261E | #5FC48A / #E8C14E / #FF8A80 | 只作文字和 6pt 圆点，不做底色块 |

AccentText 与 AccentColor 合并为 Accent。删除：SurfaceInset、各 *Soft、OrbitBubble、OnUserBubble（= Ink）、GlassEdge；BrandApricot / BrandSoft 不再当界面色（`OrbitSpinner` 等进行中指示改用 Accent）。
**角色专用色**（不是 token，保持现有值）：光晕 #FFF3E6 / #2A221C，头像底圆 #FCE9D8 / #453022，OrbitMark 奶白 + 杏橙环 + 橙色卫星；标签栏角标是系统红。

**对比度**（WCAG 2.x，文字要 ≥ 4.5:1；已逐项计算）

| 文字色 | 浅 Canvas | 浅 Surface | 深 Canvas | 深 Surface |
|---|---|---|---|---|
| Ink | 15.90 | 17.17 | 16.57 | 15.12 |
| InkSecondary | 6.24 | 6.74 | 7.60 | 6.94 |
| InkTertiary | 4.62 | 4.99 | 5.35 | 4.88 |
| Accent | 4.97 | 5.37 | 8.95 | 8.17 |
| Success / Warning / Danger | 4.93 / 5.13 / 6.05 | 5.33 / 5.54 / 6.54 | 8.76 / 10.93 / 8.26 | 7.99 / 9.97 / 7.54 |

OnPrimary / PrimaryFill：浅 17.17，深 16.57。给定色值全部达标，无需微调；未给定的值（InkTertiary 深色，Success / Warning / Danger 浅深两套）是本稿新定，也已达标。
限制：UserBubble 上 InkTertiary 只有 4.15 / 4.17（浅 / 深），浅色 Accent 4.47，所以 UserBubble 上只放 Ink / InkSecondary；深色光晕上 InkTertiary 4.43，同理。

## 2 字体（只用系统字体，不用 rounded）
| 用途 | 规格 |
|---|---|
| 顶级页面大标题（任务、欢迎页标题） | 30 / 36 bold |
| Sheet 标题、空对话标题、设置头部名称 | 22 / 28 semibold |
| 分区标题 | 13 / 18 semibold InkSecondary，不加大写和字距，左缩进 6；数量写成「等你处理 · 2」 |
| 正文 | 17 / 25 regular；列表标题 17 / 22 medium |
| 次要 | 15 / 21 InkSecondary（目标、说明、提示行） |
| 辅助 | 13 / 18 InkSecondary；时间、计数用 InkTertiary；数字用等宽（tabular） |
| 按钮 / 文字链接 | 按钮 17 semibold；独立文字链接 17 medium；行内文字按钮 15 medium |

## 3 形状与组件规则
- **卡片 / 分组列表**：Surface，圆角 12（continuous），0.5pt Hairline 描边，无阴影，内边距 14（分组行 12 × 14，最小高 48）。卡片里不再套带底色的圆角块，用 0.5pt Hairline 分组。
- **按钮**：圆角 12，高 48，不用胶囊。主按钮 PrimaryFill / OnPrimary；次按钮 Surface + 0.5pt Hairline + Ink；文字按钮 Accent、无底。
- **输入框**：Surface，圆角 12，高 48，0.5pt 描边，无阴影；左「+」InkSecondary，右发送箭头（空时 InkTertiary，有内容时 Ink）。
- **气泡**：你的消息 UserBubble、圆角 16、内边距 9 × 14、最宽 80%、无尾巴；Orbit 的回复不加气泡。
- **状态 / 数量**：不用胶囊。状态 = 6pt 圆点 + 文字：Success 待命中 / 已连接 / 已完成，Accent 进行中，Warning 需要你 / 中风险，Danger 遇到阻碍 / 离线，InkTertiary 已取消。数量 = 文字「· 2」。
- **图标**：SF Symbols 线性，InkSecondary，行内 20pt，不垫色块（仅标签栏选中项用 fill）。连接入口 = 无底色电脑图标（24pt）；恢复中 / 离线 = 图标 + 13pt 文字（Warning），不用胶囊。
- **进度**：2pt 线，轨道 Hairline，填充 Accent，距上方文字 10；不写百分比。
- **点击区域** ≥ 44 × 44 pt：行内文字按钮、提示行（可视高 38）用 `contentShape` 扩大，可视尺寸不变。
- **标签栏**：沿用系统 TabView（iOS 26 浮动样式），选中项 Ink、未选中 InkSecondary；角标是系统组件，保持。
- **文案**：功能性短句，不写自我介绍和卖萌句子（已确认保留的欢迎页、空对话问候语除外）；产品叫 Orbit，不出现「管家」；不出现技术词（工具名、模型名、id、设备型号）。
- **没画的状态**（离线、失败、过期、大字号）按同一规则：状态 = 圆点 + 文字，提示 = 一行文字，不用胶囊和色块。
- **深色**：同一套 token；主按钮反白；卡片靠 Surface + Hairline 分层；光晕 #2A221C。
- **阴影**：全部去掉（`Elevation` 删除）；深色靠 Surface 与 Hairline 分层。间距：页边 16（大标题 20）、分区间 22、卡片间 12、Sheet 左右 22。

## 4 六个界面要点
1. **欢迎 / 配对**：Canvas + 光晕；居中一列：角色 178（挥手一次）、标题「你好，我是 Orbit」30 bold、副标题「连接你的 Mac，把想做的事交给我。」17 InkSecondary；整体下移到视觉中心（角色顶 ≈ 200）。删 `points` 三条。底部（左右 20）：主按钮「连接我的 Mac」（带扫码图标）；下方左「粘贴配对链接」Accent（带图标）、右「体验演示」InkSecondary，17 medium。
2. **空对话**：居中舞台不变：角色 140、「● Orbit · 待命中」13、标题 22 semibold、说明 15（文字不变）；删建议按钮。右上无底色电脑图标。输入框上方「最近」（新增，可去掉）：13 semibold 标题 + 最多 3 行（标题 17 / 「昨天 · 已完成」13 / 右箭头 InkTertiary），行上下 0.5pt 分隔线；放不下（键盘、大字号）时隐藏。占位「给 Orbit 发消息」。
3. **对话流**：头部靠左：头像 36（3D，不加杏橙环）+ 名称 17 semibold + 状态行（6pt 圆点 + 13；处理中用 Accent 点），右侧连接图标。正文 17 / 25 无气泡。卡片见 §3。**对比卡**：每行 名称 17（推荐项 semibold）｜评分距离 13 InkSecondary｜价格 17 等宽右对齐（「¥280/人」），行间 Hairline，卡底 Hairline + 一行优点 13。**预订卡**：键 15 InkSecondary（宽 64）/ 值 17，行距 Hairline。**任务进度卡**：标题 17 semibold + 「● 3/4 步 · 正在确认空位」13 + 2pt 进度线。**提示行**：记忆「已记住：…」InkSecondary +「撤销」；确认「● 需要你确认：…」Ink（Warning 点）+「查看」；单行、最小高 38、行间与上下各一条 Hairline，操作文字 Accent 15 medium。**思考行**：OrbitMark 16（浅色带轮廓）+「正在想办法…」15 InkSecondary，去掉骨架卡。
4. **任务**：大标题「任务」30 bold；三组分组列表（卡片规格）：「等你处理 · 2」（标题 17 / 副标题 13，「中风险」用 Warning / 右侧 Accent「查看」「回答」）、「进行中 · 3」（标题 / 一行目标 15 / 「● 2/4 步 · 3 分钟前」13 InkTertiary / 底部 2pt 进度线）、「已结束 · 5」（一行「显示已结束的任务」+ Accent「清除」，沿用先确认数量的行为）。无左侧色条、无胶囊。
5. **审批弹窗**（detents 不变）：头部：头像 26（3D）+「需要你确认」15 InkSecondary +「✕」（无底色）；标题 22 semibold；下一行 13「中风险（Warning）· 28 分钟后过期」；键值行（标签 15 / 值 17，首行上方、行间、末行下方各一条 Hairline）；下面一段 15 InkSecondary 无底色无图标：「批准后：…不会在线付款。」；按钮：主「批准」（需要生物识别时带 Face ID 图标）、次「拒绝」，间距 10。不再单独写「需要 Face ID」一行。
6. **设置首页**：头部左对齐一行：头像 40（3D）+「Orbit」22 semibold + 「● 已连接 · Herry 的 MacBook」15；其下三组分组列表「我的 Orbit / 连接与设备 / 记忆与通知」（行标签沿用现有文案），行首 20pt 线性图标（无色块，分隔线从 46 起），右侧值 17 InkSecondary + 箭头 14 InkTertiary；设备型号等技术信息不上首页。

## 5 与现有代码的对应
| 现有 | 改为 |
|---|---|
| `Tokens.swift` + 各 colorset | 按 §1 改值，删废弃色；`Radius.card` 22→12、`input` 26→12、`bubble` 20→16；`Elevation` 删除 |
| `Typography.swift` | 去掉 `.rounded`；欢迎 / 大标题 30 bold，空对话标题 22 semibold |
| `Surfaces.swift` | `OrbitCardSurface` 去阴影；`KeyValueList` 去 SurfaceInset 改 Hairline；`NoteBlock` 去底色；`SectionHeader` 计数胶囊改「· N」 |
| `Buttons.swift`、`Status.swift` | `.capsule` → 圆角 12、高 48；删 `.soft` / `.inset`，新增 secondary；`StatusChip` → 圆点 + 文字 |
| `Glass.swift`、`Connection.swift` | 连接入口去玻璃底，变无底色图标 |
| `ChatStage` / `ChatHeader` / `ComposerView` / `MessageViews` / `ThinkingRow` | 删建议按钮、加「最近」；头部靠左、头像去环；输入框 12 / 48；Orbit 回复去气泡；删 `SkeletonCard` |
| `CardChrome` / `BoundCards` / `ContentCards` | 卡片外观、对比卡、预订卡、进度卡、提示行按 §4.3 |
| `TasksView` / `TaskPresentation` | 行样式、分组标题、去色条和芯片 |
| `ApprovalSheet`、`SettingsView` / `SettingsComponents`、`PairingWelcomePage`、`MainTabView` | 按 §4.5、§4.6、§4.1；`SettingsIconTile` 删除；删 `WelcomePoint`；TabView tint 设为 Ink（页面内的链接、Toggle 另设 Accent） |

## 6 待确认 / 与最初规格的差异
- 欢迎页没有放编号步骤（只做已定的修改）；按钮、链接文字沿用现有（「连接我的 Mac」「粘贴配对链接」「体验演示」）。
- 对话头部从居中改为靠左，是照最初规格套用的，头像保持 3D（36pt）。若想保留居中头部，只需改 §4.3 头部一条。
- 审批弹窗头部改成「需要你确认」后，标题下一行去掉重复的「需要你确认 ·」，只留「中风险 · 28 分钟后过期」。
- 标签栏角标（系统红）是唯一保留的胶囊，因为它是系统组件。
- 现有「遇到问题」分组设计稿没画：建议并入「等你处理」（行内 Danger 点 +「遇到阻碍」）；要独立保留则沿用同一分组样式。
- 「改前」任务截图用 `wp4/01-tasks-third.png`（浅）和 `wp4/list-dark-top.png`（深），比 `00-baseline-tasks.png` 更接近现在的版本。
