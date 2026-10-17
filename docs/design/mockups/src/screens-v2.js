// Orbit v2 direction: restrained, system-like screens (light + dark). Spec and tokens: docs/design/v2-direction.md.
// Each function returns one 420 x 912 artboard (.p2). "Before" artboards are the real app screenshots in ios/screenshots.
// Kept from the current app on purpose: the 3D character (stage, header avatar, settings, approval), the stage glow, the
// centered welcome / empty state. The flat OrbitMark appears only in the thinking row, as in the current app.

const V2_SHOTS = '../../../ios/screenshots/';

/* ───────── shared pieces ───────── */

function v2Frame(theme, body, { island = false } = {}) {
  // The Dynamic Island is drawn only where the matching "before" screenshot shows one.
  return `<div class="p2" data-theme="${theme}"><div class="v-content">${body}</div>${statusBar(false).replace('>9:41<', '>09:41<')}${island ? '<div class="di"></div>' : ''}<div class="home"></div></div>`;
}

/** "Before" artboard: a real screenshot. `crop` = the first of the four screens in the settings composite. */
function v2Before({ src, crop = false, dark = false }) {
  return `<div class="p2b${crop ? ' crop' : ''}${dark ? ' dk' : ''}"><img src="${V2_SHOTS}${src}" alt=""></div>`;
}

const v2Av = (size) => `<span class="v-av" style="width:${size}px;height:${size}px"><img src="assets/placeholder-avatar-face.png" alt=""></span>`;
const v2Hero = (size) => `<img class="v-hero" src="assets/placeholder-hero-wave.png" style="width:${size}px;height:${size}px;--s:${size}px" alt="">`;
const v2Laptop = (top = 58) => `<span class="v-ibtn" style="position:absolute;top:${top}px;right:12px;z-index:31">${ic('laptop', 24, 1.6)}</span>`;

function v2Tabbar(active, badge = 0) {
  const tab = (id, label, on, off) => `<div class="v-tab${active === id ? ' on' : ''}">${active === id ? on : off}<span>${label}</span>${id === 'tasks' && badge ? `<b class="v-badge">${badge}</b>` : ''}</div>`;
  return `<div class="v-tabbar">${tab('chat', '对话', ic('tabChat', 24), ic('bubble', 24, 1.6))}${tab('tasks', '任务', ic('tasksFill', 24), ic('tasks', 24))}${tab('settings', '设置', ic('gearFill', 24), ic('gear', 24))}</div>`;
}

const v2Composer = (ph = '给 Orbit 发消息') => `<div class="v-comp"><span class="pl">${ic('plus', 22, 1.7)}</span><span class="ph">${ph}</span><span class="sd">${ic('arrowUp', 20, 2)}</span></div>`;

/* ───────── 1 · 欢迎 / 配对 ───────── */

function v2Welcome(t) {
  // Greeting, subtitle, button and link wording are the current app's. Changed: no selling points, system font,
  // 12 pt button, new colors.
  return v2Frame(t, `
    <div class="v-glow"></div>
    <div class="v-center" style="top:200px">
      ${v2Hero(178)}
      <h1 class="v-t30" style="margin-top:24px">你好，我是 Orbit</h1>
      <p class="v-sub17" style="margin-top:8px">连接你的 Mac，把想做的事交给我。</p>
    </div>
    <div class="v-bottom">
      <div class="v-btn pri">${ic('qr', 22, 1.7)}连接我的 Mac</div>
      <div class="v-links"><span class="paste">${ic('paste', 19, 1.7)}粘贴配对链接</span><span class="demo">体验演示</span></div>
    </div>`);
}

/* ───────── 2 · 空对话 ───────── */

function v2Empty(t) {
  const recent = [['整理上周的会议纪要', '昨天 · 已完成'], ['把下载文件夹按类型归档', '昨天 · 已完成'], ['查周末去苏州的高铁', '周三 · 已完成']];
  return v2Frame(t, `
    <div class="v-glow"></div>
    ${v2Laptop(58)}
    <div class="v-center" style="top:198px">
      ${v2Hero(140)}
      <div class="v-st" style="margin-top:14px"><i class="v-dot ok"></i>Orbit · 待命中</div>
      <h2 class="v-t22" style="margin-top:10px">今天想把什么交给我？</h2>
      <p class="v-sec15" style="margin-top:8px;padding:0 44px">我在你的 Mac 上动手。花钱、对外发送这类事，只在你明确要求或批准后才做。</p>
    </div>
    <div class="v-recent">
      <div class="v-secH">最近</div>
      ${recent.map(([a, b]) => `<div class="v-rr"><div class="tx"><div class="t">${a}</div><div class="s">${b}</div></div><span class="chev">${ic('chevR', 14, 2.2)}</span></div>`).join('')}
    </div>
    ${v2Composer()}
    ${v2Tabbar('chat')}`);
}

/* ───────── 3 · 对话流 ───────── */

function v2ChatHeader() {
  return `<div class="v-chead"><div class="who">${v2Av(36)}<div><div class="nm">Orbit</div><div class="v-st"><i class="v-dot run"></i>处理中</div></div></div><span class="v-ibtn">${ic('laptop', 24, 1.6)}</span></div>`;
}

function v2ChatThread(t) {
  const opt = (rec, name, d, price) => `<div class="v-opt${rec ? ' rec' : ''}"><span class="n">${name}</span><span class="d">${d}</span><span class="p">${price}<small>/人</small></span></div>`;
  const kv = (k, v) => `<div class="r"><span class="k">${k}</span><span class="v">${v}</span></div>`;
  // The thinking row keeps the app's own mark: cream body, apricot ring, one satellite; outline in light mode only.
  // The app's outline is 0.75 pt at 16 pt (= 3 grid units of the 64-unit mark), thicker than the board mark's default.
  const mark = orbitMark(16, { stroke: t === 'light' ? '#C9AE95' : null }).replace('stroke-width="1.6"', 'stroke-width="3"');
  return `<div class="v-thread">
    <div class="v-card">
      ${opt(true, '鮨 · 静安店', '4.8 分 · 1.2 km', '¥280')}
      ${opt(false, '一番寿司', '4.6 分 · 2.0 km', '¥240')}
      ${opt(false, '和之味', '4.5 分 · 0.8 km', '¥300')}
      <div class="v-pros">鮨 · 静安店：评分最高，有吧台位，19:00 有位</div>
    </div>
    <div class="v-ub">订第一家，我不吃香菜。</div>
    <div class="v-ot">好，预订信息如下，提交前需要你确认。</div>
    <div class="v-card"><div class="v-kv">${kv('餐厅', '鮨 · 静安店')}${kv('时间', '10 月 18 日 周六 19:00')}${kv('人数', '2 人 · 吧台位')}</div></div>
    <div class="v-card">
      <div class="v-ptitle">订周六晚上的日料</div>
      <div class="v-st" style="margin-top:2px"><i class="v-dot run"></i>3/4 步 · 正在确认空位</div>
      <div class="v-line"><i style="width:75%"></i></div>
    </div>
    <div class="v-hints">
      <div class="v-hint"><span class="tx">已记住：Herry 不吃香菜</span><a>撤销</a></div>
      <div class="v-hint"><span class="tx strong"><i class="v-dot warn"></i>需要你确认：提交这家餐厅的预订</span><a>查看</a></div>
    </div>
    <div class="v-think">${mark}<span>正在想办法…</span></div>
  </div>`;
}

function v2Chat(t) {
  return v2Frame(t, `${v2ChatThread(t)}${v2ChatHeader()}${v2Composer()}${v2Tabbar('chat', 2)}`);
}

/* ───────── 4 · 任务 ───────── */

function v2TasksBody() {
  const active = [
    ['预订上海出差酒店', '10 月 20–24 日，外滩附近，预算 ¥900/晚', '2/4 步 · 刚刚', 50],
    ['订周六晚上的日料', '找 3 家评分 4.5+、人均 ¥300 内的店', '3/4 步 · 1 分钟前', 75],
    ['整理 9 月发票做报销表', '把邮箱里的 PDF 发票金额填进报销表', '2/4 步 · 3 分钟前', 50],
  ];
  return `
    ${v2Laptop(58)}
    <div style="position:absolute;inset:0;padding:104px 16px 0">
      <h1 class="v-t30" style="margin:0 0 20px 4px">任务</h1>
      <div class="v-secH">等你处理 · 2</div>
      <div class="v-grp">
        <div class="v-row"><div class="tx"><div class="t">提交这家餐厅的预订</div><div class="s"><span class="v-warnT">中风险</span> · 28 分钟后过期</div></div><span class="act">查看</span></div>
        <div class="v-row"><div class="tx"><div class="t">比较两款降噪耳机</div><div class="s">想先确认预算：在 ¥2000 以内吗？</div></div><span class="act">回答</span></div>
      </div>
      <div class="v-secH" style="margin-top:22px">进行中 · 3</div>
      <div class="v-grp">
        ${active.map(([t1, goal, meta, pct]) => `<div class="v-row"><div class="tx"><div class="t">${t1}</div><div class="g">${goal}</div><div class="m"><i class="v-dot run"></i><span class="v-num">${meta}</span></div><div class="v-line"><i style="width:${pct}%"></i></div></div></div>`).join('')}
      </div>
      <div class="v-secH" style="margin-top:22px">已结束 · 5</div>
      <div class="v-grp">
        <div class="v-row"><div class="tx"><div class="t" style="font-weight:400">显示已结束的任务</div></div><span class="act">清除</span></div>
      </div>
    </div>`;
}

function v2Tasks(t) {
  return v2Frame(t, `${v2TasksBody()}${v2Tabbar('tasks', 2)}`);
}

/* ───────── 5 · 审批弹窗 ───────── */

function v2Approval(t) {
  const kv = (k, v) => `<div class="r"><span class="k">${k}</span><span class="v">${v}</span></div>`;
  return v2Frame(t, `
    ${v2TasksBody()}
    <div class="v-scrim"></div>
    <div class="v-sheet">
      <div class="grab"></div>
      <div class="hd">${v2Av(26)}<span>需要你确认</span><span class="x">${ic('x', 18, 1.8)}</span></div>
      <h2 class="v-t22" style="margin-top:12px">提交这家餐厅的预订</h2>
      <div class="v-st" style="margin-top:4px"><span class="v-warnT">中风险</span> · 28 分钟后过期</div>
      <div class="v-kv framed" style="margin-top:16px">${kv('餐厅', '鮨 · 静安店')}${kv('时间', '10 月 18 日 周六 19:00')}${kv('人数', '2 人 · 吧台位')}${kv('费用', '人均 ¥280，到店付款')}</div>
      <p class="v-sec15" style="margin:16px 0 22px">批准后：我会在安卓手机上用大众点评提交预订，餐厅可能会发确认短信。不会在线付款。</p>
      <div class="v-btn pri">${ic('faceid', 22, 1.7)}批准</div>
      <div class="v-btn alt" style="margin-top:10px">拒绝</div>
    </div>`);
}

/* ───────── 6 · 设置首页 ───────── */

function v2Settings(t) {
  const row = (icon, title, val, sub = '') => `<div class="v-row has-ic"><span class="ri">${ic(icon, 20, 1.6)}</span><div class="tx"><div class="t" style="font-weight:400">${title}</div>${sub ? `<div class="s">${sub}</div>` : ''}</div>${val ? `<span class="rv">${val}</span>` : ''}<span class="chev">${ic('chevR', 14, 2.2)}</span></div>`;
  return v2Frame(t, `
    <div style="position:absolute;inset:0;padding:78px 16px 0">
      <div style="display:flex;align-items:center;gap:12px;padding:0 6px;margin-bottom:26px">
        ${v2Av(40)}
        <div><div class="v-t22">Orbit</div><div class="v-st" style="font-size:15px;line-height:20px;margin-top:1px"><i class="v-dot ok"></i>已连接 · Herry 的 MacBook</div></div>
      </div>
      <div class="v-secH">我的 Orbit</div>
      <div class="v-grp">${row('person', '名字和形象', 'Orbit')}${row('bubble', '怎么称呼你', 'Herry')}${row('sparkle', '性格', '温和、靠谱')}</div>
      <div class="v-secH" style="margin-top:22px">连接与设备</div>
      <div class="v-grp">${row('laptop', 'Herry 的 MacBook', '', '已连接 · 局域网')}${row('android', '安卓执行手机', '', '已就绪')}${row('iphone', '已配对设备', '2 台')}</div>
      <div class="v-secH" style="margin-top:22px">记忆与通知</div>
      <div class="v-grp">${row('memory', '记忆', '4 条')}${row('slider', '主动程度', '适中')}${row('moon', '安静时段', '23:00–08:00')}${row('bell', '每日通知上限', '5 条')}</div>
    </div>
    ${v2Tabbar('settings')}`, { island: true });
}
