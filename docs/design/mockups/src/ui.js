// Orbit redesign — shared mockup components. Content is illustrative; every control maps to an existing
// protocol capability unless marked otherwise on the boards.
const IMG = (n) => `assets/placeholder-${n}.png`;
const mk = (n, x, y) => `<div class="mk" style="left:${x}px;top:${y}px">${n}</div>`;
/** Annotation anchor: markers are placed after layout next to the element (pos: tr | tl | r | l | br | bl). */
const MK = (n, pos = 'tr') => (n ? ` data-mk="${n}" data-mk-pos="${pos}"` : '');

function statusBar(light = false) {
  return `<div class="sb${light ? ' light-on-dark' : ''}"><span>9:41</span><span class="ic">${ic('signal', 18)}${ic('wifiS', 18)}${ic('battery', 26)}</span></div>`;
}

function frame(theme, body, { marks = [], sbLight = false, noHome = false, homeLight = false } = {}) {
  return `<div class="phone" data-theme="${theme}">
    <div class="content">${body}</div>
    ${statusBar(sbLight)}<div class="di"></div>
    ${noHome ? '' : `<div class="home" ${homeLight ? 'style="background:#fff"' : ''}></div>`}
    ${marks.map(([n, x, y]) => mk(n, x, y)).join('')}
  </div>`;
}

function av(size, { ring = false, img = 'avatar-tile', bg = '' } = {}) {
  return `<span class="av${ring ? ' ring' : ''}" style="width:${size}px;height:${size}px;${bg ? `background:${bg};` : ''}"><img src="${IMG(img)}" alt=""></span>`;
}

function connBtn(state = 'ok', top = 62, mkn = 0) {
  if (state === 'offline') return `<div style="position:absolute;top:${top + 4}px;right:16px;z-index:32"><span class="pill-btn warn"${MK(mkn, 'l')}>${ic('laptop', 18)}Mac 离线</span></div>`;
  if (state === 'connecting') return `<div style="position:absolute;top:${top + 4}px;right:16px;z-index:32"><span class="pill-btn">${ic('refresh', 17)}恢复中</span></div>`;
  return `<div style="position:absolute;top:${top}px;right:16px;z-index:32"><span class="gbtn" aria-label="Mac 已连接"${MK(mkn, 'l')}>${ic('laptop', 21)}<span class="dot"></span></span></div>`;
}

/** Muse-style presence: avatar + name + live snippet, centred. Tap → 活动与权限 sheet. */
function presence({ status = '待命中', kind = '', ring = false, conn = 'ok', icon = '', mkn = 0, mkConn = 0 } = {}) {
  return `<div style="position:absolute;top:0;left:0;right:0;height:166px;z-index:30;background:linear-gradient(var(--canvas) 82%, color-mix(in srgb, var(--canvas) 0%, transparent));"></div>
  <div class="center" style="position:absolute;top:58px;left:80px;right:80px;z-index:31;gap:3px">
    <span${MK(mkn, 'l')} style="display:inline-flex">${av(42, { ring })}</span>
    <div style="font:600 14px/1.2 var(--font);display:flex;align-items:center;gap:2px;margin-top:3px">Orbit<span class="faint" style="display:inline-flex">${ic('chevR', 13, 2.2)}</span></div>
    <div class="presence-status" style="font-size:12.5px;line-height:1.2;display:flex;align-items:center;gap:4px;color:${kind === 'live' ? 'var(--accentText)' : kind === 'warn' ? 'var(--warning)' : 'var(--ink2)'}">${icon}${status}</div>
  </div>
  ${connBtn(conn, 62, mkConn)}`;
}

function tabbar(active = 'chat', badge = 0) {
  const t = (id, label, glyph) => `<div class="tab${active === id ? ' on' : ''}">${glyph}${label}${id === 'tasks' && badge ? `<span class="badge">${badge}</span>` : ''}</div>`;
  return `<div class="tabbar">${t('chat', '对话', ic('tabChat', 25))}${t('tasks', '任务', ic('tasksFill', 25))}${t('settings', '设置', ic('gearFill', 25))}</div>`;
}

function composer({ bottom = 98, text = '', ph = '把想做的事交给 Orbit…', mode = 'idle', atts = '', mkPlus = 0, mkSend = 0 } = {}) {
  const right = mode === 'stop' ? `<span class="stopb main" aria-label="停止回复"${MK(mkSend, 'tr')}>${ic('stop', 22)}</span>`
    : mode === 'stop+send' ? `<span class="stopb" aria-label="停止回复"${MK(mkSend, 'tl')}>${ic('stop', 20)}</span><span class="send" aria-label="发送">${ic('arrowUp', 20, 2.4)}</span>`
      : `<span class="send${text || atts ? '' : ' off'}" aria-label="发送"${MK(mkSend, 'tr')}>${ic('arrowUp', 20, 2.4)}</span>`;
  const field = `<div class="field${text ? '' : ' ph'}">${text || ph}</div>`;
  return `<div class="composer" style="bottom:${bottom}px">
    <span class="plus" aria-label="添加附件"${MK(mkPlus, 'tl')}>${ic('plus', 21, 2.2)}</span>
    ${atts ? `<div class="stack"><div class="att-row">${atts}</div>${field}</div>` : field}
    ${right}
  </div>`;
}

const bu = (text, status = '', mkn = 0) => `<div class="grp u"><div class="bub u"${MK(mkn, 'l')}>${text}</div>${status}</div>`;
const by = (time, extra = '') => `<div class="by">${av(20)}<span>Orbit · ${time}</span>${extra}</div>`;
const bo = (text, cls = '') => `<div class="bub o ${cls}">${text}</div>`;
const chip = (kind, text, dot = false) => `<span class="chip ${kind}">${dot ? '<span class="d"></span>' : ''}${text}</span>`;
const seg = (total, done, cur = -1) => `<div class="seg">${Array.from({ length: total }, (_, i) => `<i class="${i < done ? 'on' : i === cur ? 'cur' : ''}"></i>`).join('')}</div>`;

function step(state, title, sub = '') {
  const m = state === 'done' ? `<span class="m done">${ic('check', 13, 2.6)}</span>`
    : state === 'run' ? '<span class="m run"></span>'
      : state === 'fail' ? `<span class="m fail">${ic('x', 12, 2.6)}</span>`
        : state === 'skip' ? `<span class="m skip">${ic('minus', 12, 2.6)}</span>` : '<span class="m pend"></span>';
  const tc = state === 'run' ? 'cur' : state === 'pend' ? 'pend' : '';
  return `<div class="step">${m}<div class="t ${tc}">${title}${sub ? `<div class="s">${sub}</div>` : ''}</div></div>`;
}

function taskCard({ title, chipHtml, steps, foot, menu = true, syncNote = '', mkMenu = 0, mkSteps = 0, mkSync = 0 }) {
  return `<div class="card">
    <div class="hd"><span class="ttl">${title}</span>${chipHtml}${menu ? `<span class="faint" style="margin-left:2px;display:inline-flex"${MK(mkMenu, 'tr')}>${ic('dots', 20)}</span>` : ''}</div>
    <div class="bd"><div class="steps rail"${MK(mkSteps, 'r')}>${steps.join('')}</div></div>
    ${syncNote ? `<div style="padding:0 16px 12px"><div class="note warn" style="padding:9px 12px;font-size:13px"${MK(mkSync, 'tr')}>${ic('clock', 16)}<span>${syncNote}</span></div></div>` : ''}
    <div class="ft">${foot}</div>
  </div>`;
}

const ORDER_TASK_STEPS = (cur = 1) => [
  step(cur > 0 ? 'done' : 'run', '理解需求'),
  step(cur > 1 ? 'done' : cur === 1 ? 'run' : 'pend', '搜索附近的日料店', cur === 1 ? '在大众点评筛选：评分 4.5+、人均 ≤ ¥300、静安附近' : ''),
  step(cur > 2 ? 'done' : cur === 2 ? 'run' : 'pend', '核对周六 19:00 的空位'),
  step(cur > 3 ? 'done' : cur === 3 ? 'run' : 'pend', '你选定后提交预订'),
];
