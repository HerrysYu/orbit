// Orbit redesign — screens. Each returns a 420×912 artboard.

/* ───────────── 对话 ───────────── */

function sChatEmpty(t) {
  return frame(t, `
    <div style="position:absolute;inset:0;background:var(--stage)"></div>
    ${connBtn('ok', 62, 1)}
    <div class="center" style="position:absolute;top:196px;left:0;right:0">
      <img class="mascot" src="${IMG('hero-wave')}" style="width:142px" alt=""${MK(2, 'tl')}>
      <div class="floor" style="width:90px"></div>
      <div style="margin-top:14px;font-size:13px;color:var(--ink3);display:flex;align-items:center;gap:6px"><span style="width:6px;height:6px;border-radius:3px;background:var(--success)"></span>Orbit · 待命中</div>
      <h2 class="h-empty" style="margin-top:10px">今天想把什么交给我？</h2>
      <p class="muted" style="font-size:15px;line-height:1.5;margin:8px 48px 0">我在你的 Mac 上动手。花钱、对外发送这类事，只在你明确要求或批准后才做。</p>
    </div>
    <div class="center" style="position:absolute;bottom:166px;left:0;right:0;gap:10px">
      <span class="sugg"${MK(3, 'r')}>${ic('calendar', 18)}整理明天的日程</span>
      <span class="sugg">${ic('columns', 18)}帮我比较几个方案</span>
      <span class="sugg">${ic('doc', 18)}总结这份文件</span>
    </div>
    ${composer({ bottom: 98, mkPlus: 4 })}
    ${tabbar('chat')}
  `);
}

function chatRunningThread(mk = false) {
  return `<div class="thread" style="bottom:164px">
    <div class="day">今天 17:20</div>
    ${bu('帮我订周六晚上两个人的日料，人均 300 以内，离静安近一点。')}
    <div class="grp">
      ${by('17:20')}
      ${bo('好，我先找 3 家周六 19:00 有位的店，比较价格和评价后给你选。提交预订前会先问你。')}
      <div style="width:100%;margin-top:6px">${taskCard({
    title: '订周六晚的日料', chipHtml: chip('run', '进行中', true), steps: ORDER_TASK_STEPS(1),
    foot: '<span>已完成 1 / 4 步 · 刚刚更新</span><a>查看任务' + ic('chevR', 14, 2.2) + '</a>',
    mkSteps: mk ? 2 : 0, mkMenu: mk ? 5 : 0,
  })}</div>
    </div>
    ${bu('最好有吧台位', '', mk ? 3 : 0)}
    <div class="grp">${bo('收到，我把“吧台位”加进筛选条件了<span class="cursor"></span>')}</div>
  </div>`;
}

function sChatRunning(t) {
  return frame(t, `
    ${chatRunningThread(true)}
    ${presence({ status: '正在搜索附近的日料店', kind: 'live', ring: true, icon: '<span style="width:6px;height:6px;border-radius:3px;background:var(--apricot)"></span>', mkn: 1 })}
    ${composer({ bottom: 98, ph: '补充要求，或交给 Orbit 新的事…', mode: 'stop', mkSend: 4 })}
    ${tabbar('chat')}
  `);
}

function sChatResult(t) {
  const item = (rec, name, meta, tags) => `
    <div style="display:flex;gap:12px;padding:12px 14px;border-radius:16px;${rec ? 'background:var(--brandSoft);' : ''}align-items:flex-start">
      <div class="thumb" style="width:52px;height:52px;flex:none;display:grid;place-items:center;background:${rec ? 'var(--surface)' : 'var(--surfaceInset)'};color:var(--accentText)">${ic('pin', 22)}</div>
      <div style="flex:1;min-width:0">
        <div style="display:flex;align-items:center;gap:6px"><b style="font-size:16px;font-weight:600">${name}</b>${rec ? '<span class="chip run" style="height:20px;font-size:11.5px;padding:0 7px">推荐</span>' : ''}</div>
        <div style="font-size:13px;color:var(--ink2);margin-top:3px;display:flex;align-items:center;gap:4px"><span style="color:var(--apricot);display:inline-flex">${ic('star', 13)}</span>${meta}</div>
        <div style="font-size:12.5px;color:var(--ink3);margin-top:3px">${tags}</div>
      </div>
      <span class="btn xs ${rec ? 'primary' : 'inset'}" style="margin-top:8px">选这家</span>
    </div>`;
  return frame(t, `
    <div class="thread" style="bottom:164px">
      <div class="grp">
        ${by('17:31')}
        ${bo('找到 3 家周六 19:00 有位的。我更推荐第一家：评分最高，离你也最近，有吧台位。')}
        <div style="width:100%;margin-top:6px"><div class="card"${MK(1, 'tr')}>
          <div class="hd" style="padding-bottom:4px"><span class="kicker">比较 · 周六 19:00 · 2 人 · 静安附近</span></div>
          <div style="padding:4px 6px 6px;display:flex;flex-direction:column;gap:2px">
            ${item(true, '鮨 · 静安店', '4.8 · 人均 ¥280 · 1.2 km', '吧台位 · 安静 · 19:00 有位')}
            ${item(false, '一番寿司', '4.6 · 人均 ¥240 · 2.0 km', '19:30 有位 · 无吧台')}
            ${item(false, '和之味', '4.5 · 人均 ¥300 · 0.8 km', '19:00 有位 · 需预付定金')}
          </div>
          <div class="ft"><span>来自大众点评 · 17:31 查询</span><a>完整对比${ic('chevR', 14, 2.2)}</a></div>
        </div></div>
      </div>
      ${bu('选「鮨 · 静安店」', '<div class="bub-status">' + ic('check', 13, 2.4) + '来自对比卡片</div>', 2)}
      <div class="grp">
        ${bo('好，我把预订准备好了。提交前需要你确认一下。')}
        <div style="width:100%;margin-top:6px"><div class="card"${MK(3, 'tr')}>
          <div class="hd"><span style="color:var(--warning);display:inline-flex">${ic('hand', 20)}</span><span class="ttl">需要你确认：提交预订</span>${chip('wait', '待确认')}</div>
          <div class="bd" style="font-size:14.5px;color:var(--ink2);line-height:1.5">鮨 · 静安店 · 10 月 18 日 周六 19:00 · 2 人 · 吧台位。到店付款，不会在线支付。</div>
          <div style="display:flex;gap:10px;padding:0 16px 16px"><span class="btn sm primary" style="flex:1;justify-content:center">${ic('faceid', 18)}查看并确认</span><span class="btn sm inset" style="flex:none">拒绝</span></div>
        </div></div>
      </div>
    </div>
    ${presence({ status: '等你确认 1 件事', kind: 'warn', icon: ic('hand', 13) })}
    ${composer({ bottom: 98 })}
    ${tabbar('chat', 1)}
  `);
}

function sChatAttach(t) {
  const ph = (i, sel) => `<div class="thumb" style="aspect-ratio:1;border-radius:4px;position:relative;background:${['linear-gradient(135deg,#E9D8C4,#CDB69C)', 'linear-gradient(135deg,#D6C7B8,#9F8F80)', 'linear-gradient(135deg,#F3E2CF,#E2B990)', 'linear-gradient(135deg,#C9D3CF,#93A69E)', 'linear-gradient(135deg,#E8E2DA,#BCB0A3)', 'linear-gradient(135deg,#EAD1C1,#C89377)'][i % 6]}">${sel ? `<span style="position:absolute;right:6px;bottom:6px;width:22px;height:22px;border-radius:11px;background:var(--apricot);color:#fff;display:grid;place-items:center;box-shadow:0 0 0 2px #fff">${ic('check', 13, 3)}</span>` : '<span style="position:absolute;right:6px;bottom:6px;width:22px;height:22px;border-radius:11px;box-shadow:inset 0 0 0 1.5px #fff;background:rgba(0,0,0,.12)"></span>'}</div>`;
  const opt = (icon, label) => `<div class="center" style="gap:6px;flex:1"><span style="width:52px;height:52px;border-radius:18px;background:var(--surfaceInset);display:grid;place-items:center;color:var(--ink)">${ic(icon, 24)}</span><span style="font-size:12.5px;color:var(--ink2)">${label}</span></div>`;
  const atts = `<div class="att" style="background:linear-gradient(135deg,#F3E2CF,#E2B990)"${MK(2, 'tl')}><span class="x">${ic('x', 11, 3)}</span></div>
    <div class="att file">${ic('doc', 22)}<span>9月发票.pdf<small>412 KB</small></span><span class="x">${ic('x', 11, 3)}</span></div>
    <div class="att" style="background:linear-gradient(135deg,#EAD1C1,#C89377)"${MK(3, 'tr')}><span class="prog">${ic('dots', 18)}</span></div>`;
  return frame(t, `
    <div class="thread" style="bottom:470px;opacity:.55">
      <div class="grp">${by('17:40')}${bo('报销表建好了，还差 9 月的两张发票，发给我就行。')}</div>
    </div>
    ${presence({ status: '待命中' })}
    ${composer({ bottom: 386, text: '这三张也加进报销表', atts })}
    <div style="position:absolute;left:0;right:0;bottom:0;height:372px;background:var(--surface);border-radius:28px 28px 0 0;box-shadow:0 -8px 30px -12px rgba(48,43,39,.25);z-index:33;padding:16px 16px 0">
      <div style="display:flex;gap:4px;margin-bottom:14px"${MK(1, 'tl')}>${opt('photo', '照片')}${opt('doc', '文件')}${opt('link', '链接 / 文本')}${opt('reminders', '提醒事项')}</div>
      <div style="display:flex;align-items:center;justify-content:space-between;margin:0 2px 8px"><b style="font-size:14px;font-weight:600">最近照片</b><span style="font-size:14px;color:var(--accentText);font-weight:600">全部照片</span></div>
      <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:3px"${MK(4, 'tr')}>${[0, 1, 2, 3, 4, 5, 0, 3].map((i, k) => ph(i, k === 2 || k === 5)).join('')}</div>
    </div>
  `);
}

function sChatKeyboard(t) {
  const keys = (row) => `<div class="kr">${row.split('').map((k) => `<span class="k">${k}</span>`).join('')}</div>`;
  return frame(t, `
    <div class="thread" style="bottom:470px">
      <div class="grp">${by('17:05')}${bo('桌面上的 <b>orbit-test.txt</b> 已经建好了，内容是今天的日期，我重新打开核对过。')}</div>
      ${bu('再帮我写一份周报，按照上周的格式')}
      <div class="grp">${bo('好，我先找到上周的周报，照着格式整理这周的提交记录和日程……')}</div>
    </div>
    ${presence({ status: '正在回复…', kind: 'live', ring: true, icon: '<span style="width:6px;height:6px;border-radius:3px;background:var(--apricot)"></span>' })}
    <span class="pillnew" style="bottom:432px"${MK(1, 'r')}>${ic('arrowDown', 15, 2.4)}有新回复</span>
    ${composer({ bottom: 344, text: '顺便把下周一的会议也写进去，会议纪要在 Notion 里', mode: 'stop+send', mkSend: 3, mkPlus: 2 })}
    <div class="kb">
      ${keys('qwertyuiop')}${keys('asdfghjkl')}
      <div class="kr"><span class="k w">⇧</span>${'zxcvbnm'.split('').map((k) => `<span class="k">${k}</span>`).join('')}<span class="k w">⌫</span></div>
      <div class="kr"><span class="k w">123</span><span class="k w">🌐</span><span class="k sp">空格</span><span class="k w">换行</span></div>
    </div>
  `, { homeLight: t === 'dark' });
}

function sChatOffline(t) {
  return frame(t, `
    <div class="thread" style="bottom:164px">
      <div class="grp">
        ${by('17:42')}
        <div style="width:100%">${taskCard({
    title: '整理 9 月发票做报销表', chipHtml: chip('run', '进行中', true),
    steps: [step('done', '找出邮箱里的 PDF 发票'), step('done', '识别金额和日期'), step('run', '填进报销表模板', '已填 9 / 14 张')],
    foot: '<span>已完成 2 / 3 步</span><a>查看任务' + ic('chevR', 14, 2.2) + '</a>',
    syncNote: '最后同步 17:42。Mac 离线期间任务可能仍在运行，恢复后自动更新。', mkSync: 3,
  })}</div>
      </div>
      ${bu('做完发我一份 PDF', `<div class="bub-status warn">${ic('clock', 13, 2)}待发送 · Mac 连上后自动发出</div>`, 4)}
      ${bu('另外记得报销截止是 25 号', `<div class="bub-status danger">${ic('alert', 13, 2)}没有送达<a>重试</a></div>`, 5)}
    </div>
    ${presence({ status: 'Mac 离线 · 2 分钟前在线', kind: 'warn', conn: 'offline', mkConn: 1 })}
    <div class="banner warn" style="top:142px"${MK(2, 'br')}>${ic('laptop', 20)}<div class="grow"><b>Mac 暂时离线</b><br><span style="opacity:.85">消息会排队，连上后发送。正在重试…</span></div><span style="font-weight:600">详情</span></div>
    ${composer({ bottom: 98, ph: '可以继续输入，连上后发送' })}
    ${tabbar('chat')}
  `);
}

/* ───────────── 任务 ───────────── */

function taskRow({ title, chipHtml, sub, total = 0, done = 0, cur = -1, time, bar = true, trailing = '', mkBar = 0, mkSub = 0 }) {
  return `<div class="row" style="align-items:flex-start;padding:14px 16px 14px 18px">
    ${bar ? `<span style="position:absolute;left:0;top:16px;bottom:16px;width:3px;border-radius:0 2px 2px 0;background:var(--apricot)"${MK(mkBar, 'bl')}></span>` : ''}
    <div class="rt">
      <div style="display:flex;align-items:center;gap:8px"><span style="font-weight:600;flex:1;font-size:16.5px">${title}</span>${chipHtml}</div>
      <small style="margin-top:5px"><span${MK(mkSub, 'r')}>${sub}</span></small>
      <div style="display:flex;align-items:center;gap:10px;margin-top:9px">${total ? `<div style="width:84px">${seg(total, done, cur)}</div>` : ''}<span style="font-size:12.5px;color:var(--ink3);white-space:nowrap">${time}</span>${trailing}</div>
    </div>
  </div>`;
}

function sTasks(t) {
  return frame(t, `
    ${connBtn('ok', 58)}
    <div style="position:absolute;top:106px;left:20px"><h1 class="h-large">任务</h1></div>
    <div style="position:absolute;top:150px;left:16px;right:16px">
      <div class="sec" style="margin-top:6px"><span${MK(1, 'r')}>需要你处理</span><span class="n">2</span></div>
      <div class="list">
        <div class="row"><span class="ri" style="background:var(--warningSoft);color:var(--warning)">${ic('hand', 17)}</span><div class="rt">确认预订：鮨 · 静安店<small>订周六晚的日料 · 29 分钟后过期</small></div><span class="btn xs primary"${MK(2, 'tr')}>查看</span></div>
        <div class="row"><span class="ri" style="background:var(--warningSoft);color:var(--warning)">${ic('qbubble', 17)}</span><div class="rt">比较两款降噪耳机<small>想先确认预算：在 ¥2000 以内吗？</small></div><span class="btn xs inset">回答</span></div>
      </div>
      <div class="sec">进行中</div>
      <div class="list">
        ${taskRow({ title: '整理 9 月发票做报销表', chipHtml: chip('run', '进行中', true), sub: '正在把发票金额填进报销表模板', total: 3, done: 2, cur: 2, time: '已完成 2 / 3 步 · 3 分钟前', mkBar: 3, mkSub: 4 })}
        ${taskRow({ title: '订周六晚的日料', chipHtml: chip('wait', '等你确认'), sub: '预订已准备好，等你批准后提交', total: 4, done: 3, cur: 3, time: '已完成 3 / 4 步 · 刚刚', bar: false })}
      </div>
      <div class="sec"><span${MK(5, 'r')}>遇到问题</span></div>
      <div class="list">
        <div class="row" style="align-items:flex-start;padding:14px 16px"><span class="ri" style="background:var(--dangerSoft);color:var(--danger);margin-top:1px">${ic('alert', 17)}</span><div class="rt"><div style="display:flex;align-items:center;gap:8px"><span style="flex:1;font-weight:600">查询本月社保缴费</span>${chip('block', '遇到阻碍')}</div><small style="margin-top:5px">需要你在安卓手机上完成微信登录验证，完成后告诉我。</small><div style="font-size:12.5px;color:var(--ink3);margin-top:6px">12 分钟前</div></div></div>
      </div>
      <div class="sec" style="justify-content:space-between">最近完成<span style="color:var(--accentText);font-weight:600"${MK(6, 'l')}>清除</span></div>
      <div class="list">
        <div class="row" style="min-height:46px;padding:10px 16px"><span style="color:var(--success);display:inline-flex">${ic('check', 18, 2.4)}</span><div class="rt" style="font-size:15.5px">在桌面创建 orbit-test.txt</div><span class="rv" style="font-size:13px">17:05</span></div>
      </div>
    </div>
    ${tabbar('tasks', 2)}
  `);
}

function sTasksEmpty(t) {
  return frame(t, `
    ${connBtn('ok', 58)}
    <div style="position:absolute;top:106px;left:20px"><h1 class="h-large">任务</h1></div>
    <div class="center" style="position:absolute;top:300px;left:0;right:0">
      <img class="mascot" src="${IMG('attentive')}" style="width:96px" alt="">
      <h3 class="h-title3" style="margin-top:18px">这里会记录我替你做的事</h3>
      <p class="muted" style="font-size:15px;margin:6px 60px 14px;line-height:1.5">进行中、等你确认和已完成的任务都会出现在这里。</p>
      <span class="btn sm soft">${ic('bubble', 17)}去聊聊</span>
    </div>
    ${tabbar('tasks')}
  `);
}

function sTaskDetail(t) {
  return frame(t, `
    <div style="position:absolute;top:58px;left:16px;right:16px;display:flex;justify-content:space-between;z-index:30"><span class="gbtn">${ic('chevL', 22, 2.2)}</span><span class="gbtn"${MK(1, 'l')}>${ic('dots', 22)}</span></div>
    <div style="position:absolute;top:116px;left:20px;right:20px">
      <div style="display:flex;gap:8px;align-items:center">${chip('wait', '等你确认')}<span style="font-size:13px;color:var(--ink3)">17:20 开始 · 刚刚更新</span></div>
      <h1 class="h-title2" style="margin-top:10px;font-size:26px">订周六晚的日料</h1>
      <p class="muted" style="font-size:15px;line-height:1.5;margin:6px 0 0">找 3 家评分 4.5+、人均 ¥300 内、周六 19:00 有位的日料，你选定后提交预订。</p>
      <div class="note warn" style="margin-top:16px;align-items:center"${MK(2, 'tl')}>${ic('hand', 20)}<div style="flex:1"><b>现在等你确认提交预订</b><br><span style="opacity:.9">鮨 · 静安店 · 周六 19:00 · 2 人</span></div><span class="btn xs primary">查看</span></div>
      <div class="sec" style="margin:22px 2px 10px"><span${MK(3, 'r')}>步骤</span></div>
      <div class="steps rail" style="gap:2px">
        ${step('done', '理解需求')}
        ${step('done', '搜索附近的日料店', '找到 11 家，按评分和距离筛到 3 家')}
        ${step('done', '核对周六 19:00 的空位')}
        <div style="background:var(--surface);border-radius:16px;padding:6px 10px 8px;margin:4px -10px;box-shadow:0 0 0 .5px var(--hairline)">${step('run', '你选定后提交预订', '等你批准 · 批准后在安卓手机上提交')}</div>
      </div>
      <div class="sec" style="margin:22px 2px 8px"><span${MK(4, 'r')}>结果</span></div>
      <div class="list">
        <div class="row"><span class="ri">${ic('columns', 17)}</span><div class="rt">餐厅对比 · 3 家<small>在对话中查看</small></div><span class="chev">${ic('chevR', 16, 2.2)}</span></div>
        <div class="row"><span class="ri">${ic('terminal', 17)}</span><div class="rt">执行详情<small>2 个执行会话 · 1 个在安卓手机上</small></div><span class="chev">${ic('chevR', 16, 2.2)}</span></div>
      </div>
      <div style="display:flex;gap:10px;margin-top:18px"><span class="btn inset" style="flex:1">${ic('bubble', 18)}回到对话</span><span class="btn danger-plain" style="flex:none;width:auto;padding:0 18px"${MK(5, 'tr')}>取消任务</span></div>
    </div>
  `);
}

function sSessionSheet(t) {
  const item = (time, icon, text, faint = false) => `<div style="display:grid;grid-template-columns:44px 22px 1fr;gap:8px;padding:8px 0;font-size:14.5px;line-height:1.4;${faint ? 'color:var(--ink3)' : ''}"><span style="color:var(--ink3);font-size:12.5px;padding-top:2px;font-variant-numeric:tabular-nums">${time}</span><span style="color:var(--ink2)">${ic(icon, 17)}</span><span>${text}</span></div>`;
  return frame(t, `
    ${sTaskDetailBg()}
    <div class="scrim"></div>
    <div class="sheet" style="top:120px">
      <div class="grab"></div>
      <div style="display:flex;align-items:center;gap:10px;margin-top:6px">
        <span class="ri" style="width:40px;height:40px;border-radius:12px;background:var(--surfaceInset);display:grid;place-items:center">${ic('android', 22)}</span>
        <div style="flex:1"${MK(1, 'tr')}><div style="font-weight:600;font-size:17px">大众点评查询空位</div><div style="font-size:13px;color:var(--ink2);margin-top:2px">安卓手机 · 已完成 · 用时 2 分 14 秒</div></div>
        <span class="gbtn" style="width:34px;height:34px">${ic('x', 16, 2.2)}</span>
      </div>
      <div style="display:flex;gap:6px;margin:14px 0 6px;flex-wrap:wrap">${chip('done', '已完成')}<span class="chip plan">${ic('cpu', 13)}GPT-6 Luna</span><span class="chip plan">${ic('shield', 13)}敏感点击自动执行</span></div>
      <div class="divider" style="margin:10px 0 4px"></div>
      <div${MK(2, 'tr')}>${item('17:24', 'open', '打开大众点评')}</div>
      ${item('17:24', 'globe', '搜索：静安 日料 评分 4.5 以上')}
      ${item('17:25', 'eye', '查看「鮨 · 静安店」详情页')}
      ${item('17:26', 'calendar', '选择 10 月 18 日 19:00，2 人 → 显示有位')}
      ${item('17:26', 'eye', '查看「一番寿司」「和之味」可订时段')}
      ${item('17:26', 'check', '交回结果：3 家可订，附截图证据')}
      <div class="note info" style="margin-top:12px;font-size:13px">${ic('info', 16)}<span>截图证据保存在你的 Mac：~/.opa/phone/evidence/。手机上的敏感点击按你的设置自动执行，并留有审计记录。</span></div>
      <div style="display:flex;gap:10px;margin-top:14px"><span class="btn inset sm" style="flex:1;justify-content:center"${MK(3, 'tl')}>${ic('pencil', 16)}补充指令</span><span class="btn inset sm" style="flex:1;justify-content:center">归档</span></div>
    </div>
  `);
}
function sTaskDetailBg() {
  return `<div style="position:absolute;top:116px;left:20px;right:20px;opacity:.9"><h1 class="h-title2" style="font-size:26px;margin-top:34px">订周六晚的日料</h1></div>`;
}

/* ───────────── 确认 ───────────── */

function sApproval(t) {
  return frame(t, `
    ${chatRunningThread()}
    ${presence({ status: '等你确认 1 件事', kind: 'warn', icon: ic('hand', 13) })}
    ${composer({ bottom: 98 })}
    ${tabbar('chat', 1)}
    <div class="scrim"></div>
    <div class="sheet" style="top:252px">
      <div class="grab"${MK(1, 'r')}></div>
      <div style="display:flex;align-items:center;gap:8px;margin-top:4px">${av(26)}<span class="muted" style="font-size:14px;flex:1">Orbit 请你确认</span><span class="gbtn" style="width:34px;height:34px" aria-label="关闭">${ic('x', 16, 2.2)}</span></div>
      <h2 class="h-title2" style="margin:12px 0 14px">提交这家餐厅的预订</h2>
      <div class="kv"${MK(2, 'tr')}>
        <div class="r"><span class="k">餐厅</span><span class="v">鮨 · 静安店（大众点评 4.8）</span></div>
        <div class="r"><span class="k">时间</span><span class="v">10 月 18 日 周六 19:00</span></div>
        <div class="r"><span class="k">人数</span><span class="v">2 人 · 吧台位</span></div>
        <div class="r"><span class="k">费用</span><span class="v">人均约 ¥280，到店付款</span></div>
      </div>
      <div class="note info" style="margin-top:12px"${MK(3, 'tr')}>${ic('info', 18)}<span>批准后，Orbit 会在你的安卓手机上用大众点评提交预订，餐厅可能会给你发确认短信。不会在线付款。</span></div>
      <div style="display:flex;gap:6px;align-items:center;margin:14px 2px 12px;color:var(--warning);font-size:13.5px;font-weight:600">${ic('lock', 16)}需要 Face ID<span style="color:var(--ink3);font-weight:500">· 29 分钟后过期</span></div>
      <div class="btn primary"${MK(4, 'tr')}>${ic('faceid', 20)}确认预订</div>
      <div class="btn inset" style="margin-top:10px">拒绝</div>
      <div class="foot" style="text-align:center;margin-top:10px"><span${MK(5, 'r')}>来自任务「订周六晚的日料」</span></div>
    </div>
  `);
}

/* ───────────── 连接 ───────────── */

function sWelcome(t) {
  const li = (icon, a, b) => `<div style="display:flex;gap:14px;align-items:flex-start"><span class="ri" style="width:36px;height:36px;border-radius:11px;background:var(--brandSoft);color:var(--accentText);display:grid;place-items:center;flex:none">${ic(icon, 20)}</span><div><div style="font-weight:600;font-size:16px">${a}</div><div class="muted" style="font-size:14px;margin-top:2px;line-height:1.45">${b}</div></div></div>`;
  return frame(t, `
    <div style="position:absolute;inset:0;background:var(--stage)"></div>
    <div class="center" style="position:absolute;top:96px;left:0;right:0">
      <img class="mascot" src="${IMG('hero-wave')}" style="width:178px" alt=""${MK(1, 'tl')}>
      <div class="floor" style="width:110px"></div>
      <h1 class="h-welcome" style="margin-top:18px">你好，我是 Orbit</h1>
      <p class="muted" style="font-size:16px;margin:8px 0 0">连接你的 Mac，把想做的事交给我。</p>
    </div>
    <div style="position:absolute;top:470px;left:34px;right:34px;display:flex;flex-direction:column;gap:18px">
      ${li('laptop', '在你的 Mac 上执行', '我的大脑和工具都在你的电脑上运行')}
      ${li('iphone', '手机随时查看', '进度、结果和需要你的时候，都会推到这里')}
      ${li('shield', '重要的事由你决定', '花钱、对外发送，只在你要求或批准后才做')}
    </div>
    <div style="position:absolute;left:20px;right:20px;bottom:44px">
      <div class="btn primary"${MK(2, 'tr')}>${ic('qr', 20)}连接我的 Mac</div>
      <div style="display:flex;justify-content:space-between;margin-top:6px"><span class="btn plain" style="width:auto;padding:0 8px"${MK(3, 'tr')}>${ic('paste', 18)}粘贴配对链接</span><span class="btn plain" style="width:auto;padding:0 8px;color:var(--ink2)"${MK(4, 'tl')}>体验演示</span></div>
    </div>
  `);
}

function sScan(t) {
  const qr = Array.from({ length: 21 * 21 }, (_, i) => { const x = i % 21, y = Math.floor(i / 21); const f = (a, b) => x >= a && x < a + 7 && y >= b && y < b + 7; const fin = f(0, 0) || f(14, 0) || f(0, 14); const inner = (a, b) => x >= a + 2 && x < a + 5 && y >= b + 2 && y < b + 5; const ring = (a, b) => f(a, b) && !(x > a && x < a + 6 && y > b && y < b + 6); const on = fin ? (ring(0, 0) || ring(14, 0) || ring(0, 14) || inner(0, 0) || inner(14, 0) || inner(0, 14)) : ((x * 7 + y * 13 + x * y) % 5 < 2); return on ? `<rect x="${x}" y="${y}" width="1" height="1"/>` : ''; }).join('');
  return frame('dark', `
    <div class="camera"></div>
    <div style="position:absolute;left:105px;top:268px;width:210px;height:210px;background:#EDE6DD;border-radius:10px;padding:14px;transform:rotate(-4deg);opacity:.9;filter:blur(.4px)"><svg viewBox="0 0 21 21" width="182" height="182" fill="#1d1a17">${qr}</svg></div>
    <div class="vf"><i></i><i></i><i></i><i></i></div>
    <div style="position:absolute;top:58px;left:16px;right:16px;display:flex;justify-content:space-between;align-items:center;z-index:30"><span class="gbtn" style="background:rgba(255,255,255,.16);color:#fff;box-shadow:none">${ic('x', 18, 2.2)}</span><span style="color:#fff;font-weight:600;font-size:17px">连接 Mac</span><span style="width:44px"></span></div>
    <div class="center" style="position:absolute;top:150px;left:30px;right:30px;color:#fff;gap:6px"><b style="font-size:20px;font-weight:600"${MK(1, 'r')}>扫描 Mac 上的二维码</b><span style="font-size:14.5px;opacity:.75">在 Mac 终端运行 <span style="font-family:var(--mono);background:rgba(255,255,255,.14);padding:2px 6px;border-radius:6px">opa pair</span></span></div>
    <div class="center" style="position:absolute;top:524px;left:0;right:0;color:#fff;gap:8px;font-size:14px;opacity:.85"><span style="display:inline-flex;align-items:center;gap:6px"${MK(2, 'r')}>${ic('check', 16, 2.4)}识别到 HerrysYu 的 MacBook Pro</span></div>
    <div style="position:absolute;left:12px;right:12px;bottom:28px;background:rgba(36,33,30,.78);backdrop-filter:blur(24px);border-radius:30px;padding:8px;display:flex;gap:8px"${MK(3, 'tl')}>
      <span class="btn sm" style="flex:1;justify-content:center;background:rgba(255,255,255,.12);color:#fff;height:48px;border-radius:24px">${ic('paste', 18)}粘贴链接</span>
      <span class="btn sm" style="flex:1;justify-content:center;background:rgba(255,255,255,.12);color:#fff;height:48px;border-radius:24px">${ic('photo', 18)}从相册识别</span>
    </div>
  `, { sbLight: true, homeLight: true });
}

function sVerify(t) {
  return frame(t, `
    <div style="position:absolute;top:58px;left:16px;z-index:30"><span class="gbtn">${ic('chevL', 22, 2.2)}</span></div>
    <div class="center" style="position:absolute;top:128px;left:24px;right:24px">
      <img class="mascot" src="${IMG('attentive')}" style="width:104px" alt="">
      <h2 class="h-title2" style="margin-top:20px">核对校验码</h2>
      <p class="muted" style="font-size:15.5px;line-height:1.5;margin:8px 10px 0">确认 Mac 上显示的是同样的 6 位数字，<br>然后在 Mac 上输入 y 并回车。</p>
      <div style="margin-top:26px;background:var(--surface);border-radius:24px;padding:22px 28px;box-shadow:var(--shadowCard),0 0 0 .5px var(--hairline);width:100%">
        <div class="code"><span${MK(1, 'r')}>153 098</span></div>
        <div style="display:flex;align-items:center;justify-content:center;gap:6px;margin-top:14px;font-size:14px;color:var(--ink2)">${ic('laptop', 17)}HerrysYu 的 MacBook Pro · 局域网</div>
      </div>
      <div style="display:flex;align-items:center;gap:8px;margin-top:22px;color:var(--ink2);font-size:14.5px"><span class="spin-dot" style="width:16px;height:16px;border-radius:8px;border:2px solid var(--hairline);border-top-color:var(--apricot)"></span><span${MK(2, 'r')}>等待 Mac 确认…</span></div>
    </div>
    <div style="position:absolute;left:20px;right:20px;bottom:44px"><div class="btn danger-plain"><span${MK(3, 'r')}>数字不一致，取消连接</span></div></div>
  `);
}

function sPaired(t) {
  return frame(t, `
    <div style="position:absolute;inset:0;background:var(--stage)"></div>
    <div class="center" style="position:absolute;top:196px;left:24px;right:24px">
      <img class="mascot" src="${IMG('happy')}" style="width:168px" alt=""${MK(1, 'tr')}>
      <div class="floor" style="width:100px"></div>
      <h1 class="h-welcome" style="margin-top:20px">连上了</h1>
      <p class="muted" style="font-size:16px;margin:8px 0 0">HerrysYu 的 MacBook Pro</p>
      <div style="display:flex;gap:8px;margin-top:16px">${chip('ok', '已加密')}${chip('plan', '局域网 + 外网中继')}</div>
    </div>
    <div style="position:absolute;left:20px;right:20px;bottom:44px">
      <div class="btn primary"${MK(2, 'tr')}>开始和 Orbit 聊聊${ic('arrowR', 19, 2.2)}</div>
      <p class="faint" style="text-align:center;font-size:12.5px;margin:12px 0 0">之后可以在 设置 › 连接与设备 里查看或断开</p>
    </div>
  `);
}

/* ───────────── 设置 ───────────── */

function sSettings(t) {
  const row = (icon, label, value = '', { chev = true, tail = '', small = '' } = {}) => `<div class="row"><span class="ri">${ic(icon, 17)}</span><div class="rt">${label}${small ? `<small>${small}</small>` : ''}</div>${value ? `<span class="rv">${value}</span>` : ''}${tail}${chev ? `<span class="chev">${ic('chevR', 16, 2.2)}</span>` : ''}</div>`;
  return frame(t, `
    <div class="center" style="position:absolute;top:70px;left:0;right:0">
      <span${MK(1, 'r')} style="display:inline-flex">${av(76, { ring: false })}</span>
      <div style="font:600 22px/1.2 var(--rounded);margin-top:10px">Orbit</div>
      <div class="muted" style="font-size:13.5px;margin-top:4px;display:flex;align-items:center;gap:5px"><span style="width:6px;height:6px;border-radius:3px;background:var(--success)"></span>已连接 HerrysYu 的 MacBook Pro</div>
    </div>
    <div style="position:absolute;top:212px;left:16px;right:16px">
      <div class="sec" style="margin-top:4px">我的 Orbit</div>
      <div class="list">${row('person', '名字和形象', 'Orbit')}${row('bubble', '怎么称呼你', '你')}${row('sparkle', '性格', '温和、靠谱')}</div>
      <div class="sec"><span${MK(2, 'r')}>连接与设备</span></div>
      <div class="list">${row('laptop', 'HerrysYu 的 MacBook Pro', '', { small: '已连接 · 局域网' })}${row('android', '安卓执行手机', '', { small: '小米 23116PN5BC · 已就绪' })}</div>
      <div class="sec">记忆、主动与通知</div>
      <div class="list">${row('memory', '记忆', '12 条')}${row('slider', '主动程度', '适中')}${row('moon', '安静时段', '23:00–08:00')}</div>
      <div class="sec"><span${MK(3, 'r')}>权限与隐私</span></div>
      <div class="list">${row('shield', '执行权限', '逐项确认')}${row('lock', '设备信息', '位置、日历')}</div>
      <div class="sec"><span${MK(4, 'r')}>高级</span></div>
      <div class="list">${row('cpu', '模型', '自动')}</div>
    </div>
    ${tabbar('settings')}
  `);
}

function sMemory(t) {
  const m = (text, meta, inferred = false) => `<div class="row noicon" style="align-items:flex-start;padding:13px 16px"><div class="rt" style="font-size:16px">${text}<small style="display:flex;align-items:center;gap:5px;margin-top:4px">${inferred ? `<span style="color:var(--accentText);font-weight:600">我推断的</span>` : '<span>你告诉我的</span>'}<span class="faint">· ${meta}</span></small></div></div>`;
  return frame(t, `
    <div style="position:absolute;top:58px;left:16px;right:16px;display:flex;justify-content:space-between;z-index:30"><span class="gbtn">${ic('chevL', 22, 2.2)}</span><span class="gbtn"${MK(1, 'l')}>${ic('plus', 21, 2.2)}</span></div>
    <div style="position:absolute;top:116px;left:20px;right:20px">
      <h1 class="h-large" style="font-size:32px">记忆</h1>
      <p class="muted" style="font-size:14.5px;line-height:1.5;margin:6px 0 14px">Orbit 记住的关于你的事。它只在需要时用到这些，你可以随时删除。</p>
      <div class="segc"${MK(2, 'tr')}><span class="on">全部 12</span><span>你告诉我的 9</span><span>我推断的 3</span></div>
    </div>
    <div style="position:absolute;top:262px;left:16px;right:16px">
      <div class="sec" style="margin-top:6px">偏好</div>
      <div class="list">
        ${m('不吃香菜', '10 月 15 日')}
        <div style="position:relative;overflow:hidden">
          <div style="position:absolute;right:0;top:0;bottom:0;width:86px;background:var(--danger);color:#fff;display:grid;place-items:center;font-weight:600;font-size:15px"${MK(3, 'tl')}>删除</div>
          <div style="background:var(--surface);transform:translateX(-86px);border-left:.5px solid var(--hairline)">${m('喜欢安静的餐厅，偏爱吧台位', '10 月 15 日', true)}</div>
        </div>
        ${m('早上 9 点前不要发通知', '10 月 12 日')}
      </div>
      <div class="sec">地点与人</div>
      <div class="list">
        ${m('公司在静安区南京西路', '10 月 10 日')}
        ${m('常和 Lily 一起吃饭，她对海鲜过敏', '10 月 9 日', true)}
      </div>
      <div class="foot"${MK(4, 'tl')}>删除前会再确认一次；删除后 Orbit 不再记得这件事。对 Orbit 说“记住…”也可以添加。</div>
    </div>
  `);
}

/* ───────────── 活动与权限（点头像） ───────────── */

function sActivity(t) {
  const sess = (icon, title, sub, chipHtml) => `<div class="row" style="align-items:flex-start"><span class="ri" style="margin-top:2px">${ic(icon, 17)}</span><div class="rt" style="font-size:15.5px"><div style="display:flex;gap:8px;align-items:center"><span style="flex:1;font-weight:600">${title}</span>${chipHtml}</div><small>${sub}</small></div></div>`;
  return frame(t, `
    ${chatRunningThread()}
    ${presence({ status: '正在搜索附近的日料店', kind: 'live', ring: true })}
    ${tabbar('chat')}
    <div class="scrim"></div>
    <div class="sheet" style="top:112px">
      <div class="grab"></div>
      <div class="center" style="gap:4px;margin-top:4px"><span${MK(1, 'r')} style="display:inline-flex">${av(54, { ring: true })}</span><div style="font:600 18px/1.2 var(--rounded);margin-top:6px">Orbit 正在做</div><div class="muted" style="font-size:13px">2 件事在进行 · Mac 已连接（局域网）</div></div>
      <div class="sec" style="margin:16px 2px 8px"><span${MK(2, 'r')}>执行中</span></div>
      <div class="list" style="box-shadow:0 0 0 .5px var(--hairline)">
        ${sess('android', '大众点评 · 查周六空位', '订周六晚的日料 · 正在查看「一番寿司」可订时段', chip('run', '进行中', true))}
        ${sess('laptop', '填写报销表', '整理 9 月发票 · 已填 9 / 14 张', chip('run', '进行中', true))}
      </div>
      <div class="sec" style="margin:16px 2px 8px"><span${MK(3, 'r')}>最近的动作</span></div>
      <div style="font-size:14px;line-height:1.5;color:var(--ink2);display:flex;flex-direction:column;gap:6px;padding:0 4px">
        <div><span class="faint" style="font-variant-numeric:tabular-nums">17:26</span>　在安卓手机上打开大众点评</div>
        <div><span class="faint" style="font-variant-numeric:tabular-nums">17:21</span>　派出任务「订周六晚的日料」</div>
        <div><span class="faint" style="font-variant-numeric:tabular-nums">17:20</span>　记下：你喜欢有吧台位的店</div>
      </div>
      <div class="sec" style="margin:16px 2px 8px"><span${MK(4, 'r')}>我能做什么</span></div>
      <div class="list" style="box-shadow:0 0 0 .5px var(--hairline)">
        <div class="row"><span class="ri">${ic('laptop', 17)}</span><div class="rt" style="font-size:15.5px">Mac 上的操作<small>沙箱外的命令逐项问你</small></div><span class="chev">${ic('chevR', 16, 2.2)}</span></div>
        <div class="row"><span class="ri">${ic('android', 17)}</span><div class="rt" style="font-size:15.5px">安卓手机上的操作<small>敏感点击自动执行，并记录在案</small></div><span class="chev">${ic('chevR', 16, 2.2)}</span></div>
      </div>
    </div>
  `);
}

/* ───────────── 系统表面 ───────────── */

function sLock(t) {
  return frame('dark', `
    <div style="position:absolute;inset:0;background:radial-gradient(120% 80% at 30% 10%, #6b4a33 0%, #2a1f19 45%, #121010 100%)"></div>
    <div style="position:absolute;top:84px;left:0;right:0;text-align:center;color:#fff;font-size:19px;font-weight:600;opacity:.9">10月15日 星期四</div>
    <div class="lock-time" style="position:absolute;top:110px;left:0;right:0">9:41</div>
    <div style="position:absolute;left:12px;right:12px;top:470px;display:flex;flex-direction:column;gap:10px">
      <div class="la"${MK(1, 'tr')}>
        <div style="display:flex;align-items:center;gap:12px">
          ${av(40, { bg: '#453022' })}
          <div style="flex:1;min-width:0"><div style="font-weight:600;font-size:16px">订周六晚的日料</div><div style="font-size:13.5px;opacity:.75;margin-top:2px">核对周六 19:00 的空位</div></div>
          <span class="chip run" style="--brandSoft:#453022;--accentText:#F2AD73;--apricot:#F2AD73">进行中</span>
        </div>
        <div style="display:flex;align-items:center;gap:10px;margin-top:12px"><div style="flex:1;--surfaceInset:rgba(255,255,255,.16);--apricot:#F2AD73">${seg(4, 2, 2)}</div><span style="font-size:12.5px;opacity:.75;white-space:nowrap">已完成 2 / 4 步</span></div>
      </div>
      <div class="la" style="background:rgba(36,31,27,.5)"${MK(2, 'tr')}>
        <div style="display:flex;gap:12px;align-items:flex-start">
          <div class="icon-tile" style="width:38px;height:38px;border-radius:9px;flex:none"><img src="${IMG('icon-apricot')}" alt=""></div>
          <div style="flex:1"><div style="display:flex;justify-content:space-between;font-size:14px"><b style="font-weight:600">Orbit</b><span style="opacity:.6;font-size:13px">现在</span></div><div style="font-weight:600;font-size:15px;margin-top:2px">需要你确认：提交预订</div><div style="font-size:14px;opacity:.8;margin-top:2px">鮨 · 静安店 · 周六 19:00 · 2 人。打开 Orbit 查看并确认。</div></div>
        </div>
      </div>
    </div>
    <div style="position:absolute;bottom:40px;left:46px;right:46px;display:flex;justify-content:space-between"><span class="gbtn" style="background:rgba(255,255,255,.18);color:#fff;box-shadow:none;width:50px;height:50px;border-radius:25px">${ic('bell', 22)}</span><span class="gbtn" style="background:rgba(255,255,255,.18);color:#fff;box-shadow:none;width:50px;height:50px;border-radius:25px">${ic('camera', 22)}</span></div>
  `, { sbLight: true, homeLight: true });
}

function sIsland(t) {
  const icon = (img, label, dark) => `<div class="center" style="gap:6px;width:72px"><div class="icon-tile" style="width:64px;height:64px"><img src="${IMG(img)}" alt=""></div><span style="font-size:12px;color:#fff;text-shadow:0 1px 2px rgba(0,0,0,.4)">${label}</span></div>`;
  const blank = (bg) => `<div class="center" style="gap:6px;width:72px"><div style="width:64px;height:64px;border-radius:15px;background:${bg};opacity:.85"></div><span style="font-size:12px;color:#fff;opacity:.8">　</span></div>`;
  return frame('dark', `
    <div style="position:absolute;inset:0;background:linear-gradient(160deg,#cf9d76 0%,#7d5a44 45%,#2b2220 100%)"></div>
    <div class="dyn" style="position:absolute;top:11px;left:14px;right:14px;height:168px;z-index:46;padding:18px 20px"${MK(1, 'br')}>
      <div style="display:flex;align-items:center;gap:12px">${av(44, { bg: '#453022' })}<div style="flex:1"><div style="font-weight:600;font-size:16px">订周六晚的日料</div><div style="font-size:13.5px;opacity:.7;margin-top:2px">需要你确认提交预订</div></div><span style="color:#E7BA73;display:inline-flex">${ic('hand', 22)}</span></div>
      <div style="display:flex;align-items:center;gap:10px;margin-top:16px"><div style="flex:1;--surfaceInset:rgba(255,255,255,.16);--apricot:#F2AD73">${seg(4, 3, 3)}</div><span style="font-size:12.5px;opacity:.7">3 / 4 步</span></div>
      <div style="margin-top:14px;height:36px;border-radius:18px;background:#F2AD73;color:#241A13;display:flex;align-items:center;justify-content:center;font-weight:600;font-size:14.5px">打开 Orbit 确认</div>
    </div>
    <div style="position:absolute;top:220px;left:30px;right:30px;display:grid;grid-template-columns:repeat(4,72px);justify-content:space-between;row-gap:22px">
      ${blank('#e9dccf')}${blank('#5a7d6c')}<div${MK(3, 'tr')}>${icon('icon-apricot', 'Orbit')}</div>${blank('#3d5873')}
      ${blank('#d6a46d')}${blank('#c7c2bb')}${blank('#7b6a8f')}${blank('#9e4f3e')}
    </div>
    <div style="position:absolute;top:470px;left:20px;right:20px;color:#fff">
      <div style="font-size:13px;font-weight:600;opacity:.8;margin-bottom:10px"><span${MK(2, 'r')}>灵动岛 · 紧凑 / 最小</span></div>
      <div style="display:flex;gap:14px;align-items:center">
        <div class="dyn" style="height:37px;width:236px;display:flex;align-items:center;justify-content:space-between;padding:0 12px 0 10px">${orbitMark(24)}<span style="font:600 14px/1 var(--font);color:#F2AD73">2/4</span></div>
        <div class="dyn" style="height:37px;width:37px;display:grid;place-items:center">${orbitMark(24)}</div>
      </div>
      <div style="display:flex;gap:14px;align-items:center;margin-top:12px">
        <div class="dyn" style="height:37px;width:236px;display:flex;align-items:center;justify-content:space-between;padding:0 12px 0 10px">${orbitMark(24)}<span style="font:600 13px/1 var(--font);color:#E7BA73;display:inline-flex;align-items:center;gap:4px">${ic('hand', 15)}待确认</span></div>
      </div>
      <p style="font-size:12.5px;opacity:.75;line-height:1.5;margin:14px 0 0">紧凑态左侧用矢量星环标识（不缩放 3D 图），右侧给步骤计数或“待确认”文字；需要你时不只改变颜色。</p>
    </div>
  `, { sbLight: true, homeLight: true });
}
