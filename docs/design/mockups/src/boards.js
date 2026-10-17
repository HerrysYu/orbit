// Orbit redesign — boards (what gets reviewed). ?board=<id> renders a single board for export.
const PH = '<span class="tag ph">角色图：设定图临时抠图，仅供评审</span>';

const KEY_NOTES = {
  empty: [
    '连接入口：Mac 已连接时只显示电脑图标和绿点；离线或恢复中变成带文字的胶囊（见 ②-4）。点击打开连接详情。',
    '角色是这一屏唯一的主角（140pt 迎接姿态）。打开时挥一次手后静止；开始对话或弹出键盘时，它缩小并飞到顶部头像的位置（同一元素位移，不是淡入淡出）。',
    '建议最多 3 条，贴近输入框方便单手点。点按只把文字填进输入框，不会直接发送。',
    '“+”打开附件托盘（照片、文件、链接、提醒事项），附件随消息一起发送。不放麦克风：语音尚未实现。',
  ],
  running: [
    '顶部是 Orbit 的“在场状态”（参考 Muse）：头像 + 一行实时状态，来自 butler.status 与 session.progress。点头像打开「活动与权限」（④-3）。',
    '任务卡在对话里原位更新：当前步骤加粗并附真实动作摘要；进度只写“已完成 1 / 4 步”，不出现百分比或预计时间。',
    '一条长对话：Orbit 工作时随时可以补充要求（这里的“吧台位”），会送进正在进行的工作，不必等它回完。',
    '正在回复且输入框为空时，发送键变成 ■「停止回复」——只停这条回复，任务和手机上的操作继续。',
    '取消整个任务在任务卡 ⋯ 或任务详情里，并单独确认。“停止回复”和“取消任务”永远不共用一个按钮。',
  ],
  tasks: [
    '“需要你处理”永远置顶：待确认的操作和等你回答的问题，写明对象与过期时间。底部 Tab 角标与之一致。',
    '“查看”直接打开确认 Sheet；“回答”跳回对话里对应的问题。',
    '进行中任务用左侧细杏橙条标记；分段进度条按步骤数（Task.steps）绘制，不是百分比。',
    '摘要用真实动作（来自执行会话），不写“处理中…”这类空话。',
    '“遇到问题”写清原因和你要做什么，不捏造自动恢复时间。已完成的任务紧凑排列，不播放动画。',
    '“清除”一次移除所有已结束的任务（已完成 / 未完成 / 已取消），先确认数量；对应的执行会话一并归档。也可以左滑单条清除。',
  ],
  approval: [
    'Sheet 从对话卡片、任务页或通知进入，可下拉关闭（关闭 ≠ 拒绝，审批仍待确认）。',
    '列出对象、时间、人数、费用。显示层把 Approval.detail 里的「标签：内容」逐行解析成表格，不改协议。',
    '写清批准后会发生什么、不会发生什么（不会在线付款）。',
    '按服务端 requireBiometric 调起 Face ID；按钮用具体动词；提交中锁定，防止重复提交。',
    '“已批准”只表示授权成功；真正提交完成后，对话和任务里才显示“已预订”。过期后按钮不可用并说明原因。',
  ],
};

const BOARDS = [
  {
    id: 'key-light', title: '① 四个关键画面 · 浅色', theme: 'light',
    sub: '对话空状态、执行中的对话、任务列表、需要确认的操作。一条长对话 + Orbit 在场状态（参考 Muse）；角色只在欢迎、空状态和关键反馈时作为主角出现，平时缩成顶部头像。所有控件都对应现有协议能力。',
    screens: [
      { cap: '对话 · 首次 / 空状态', fn: sChatEmpty, notes: KEY_NOTES.empty },
      { cap: '对话 · 执行中', fn: sChatRunning, notes: KEY_NOTES.running },
      { cap: '任务', fn: sTasks, notes: KEY_NOTES.tasks },
      { cap: '需要你确认', fn: sApproval, notes: KEY_NOTES.approval },
    ],
  },
  {
    id: 'key-dark', title: '① 四个关键画面 · 深色', theme: 'dark', dark: true,
    sub: '温暖炭灰 + 奶白。主要实心按钮在深色下改为杏橙底、深棕字（primaryFill #F2AD73 / onPrimary #241A13）；卡片靠表面色分层、不用阴影；角色是透明抠图，没有亮色底块。',
    screens: [
      { cap: '对话 · 首次 / 空状态', fn: sChatEmpty, notes: ['同浅色。舞台光晕换成很淡的暖棕，角色投影加深，避免“贴纸感”。'] },
      { cap: '对话 · 执行中', fn: sChatRunning, notes: ['Orbit 气泡用 surface #24211E，不加描边；你的气泡用 brandSoft #453022，正文奶白。'] },
      { cap: '任务', fn: sTasks, notes: ['状态色全部换成深色版本，文字对比度见设计系统板；“需要你处理”的图标底色仍是 warningSoft。'] },
      { cap: '需要你确认', fn: sApproval, notes: ['遮罩加深到 55%，Sheet 用 surface；主按钮杏橙底深棕字，Face ID 图标同色。'] },
    ],
  },
  {
    id: 'chat-more', title: '② 对话的更多状态', theme: 'light',
    sub: '结果交付与选择、附件、键盘与“有新回复”、Mac 离线与发送失败。卡片原位更新，同一结果不会因状态变化不断新增副本。',
    screens: [
      { cap: '结果交付 · 你来选', fn: sChatResult, notes: ['对比卡窄屏纵向排列；推荐项用浅杏橙底和“推荐”标签，不用撒花和徽章。每一项都能直接“选这家”。', '你的选择会作为你发出的消息出现在对话里（ui.action），卡片保留选中结果。', '需要确认的操作在对话里是一张紧凑卡；“查看并确认”打开 ①-4 的 Sheet。批准、执行结果都在这张卡上原位更新。'] },
      { cap: '附件托盘', fn: sChatAttach, notes: ['“+”打开附件托盘，占据键盘的位置；再点一次或下拉收起。', '已选附件出现在输入框上方：缩略图或文件名，右上角移除。', '处理中的附件（压缩到 ≤2048px）显示进度，完成前发送键不可用。', '托盘里直接嵌入系统照片选择器（PhotosPicker inline），文件、链接、提醒事项各自打开系统面板。'] },
      { cap: '键盘 · 有新回复', fn: sChatKeyboard, notes: ['你往上翻看旧消息时，新回复不把你拉回底部；出现“有新回复”，点一下回到底部。只有原本就在底部时才跟随。', '输入框最多自然增长到 6 行，再在内部滚动；角色已缩成顶部头像，不占空间。', '回复生成中、输入框有草稿：右侧同时出现 ■ 停止回复 与 ↑ 发送补充，两个动作分开。'] },
      { cap: 'Mac 离线 · 发送失败', fn: sChatOffline, notes: ['连接入口变成醒目的“Mac 离线”，状态行写上次在线时间。', '横幅说明实际影响：消息会排队、正在重试；“详情”查看连接路径并手动重连。', '任务卡保留最后同步的状态并标注时间，不会因为断线改成“失败”。', '已进入发送队列的消息标“待发送”。', '真正失败的消息标“没有送达”并给出重试；输入框仍可用。'] },
    ],
  },
  {
    id: 'connect', title: '③ 连接 Mac', theme: 'light',
    sub: '欢迎 → 扫码 → 核对校验码 → 成功，四步完成，没有必读教程。覆盖相机未授权、二维码过期、连接失败与重试。',
    screens: [
      { cap: '欢迎', fn: sWelcome, notes: ['唯一主角是挥手的 Orbit（178pt），进入时挥一次手。', '主操作“连接我的 Mac”进入扫码；三行说明只讲在哪运行、怎么看进度、谁做决定。', '备用：粘贴配对链接（也支持在备忘录、信息里直接点 opa:// 链接）。', '“体验演示”全程带“演示”标记，看起来不会像已连接真实设备。'] },
      { cap: '扫码', fn: sScan, notes: ['提示在 Mac 运行 opa pair。相机画面用 AVFoundation 取帧、SwiftUI 渲染，不引入 UIKit。', '识别成功先显示 Mac 名称再进入核对；二维码过期提示在 Mac 上重新运行。', '相机被拒时，取景区换成“去设置开启相机”，下面的粘贴链接、相册识别始终可用。'] },
      { cap: '核对校验码', fn: sVerify, notes: ['6 位校验码大号显示，附 Mac 名称和连接路径。', '等待 Mac 确认时只有一个小指示器，不用全屏转圈。', '数字不一致直接取消；失败时说明原因（过期 / 被拒绝 / 连接中断）并给“重试”。'] },
      { cap: '连接成功', fn: sPaired, notes: ['角色举手庆祝一次，随后静止，不放全屏撒花。', '一个按钮直接进入对话；连接详情以后在设置里看。'] },
    ],
  },
  {
    id: 'detail', title: '④ 任务详情 · 执行详情 · 活动与权限', theme: 'light',
    sub: '“看得见它在做什么”（参考 Muse 的状态摘要与活动记录）：点头像看全局，点任务看步骤，点执行会话看每一步动作。',
    screens: [
      { cap: '任务详情', fn: sTaskDetail, notes: ['左上返回任务列表；⋯ 里放“取消任务”等次要操作。', '层级：状态 → 标题 → 目标 → 现在等你做什么（直接给操作）。', '时间线只强调当前步骤，历史步骤不一起闪动；已完成步骤可展开看细节。', '结果优先给可用入口；执行会话收在“执行详情”。没有接口支持的下载、分享、暂停、重试不出现。', '取消前说明后果（停止进行中的步骤，已完成的不撤销），在 Mac 确认前显示“正在取消”。'] },
      { cap: '执行详情（Sheet）', fn: sSessionSheet, notes: ['每个执行会话一张 Sheet：在哪执行（Mac / 安卓手机）、状态、用时、模型、权限。', '动作记录来自 session.detail：时间 + 图标 + 一句话，不展示原始日志。', '可以补充指令（steer）或归档。手机截图证据目前只存在 Mac 上；在 App 里看截图需要新增接口（未实现，不画按钮）。'] },
      { cap: '活动与权限（点头像）', fn: sActivity, notes: ['点顶部头像打开：Orbit 现在在做什么、在哪里做。', '执行中的会话实时更新，点进去是执行详情。', '“最近的动作”是审计记录的摘要，回答“它刚才做了什么”。', '“我能做什么”直接列出权限：Mac 命令逐项确认；手机敏感点击按你的选择自动执行并留记录。点进可调整。'] },
      { cap: '任务 · 空状态', fn: sTasksEmpty, notes: ['90pt 角色 + 一句说明 + “去聊聊”。有任务后，角色不再占据大块屏幕。'] },
    ],
  },
  {
    id: 'settings', title: '⑤ 设置 · 记忆 · 锁屏 · 灵动岛', theme: 'light',
    sub: '设置先回答“它会怎样帮我、我能控制什么”；技术细节放到下一级。锁屏与灵动岛用静态素材也能说清状态。',
    screens: [
      { cap: '设置', fn: sSettings, notes: ['顶部 76pt 头像与名字，点头像进入“名字和形象”。', '连接与设备同时显示 Mac 和安卓执行手机的状态。', '权限用具体后果描述（例：完全访问＝Mac 上的命令不再逐项询问），不用“更聪明模式”这类说法。', '模型、Host ID、中继地址等技术项放在“高级”和连接详情里；保存时显示保存中 / 成功 / 失败。'] },
      { cap: '记忆', fn: sMemory, notes: ['右上 + 手动添加；也可以在对话里说“记住…”。', '分段筛选：你告诉我的 / 我推断的（Memory.source）。', '左滑删除，删除前确认。接口没有撤销能力，所以不画“撤销”。', '说明删除后的后果。'] },
      { cap: '锁屏 · Live Activity · 通知', fn: sLock, notes: ['Live Activity：任务名、当前步骤、步骤计数、状态；头像静态显示，不依赖持续动画。', '需要确认时推送通知写清对象，点开直接进入确认 Sheet；Face ID 在 App 内完成。'] },
      { cap: '灵动岛 · 主屏图标', fn: sIsland, notes: ['展开态：需要你时写明原因，并提供“打开 Orbit 确认”。', '紧凑 / 最小态用矢量星环标识 + 文字，不缩放 3D 图；需要你时同时出现图标和“待确认”文字。', '主屏上的 Orbit 图标，详见 ⑥。'] },
    ],
  },
];

/* ───────────── v2 · 新方向对照（克制、系统化）─────────────
   改前 = 现在 App 的真实截图（ios/screenshots），改后 = 设计稿（screens-v2.js）。规格：docs/design/v2-direction.md。
   ?board=v2-light&g=chat 只渲染一组，方便检查。 */

const V2_SW = {
  light: [['画布 Canvas', '#F7F6F4'], ['表面 Surface', '#FFFFFF'], ['文字 Ink', '#1D1B19'], ['次要 InkSecondary', '#5F5B55'], ['辅助 InkTertiary', '#736F69'], ['分隔线 Hairline', '#E6E3DE'], ['强调 Accent', '#A9521A'], ['我的气泡 UserBubble', '#ECEAE6']],
  dark: [['画布 Canvas', '#121110'], ['表面 Surface', '#1C1B19'], ['文字 Ink', '#F2F0EC'], ['次要 InkSecondary', '#A8A49D'], ['辅助 InkTertiary', '#8C8882'], ['分隔线 Hairline', '#2E2C29'], ['强调 Accent', '#F0A15E'], ['我的气泡 UserBubble', '#2A2826']],
};

const V2_GROUPS = {
  welcome: { id: 'welcome', n: '1', title: '欢迎 / 配对', before: { src: 'wp5/01-welcome-light.png' }, after: v2Welcome,
    cap: '<b>改了什么：</b>去掉三条带色块图标的卖点（审查 3）；主按钮由胶囊改为圆角 12、高 48，配色换成新规范（审查 8）；标题改用系统字体，不再用圆体。角色、问候语、副标题、光晕和居中布局都保持，去掉卖点后整体略微下移。' },
  empty: { id: 'empty', n: '2', title: '空对话', before: { src: 'wp2/02-empty-light.png' }, after: v2Empty,
    cap: '<b>改了什么：</b>去掉三个建议按钮（审查 9）；输入框由悬浮胶囊改为圆角 12、细描边、无阴影，占位文字改为「给 Orbit 发消息」（审查 10、8）；输入框上方新增「最近」任务（放不下可去掉）。角色、问候语、说明文字和光晕保持不变。' },
  chat: { id: 'chat', n: '3', title: '对话流', before: { src: 'wp2/01-demo-light.png' }, after: v2Chat,
    cap: '<b>改了什么：</b>卡片去掉阴影与嵌套色块，改成白底 + 0.5pt 细描边、圆角 12（审查 5）；Orbit 的回复不加气泡，你的消息用中性灰底（审查 8）；记忆、确认提示压成一行文字加文字按钮；思考行去掉骨架卡；头部改为靠左一行，头像保持。' },
  tasks: { id: 'tasks', n: '4', title: '任务', before: { src: 'wp4/01-tasks-third.png' }, after: v2Tasks,
    cap: '<b>改了什么：</b>任务大卡改成系统分组列表，去掉左侧色条和阴影（审查 11、5）；状态改为「圆点 + 文字」，数量改为「· 2」，不再用胶囊（审查 8）；进度只留一条 2pt 细线。Accent 只用于链接、进行中圆点和进度线。' },
  approval: { id: 'approval', n: '5', title: '审批弹窗', before: { src: 'wp4/approval-ap1-light.png' }, after: v2Approval,
    cap: '<b>改了什么：</b>头部文字改为「需要你确认」（审查 10）；键值块去掉米色底，改成细分隔线；说明文字不再套色块和图标（审查 5、8）；按钮改为圆角 12，次按钮用描边；关闭按钮去掉底色圆。头部的角色头像保持。' },
  settings: { id: 'settings', n: '6', title: '设置首页', before: { src: 'wp6/settings-home-light.png', crop: true }, after: v2Settings,
    cap: '<b>改了什么：</b>图标不再垫彩色方块，直接用线性图标；分组改成白底 + 0.5pt 细描边、无阴影（审查 5、8）；头部改为头像 + 名称 + 连接状态一行，不再居中放大；设备型号这类技术信息不上首页。' },
};

BOARDS.push(
  {
    id: 'v2-light', layout: 'compare', theme: 'light', title: '新方向 · 改前 / 改后对照（浅色）', swatches: V2_SW.light,
    sub: '像系统自带的 App 一样克制：信息靠排版、留白和细分隔线组织，不靠彩色底块、阴影和胶囊。保留 3D 角色、居中舞台和光晕；扁平 OrbitMark 只用在思考行。左边是现在 App 的真实截图，右边是设计稿（iPhone Air，420 × 912 pt）。',
    groups: ['welcome', 'empty', 'chat', 'tasks', 'approval', 'settings'].map((k) => V2_GROUPS[k]),
  },
  {
    id: 'v2-dark', layout: 'compare', theme: 'dark', dark: true, title: '新方向 · 改前 / 改后对照（深色）', swatches: V2_SW.dark,
    sub: '对话流与任务的深色版，和浅色同一套 token。深色下卡片只靠 0.5pt 细描边和表面色分层，不用阴影。左边是现在 App 的真实截图，右边是设计稿。',
    groups: [
      { ...V2_GROUPS.chat, before: { src: 'wp2/04-demo-dark.png', dark: true },
        cap: '<b>深色：</b>画布 #121110、表面 #1C1B19，卡片只靠 0.5pt 细描边分层，无阴影；Accent 提亮为 #F0A15E，主按钮反白；提醒点 #E8C14E，思考行标志不加描边。其余改动同浅色。' },
      { ...V2_GROUPS.tasks, before: { src: 'wp4/list-dark-top.png', dark: true },
        cap: '<b>深色：</b>状态只用文字与 6pt 圆点（已连接 #5FC48A、需要你 #E8C14E、危险 #FF8A80），不做色块；进度线用 Accent #F0A15E，轨道用 Hairline #2E2C29。其余改动同浅色。' },
    ],
  },
);

/* ───────────── render helpers ───────────── */

function renderPhoneBoard(b) {
  if (b.layout === 'compare') return renderCompareBoard(b);
  return `<section class="board${b.dark ? ' dark' : ''}" id="${b.id}" style="width:${64 * 2 + 420 * 4 + 56 * 3}px">
    <h1>${b.title}</h1><div class="sub">${b.sub}</div>
    <div class="legend">${PH}<span class="tag new">iPhone Air · 420 × 912 pt</span></div>
    <div class="screens">${b.screens.map((s) => `<div class="col"><div class="cap"><b>${s.cap}</b></div>${s.fn(b.theme)}<ol class="notes">${s.notes.map((n) => `<li>${n}</li>`).join('')}</ol></div>`).join('')}</div>
  </section>`;
}

/** v2 boards: groups of "改前 | 改后" (real screenshot beside the new design), two groups per row. */
function renderCompareBoard(b) {
  const solo = new URLSearchParams(location.search).get('g');
  const sw = (b.swatches || []).map(([n, c]) => `<span><i style="background:${c}"></i>${n} <code>${c}</code></span>`).join('');
  const group = (g) => `<div class="v2group" id="${b.id}-${g.id}">
      <div class="v2gh"><span class="n">${g.n}</span><b>${g.title}</b></div>
      <div class="v2pair">
        <div class="v2col"><div class="v2lab">改前 · 现在的 App</div>${v2Before(g.before)}</div>
        <div class="v2col"><div class="v2lab after">改后 · 设计稿</div>${g.after(b.theme)}</div>
      </div>
      <p class="v2cap">${g.cap}</p>
    </div>`;
  return `<section class="board v2board${b.dark ? ' dark' : ''}" id="${b.id}" style="width:1976px">
    <h1>${b.title}</h1><div class="sub">${b.sub}</div>
    ${sw ? `<div class="sw">${sw}</div>` : ''}
    <div class="v2grid">${b.groups.filter((g) => !solo || g.id === solo).map(group).join('')}</div>
  </section>`;
}

/* ───────────── ⑥ App 图标 ───────────── */

function renderIconBoard() {
  const tile = (img, size, extra = '') => `<div class="icon-tile" style="width:${size}px;height:${size}px;${extra}"><img src="${IMG(img)}" alt=""></div>`;
  const home = (bg, label, dark) => `<div style="width:420px;height:300px;border-radius:40px;background:${bg};position:relative;overflow:hidden;box-shadow:0 30px 60px -30px rgba(48,43,39,.5)">
    <div style="position:absolute;top:44px;left:34px;right:34px;display:grid;grid-template-columns:repeat(4,64px);justify-content:space-between;row-gap:24px">
      ${['#e9dccf', '#5a7d6c', null, '#3d5873', '#d6a46d', '#c7c2bb', '#7b6a8f', '#9e4f3e'].map((c) => c ? `<div class="center" style="gap:6px"><div style="width:64px;height:64px;border-radius:15px;background:${c};opacity:${dark ? .7 : .9}"></div><span style="font-size:12px;color:${dark ? '#fff' : '#302B27'};opacity:.6">　</span></div>` : `<div class="center" style="gap:6px">${tile(dark ? 'icon-dark' : 'icon-apricot', 64)}<span style="font-size:12px;color:${dark ? '#fff' : '#302B27'}">Orbit</span></div>`).join('')}
    </div>
    <div style="position:absolute;bottom:16px;left:0;right:0;text-align:center;font-size:12.5px;color:${dark ? '#fff' : '#302B27'};opacity:.7">${label}</div>
  </div>`;
  return `<section class="board" id="icon" style="width:1976px">
    <h1>⑥ App 图标</h1>
    <div class="sub">直接采用设定图右下角的两张头像构图：浅杏橙底为默认图标，炭灰底作为系统深色图标，再派生着色版本。下图是临时裁切，用于确认方向；正式图标需按清单重新渲染。</div>
    <div class="legend"><span class="tag ph">临时裁切自设定图</span><span class="tag gap">正式 1024 源文件待制作</span></div>
    <div style="display:flex;gap:56px;margin-top:40px;align-items:flex-end">
      <div class="center" style="gap:14px">${tile('icon-apricot', 260)}<b style="font-size:16px">浅色（默认）</b><span style="font-size:13px;color:#6D6259">#F2A15F 杏橙底 · 奶白角色</span></div>
      <div class="center" style="gap:14px">${tile('icon-dark', 260)}<b style="font-size:16px">深色</b><span style="font-size:13px;color:#6D6259">#2F2B28 炭灰底 · 角色保持奶白</span></div>
      <div class="center" style="gap:14px">${tile('icon-dark', 260, 'filter:grayscale(1) contrast(1.15) brightness(1.05)')}<b style="font-size:16px">着色</b><span style="font-size:13px;color:#6D6259">系统按亮度着色，角色轮廓需清晰</span></div>
      <div style="flex:1;padding-bottom:40px">
        <b style="font-size:16px">小尺寸可读性</b>
        <div style="display:flex;gap:18px;align-items:flex-end;margin-top:16px">${[120, 87, 60, 40, 29].map((s) => `<div class="center" style="gap:8px">${tile('icon-apricot', s)}<span style="font-size:12px;color:#7E7268">${s}pt</span></div>`).join('')}</div>
        <ol class="notes" style="margin-top:22px">
          <li>40pt 以下仍能认出：奶白翘角轮廓 + 杏橙星环 + 两只眼睛。图标里不放文字和“orbit”字标。</li>
          <li>正式源文件：1024 × 1024、完整不透明背景、sRGB、无圆角（系统加遮罩）。角色重心略高于中心，星环两端留安全距离。</li>
          <li>iOS 26 用 Icon Composer 分三层（背景 / 角色 / 星环与卫星），系统可生成浅色、深色、着色、透明效果；iOS 18 回退为单图 + 深色 / 着色两张变体。</li>
        </ol>
      </div>
    </div>
    <div style="display:flex;gap:56px;margin-top:48px">${home('linear-gradient(160deg,#f3dcc4,#e6c3a2 55%,#d9a982)', '浅色主屏', false)}${home('linear-gradient(160deg,#4a3a30,#211b17 70%)', '深色主屏', true)}
      <div style="flex:1;font-size:14px;line-height:1.6;color:#4A423B;padding-top:8px">
        <b style="font-size:16px;color:#302B27">为什么用这一版</b>
        <p style="margin:10px 0 0">它就是你认可的角色头像示例：角色居中、星环斜绕、背景是品牌杏橙。放在主屏上，暖色在一排蓝绿图标里很容易找到，同时角色表情友善不幼稚。</p>
        <p style="margin:10px 0 0">深色图标保持角色本色，只把背景换成炭灰，不额外加发光或描边。</p>
      </div>
    </div>
  </section>`;
}

/* ───────────── ⑦ 设计系统 ───────────── */

function lum(hex) { const c = hex.replace('#', '').match(/../g).map((h) => parseInt(h, 16) / 255).map((v) => (v <= .03928 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4)); return .2126 * c[0] + .7152 * c[1] + .0722 * c[2]; }
function ratio(a, b) { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + .05) / (y + .05); }

const TOK = {
  light: { canvas: '#FAF7F2', surface: '#FFFFFF', surfaceInset: '#F1EBE3', ink: '#302B27', inkSecondary: '#6D6259', inkTertiary: '#7E7268', hairline: '#DED5CA', brandApricot: '#F2A15F', brandSoft: '#FCE9D8', accentText: '#8C471B', primaryFill: '#302B27', onPrimary: '#FFFDF9', success: '#326447', successSoft: '#E9F2E9', warning: '#875015', warningSoft: '#FFF0D6', danger: '#AC3932', dangerSoft: '#FBE9E5' },
  dark: { canvas: '#191715', surface: '#24211E', surfaceInset: '#302B26', ink: '#F6EFE6', inkSecondary: '#C4B8AA', inkTertiary: '#A99B8D', hairline: '#51473E', brandApricot: '#F2AD73', brandSoft: '#453022', accentText: '#F2AD73', primaryFill: '#F2AD73', onPrimary: '#241A13', success: '#91C7A2', successSoft: '#23362A', warning: '#E7BA73', warningSoft: '#3E301D', danger: '#F39C91', dangerSoft: '#412724' },
};
const PAIRS = [
  ['ink', 'canvas', '正文'], ['inkSecondary', 'canvas', '次要文字'], ['inkTertiary', 'canvas', '辅助文字'], ['inkTertiary', 'surface', '卡片内辅助文字'],
  ['accentText', 'canvas', '链接 / 强调'], ['accentText', 'brandSoft', '进行中标签'], ['ink', 'brandSoft', '你的气泡'], ['onPrimary', 'primaryFill', '主按钮'],
  ['success', 'successSoft', '已完成标签'], ['warning', 'warningSoft', '等你标签'], ['danger', 'dangerSoft', '阻碍标签'], ['ink', 'surfaceInset', '次按钮'],
];

function renderSystemBoard() {
  const sw = (mode) => Object.entries(TOK[mode]).map(([k, v]) => `<div style="display:flex;align-items:center;gap:10px;padding:6px 0"><span style="width:34px;height:34px;border-radius:10px;background:${v};box-shadow:inset 0 0 0 .5px rgba(0,0,0,.15)"></span><div style="flex:1"><div style="font-size:13.5px;font-weight:600">${k}</div><div style="font-size:12px;opacity:.65;font-family:var(--mono)">${v}</div></div></div>`).join('');
  const crow = (mode) => PAIRS.map(([f, bg, label]) => { const r = ratio(TOK[mode][f], TOK[mode][bg]); const ok = r >= 4.5; return `<tr><td><span style="display:inline-block;padding:3px 9px;border-radius:7px;background:${TOK[mode][bg]};color:${TOK[mode][f]};font-weight:600;font-size:13px">${label}</span></td><td style="font-family:var(--mono);font-size:12px">${f} / ${bg}</td><td style="font-weight:700;color:${ok ? '#326447' : '#AC3932'}">${r.toFixed(2)} ${ok ? 'AA' : '未达 4.5'}</td></tr>`; }).join('');
  const type = [['欢迎标题', '30 / 36 · Semibold · Rounded', 'font:600 30px/1.2 var(--rounded)', '你好，我是 Orbit'], ['大标题', '34 / 41 · Bold', 'font:700 34px/1.2 var(--font)', '任务'], ['页面标题', '23 / 29 · Bold', 'font:700 23px/1.25 var(--font)', '提交这家餐厅的预订'], ['卡片标题', '17 / 22 · Semibold', 'font:600 17px/1.3 var(--font)', '订周六晚的日料'], ['正文', '17 / 25 · Regular', 'font:400 17px/1.5 var(--font)', '好，我先找 3 家周六 19:00 有位的店。'], ['次要', '15 / 21 · Regular', 'font:400 15px/1.4 var(--font);color:#6D6259', '正在把发票金额填进报销表模板'], ['辅助', '13 / 18 · Regular', 'font:400 13px/1.4 var(--font);color:#7E7268', '已完成 2 / 3 步 · 3 分钟前']]
    .map(([n, spec, css, s]) => `<div style="display:grid;grid-template-columns:96px 200px 1fr;gap:12px;align-items:baseline;padding:9px 0;border-bottom:.5px solid #DED5CA"><b style="font-size:13px">${n}</b><span style="font-size:12px;color:#7E7268;font-family:var(--mono)">${spec}</span><span style="${css}">${s}</span></div>`).join('');
  const comp = `
    <div class="t-light" style="display:flex;flex-direction:column;gap:12px;background:#FAF7F2;padding:20px;border-radius:24px">
      <div style="display:flex;gap:10px"><span class="btn sm primary">${ic('faceid', 17)}确认预订</span><span class="btn sm soft">去聊聊</span><span class="btn sm inset">拒绝</span><span class="btn sm plain" style="height:36px">粘贴配对链接</span><span class="btn sm danger-plain" style="height:36px">取消任务</span></div>
      <div style="display:flex;gap:8px;flex-wrap:wrap">${chip('plan', '规划中')}${chip('run', '进行中', true)}${chip('wait', '等你补充')}${chip('block', '遇到阻碍')}${chip('done', '已完成')}${chip('fail', '未完成')}${chip('cancel', '已取消')}${chip('draft', '草稿')}</div>
      <div style="display:flex;gap:18px;align-items:center;font-size:13px;color:#6D6259">${['done', 'run', 'pend', 'fail', 'skip'].map((s) => `<span style="display:inline-flex;align-items:center;gap:6px">${step(s, '').replace('<div class="t "></div>', '').replace('class="step"', 'class="step" style="display:inline-grid;grid-template-columns:22px;padding:0"')}${{ done: '完成', run: '进行中', pend: '待开始', fail: '失败', skip: '跳过' }[s]}</span>`).join('')}</div>
      <div style="display:flex;gap:12px;align-items:center"><span class="gbtn">${ic('laptop', 21)}<span class="dot"></span></span><span class="pill-btn">${ic('refresh', 17)}恢复中</span><span class="pill-btn warn">${ic('laptop', 18)}Mac 离线</span><span style="font-size:12.5px;color:#7E7268">连接状态（独立于 Orbit 状态和任务状态）</span></div>
      <div style="width:200px">${seg(4, 2, 2)}</div>
    </div>`;
  const moods = [['hero-wave', '迎接 / 待机', '欢迎、对话空状态', 'ph'], ['side', '思考', 'thinking · 星环低调转动', 'ph'], ['focused', '执行', 'acting · 配真实步骤文字', 'ph'], ['attentive', '等你', 'waiting · 静止注视', 'ph'], ['happy', '完成', '单次举手，随后恢复平静', 'ph'], ['thinking', '受阻', '暂借“思考”姿态，需补“困惑”表情', 'gap'], ['focused', 'Mac 离线', '安静姿态 + 必须配“Mac 暂时离线”文字', 'gap']]
    .map(([img, name, desc, tag]) => `<div class="center" style="gap:6px;width:150px"><div style="height:120px;display:flex;align-items:flex-end"><img src="${IMG(img)}" style="max-width:118px;max-height:116px;filter:drop-shadow(0 10px 12px rgba(120,72,30,.15))"></div><b style="font-size:14px;margin-top:4px">${name}</b><span style="font-size:12px;color:#6D6259;line-height:1.4">${desc}</span><span class="tag ${tag}" style="height:20px;font-size:11px">${tag === 'ph' ? '临时抠图' : '缺素材'}</span></div>`).join('');
  const scale = [[178, 'hero-wave', '欢迎'], [140, 'hero-wave', '对话空状态'], [96, 'attentive', '任务空状态'], [76, 'avatar', '设置头部'], [42, 'avatar', '顶部在场头像'], [20, 'avatar', '消息组标记'], [24, 'mark', '灵动岛'], [16, 'mark', '紧凑状态']]
    .map(([s, k, n]) => `<div class="center" style="gap:8px"><div style="height:182px;display:flex;align-items:flex-end;justify-content:center">${k === 'mark' ? orbitMark(s) : k === 'avatar' ? `<span class="t-light">${av(s)}</span>` : `<img src="${IMG(k)}" style="width:${s}px">`}</div><b style="font-size:13px">${s}pt</b><span style="font-size:12px;color:#6D6259">${n}</span></div>`).join('');
  const assets = [['orbit-idle.png', '标准三分之四角度', '临时：hero-wave 抠图'], ['orbit-wave.png', '欢迎挥手', '临时：hero-wave 抠图'], ['orbit-thinking.png', '思考', '临时：侧面图'], ['orbit-working.png', '专注执行', '临时：闭眼专注'], ['orbit-waiting.png', '等待回应', '临时：注视'], ['orbit-success.png', '完成', '临时：开心'], ['orbit-trouble.png', '受阻 / 困惑', '缺'], ['orbit-avatar.png', '头像专用构图', '临时：头像示例抠图'], ['orbit-mark.svg', '小尺寸星环标识', '本次已画矢量草案'], ['orbit-app-icon (1024)', '浅色 / 深色 / 着色', '临时：设定图裁切']]
    .map(([f, d, s]) => `<tr><td style="font-family:var(--mono);font-size:12.5px">${f}</td><td>${d}</td><td><span class="tag ${s.startsWith('缺') ? 'gap' : s.startsWith('本次') ? 'new' : 'ph'}" style="height:22px">${s}</span></td></tr>`).join('');
  const motion = [['按下', '缩放 0.97，按下即反馈', '0.15 s 回弹，damping 1.0'], ['小状态切换', '标签、图标、颜色', '0.2–0.26 s'], ['卡片展开 / 布局变化', '原位展开，内容不跳动', 'spring response 0.35，damping 1.0'], ['Sheet', '跟手拖动、可中断反向', 'spring response 0.3，damping 0.8（仅手势释放）'], ['角色飞入头像', '空状态 → 顶部头像，同一元素', 'spring response 0.4，damping 1.0'], ['完成反馈', '小卫星短亮一次 + 轻触感', '单次 0.6 s，不循环'], ['流式文字', '整段追加，不逐字淡入', '—'], ['减少动态效果', '去掉位移、旋转、弹跳', '0.15 s 淡变']]
    .map((r) => `<tr>${r.map((c) => `<td>${c}</td>`).join('')}</tr>`).join('');
  return `<section class="board" id="system" style="width:1976px">
    <h1>⑦ 设计系统</h1>
    <div class="sub">语义 token 直接沿用设计简报 §4 的取值；对比度在本页实时计算（WCAG 2.x）。组件、角色尺度、素材缺口和动效参数是实现时的约束。</div>
    <div style="display:grid;grid-template-columns:300px 300px 1fr;gap:40px;margin-top:36px">
      <div><b style="font-size:16px">浅色 token</b><div style="margin-top:10px">${sw('light')}</div></div>
      <div class="t-dark" style="background:#191715;color:#F6EFE6;border-radius:24px;padding:18px 20px"><b style="font-size:16px">深色 token</b><div style="margin-top:10px">${sw('dark')}</div></div>
      <div>
        <b style="font-size:16px">文字对比度</b>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:24px;margin-top:12px">
          <table style="border-collapse:collapse;font-size:13px;width:100%"><thead><tr><th align="left" colspan="3" style="padding-bottom:8px">浅色</th></tr></thead><tbody style="line-height:2.1">${crow('light')}</tbody></table>
          <table class="t-dark" style="border-collapse:collapse;font-size:13px;width:100%;background:#191715;color:#F6EFE6;border-radius:16px"><thead><tr><th align="left" colspan="3" style="padding:10px 10px 8px">深色</th></tr></thead><tbody style="line-height:2.1">${crow('dark').replace(/<td>/g, '<td style="padding:0 10px">')}</tbody></table>
        </div>
        <p style="font-size:13px;color:#6D6259;margin:12px 0 0;line-height:1.55">实现时以此表为准逐项复核；若某组合低于 4.5:1，只用于 ≥18pt 文字或非文字元素，或微调色值后再用。新增派生 token：orbitBubble（Orbit 气泡）、scrim、glass，均在样式表里定义，不在页面里临时取色。</p>
        <b style="font-size:16px;display:block;margin-top:26px">组件</b>
        <div style="margin-top:12px">${comp}</div>
      </div>
    </div>
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:40px;margin-top:40px">
      <div><b style="font-size:16px">字体层级</b><div style="margin-top:8px">${type}</div>
        <b style="font-size:16px;display:block;margin-top:26px">间距与圆角</b>
        <div style="display:flex;gap:14px;align-items:flex-end;margin-top:12px;font-size:12px;color:#6D6259">${[4, 8, 12, 16, 20, 24, 32].map((s) => `<div class="center" style="gap:6px"><div style="width:${s}px;height:${s}px;background:#F2A15F;border-radius:3px"></div>${s}</div>`).join('')}<div style="width:30px"></div>${[[12, '小组件'], [16, '提示块'], [22, '卡片'], [26, '输入区'], [44, 'Sheet']].map(([r, n]) => `<div class="center" style="gap:6px"><div style="width:64px;height:48px;border-radius:${r}px;background:#fff;box-shadow:0 0 0 .5px #DED5CA"></div>${r} · ${n}</div>`).join('')}</div>
        <p style="font-size:13px;color:#6D6259;line-height:1.55;margin-top:12px">页面边距 16–20；区块间距 24–32；组件内 12–16；相关信息 4–8。按钮高 48–52，可点区域 ≥ 44 × 44。</p>
      </div>
      <div><b style="font-size:16px">动效</b>
        <table style="border-collapse:collapse;width:100%;font-size:13px;margin-top:10px;line-height:1.5">${motion.replace(/<td>/g, '<td style="padding:8px 10px 8px 0;border-bottom:.5px solid #DED5CA;vertical-align:top">')}</table>
        <p style="font-size:13px;color:#6D6259;line-height:1.55;margin-top:10px">不默认运行永久循环的漂浮、呼吸或星环旋转；离屏、后台、低电量时停止装饰动画。触感只用于提交、关键状态和错误。</p>
      </div>
    </div>
    <div style="margin-top:40px"><b style="font-size:16px">角色：尺度与状态</b>
      <div style="display:flex;gap:30px;align-items:flex-end;margin-top:12px">${scale}</div>
      <div style="display:flex;gap:6px;margin-top:28px">${moods}</div>
    </div>
    <div style="margin-top:36px;display:grid;grid-template-columns:1fr 1fr;gap:40px"><div><b style="font-size:16px">素材清单（§7.3）</b>
      <table style="border-collapse:collapse;width:100%;font-size:13.5px;margin-top:10px;line-height:2.2">${assets}</table></div>
      <div style="font-size:13.5px;line-height:1.6;color:#4A423B"><b style="font-size:16px;color:#302B27">素材规则</b>
        <p style="margin:10px 0 0">正式角色素材：透明背景、sRGB、统一视角与光照、1024 × 1024 同画布与视觉重心，星环与挥手边缘留安全区。本板的角色图都是用 Vision 从设定图里临时抠出来的，只用于评审，不进入 App。</p>
        <p style="margin:10px 0 0">16–24pt 场景一律用矢量星环标识（右侧草案），不缩小 3D 图。头像用专门的头像构图，保证 20pt 时仍能看见眼睛。</p>
        <div style="display:flex;gap:20px;align-items:center;margin-top:14px">${orbitMark(64)}${orbitMark(40)}${orbitMark(24)}${orbitMark(16)}<span style="width:1px;height:40px;background:#DED5CA"></span><div style="background:#000;border-radius:20px;padding:8px 14px;display:flex;gap:12px">${orbitMark(24)}${orbitMark(16)}</div><span style="font-size:12px;color:#6D6259">orbit-mark 草案（浅底 / 灵动岛）</span></div>
      </div></div>
  </section>`;
}

/* ───────────── ⑧ 交互逻辑 ───────────── */

function box(t, s = '', kind = '') {
  const bg = { tab: '#302B27', sheet: '#FCE9D8', push: '#FFFFFF', sys: '#F1EBE3' }[kind] || '#FFFFFF';
  const fg = kind === 'tab' ? '#FFFDF9' : '#302B27';
  return `<div style="background:${bg};color:${fg};border-radius:14px;padding:10px 12px;box-shadow:0 0 0 .5px #DED5CA;font-size:13.5px;line-height:1.35"><b style="font-weight:600">${t}</b>${s ? `<div style="font-size:12px;opacity:.75;margin-top:2px">${s}</div>` : ''}</div>`;
}
function renderFlowBoard() {
  const arrow = '<div style="display:grid;place-items:center;color:#B9A897">' + ic('arrowR', 22, 2) + '</div>';
  const flow = [['你发送', '文字 / 附件；Mac 离线时进入待发送队列'], ['Orbit 接话', '流式回复；顶部状态“正在想办法…”'], ['任务出现', '对话里的任务卡 + 任务页同步（task.upsert）'], ['执行中', '状态行、任务卡、Live Activity 显示真实动作'], ['需要你时', '通知 + Tab 角标 + 确认卡 → Sheet（Face ID）'], ['交付结果', '结果卡（对比、表格、预订…）原位更新'], ['完成', '小卫星短亮一次；任务进入“最近完成”']];
  const stopCancel = [['停止回复', '■ 输入框右侧（生成中出现）', '只停止 Orbit 当前这条回复（chat.interrupt）', '任务、执行会话、手机操作继续'], ['发送补充', '生成中输入框有草稿时的 ↑', '补充指令送进正在进行的工作', '不打断，不新建对话'], ['中止执行会话', '执行详情 Sheet', '停止某一个会话当前这一轮（task.cmd interrupt）', '任务本身保留，可补充指令后继续'], ['取消任务', '任务卡 ⋯ / 任务详情', '停止该任务全部会话并标记已取消（task.cmd cancel）', '先确认后果；Mac 确认前显示“正在取消”']];
  const sm = [['待确认', '#FFF0D6', '#875015'], ['提交中', '#F1EBE3', '#6D6259'], ['已批准 · 等执行结果', '#FCE9D8', '#8C471B'], ['已完成（如：已预订）', '#E9F2E9', '#326447']];
  return `<section class="board" id="flows" style="width:1976px">
    <h1>⑧ 交互逻辑</h1>
    <div class="sub">导航结构、一句话到结果的路径、易混淆操作的边界、审批生命周期，以及三种互相独立的状态。</div>
    <div style="display:grid;grid-template-columns:1.05fr 1fr;gap:48px;margin-top:36px">
      <div>
        <b style="font-size:16px">导航结构（原生 TabView + NavigationStack）</b>
        <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin-top:14px">
          <div style="display:flex;flex-direction:column;gap:8px">${box('对话', '默认首页 · 一条长对话', 'tab')}${box('活动与权限', '点顶部头像', 'sheet')}${box('需要你确认', '确认卡 / 通知 / 任务页', 'sheet')}${box('附件托盘', '“+”', 'sheet')}${box('连接详情', '右上电脑图标', 'sheet')}</div>
          <div style="display:flex;flex-direction:column;gap:8px">${box('任务', '需要你处理 / 进行中 / 遇到问题 / 最近完成', 'tab')}${box('任务详情', 'push', 'push')}${box('执行详情', '每个执行会话一张', 'sheet')}${box('回到对话', '定位到该任务的消息', 'sys')}</div>
          <div style="display:flex;flex-direction:column;gap:8px">${box('设置', '头像 + 分组列表', 'tab')}${box('名字和形象 · 称呼 · 性格', 'push', 'push')}${box('连接与设备 · 记忆', 'push', 'push')}${box('主动与通知 · 权限', 'push', 'push')}${box('高级（模型、连接详情）', 'push', 'push')}</div>
        </div>
        <div style="display:flex;gap:16px;margin-top:12px;font-size:12.5px;color:#6D6259"><span>■ 深色 = Tab</span><span style="color:#8C471B">■ 杏橙 = Sheet（可下拉关闭，关闭不等于拒绝）</span><span>□ 白 = Push（左上返回 / 边缘右滑）</span></div>
        <b style="font-size:16px;display:block;margin-top:30px">停止、补充、中止、取消：四个动作永不混用</b>
        <table style="border-collapse:collapse;width:100%;font-size:13px;margin-top:10px;line-height:1.5"><tr style="color:#6D6259"><th align="left">动作</th><th align="left">入口</th><th align="left">影响</th><th align="left">不影响 / 说明</th></tr>${stopCancel.map((r) => `<tr>${r.map((c, i) => `<td style="padding:9px 10px 9px 0;border-top:.5px solid #DED5CA;vertical-align:top;${i === 0 ? 'font-weight:600' : ''}">${c}</td>`).join('')}</tr>`).join('')}</table>
      </div>
      <div>
        <b style="font-size:16px">一句话到结果</b>
        <div style="display:flex;flex-direction:column;gap:6px;margin-top:14px">${flow.map(([a, b], i) => `<div style="display:grid;grid-template-columns:28px 1fr;gap:10px;align-items:center"><span style="width:26px;height:26px;border-radius:13px;background:${i === 4 ? '#FFF0D6' : '#302B27'};color:${i === 4 ? '#875015' : '#FFFDF9'};display:grid;place-items:center;font-weight:700;font-size:12px">${i + 1}</span>${box(a, b)}</div>`).join('')}</div>
        <b style="font-size:16px;display:block;margin-top:28px">审批生命周期</b>
        <div style="display:flex;align-items:center;gap:8px;margin-top:12px;flex-wrap:wrap">${sm.map(([t, bg, fg], i) => `<span style="background:${bg};color:${fg};border-radius:12px;padding:8px 12px;font-weight:600;font-size:13px">${t}</span>${i < sm.length - 1 ? arrow : ''}`).join('')}</div>
        <div style="display:flex;gap:10px;margin-top:10px;font-size:13px">${[['已拒绝', '#F1EBE3', '#6D6259'], ['已过期 · 按钮禁用', '#F1EBE3', '#7E7268'], ['提交失败 · 保留内容 + 重试', '#FBE9E5', '#AC3932']].map(([t, bg, fg]) => `<span style="background:${bg};color:${fg};border-radius:12px;padding:7px 11px;font-weight:600">${t}</span>`).join('')}</div>
        <p style="font-size:13px;color:#6D6259;line-height:1.55;margin:10px 0 0">结果同步到对话卡片、任务页、Live Activity；重复到达的结果不重复弹窗。手机上的敏感点击按你的设置自动执行，不进入此流程，但留审计记录。</p>
        <b style="font-size:16px;display:block;margin-top:26px">三种状态各自独立</b>
        <table style="border-collapse:collapse;width:100%;font-size:13px;margin-top:10px;line-height:1.5">
          <tr><td style="padding:8px 10px 8px 0;font-weight:600;border-top:.5px solid #DED5CA">连接</td><td style="border-top:.5px solid #DED5CA">已连接（局域网 / 中继）→ 恢复中 → Mac 离线</td><td style="border-top:.5px solid #DED5CA;color:#6D6259">右上入口、横幅</td></tr>
          <tr><td style="padding:8px 10px 8px 0;font-weight:600;border-top:.5px solid #DED5CA">Orbit</td><td style="border-top:.5px solid #DED5CA">待命 / 思考 / 执行 / 等你（butler.status）</td><td style="border-top:.5px solid #DED5CA;color:#6D6259">顶部头像与状态行</td></tr>
          <tr><td style="padding:8px 10px 8px 0;font-weight:600;border-top:.5px solid #DED5CA">任务</td><td style="border-top:.5px solid #DED5CA">规划中 · 进行中 · 等你补充 · 遇到阻碍 · 已完成 · 未完成 · 已取消</td><td style="border-top:.5px solid #DED5CA;color:#6D6259">任务卡、任务页、灵动岛</td></tr>
        </table>
        <p style="font-size:13px;color:#6D6259;line-height:1.55;margin:10px 0 0">不把“思考”“等待审批”“连接中”“Mac 离线”画成同一个转圈；Mac 断线不代表远端任务停止，也不会把进行中任务改成失败。</p>
      </div>
    </div>
  </section>`;
}

function placeMarkers() {
  document.querySelectorAll('.phone').forEach((ph) => {
    const pr = ph.getBoundingClientRect();
    ph.querySelectorAll('[data-mk]').forEach((el) => {
      const r = el.getBoundingClientRect();
      const pos = el.dataset.mkPos || 'tr';
      const mid = r.top - pr.top + r.height / 2 - 11;
      const at = { tr: [r.right - pr.left - 11, r.top - pr.top - 11], tl: [r.left - pr.left - 11, r.top - pr.top - 11], br: [r.right - pr.left - 11, r.bottom - pr.top - 11], bl: [r.left - pr.left - 11, r.bottom - pr.top - 11], r: [r.right - pr.left + 6, mid], l: [r.left - pr.left - 28, mid] }[pos];
      const m = document.createElement('div');
      m.className = 'mk';
      m.textContent = el.dataset.mk;
      m.style.left = `${Math.max(4, Math.min(394, at[0]))}px`;
      m.style.top = `${Math.max(56, Math.min(884, at[1]))}px`;
      ph.appendChild(m);
    });
  });
}

function renderAll(only) {
  const all = [...BOARDS.map((b) => ({ id: b.id, html: () => renderPhoneBoard(b) })), { id: 'icon', html: renderIconBoard }, { id: 'system', html: renderSystemBoard }, { id: 'flows', html: renderFlowBoard }];
  document.body.innerHTML = all.filter((b) => !only || b.id === only).map((b) => b.html()).join('');
  placeMarkers();
}
