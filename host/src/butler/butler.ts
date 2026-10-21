// The bot (Orbit): an always-on, event-driven actor. Its brain is a Codex thread (billed to the ChatGPT plan) — 方案 §4.1.
import { createHash } from 'node:crypto';
import type { CodexBridge, ApprovalAsk, ApprovalDecision } from '../codex/bridge.ts';
import type { Db } from '../store/db.ts';
import type { EventLog } from '../store/events.ts';
import type { Gateway } from '../gateway/gateway.ts';
import { DEFAULT_SETTINGS, type DeviceContext, type Session, type Settings, type Task } from '../types.ts';
import { State } from './state.ts';
import { MemoryStore } from './memory.ts';
import { Scheduler, type Schedule } from './scheduler.ts';
import { Notifier } from './notifier.ts';
import { ModelCatalog } from './models.ts';
import { Brain } from './brain.ts';
import { DEFAULT_BOT_EFFORT, pickEffort, readEffort } from './effort.ts';
import { buildInstructions, loadSkillIndex } from './prompt.ts';
import { cancelPendingPhoneTask, isPhoneTaskStarting, TOOLS, TOOL_MAP, workerEffort, workerModel, type Rt } from './tools.ts';
import { toolActivityLabel } from './activity.ts';
import { fmtLocal, inQuietHours } from '../util/cron.ts';
import { phoneConfigStatus } from '../phone/config.ts';
import { PhoneNotificationWatcher, type PhoneNotificationOptions } from '../phone/notifications.ts';
import { PhoneRunner } from '../phone/runner.ts';
import { log, uid } from '../util/log.ts';

export interface BEvent { type: string; body: string; fromUser?: boolean; ts: number }

const MAX_TOOL_OUTPUT = 12_000;

/** Context size (tokens) at which an idle bot compacts its brain thread. `OPA_BRAIN_COMPACT_TOKENS` overrides it. */
const DEFAULT_COMPACT_TOKENS = 60_000;
/** …but never beyond this share of the model's context window. */
const COMPACT_WINDOW_SHARE = 0.6;
/** Two compactions are at least this far apart. */
const COMPACT_COOLDOWN_MS = 5 * 60_000;

/** The status bar's sections, in the order the brain reads them. */
export const STATUS_KEYS = ['time', 'presence', 'phone', 'device', 'calendar', 'reminders', 'tasks', 'sessions', 'approvals', 'schedules', 'imports', 'memory'] as const;
export type StatusKey = typeof STATUS_KEYS[number];

/**
 * One section of the status bar. `text` is what the brain reads ('' = nothing to show right now); `empty` is the one line
 * sent when a section that was shown earlier has gone empty. `sig` is what decides "did it change" when that differs from
 * `text` (so a timestamp in the text does not make the section look new every time).
 */
export interface StatusSection { key: StatusKey; text: string; empty: string; sig?: string }

/** The status bar for one brain input, plus a way to take it back if the input never reached the brain. */
interface StatusDelta { text: string; undo(): void }

/** Opens every status bar. */
const STATUS_NOTE = '只列出与上次相比有变化的部分；没列出的沿用之前的状态。';

const digest = (s: string) => createHash('sha1').update(s).digest('hex').slice(0, 16);

export class Butler implements Rt {
  readonly state: State;
  readonly memory: MemoryStore;
  readonly scheduler: Scheduler;
  readonly notifier: Notifier;
  readonly models: ModelCatalog;
  readonly brain: Brain;
  /** Wakes the bot when the dedicated phone gets new notifications. */
  readonly phoneNotifications: PhoneNotificationWatcher;
  /** Drives phone tasks step by step (phone_task, OPA_PHONE_MODE=steps). */
  readonly phone: PhoneRunner;
  readonly watches = new Map<string, { note: string; on: string[] }>();
  private inbox: BEvent[] = [];
  private running = false;
  private yielded = false;
  private streamingId?: string;
  private streamText = '';
  /** msg.start has been sent for the current stream (only once it has visible text). */
  private streamStarted = false;
  private sentLen = 0;
  private roundUserTriggered = false;
  private roundHeartbeat = false;
  private recent: string[] = [];
  /** Increments whenever the conversational timeline is cleared; old turns may finish but can no longer publish. */
  private chatEpoch = 0;
  private chatClearing = false;
  private msgId?: string;
  private heartbeatTimer?: NodeJS.Timeout;
  private lastRoundAt = 0;
  /** True while the brain thread is being compacted: new events queue up instead of steering into a turn. */
  private compacting = false;
  private lastCompactAt = 0;
  /**
   * What the current brain thread has been told of the status bar: section key → digest of its text ('' = last told
   * "（无）"). Emptied whenever that stops being true: new thread, compaction, Host start (it lives in memory only).
   */
  private sentSections = new Map<string, string>();
  /** The thread `sentSections` belongs to. */
  private statusThread?: string;
  private pendingQuestions = new Map<string, (answers: Record<string, string[]>) => void>();

  /** `opts.phoneNotifications` is a test seam (fake adb, fake clock); normal callers pass nothing. */
  constructor(readonly db: Db, readonly ev: EventLog, readonly bridge: CodexBridge, readonly gw: Gateway, opts: { phoneNotifications?: Partial<PhoneNotificationOptions> } = {}) {
    this.state = new State(db, ev);
    this.memory = new MemoryStore(db);
    this.scheduler = new Scheduler(db, () => this.tz());
    this.notifier = new Notifier(db, gw, () => this.settings(), () => this.tz());
    this.models = new ModelCatalog(bridge);
    this.brain = new Brain(bridge, db);
    this.phone = new PhoneRunner({
      bridge,
      resolve: () => {
        const model = workerModel(this);
        // One phone step is a small decision: unless the owner picked an effort, medium is plenty.
        return { model, effort: workerEffort(this, undefined, model) ?? 'medium' };
      },
      syncSession: (id, patch) => this.syncSession(id, patch),
      audit: (actor, action, detail) => this.db.audit(actor, action, detail),
    });
    this.phoneNotifications = new PhoneNotificationWatcher({
      push: (e) => this.push(e), settings: () => this.settings(), tz: () => this.tz(), db, ...opts.phoneNotifications,
    });
  }

  // ───────────── Rt ─────────────
  settings(): Settings {
    const s = this.db.get<Partial<Settings>>('settings') ?? {};
    return { ...DEFAULT_SETTINGS, ...s, butler: { ...DEFAULT_SETTINGS.butler, ...s.butler }, models: { ...DEFAULT_SETTINGS.models, ...s.models }, quietHours: { ...DEFAULT_SETTINGS.quietHours, ...s.quietHours } };
  }
  device(): DeviceContext | undefined { return this.db.get<DeviceContext>('device.context'); }
  tz(): string { return this.device()?.timezone ?? Intl.DateTimeFormat().resolvedOptions().timeZone; }
  currentMsgId() { return this.msgId; }
  chatGeneration() { return this.chatEpoch; }
  requestYield() { this.yielded = true; }
  isChatClearing() { return this.chatClearing; }

  /** Clear only conversational state. The phone runner, worker sessions, tasks, memories and settings keep running. */
  clearChat(): { cleared: true; seq: number; clearedAt: number } {
    if (this.chatClearing) throw new Error('chat.clear is already in progress');
    const previousEpoch = this.chatEpoch;
    this.chatClearing = true;
    this.chatEpoch++;
    let committed = false;
    try {
      const cleared = this.ev.clearChat();
      committed = true;
      const target = this.brain.resetForClear();
      this.brain.interruptAndArchive(target);
      this.inbox = this.inbox.filter((e) => !e.fromUser);
      this.recent.length = 0;
      this.streamingId = undefined;
      this.streamText = '';
      this.streamStarted = false;
      this.sentLen = 0;
      this.msgId = undefined;
      this.sentSections.clear();
      this.statusThread = undefined;
      this.lastCompactAt = 0;
      try { this.ev.emitLive('butler.status', { state: 'idle' }); } catch { /* the durable clear is already complete */ }
      return { cleared: true, seq: cleared.seq, clearedAt: (cleared.d as { clearedAt: number }).clearedAt };
    } catch (e) {
      if (!committed) this.chatEpoch = previousEpoch;
      throw e;
    } finally {
      this.chatClearing = false;
    }
  }

  syncSession(threadId: string, patch: Partial<Session> = {}): Session | undefined {
    const live = this.bridge.sessions.get(threadId);
    const changes = { ...patch };
    if (!changes.mcpServices?.length) delete changes.mcpServices;
    return this.state.upsertSession({
      id: threadId,
      ...(live ? {
        title: live.title, model: live.model, status: live.status, permission: live.permission, lastActivity: live.lastActivity,
        ...(live.mcpServices?.length ? { mcpServices: [...live.mcpServices] } : {}),
      } : {}),
      ...changes,
    });
  }

  // ───────────── lifecycle ─────────────
  start() {
    this.state.expireStaleApprovals();
    // A phone run lives in this process only: one that was still running when the Host went down is over.
    for (const s of this.state.sessions()) {
      if (s.id.startsWith('phone_') && (s.status === 'running' || s.status === 'waiting_approval')) this.syncSession(s.id, { status: 'error', lastActivity: 'Host 重启，手机任务已中断' });
    }
    this.bridge.approvalHandler = (ask) => this.onApprovalAsk(ask);
    this.bridge.audit = (actor, action, detail) => this.db.audit(actor, action, detail);
    this.wireBridge();
    this.wireLiveActivities();
    this.scheduler.onFire = (s) => this.onSchedule(s);
    this.scheduler.start();
    this.armHeartbeat();
    void this.reattachSessions();
    this.wireBrain();
    this.phoneNotifications.start();
  }

  /** Stops the timers (host shutdown, tests). The bot's own thread and queued events are left alone. */
  stop() {
    clearInterval(this.heartbeatTimer);
    this.scheduler.stop();
    this.phoneNotifications.stop();
  }

  /** Re-subscribe to Codex threads that were running before a host restart. */
  private async reattachSessions() {
    for (const s of this.state.sessions()) {
      if (s.status === 'archived' || s.id.startsWith('phone_')) continue; // phone runs are not Codex threads
      try {
        await this.bridge.attach(s.id, s.title, s.permission, s.mcpServices);
      } catch (e: any) {
        log.debug('butler', `cannot reattach ${s.id}: ${e?.message}`);
      }
    }
  }

  armHeartbeat() {
    clearInterval(this.heartbeatTimer);
    const mins = Math.max(5, this.settings().heartbeatMinutes);
    this.heartbeatTimer = setInterval(() => void this.heartbeat(), mins * 60_000);
  }

  // ───────────── inputs ─────────────
  push(e: Omit<BEvent, 'ts'>) {
    if (this.chatClearing && e.fromUser) return;
    const ev = { ...e, ts: Date.now() };
    // A heartbeat round runs on the heartbeat model and effort, so the user's message waits for it instead of joining it.
    // A compaction takes no input at all: whatever arrives meanwhile queues up and gets its round once it is done.
    if (this.running && !this.compacting && e.fromUser && this.brain.busy && !this.roundHeartbeat) {
      // The user takes priority: inject into the brain's running turn (it sees it at the next step).
      const epoch = this.chatEpoch;
      const bar = this.nextStatusBar();
      void this.brain.steer(this.renderEvents([ev], bar.text)).then((ok) => {
        if (epoch !== this.chatEpoch) return;
        if (!ok) { bar.undo(); this.inbox.push(ev); void this.pump(); }
      });
      return;
    }
    this.inbox.push(ev);
    void this.pump();
  }

  userMessage(text: string, clientId: string, attachments: any[] = []): string {
    const id = uid('u_');
    this.ev.emitEv('msg.user', { id, clientId, text, attachments: attachments.map((a) => ({ ...a, dataB64: undefined })), ts: Date.now() });
    const imgs = attachments.filter((a) => a.kind === 'image' && a.dataB64);
    const extra = attachments.filter((a) => !(a.kind === 'image' && a.dataB64)).map((a) => `[附件 ${a.kind}: ${a.name ?? a.url ?? ''}]`).join(' ');
    let body = text + (extra ? `\n${extra}` : '');
    if (imgs.length) {
      const ids = this.state.addImports(imgs.map((a) => ({ kind: 'photo' as const, title: a.name ?? '聊天图片', mime: a.mime ?? 'image/jpeg', dataB64: a.dataB64 })));
      body += `\n[主人随消息发来 ${ids.length} 张图片，已存为导入项：${ids.join(', ')}，用 import_read 查看]`;
    }
    this.push({ type: 'user_message', body, fromUser: true });
    return id;
  }

  interrupt() {
    this.inbox = this.inbox.filter((e) => !e.fromUser);
    cancelPendingPhoneTask(this.bridge);
    this.phone.cancelAll();
    void this.brain.interrupt();
    const phoneSessions = [...this.bridge.sessions.values()].filter((s) => (s.phone || s.title.startsWith('📱')) && s.activeTurnId);
    for (const s of phoneSessions) void this.bridge.interrupt(s.threadId).catch((e) => log.warn('butler', `failed to cancel phone session ${s.threadId}: ${String(e)}`));
    this.recent.push('（主人按下了停止）');
  }

  uiAction(cardId: string, actionId: string, value: unknown) {
    const card = this.state.card(cardId);
    if (card?.component === 'memory_saved' && actionId === 'undo') {
      this.memory.delete(String(card.props.memoryId));
      this.state.patchCard(cardId, { text: `（已撤销）${card.props.text}` });
      this.ev.emitEv('memory.changed', {});
      return;
    }
    const label = card?.actions?.find((a) => a.id === actionId)?.label;
    this.push({
      type: 'ui_action', fromUser: true,
      body: `主人在卡片 ${cardId}（${card?.component ?? '?'}）上操作：action=${actionId}${label ? `「${label}」` : ''}${value !== undefined ? ` value=${JSON.stringify(value)}` : ''}`,
    });
  }

  approvalResponse(id: string, approve: boolean, note?: string) {
    this.state.resolveApproval(id, approve, note, 'user');
  }

  importsAdded(ids: string[], kinds: string[]) {
    this.push({ type: 'import_received', body: `主人导入了 ${ids.length} 项内容（${[...new Set(kinds)].join('、')}）：${ids.join(', ')}。按 import-triage 处理。` });
  }

  // ───────────── Codex → butler ─────────────
  private wireBridge() {
    this.bridge.on('status', ({ threadId }) => this.syncSession(threadId));
    let lastPersist = 0;
    this.bridge.on('activity', ({ threadId, text }) => {
      this.ev.emitLive('session.progress', { sessionId: threadId, text });
      if (Date.now() - lastPersist > 5000) { lastPersist = Date.now(); this.syncSession(threadId); }
    });
    this.bridge.on('turn_completed', ({ threadId, status, text, error }) => {
      const s = this.syncSession(threadId);
      const w = this.watches.get(threadId);
      const kind = status === 'completed' ? 'done' : status === 'interrupted' ? 'interrupted' : 'error';
      if (kind === 'interrupted' && !(w?.on.includes('interrupted'))) return;
      if (w && kind !== 'interrupted') this.watches.delete(threadId);
      let deliverable = text ?? '(没有最终消息)';
      if (deliverable.length > 6000) {
        const aid = this.state.putArtifact(`session ${threadId} 交付`, s?.title ?? '', 'text/markdown', deliverable);
        deliverable = `${deliverable.slice(0, 2500)}\n…（全文共 ${deliverable.length} 字，artifact_read ${aid}）…\n${deliverable.slice(-2500)}`;
      }
      this.push({
        type: 'session_update',
        body: `session ${threadId}「${s?.title ?? ''}」${s?.taskId ? `（task ${s.taskId}）` : ''} 本轮结束：${kind}${error ? `，错误：${error}` : ''}\n${w ? `你之前的 watch 备注：${w.note}\n` : ''}交付内容：\n${deliverable}`,
      });
    });
    this.bridge.on('status', ({ threadId, status }) => {
      const w = this.watches.get(threadId);
      if (w?.on.includes(status) && status === 'running') this.push({ type: 'session_update', body: `session ${threadId} 开始运行。watch 备注：${w.note}` });
    });
  }

  /** Policy engine for Codex approval requests — 方案 §3.2 审批路由. */
  private async onApprovalAsk(ask: ApprovalAsk): Promise<ApprovalDecision> {
    const s = this.syncSession(ask.threadId, { status: 'waiting_approval' });
    const where = `session ${ask.threadId}「${s?.title ?? ''}」`;
    if (ask.kind === 'userInput') {
      const qid = uid('q_');
      const p = new Promise<Record<string, string[]>>((resolve) => this.pendingQuestions.set(qid, resolve));
      this.push({ type: 'codex_question', body: `${where} 在向你提问（question_id=${qid}）：\n${ask.detail}\n用 codex_answer 回答；需要主人决定的先问主人。` });
      const answers = await Promise.race([p, new Promise<Record<string, string[]>>((r) => setTimeout(() => r({}), 20 * 60_000))]);
      this.pendingQuestions.delete(qid);
      return { approve: true, answers };
    }
    if (ask.risk === 'low') {
      this.db.audit('policy', 'auto-approve', { thread: ask.threadId, kind: ask.kind, detail: ask.detail });
      return { approve: true };
    }
    const delegated = ask.risk === 'medium';
    const { approval, done } = this.state.requestApproval({
      title: `${s?.title ?? '任务'}：${ask.title}`, detail: ask.detail, risk: ask.risk, sessionId: ask.threadId,
      kind: ask.kind === 'elicitation' ? 'elicitation' : ask.kind === 'permissions' ? 'permissions' : ask.kind === 'fileChange' ? 'fileChange' : 'command',
      requireBiometric: ask.risk === 'high',
    });
    if (delegated) {
      this.push({ type: 'approval_needed', body: `${where} 申请（approval_id=${approval.id}，风险 medium，delegated=true）：${ask.title}\n${ask.detail}\n你可以用 approval_decide 代为处理；拿不准就留给主人。` });
    } else {
      this.notifier.notify({ title: '需要你批准', body: `${s?.title ?? '任务'}：${ask.title}`, level: 'timeSensitive', approvalId: approval.id });
      this.push({ type: 'approval_needed', body: `${where} 申请高风险操作（approval_id=${approval.id}，delegated=false，已推送给主人审批）：${ask.title}\n${ask.detail}` });
    }
    const r = await done;
    this.syncSession(ask.threadId, { status: 'running' });
    this.db.audit(r.by, r.ok ? 'approve' : 'deny', { approval: approval.id, thread: ask.threadId, note: r.note });
    if (!delegated || r.by !== 'butler') this.push({ type: 'approval_result', body: `审批 ${approval.id}（${ask.title}）结果：${r.ok ? '批准' : '拒绝'}（by ${r.by}）${r.note ? `，备注：${r.note}` : ''}` });
    return { approve: r.ok };
  }

  answerQuestion(qid: string, answers: Record<string, string[]>): boolean {
    const r = this.pendingQuestions.get(qid);
    if (!r) return false;
    r(answers);
    return true;
  }

  /** Action approvals (request_approval) resolve here too → tell the butler. */
  private wireLiveActivities() {
    this.ev.on('ev', (e) => {
      if (e.k === 'approval.resolved') {
        const a = this.db.getDoc<any>('approvals', e.d.id);
        if (a?.kind === 'action') this.push({ type: 'approval_result', fromUser: e.d.by === 'user', body: `审批 ${a.id}（${a.title}）结果：${e.d.decision === 'approve' ? '批准' : '拒绝'}（by ${e.d.by}）` });
      }
      if (e.k === 'task.upsert') {
        const t = e.d as Task;
        const done = t.steps.filter((s) => s.status === 'done' || s.status === 'skipped').length;
        const end = ['done', 'failed', 'cancelled'].includes(t.status);
        const now = Math.floor(Date.now() / 1000);
        this.gw.push({
          pushType: 'liveactivity', kind: 'liveactivity', taskId: t.id, priority: end ? 10 : 5,
          payload: { aps: {
            timestamp: now, event: end ? 'end' : 'update',
            'content-state': { title: t.title, status: t.status, done, total: t.steps.length, detail: t.summary ?? t.steps.find((s) => s.status === 'running')?.title ?? null },
            ...(end ? { 'dismissal-date': now + 3600 } : {}),
          } },
        });
      }
    });
  }

  private onSchedule(s: Schedule) {
    this.push({ type: 'schedule_fired', body: `闹钟 ${s.id} 到点${s.kind !== 'once' ? `（周期 ${s.cron ?? `每 ${s.everyMinutes} 分钟`}，第 ${s.firedCount} 次）` : ''}${s.taskId ? `，关联 task ${s.taskId}` : ''}：${s.note}` });
  }

  // ───────────── status bar ─────────────
  /**
   * The state the brain should know about, in fixed-key sections. The brain is not handed all of it every round:
   * `nextStatusBar()` sends the time every round and any other section only when it differs from what the current
   * brain thread was last told.
   */
  statusSections(): StatusSection[] {
    const tz = this.tz();
    const d = this.device();
    const s = this.settings();
    const now = Date.now();
    /** A section named `label`; `body` '' = nothing to show. A multi-line body starts with a newline. */
    const sec = (key: StatusKey, label: string, body: string): StatusSection => ({ key, text: body ? `${label}：${body}` : '', empty: `${label}：（无）` });
    const phone = phoneConfigStatus();
    const parts = d ? [`设备 ${d.deviceName}`, d.network && `网络 ${d.network}`, d.battery && `电量 ${Math.round(d.battery.level * 100)}%${d.battery.charging ? '充电中' : ''}`,
      d.focus && `专注模式 ${d.focus}`, d.location && `位置 ${d.location.placeName ?? `${d.location.lat.toFixed(3)},${d.location.lon.toFixed(3)}`}`].filter(Boolean).join(' · ') : '';
    // The report time is only informative: it must not make an unchanged context look new, so the change check leaves it out.
    const device: StatusSection = d
      ? { key: 'device', text: `主人手机上下文（上报于 ${Number.isFinite(d.now) ? fmtLocal(d.now, tz) : '未知时间'}）：${parts}`, empty: '', sig: `主人手机上下文：${parts}` }
      : { key: 'device', text: '主人手机上下文：尚未上报', empty: '' };
    const events = (d?.upcomingEvents ?? []).slice(0, 5).map((e) => `${fmtLocal(e.start, tz).slice(5)} ${e.title}${e.location ? ` @${e.location}` : ''}`);
    const reminders = (d?.reminders ?? []).filter((r) => !r.done).slice(0, 5).map((r) => r.title);
    const tasks = this.state.tasks();
    const sessions = this.state.sessions().filter((x) => x.status !== 'archived').slice(0, 10);
    const approvals = this.state.pendingApprovals();
    const schedules = this.scheduler.list().slice(0, 8);
    const newImports = this.state.imports('new').length;
    return [
      { key: 'time', text: `现在：${fmtLocal(now, tz)}（${tz}）${inQuietHours(s.quietHours, now, tz) ? ' · 勿扰时段' : ''}`, empty: '' },
      { key: 'presence', text: `主人在线：${this.gw.onlineDevices.length ? '正在看 App' : '未打开 App'} · 今日已推送 ${this.notifier.usedToday()}/${s.dailyNotifyBudget}`, empty: '' },
      { key: 'phone', text: `手机自动化：${phone.available ? '可用' : `未配置${phone.reason ? `（${phone.reason}）` : ''}`}`, empty: '' },
      device,
      sec('calendar', '接下来的日程', events.join('；')),
      sec('reminders', '未完成提醒', reminders.join('；')),
      sec('tasks', '进行中的任务', tasks.length ? `\n${tasks.map((t) => `  - ${t.id} [${t.status}] ${t.title}：${t.steps.map((x) => `${x.title}(${x.status}${x.sessionId ? ' ' + x.sessionId.slice(0, 8) : ''})`).join(' → ') || '未拆解'}`).join('\n')}` : ''),
      sec('sessions', 'Codex sessions', sessions.length ? `\n${sessions.map((x) => `  - ${x.id} [${x.status}${this.watches.has(x.id) ? ' · watching' : ''}] ${x.title}${x.lastActivity ? ` — ${x.lastActivity}` : ''}`).join('\n')}` : ''),
      sec('approvals', '待审批', approvals.map((a) => `${a.id}「${a.title}」(${a.risk})`).join('；')),
      sec('schedules', '闹钟', schedules.map((x) => `${x.id} ${x.nextAt ? fmtLocal(x.nextAt, tz).slice(5) : ''} ${x.note.slice(0, 40)}`).join('；')),
      sec('imports', '未处理导入', newImports ? `${newImports} 项` : ''),
      sec('memory', '记忆（关于主人）', `\n${this.memory.summary()}`),
    ];
  }

  /** The whole status bar, every section that has something to show (what the brain gets on a fresh thread). */
  statusBar(): string {
    return this.statusSections().filter((x) => x.text).map((x) => x.text).join('\n');
  }

  /**
   * The status bar for the brain's next input: the time every round, any other section only when it differs from what
   * this brain thread was last sent (one that has gone empty is announced once as （无）). An empty `sentSections` means
   * the brain has seen none of it yet, so the bar is complete. `undo()` takes the bar back when it never reached the brain.
   */
  private nextStatusBar(): StatusDelta {
    const lines = [this.sentSections.size === 0 ? `${STATUS_NOTE}（本次是完整状态栏，没列出的部分当前没有内容。）` : STATUS_NOTE];
    const changes: { key: string; was: string | undefined; now: string }[] = [];
    for (const sec of this.statusSections()) {
      if (sec.key === 'time') { lines.push(sec.text); continue; }
      const was = this.sentSections.get(sec.key);
      const now = sec.text ? digest(sec.sig ?? sec.text) : '';
      const unchanged = sec.text ? was === now : was === undefined || was === ''; // empty: nothing to retract unless it was shown before
      if (unchanged) continue;
      lines.push(sec.text || sec.empty);
      this.sentSections.set(sec.key, now);
      changes.push({ key: sec.key, was, now });
    }
    return {
      text: lines.join('\n'),
      undo: () => {
        // Only what this bar wrote and nobody has rewritten since; a table that was emptied meanwhile stays empty.
        for (const c of changes) {
          if (this.sentSections.get(c.key) !== c.now) continue;
          if (c.was === undefined) this.sentSections.delete(c.key);
          else this.sentSections.set(c.key, c.was);
        }
      },
    };
  }

  // ───────────── heartbeat ─────────────
  /** Cheap periodic check: wake the brain only when the status bar suggests something needs attention. */
  private async heartbeat() {
    const st = this.settings();
    if (this.running || this.inbox.length) return;
    if (Date.now() - this.lastRoundAt < 10 * 60_000) return;
    if (inQuietHours(st.quietHours, Date.now(), this.tz())) return;
    const tasks = this.state.tasks();
    const stuck = this.state.sessions().filter((s) => (s.status === 'running' || s.status === 'waiting_approval') && Date.now() - s.updatedAt > 30 * 60_000);
    const soon = (this.device()?.upcomingEvents ?? []).filter((e) => e.start > Date.now() && e.start - Date.now() < 90 * 60_000);
    const reasons: string[] = [];
    if (stuck.length) reasons.push(`有 ${stuck.length} 个 session 超过 30 分钟没有进展`);
    if (soon.length) reasons.push(`接下来 90 分钟内有日程：${soon.map((e) => e.title).join('、')}`);
    if (st.proactivity !== 'low' && tasks.some((t) => t.status === 'waiting_user' && Date.now() - t.updatedAt > 3 * 3600_000)) reasons.push('有任务等主人回复已超过 3 小时');
    if (st.proactivity === 'high' && !reasons.length && Date.now() - this.lastRoundAt > 4 * 3600_000) reasons.push('已经 4 小时没有互动，看看是否有值得主动做的事');
    if (!reasons.length) return;
    this.push({ type: 'heartbeat', body: `心跳检查：${reasons.join('；')}。判断是否需要处理或提醒；不需要就直接 yield，什么都不说。` });
  }

  // ───────────── the loop ─────────────
  private renderEvents(batch: BEvent[], statusBar?: string): string {
    const evText = batch.map((e) => `<event type="${e.type}" time="${fmtLocal(e.ts, this.tz())}">\n${e.body}\n</event>`).join('\n');
    return statusBar === undefined ? evText : `${evText}\n<status_bar>\n${statusBar}\n</status_bar>`;
  }

  private async pump() {
    if (this.running) return;
    this.running = true;
    try {
      for (;;) {
        while (this.inbox.length) {
          const batch = this.inbox.splice(0);
          await this.round(batch);
        }
        // Nothing left to do: the one moment the brain's history can be tidied. Whatever arrives meanwhile queues up.
        await this.maybeCompact().catch((e) => log.warn('bot', `compaction check failed: ${e?.message ?? e}`));
        if (!this.inbox.length) break;
      }
    } catch (e: any) {
      log.error('bot', 'round crashed', e?.stack ?? e);
    } finally {
      this.running = false;
      this.ev.emitLive('butler.status', { state: 'idle' });
    }
  }

  private async round(batch: BEvent[]) {
    const epoch = this.chatEpoch;
    this.lastRoundAt = Date.now();
    const st = this.settings();
    this.roundUserTriggered = batch.some((e) => e.fromUser);
    this.roundHeartbeat = batch.length > 0 && batch.every((e) => e.type === 'heartbeat');
    this.yielded = false;
    let bar: StatusDelta | undefined;
    try {
      const threadId = await this.brain.ensure({
        instructions: buildInstructions(st, loadSkillIndex()),
        tools: this.brainTools(),
        model: st.models.butler || undefined,
        carryOver: async () => this.recent.slice(-40).join('\n'),
      });
      if (epoch !== this.chatEpoch) return;
      // A different thread has seen none of the status bar: tell it everything again.
      if (threadId !== this.statusThread) { this.statusThread = threadId; this.sentSections.clear(); }
      this.ev.emitLive('butler.status', { state: 'thinking' });
      const turn = await this.turnSettings(st, batch);
      if (epoch !== this.chatEpoch) return;
      bar = this.nextStatusBar();
      const status = await this.brain.turn(this.renderEvents(batch, bar.text), turn);
      bar = undefined;
      if (epoch === this.chatEpoch && status === 'failed' && this.roundUserTriggered) this.say('抱歉，我这边出了点问题，稍后再试一次？', false);
    } catch (e: any) {
      if (epoch === this.chatEpoch) {
        bar?.undo(); // the turn never started: the brain has not seen this bar
        log.error('bot', 'brain turn failed:', e?.message ?? e);
        if (this.roundUserTriggered) this.say('抱歉，我暂时连不上 Mac 上的 Codex。请确认 Codex 已安装并登录，稍后再试一次。', false);
      }
    } finally {
      if (epoch === this.chatEpoch) {
        this.finishStream(false);
        this.msgId = undefined;
      }
    }
    if (epoch !== this.chatEpoch) return;
    for (const e of batch) this.recent.push(`[${e.type}] ${e.body.slice(0, 300)}`);
    if (this.recent.length > 200) this.recent.splice(0, this.recent.length - 200);
  }

  /**
   * Model and reasoning effort for this round's `turn/start` — docs/protocol.md §4.5. A batch made only of heartbeats
   * uses the heartbeat pair, each half following the bot's when left on 自动; every other batch uses the bot's pair
   * (model '' = Codex's default model, effort '' = medium). Both are sent every round, because Codex keeps a turn's
   * override for the turns after it: without them a heartbeat's cheaper model would stick to the next chat. The thread
   * itself is built for the bot model only (`ensure`), never for the heartbeat one.
   */
  private async turnSettings(st: Settings, batch: BEvent[]): Promise<{ model?: string; effort?: string }> {
    const heartbeat = batch.length > 0 && batch.every((e) => e.type === 'heartbeat');
    const m = st.models;
    await this.models.list(); // cached for an hour: keeps the supported-effort check below on real catalog data without a request per round
    const model = (heartbeat && m.heartbeat?.trim()) || m.butler?.trim() || (await this.bridge.defaultModel()) || undefined;
    const entry = this.models.peek(model);
    const effort = pickEffort({
      scope: heartbeat ? '心跳' : 'bot', model, supported: entry?.efforts,
      wanted: heartbeat ? [readEffort(m.heartbeatEffort), readEffort(m.butlerEffort)] : [readEffort(m.butlerEffort)],
      fallbacks: [DEFAULT_BOT_EFFORT, entry?.defaultEffort],
    });
    return { model, effort };
  }

  // ───────────── context ─────────────
  /**
   * The context size (tokens) from which an idle bot compacts its brain thread: `OPA_BRAIN_COMPACT_TOKENS` (default
   * 60000), but never more than 60% of the model's context window once Codex has reported that.
   */
  compactThreshold(): number {
    const n = Number(process.env.OPA_BRAIN_COMPACT_TOKENS);
    const wanted = Number.isFinite(n) && n > 0 ? Math.floor(n) : DEFAULT_COMPACT_TOKENS;
    const window = this.brain.contextWindow;
    return window ? Math.min(wanted, Math.floor(window * COMPACT_WINDOW_SHARE)) : wanted;
  }

  /** Why the brain thread must be left alone right now; undefined = it may be compacted. */
  private compactBlocker(): string | undefined {
    if (this.compacting) return 'a compaction is already running';
    const tokens = this.brain.contextTokens;
    const threshold = this.compactThreshold();
    if (!this.brain.threadId || tokens < threshold) return `the context is ${tokens} tokens (threshold ${threshold})`;
    if (this.brain.busy) return 'the brain is in a turn';
    if (this.inbox.length) return 'events are waiting';
    if (this.state.tasks().some((t) => t.status === 'planning' || t.status === 'running')) return 'a task is in progress';
    const working = (x: { status: string }) => x.status === 'running' || x.status === 'waiting_approval';
    if ([...this.bridge.sessions.values()].some(working) || this.state.sessions().some(working)) return 'a session is working';
    if (this.state.pendingApprovals().length) return 'an approval is pending';
    if (isPhoneTaskStarting(this.bridge)) return 'a phone task is starting';
    if (Date.now() - this.lastCompactAt <= COMPACT_COOLDOWN_MS) return 'it was compacted less than 5 minutes ago';
    return undefined;
  }

  /**
   * Compacts the brain thread when it has grown past `compactThreshold()` and the bot is idle with nothing in flight (no
   * task, session, approval or phone start), so a job is never squeezed in the middle. Codex summarises the history; when
   * it fails or times out the thread is rotated instead: a fresh one takes over, seeded with the recent conversation.
   * Events arriving meanwhile queue up and get their round afterwards. Returns whether a compaction was attempted.
   * A Codex that cannot be reached is not an attempt: the thread stays as it is and the next idle moment tries again.
   */
  async maybeCompact(): Promise<boolean> {
    const epoch = this.chatEpoch;
    const why = this.compactBlocker();
    if (why) { log.debug('bot', `brain thread left alone: ${why}`); return false; }
    const before = this.brain.contextTokens;
    const window = this.brain.contextWindow;
    const wasRunning = this.running;
    // `running` keeps new events in the inbox (no round starts); `compacting` keeps them from steering into a turn.
    this.running = true;
    this.compacting = true;
    this.ev.emitLive('butler.status', { state: 'idle' }); // housekeeping: the app is not told the bot is thinking
    log.info('bot', `compacting the brain thread: ${before} tokens (threshold ${this.compactThreshold()}, window ${window ?? 'unknown'})`);
    let ok: boolean | undefined; // undefined: Codex could not even be asked
    try {
      ok = await this.brain.compact();
      if (epoch !== this.chatEpoch) ok = undefined;
      else if (!ok) {
        log.warn('bot', 'compaction failed or timed out; the next round starts a fresh brain thread');
        this.brain.rotate();
      }
    } catch (e: any) {
      log.warn('bot', `compaction did not start: ${e?.message ?? e}`); // nothing is known about the thread: leave it be, try again later
    } finally {
      this.compacting = false;
      this.running = wasRunning;
    }
    if (epoch === this.chatEpoch && ok !== undefined) {
      this.lastCompactAt = Date.now();
      this.sentSections.clear();
      log.info('bot', `brain thread ${ok ? 'compacted' : 'rotated'} (it held ${before} tokens)`);
      this.db.audit('bot', 'compact', { before, window, ok });
    }
    if (!wasRunning && this.inbox.length) void this.pump();
    return epoch === this.chatEpoch && ok !== undefined;
  }

  private wireBrain() {
    this.brain.runner = (name, args) => this.runTool(name, args);
    this.brain.on('delta', (delta: string) => {
      if (!this.streamingId) {
        this.streamingId = uid('a_');
        this.msgId = this.streamingId;
        this.streamText = '';
        this.sentLen = 0;
        this.streamStarted = false;
      }
      // Hold back a possible partial citation marker (\ue200cite…\ue201) until it closes, then drop it.
      this.streamText += delta;
      const clean = stripCitations(this.streamText);
      const safe = clean.replace(/\ue200[^\ue201]*$/u, '');
      const out = safe.slice(this.sentLen);
      // The app opens a reply on msg.start, so only announce one once there is visible text: a round that streams
      // nothing but whitespace or citation markers must not leave an empty reply behind.
      if (out && (this.streamStarted || out.trim())) {
        if (!this.streamStarted) {
          this.streamStarted = true;
          this.ev.emitLive('msg.start', { id: this.streamingId, proactive: !this.roundUserTriggered || undefined });
        }
        this.sentLen = safe.length;
        this.ev.emitLive('msg.delta', { id: this.streamingId, text: out });
      }
    });
    this.brain.on('message', (text: string) => {
      if (!this.streamingId && text.trim()) {
        // Message arrived without deltas (e.g. after a resume) — publish it whole.
        this.streamingId = uid('a_');
        this.msgId = this.streamingId;
        this.streamText = text;
      }
      this.finishStream(false);
    });
    this.brain.on('turn_done', (status: string) => { if (status === 'interrupted') this.finishStream(!this.yielded); });
    // Codex compacted the thread (ours, or its own when the context filled up): the old status bars are gone from its history.
    this.brain.on('compacted', () => this.sentSections.clear());
  }

  private finishStream(interrupted: boolean) {
    const id = this.streamingId;
    if (!id) return;
    this.streamingId = undefined;
    const text = stripCitations(this.streamText).trim();
    // Nothing visible was ever announced (see the delta handler), so there is no reply to close, interrupted or not.
    if (!text) return;
    this.ev.emitEv('msg.assistant', { id, text, interrupted: interrupted || undefined, proactive: !this.roundUserTriggered || undefined, ts: Date.now() });
    this.recent.push(`Orbit：${text.slice(0, 400)}`);
    if (!this.roundUserTriggered && !interrupted && text) this.notifier.notify({ title: this.settings().butler.name, body: text, level: 'normal' });
  }

  private brainTools() {
    return [
      ...TOOLS.map((t) => ({ name: t.name, description: t.description, parameters: t.parameters })),
      {
        name: 'codex_answer', description: '回答 Codex session 的提问（codex_question 事件）。answers 以问题 id 为键，值为答案字符串数组。何时用：收到 codex_question 后；需要主人决定的先 ask_user。',
        parameters: { type: 'object', properties: { question_id: { type: 'string' }, answers: { type: 'object', additionalProperties: { type: 'array', items: { type: 'string' } } } }, required: ['question_id', 'answers'] },
      },
    ];
  }

  private async runTool(name: string, args: any): Promise<{ text: string; images?: string[] }> {
    const epoch = this.chatEpoch;
    if (name !== 'yield') this.ev.emitLive('butler.status', { state: 'acting', detail: toolActivityLabel(name), tool: name });
    let output: unknown;
    try {
      if (name === 'codex_answer') output = this.answerQuestion(args.question_id, args.answers ?? {}) ? '已回答' : '该问题已超时或不存在';
      else {
        const tool = TOOL_MAP.get(name);
        output = tool ? await tool.run(args, this) : `未知工具 ${name}`;
      }
      if (name !== 'yield') this.db.audit('bot', name, args);
    } catch (e: any) {
      output = `错误：${e?.message ?? e}`;
    }
    if (name === 'yield') {
      if (epoch !== this.chatEpoch) return { text: '本轮对话已清空。' };
      // Nothing more to do this round: end the brain turn so it doesn't keep generating.
      setTimeout(() => {
        if (epoch === this.chatEpoch) void this.brain.interrupt().then(() => this.finishStream(false));
      }, 50);
      this.ev.emitLive('butler.status', { state: 'idle' });
      return { text: 'ok，本轮结束。' };
    }
    if (epoch !== this.chatEpoch) return { text: '本轮对话已清空。' };
    this.ev.emitLive('butler.status', { state: 'thinking' });
    if (Array.isArray(output) && output.every((p: any) => p?.type === 'input_text' || p?.type === 'input_image')) {
      return {
        text: output.filter((p: any) => p.type === 'input_text').map((p: any) => p.text).join('\n') || '(图片)',
        images: output.filter((p: any) => p.type === 'input_image').map((p: any) => p.image_url),
      };
    }
    let s = typeof output === 'string' ? output : JSON.stringify(output);
    if (s.length > MAX_TOOL_OUTPUT) {
      const aid = this.state.putArtifact(`tool ${name}`, '', 'application/json', s);
      s = `${s.slice(0, MAX_TOOL_OUTPUT / 2)}\n…（结果过长，共 ${s.length} 字，完整内容见 artifact_read ${aid}）`;
    }
    return { text: s };
  }

  /** Host-originated message (not from the model). */
  say(text: string, proactive: boolean) {
    const id = uid('a_');
    this.ev.emitEv('msg.assistant', { id, text, proactive: proactive || undefined, ts: Date.now() });
  }
}

/** Codex web-search citation markers look like \ue200cite\ue202turn0search0\ue201 — not meaningful on the phone. */
export function stripCitations(s: string): string {
  return s.replace(/\ue200[^\ue201]*\ue201/gu, '').replace(/[ \t]+\n/g, '\n');
}
