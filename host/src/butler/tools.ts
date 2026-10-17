// Butler tool catalog. Every tool documents: 用途 / 何时用 / 何时不要用 / 注意 — 方案 §4.3.
import type { CodexBridge } from '../codex/bridge.ts';
import { isPhoneRunId, type PhoneRunner } from '../phone/runner.ts';
import type { State } from './state.ts';
import type { MemoryStore } from './memory.ts';
import type { Scheduler } from './scheduler.ts';
import type { Notifier, NotifyLevel } from './notifier.ts';
import type { ModelCatalog } from './models.ts';
import type { DeviceContext, Permission, Settings, Session } from '../types.ts';
import { phoneConfigStatus } from '../phone/config.ts';
import { mergeModelOptions } from './model-options.ts';
import { pickEffort, readEffort } from './effort.ts';
import { COMPONENTS, validatePatch, validateProps } from './genui.ts';
import { embedCardImages } from './media.ts';
import { loadSkillIndex, skillBody } from './prompt.ts';

/** What tools need from the runtime. Implemented by Butler. */
export interface Rt {
  bridge: CodexBridge;
  /** Step-driven phone tasks (OPA_PHONE_MODE=steps, the default). */
  phone: PhoneRunner;
  state: State;
  memory: MemoryStore;
  scheduler: Scheduler;
  notifier: Notifier;
  /** Model catalog; tools only peek at its cache (to check an effort against the model), they never fetch. */
  models: ModelCatalog;
  settings(): Settings;
  device(): DeviceContext | undefined;
  tz(): string;
  watches: Map<string, { note: string; on: string[] }>;
  syncSession(threadId: string, patch?: Partial<Session>): Session | undefined;
  currentMsgId(): string | undefined;
  requestYield(): void;
}

export type ToolOutput = string | { type: 'input_text'; text: string }[] | ({ type: 'input_text'; text: string } | { type: 'input_image'; image_url: string; detail: 'auto' })[];

export interface Tool {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
  run(args: any, rt: Rt): Promise<unknown>;
}

const obj = (properties: Record<string, unknown>, required: string[] = []) => ({ type: 'object', properties, required, additionalProperties: false });
const S = (description: string, extra: object = {}) => ({ type: 'string', description, ...extra });
const N = (description: string) => ({ type: 'number', description });
const B = (description: string) => ({ type: 'boolean', description });
const A = (items: object, description: string) => ({ type: 'array', items, description });

const SESSION_STATUSES = ['done', 'error', 'waiting_approval', 'running', 'interrupted'];
// Protect the async createSession window: two brain tool calls can otherwise both see an empty session list.
const phoneTaskStarting = new WeakSet<CodexBridge>();
const pendingPhoneTaskControllers = new WeakMap<CodexBridge, AbortController>();

/**
 * `OPA_PHONE_MODE`: 'codex' (default) = a Codex worker thread with the orbit_phone MCP; 'steps' = the Host drives the
 * phone one step at a time (PhoneRunner), opt-in only. A runtime without a runner always takes the Codex way.
 */
export function phoneMode(rt?: { phone?: unknown }): 'steps' | 'codex' {
  if (process.env.OPA_PHONE_MODE?.trim().toLowerCase() !== 'steps') return 'codex';
  return rt && !rt.phone ? 'codex' : 'steps';
}

/** True while a `phone_task` is still creating its worker session, i.e. before that session shows up in `bridge.sessions`. */
export function isPhoneTaskStarting(bridge: CodexBridge): boolean {
  return phoneTaskStarting.has(bridge);
}

/** Abort a phone worker whose createSession call has not returned yet. */
export function cancelPendingPhoneTask(bridge: CodexBridge): boolean {
  const controller = pendingPhoneTaskControllers.get(bridge);
  if (!controller || controller.signal.aborted) return false;
  controller.abort();
  return true;
}

function activePhoneSession(rt: Rt) {
  const active = (s: { title: string; status: string; phone?: boolean }) => (s.phone || s.title.startsWith('📱')) && (s.status === 'running' || s.status === 'waiting_approval');
  return rt.state.sessions().find(active) ?? [...rt.bridge.sessions.values()].find(active);
}

/**
 * Which model a Codex worker session runs on. The owner's 执行模型 setting (`models.codexDefault`) always wins when it
 * is set; the bot's own pick (`requested`) only counts while the owner left it on 自动 (empty). Neither → undefined,
 * meaning "whatever Codex defaults to". Every tool that starts or continues a worker goes through here.
 */
export function workerModel(rt: Pick<Rt, 'settings'>, requested?: string): string | undefined {
  const owner = rt.settings().models.codexDefault?.trim();
  if (owner) return owner;
  return requested?.trim() || undefined;
}

/**
 * Which reasoning effort a Codex worker turn runs at — the same shape as workerModel. The owner's 执行任务推理强度
 * (`models.codexEffort`) always wins when it is set; the bot's own pick (`requested`) only counts while the owner left
 * it on 自动 (empty). Neither → undefined, meaning "whatever Codex defaults to". Every tool that starts or continues a
 * worker turn goes through here, so the bot can never override an effort the owner chose.
 *
 * `model` is the model that turn will run on (undefined = Codex's default). When the cached catalog lists the efforts
 * that model supports and the effort is not among them, it is dropped with a warning — the rule falls through to the
 * next choice, as if the setting were 自动 — instead of making Codex reject the turn.
 */
export function workerEffort(rt: Pick<Rt, 'settings'> & { models?: Pick<ModelCatalog, 'peek'> }, requested?: string, model?: string): string | undefined {
  const entry = rt.models?.peek(model);
  return pickEffort({
    scope: '执行任务', model: model ?? entry?.id, supported: entry?.efforts,
    wanted: [readEffort(rt.settings().models.codexEffort), readEffort(requested)],
  });
}

function parseAt(at: string | number | undefined): number | undefined {
  if (at === undefined || at === null || at === '') return undefined;
  if (typeof at === 'number') return at;
  const t = Date.parse(at);
  if (Number.isNaN(t)) throw new Error(`无法解析时间 "${at}"，请用带时区偏移的 ISO 8601，例如 2026-10-15T09:00:00+08:00`);
  return t;
}

export const TOOLS: Tool[] = [
  // ─────────────────────────── 自我管理 ───────────────────────────
  {
    name: 'yield',
    description: '结束本轮，回到等待事件的状态。用途：每一轮的最后一步必须调用。何时用：该做的都做完了、或在等 session/schedule/主人回复。注意：心跳时没有值得说的事，直接 yield，什么都不要输出。',
    parameters: obj({ reason: S('可选，给自己的备注：在等什么') }),
    async run(_a, rt) { rt.requestYield(); return 'ok'; },
  },
  {
    name: 'skill_load',
    description: '读取一个 skill 的完整操作手册。何时用：要做某类事情（派 Codex、渲染卡片、处理导入、读写记忆、中国本土服务）而当前上下文里还没有该手册时，先加载再行动。同一个 skill 在一段对话内加载一次即可。',
    parameters: obj({ name: S('skill 名，见系统提示中的 skills 列表') }, ['name']),
    async run(a) {
      const body = skillBody(a.name);
      if (!body) return `没有名为 ${a.name} 的 skill。可用：${loadSkillIndex().map((s) => s.name).join(', ')}`;
      return body;
    },
  },
  {
    name: 'task_create',
    description: '在任务看板上创建一个 Task（主人在 App「任务」页实时可见）。何时用：任何需要多步、需要开 Codex session、或需要过一段时间才能完成的事。何时不要用：一句话就能答完的问题、一次 connector_call 就能完成的日历或云盘读写。注意：goal 要写清完成标准；steps 先写你能想到的，之后可用 task_update 增补。默认会在对话里渲染一张 task_progress 卡片。',
    parameters: obj({
      title: S('简短标题，例如「订周六晚上两人的日料」'),
      goal: S('目标与完成标准，例如「找到 3 家 4.5 分以上、人均 300 内、周六 19:00 有位的店，主人选定后完成预订」'),
      steps: A({ type: 'string' }, '初始步骤标题列表'),
      show_card: B('是否在对话里渲染 task_progress 卡片，默认 true'),
    }, ['title', 'goal']),
    async run(a, rt) {
      const t = rt.state.createTask(a.title, a.goal, a.steps ?? []);
      if (a.show_card !== false) rt.state.renderCard({ component: 'task_progress', props: { taskId: t.id }, msgId: rt.currentMsgId() });
      return { task_id: t.id, steps: t.steps.map((s) => ({ step_id: s.id, title: s.title })) };
    },
  },
  {
    name: 'task_update',
    description: '更新 Task 状态或步骤。何时用：步骤开始/完成/失败、需要主人介入（waiting_user）、整体完成（done，并写 summary）、放弃（cancelled）。注意：只有在验收过 session 的交付之后才能把步骤或任务标为 done。',
    parameters: obj({
      task_id: S('task id'),
      status: S('任务状态', { enum: ['planning', 'running', 'waiting_user', 'blocked', 'done', 'failed', 'cancelled'] }),
      summary: S('结果摘要（完成或失败时必填）'),
      add_steps: A({ type: 'string' }, '追加的步骤标题'),
      steps: A(obj({
        step_id: S('step id（或步骤标题）'),
        status: S('步骤状态', { enum: ['pending', 'running', 'done', 'failed', 'skipped'] }),
        session_id: S('关联的 Codex session'),
      }, ['step_id']), '要更新的步骤'),
    }, ['task_id']),
    async run(a, rt) {
      const t = rt.state.updateTask(a.task_id, {
        status: a.status, summary: a.summary, addSteps: a.add_steps,
        steps: (a.steps ?? []).map((s: any) => ({ id: s.step_id, status: s.status, sessionId: s.session_id })),
      });
      return { task_id: t.id, status: t.status, steps: t.steps.map((s) => `${s.id} ${s.status} ${s.title}`) };
    },
  },
  {
    name: 'schedule',
    description: '给自己定一个闹钟，到点时你会收到 schedule_fired 事件（带上你写的 note）。何时用：提醒主人某事、过一段时间复查（价格、快递、余票、回复）、周期性例行事务（每天早上的日程简报）。何时不要用：等 Codex session 完成（用 watch）。注意：at 用带时区偏移的 ISO 8601（看状态栏里主人的时区）；cron 为 5 段式、按主人时区解释；every_minutes 至少 5。note 写成到点后你要做的具体动作。',
    parameters: obj({
      note: S('到点后要做什么，例如「提醒主人 10 分钟后出门去机场，并查一下路况」'),
      at: S('一次性：ISO 8601 时间'),
      in_minutes: N('一次性：多少分钟后'),
      cron: S('周期：5 段 cron，例如「0 8 * * 1-5」'),
      every_minutes: N('周期：每 N 分钟'),
      task_id: S('关联的 task（可选）'),
    }, ['note']),
    async run(a, rt) {
      const s = rt.scheduler.add({ note: a.note, at: parseAt(a.at), inMinutes: a.in_minutes, cron: a.cron, everyMinutes: a.every_minutes, taskId: a.task_id });
      return { schedule_id: s.id, next_at: s.nextAt ? new Date(s.nextAt).toISOString() : null };
    },
  },
  {
    name: 'schedule_cancel',
    description: '取消一个 schedule。何时用：事情已经办完、主人取消、或要改时间（先取消再新建）。',
    parameters: obj({ schedule_id: S('schedule id（见状态栏）') }, ['schedule_id']),
    async run(a, rt) { return rt.scheduler.cancel(a.schedule_id) ? '已取消' : '没有这个进行中的 schedule'; },
  },
  {
    name: 'watch',
    description: '盯住一个 Codex session：当它的状态变为指定值时，你会收到带 note 的 session_update 事件。何时用：派出 session 之后立刻调用，然后 yield。注意：session 完成（done）和出错（error）默认总会通知你；watch 的价值是写清楚「到时要做什么」，以及额外订阅 waiting_approval / running。不要轮询 codex_session_status。',
    parameters: obj({
      session_id: S('Codex session id'),
      note: S('状态变化时要做什么，例如「验收 3 家餐厅的价格和空位，渲染 comparison 让主人选」'),
      on: A({ type: 'string', enum: SESSION_STATUSES }, '要订阅的状态，默认 ["done","error","waiting_approval"]'),
    }, ['session_id', 'note']),
    async run(a, rt) {
      rt.watches.set(a.session_id, { note: a.note, on: a.on?.length ? a.on : ['done', 'error', 'waiting_approval'] });
      return 'watching';
    },
  },

  // ─────────────────────────── Codex ───────────────────────────
  {
    name: 'codex_session_create',
    description: '新开一个 Codex session 并下达第一条任务单。Codex 是一个完整的 agent：能上网检索、读写文件、写代码、调用 ChatGPT 插件（Google Calendar、Google Drive 等），以及操作浏览器。何时用：需要多步操作、检索整理、跨网站比较、操作软件的任务步骤；日历、云盘需要多步整合时也开 session，任务单里写明「使用 Google Calendar / Google Drive 插件」。何时不要用：一次性的日历、云盘读写（用 connector_call）和事实查询（web_search）；Mac 图形界面用 computer_use_task；手机 App 用 phone_task；微信不能自动操作。注意：prompt 按 codex-orchestration 的任务单模板写（目标/背景/约束/权限/交付格式/遇阻怎么办），只带完成任务必需的主人信息；需要结构化结果时给 output_schema，字段对齐 GenUI 组件。创建后记得 watch。permission=auto 需要设置允许或主人批准（传 approval_id）。',
    parameters: obj({
      title: S('session 标题，例如「查日料餐厅」'),
      prompt: S('完整任务单'),
      task_id: S('关联 task'),
      step_id: S('关联步骤'),
      model: S('子模型 id（来自 codex_models）。仅当主人的执行模型设为「自动」时生效；主人指定了执行模型时一律以主人的为准，这个参数会被忽略。省略则用默认'),
      effort: S('推理强度。仅当主人的「执行任务推理强度」设为「自动」时生效；主人指定了强度时一律以主人的为准，这个参数会被忽略。省略则用 Codex 默认', { enum: ['low', 'medium', 'high', 'xhigh'] }),
      permission: S('manual=沙箱内工作、越界需审批；auto=完全访问不再询问', { enum: ['manual', 'auto'] }),
      approval_id: S('permission=auto 时，主人已批准的 approval id'),
      skills: A({ type: 'string' }, '要挂给 Codex 的 skill，例如 ["china-services"]'),
      output_schema: { type: 'object', description: '可选：要求最终消息符合的 JSON Schema', additionalProperties: true },
    }, ['title', 'prompt']),
    async run(a, rt) {
      const permission = checkPermission(a.permission, a.approval_id, rt);
      const model = workerModel(rt, a.model);
      const s = await rt.bridge.createSession({
        title: a.title, prompt: a.prompt, model, effort: workerEffort(rt, a.effort, model), permission, skills: a.skills, outputSchema: a.output_schema,
      });
      rt.syncSession(s.threadId, { taskId: a.task_id, title: a.title });
      if (a.task_id && a.step_id) rt.state.updateTask(a.task_id, { steps: [{ id: a.step_id, status: 'running', sessionId: s.threadId }] });
      return { session_id: s.threadId, model: s.model, permission, status: s.status };
    },
  },
  {
    name: 'computer_use_task',
    description: '开一个专门操作这台 Mac 图形界面的 Codex session（computer use：截图、点击、输入）。何时用：需要登录态的网页或只有桌面 App 的服务。何时不要用：手机 App 用 phone_task；微信不能自动操作。中国本土生活服务设 china=true，会自动挂上 china-services skill（有网页端时走浏览器）。注意：同一时间只能有一个 computer use session（共用一块屏幕和鼠标）；涉及付款的一律停在支付页把订单信息交回来，由你给主人推审批卡片。',
    parameters: obj({
      title: S('标题'),
      goal: S('要完成什么，越具体越好（服务名、关键词、时间、人数、预算、偏好）'),
      china: B('是否中国本土服务，默认 true'),
      task_id: S('关联 task'),
      step_id: S('关联步骤'),
      deliverable: S('交付要求，例如「以 JSON 交回 merchant/items/total/eta/status，对齐 order_card」'),
    }, ['title', 'goal']),
    async run(a, rt) {
      const busy = rt.state.sessions().find((s) => s.title.startsWith('🖥') && (s.status === 'running' || s.status === 'waiting_approval'));
      if (busy) return `已有 computer use session 在运行（${busy.id}「${busy.title}」）。等它完成（watch）后再开，或先 codex_session_interrupt。`;
      const china = a.china !== false;
      const prompt = `## 目标\n${a.goal}\n\n## 方式\n使用 computer use 操作这台 Mac 的图形界面完成任务。每一步操作后截图确认状态；同一步最多重试 2 次，仍失败就停止并说明卡在哪里。手机 App 不在此 session 操作，必须改用 phone_task；微信不能自动操作。${china ? '\n这是中国本土服务：严格按 china-services skill 执行；优先使用成熟网页端服务。' : ''}\n\n## 红线\n- 不付款：到支付页立即停止，交回订单信息。\n- 不给任何联系人发消息、不发朋友圈、不加好友、不改设置，除非目标里明确要求。\n- 需要授权手机号、实名信息时停下来说明，不要自行同意。\n\n## 交付\n${a.deliverable ?? '最后一条消息以 ```json 代码块结尾，包含 status（done/blocked/needs_approval）、关键结果字段（价格、时间、状态等）和下一步建议。'}`;
      const model = workerModel(rt);
      const s = await rt.bridge.createSession({ title: `🖥 ${a.title}`, prompt, model, effort: workerEffort(rt, undefined, model), permission: 'manual', skills: china ? ['china-services'] : [] });
      rt.syncSession(s.threadId, { taskId: a.task_id, title: `🖥 ${a.title}` });
      if (a.task_id && a.step_id) rt.state.updateTask(a.task_id, { steps: [{ id: a.step_id, status: 'running', sessionId: s.threadId }] });
      return { session_id: s.threadId, status: s.status };
    },
  },
  {
    name: 'phone_task',
    description: '开一个手机任务，在专用的小米手机上通过 orbit_phone 操作。何时用：只有手机 App 才能办的服务、需要手机 App 登录态的操作。何时不要用：网页端可直接完成的查询优先用浏览器；这台手机上没有微信，微信小程序、公众号、微信服务不要派给手机。手机敏感点击会自动执行；只有任务单明确授权下单或付款时才可执行，否则明确只查询、不下单/付款。手机忙时等待前一任务完成后再派单。',
    parameters: obj({
      title: S('简短标题'),
      goal: S('任务目标和验收标准；若允许下单或付款，必须在任务单中明确授权，否则按只查询处理'),
      china: B('是否中国本土服务，默认 true'),
      task_id: S('关联 task'),
      step_id: S('关联步骤'),
      deliverable: S('交付要求，例如结构化 JSON 字段'),
    }, ['title', 'goal']),
    async run(a, rt) {
      if (phoneTaskStarting.has(rt.bridge)) return '已有手机任务正在启动。等它出现在状态栏后，用 watch 等它完成，再派新的手机任务。';
      const busy = activePhoneSession(rt);
      if (busy) {
        const sessionId = 'id' in busy ? busy.id : busy.threadId;
        return `已有手机任务在运行（${sessionId}「${busy.title}」）。请 watch 等它完成后再派新的手机任务，或先 codex_session_interrupt。`;
      }

      if (phoneMode(rt) === 'steps') {
        const status = phoneConfigStatus();
        if (!status.config) throw new Error(status.reason ?? '手机工具不可用；请运行 opa phone setup。');
        const { id } = rt.phone.start({ title: a.title, goal: a.goal, china: a.china !== false, deliverable: a.deliverable, taskId: a.task_id });
        if (a.task_id && a.step_id) rt.state.updateTask(a.task_id, { steps: [{ id: a.step_id, status: 'running', sessionId: id }] });
        return { session_id: id, status: 'running', mode: 'steps' };
      }

      phoneTaskStarting.add(rt.bridge);
      const controller = new AbortController();
      pendingPhoneTaskControllers.set(rt.bridge, controller);
      try {
        const china = a.china !== false;
        const prompt = `## 目标\n${a.goal}\n\n## 设备与操作边界\n必须使用本 session 专属的 orbit_phone MCP 工具在专用小米手机上完成任务。不要操作 Mac、computer use、浏览器或其他手机工具。先调用 phone_begin 并说明当前任务；之后每次只做一个手机动作，检查该动作返回的新截图再决定下一步；无论成功、受阻或失败，最后都必须调用 phone_end。\n${china ? '中国本土服务：遵循 china-services skill，微信小程序、公众号和微信服务通过手机操作。' : ''}\n\n## 支付与账号权限\n只有原任务单明确授权本次下单或付款时，才执行相应动作。默认权限是“只查询，不要下单/付款”；如果任务单没有明确授权、授权不清楚，或只是查询价格/信息，就严格只查询并停在付款前。手机敏感点击会自动执行，不会再弹审批，因此不得自行扩大授权。遇到登录、验证码、扫码或人脸识别，调用 phone_end 后返回 status=needs_human，说明需要主人完成什么；不要尝试绕过。\n\n## 占用与验收\n若 phone_begin 返回 busy，不要重试或并行开任务；报告设备忙并等待前一任务完成。验收手机返回的页面与数据，确认关键结果确实可见；在 JSON 中提供 phone_end 返回的 evidence 截图路径。\n\n## 交付\n${a.deliverable ?? '最后一条消息以 ```json 代码块结尾，包含 status（done/partial/needs_human/needs_approval/blocked/failed）、summary、关键结果字段、needs（如适用）和 evidence 截图路径。'}\n\n${a.task_id ? `关联任务：${a.task_id}${a.step_id ? `，步骤：${a.step_id}` : ''}\n` : ''}`;
        const phonePrompt = `${prompt}\n\n## 必须遵守的交付格式\n最后一条消息必须以一个 JSON 代码块结尾，包含 status（done/partial/needs_human/needs_approval/blocked/failed）、summary、关键结果字段、needs（如适用）和 phone_end 返回的 evidence 截图路径。自定义交付要求只能补充这些字段与格式，不能省略 JSON、status 或 evidence。`;

        const title = `📱 ${a.title}`;
        const skills = ['phone-automation', ...(china ? ['china-services'] : [])];
        const model = workerModel(rt);
        const s = await rt.bridge.createSession({ title, prompt: phonePrompt, model, effort: workerEffort(rt, undefined, model), permission: 'manual', skills, phone: true, signal: controller.signal });
        if (controller.signal.aborted) return '手机任务启动已取消。';
        rt.syncSession(s.threadId, { taskId: a.task_id, title });
        if (a.task_id && a.step_id) rt.state.updateTask(a.task_id, { steps: [{ id: a.step_id, status: 'running', sessionId: s.threadId }] });
        return { session_id: s.threadId, model: s.model, status: s.status, skills };
      } catch (error: any) {
        if (controller.signal.aborted || error?.name === 'AbortError') return '手机任务启动已取消。';
        throw error;
      } finally {
        pendingPhoneTaskControllers.delete(rt.bridge);
        phoneTaskStarting.delete(rt.bridge);
      }
    },
  },
  {
    name: 'phone_status',
    description: '只读查看手机自动化 MCP 的配置状态和未配置原因；不会连接或操作手机。',
    parameters: obj({}),
    async run() { return phoneConfigStatus(); },
  },
  {
    name: 'codex_session_send',
    description: '给一个 session 发下一条指令。session 空闲时开启新一轮；正在运行时会作为追加指令插入（steer）。何时用：追问、补做、验收不通过要求修正、在同一上下文里做相关的下一步。何时不要用：无关的新任务（新开 session，避免上下文污染）。',
    parameters: obj({
      session_id: S('session id'),
      text: S('指令'),
      effort: S('推理强度。仅当主人的「执行任务推理强度」设为「自动」时生效；主人指定了强度时一律以主人的为准，这个参数会被忽略。省略则用 Codex 默认', { enum: ['low', 'medium', 'high', 'xhigh'] }),
      output_schema: { type: 'object', description: '可选 JSON Schema', additionalProperties: true },
    }, ['session_id', 'text']),
    async run(a, rt) {
      if (isPhoneRunId(a.session_id)) return '手机任务运行中不能追加指令；它结束后可以再派一个 phone_task。';
      // A steer cannot switch models or efforts; only a fresh turn takes the owner's 执行模型 and 执行任务推理强度 (and updates what the app shows).
      const live = rt.bridge.sessions.get(a.session_id);
      const steering = Boolean(live?.activeTurnId);
      const model = steering ? undefined : workerModel(rt);
      // The turn runs on the owner's model if there is one, else on whatever the session already uses.
      const effort = steering ? undefined : workerEffort(rt, a.effort, model ?? live?.model ?? rt.state.session(a.session_id)?.model);
      const r = await rt.bridge.send(a.session_id, a.text, { effort, outputSchema: a.output_schema, model });
      rt.syncSession(a.session_id);
      return r === 'steered' ? '已作为追加指令插入正在进行的一轮' : '已开始新一轮';
    },
  },
  {
    name: 'codex_session_steer',
    description: '在 session 正在运行时纠偏（不打断）。何时用：主人改了要求、你发现方向不对但已有进展值得保留。session 空闲时请用 codex_session_send。',
    parameters: obj({ session_id: S('session id'), text: S('纠偏指令') }, ['session_id', 'text']),
    async run(a, rt) {
      const live = rt.bridge.sessions.get(a.session_id);
      if (!live?.activeTurnId) return 'session 当前没有在运行，请用 codex_session_send';
      await rt.bridge.send(a.session_id, a.text);
      return '已纠偏';
    },
  },
  {
    name: 'codex_session_interrupt',
    description: '中止 session 当前这一轮。何时用：主人叫停、方向完全错误、耗时远超预期、需要释放 computer use。注意：中止后 session 仍可 codex_session_send 继续。',
    parameters: obj({ session_id: S('session id') }, ['session_id']),
    async run(a, rt) {
      if (isPhoneRunId(a.session_id)) return rt.phone.cancel(a.session_id) ? '已中止' : '它当前没有在运行';
      return (await rt.bridge.interrupt(a.session_id)) ? '已中止' : '它当前没有在运行';
    },
  },
  {
    name: 'codex_session_status',
    description: '查看 session 的状态、计划和最近的过程记录（只在需要细节时用，例如验收、排查卡住的原因）。不要用来轮询进度——用 watch。',
    parameters: obj({ session_id: S('session id'), items: N('返回最近多少条记录，默认 12') }, ['session_id']),
    async run(a, rt) {
      if (isPhoneRunId(a.session_id)) {
        const info = rt.phone.status(a.session_id);
        const stored = rt.state.session(a.session_id);
        if (!info) return { status: stored?.status ?? 'unknown', title: stored?.title, note: '这个手机任务的过程记录已不在内存里（Host 重启后不保留）' };
        return {
          status: stored?.status ?? info.status, title: stored?.title ?? info.title, phone_status: info.status, steps: info.steps, max_steps: info.maxSteps,
          model: info.model, summary: info.summary, usage: info.usage, recent: info.notes.slice(-(a.items ?? 12)),
        };
      }
      const live = rt.bridge.sessions.get(a.session_id);
      const items = await rt.bridge.recentItems(a.session_id, a.items ?? 12).catch((e) => [{ kind: 'error', text: String(e), ts: Date.now() }]);
      return {
        status: live?.status ?? rt.state.session(a.session_id)?.status ?? 'unknown', title: live?.title, permission: live?.permission,
        plan: live?.plan, last_error: live?.lastError, last_message: live?.lastAgentText?.slice(0, 3000),
        recent: items.map((i) => `[${i.kind}] ${i.text}`),
      };
    },
  },
  {
    name: 'codex_sessions_list',
    description: '列出 session（状态栏里已有进行中的简表；需要看历史或已归档的才用）。',
    parameters: obj({ include_archived: B('是否包含已归档') }),
    async run(a, rt) { return rt.state.sessions(!a.include_archived).map((s) => `${s.id} [${s.status}] ${s.title}${s.taskId ? ` task:${s.taskId}` : ''}`); },
  },
  {
    name: 'codex_session_archive',
    description: '归档 session（任务完成且不再需要追问时），保持看板整洁。',
    parameters: obj({ session_id: S('session id') }, ['session_id']),
    async run(a, rt) {
      if (isPhoneRunId(a.session_id)) rt.phone.cancel(a.session_id);
      else await rt.bridge.archive(a.session_id);
      rt.syncSession(a.session_id, { status: 'archived' });
      return '已归档';
    },
  },
  {
    name: 'codex_sessions_fork',
    description: '复制一个 session 的上下文开出分支（例如同一份调研要分别按两种方案继续）。',
    parameters: obj({ session_id: S('源 session'), title: S('新标题') }, ['session_id', 'title']),
    async run(a, rt) {
      const r = await rt.bridge.rpc.request<any>('thread/fork', { threadId: a.session_id });
      const s = await rt.bridge.attach(r.thread.id, a.title);
      rt.syncSession(s.threadId, { title: a.title });
      return { session_id: s.threadId };
    },
  },
  {
    name: 'codex_session_goal',
    description: '给 session 设定长期目标（thread goal），Codex 会围绕它自主连续工作直到完成或用完 token 预算。何时用：耗时长、步骤多、可以放手让它自己推进的任务（例如「整理过去一年的发票并生成报销表」）。',
    parameters: obj({ session_id: S('session id'), objective: S('目标与完成标准'), token_budget: N('token 预算，可选') }, ['session_id', 'objective']),
    async run(a, rt) { await rt.bridge.setGoal(a.session_id, a.objective, a.token_budget); return '目标已设定'; },
  },
  {
    name: 'codex_set_permission',
    description: '切换 session 之后各轮的权限。manual：沙箱内工作，越界操作逐条审批（大部分低风险审批由系统自动处理）；auto：完全访问、不再询问。注意：切到 auto 需要设置里允许，或先 request_approval 得到主人批准并传入 approval_id。',
    parameters: obj({ session_id: S('session id'), permission: S('目标权限', { enum: ['manual', 'auto'] }), approval_id: S('主人批准的 approval id') }, ['session_id', 'permission']),
    async run(a, rt) {
      const permission = checkPermission(a.permission, a.approval_id, rt);
      const live = await rt.bridge.attach(a.session_id, undefined, permission);
      rt.syncSession(live.threadId, { permission });
      return `已切换为 ${permission}，从下一轮起生效`;
    },
  },
  {
    name: 'codex_models',
    description: '列出 Codex 模型目录（id、说明、是否默认、支持的推理强度及默认强度），并包含手动补充的 GPT-6.1 Sol 选项；手动选项不代表账号已验证可调用。何时用：要为 session 选模型时。简单检索/填表用小而快的模型，复杂研究/编码用最强模型配高 effort。',
    parameters: obj({}),
    async run(_a, rt) {
      return mergeModelOptions(await rt.bridge.models()).map((m) => ({
        id: m.id, name: m.displayName, description: m.description, default: m.isDefault,
        efforts: m.efforts, default_effort: m.defaultEffort,
      }));
    },
  },
  {
    name: 'connectors_list',
    description: '列出可直接调用的 ChatGPT 插件 / MCP 服务器及其工具名。Google Calendar、Google Drive 等插件的工具通常挂在 codex_apps 下，名字带插件前缀，例如 google_calendar.search_events。何时用：第一次需要某个插件（日历、云盘、邮件…）时确认它是否已连接、工具叫什么。列表里没有某个插件，说明主人还没有安装或连接它：告诉主人去 Codex 安装并连接（Codex CLI 里输入 /plugins，或 ChatGPT 设置 → Apps），不要退回 computer use。',
    parameters: obj({ server: S('只看某个服务器的工具（可选）') }),
    async run(a, rt) {
      const servers = await rt.bridge.mcpServers();
      return servers.filter((s) => !a.server || s.name === a.server).map((s) => ({
        server: s.name, auth: s.auth, tools: a.server ? s.tools : s.tools.slice(0, 40), more: !a.server && s.tools.length > 40 ? s.tools.length - 40 : undefined,
      }));
    },
  },
  {
    name: 'connector_call',
    description: '直接调用一个 ChatGPT 插件 / MCP 工具（不经过 Codex agent，秒级返回）。查日历、加日程、改日程，以及在云盘里找、读、建文件，都用它：不要自己写 API 调用，也不要用 computer use 或浏览器。何时用：一次性的读写，例如查今天的日程、新建一个日程、列出云盘文件。server 通常是 codex_apps，工具名先用 connectors_list 查（形如 google_calendar.search_events）。何时不要用：需要多步推理或跨插件整合的任务（开 session，并在任务单里写明「使用 Google Calendar / Google Drive 插件」）。注意：写操作（创建日程、发邮件）属于对外动作，先确认主人意图；发给他人的内容必须先 request_approval。',
    parameters: obj({
      server: S('服务器名（来自 connectors_list），ChatGPT 插件通常在 codex_apps'),
      tool: S('工具名'),
      arguments: { type: 'object', description: '工具参数', additionalProperties: true },
    }, ['server', 'tool']),
    async run(a, rt) { return await rt.bridge.callTool(a.server, a.tool, a.arguments ?? {}); },
  },

  // ─────────────────────────── 交互 ───────────────────────────
  {
    name: 'ui_render',
    description: `在对话中渲染一张 Generative UI 卡片。结构化信息（多个选项、价格、时间、地点、表格、订单、票）优先用卡片，并同时输出一句文字说明。可用组件：${COMPONENTS.join(', ')}。props 结构见 genui-guide skill（不确定时先 skill_load genui-guide）。actions 是卡片按钮，点击后你会收到 ui_action 事件；花钱、下单、对外发送的按钮必须 requires_approval=true（主人需 Face ID 确认）。返回 card_id，之后用 ui_patch 更新状态。`,
    parameters: obj({
      component: S('组件名', { enum: COMPONENTS }),
      props: { type: 'object', description: '组件 props', additionalProperties: true },
      actions: A(obj({
        id: S('按钮 id，回传到 ui_action'), label: S('按钮文字'),
        style: S('样式', { enum: ['primary', 'secondary', 'destructive'] }), requires_approval: B('是否需要 Face ID 确认'),
      }, ['id', 'label']), '卡片按钮'),
    }, ['component', 'props']),
    async run(a, rt) {
      if (a.component === 'memory_saved' || a.component === 'task_progress' || a.component === 'approval_card') {
        const key = a.component === 'memory_saved' ? 'memoryId' : a.component === 'task_progress' ? 'taskId' : 'approvalId';
        const dup = rt.state.findCard(a.component, key, String(a.props?.[key] ?? ''));
        if (dup) return { card_id: dup.id, note: '这张卡片已经由系统自动显示过了，无需重复渲染' };
      }
      const v = validateProps(a.component, a.props);
      if (!v.ok) return `渲染失败：${v.error}。请修正后重试。`;
      const props = await embedCardImages(a.component, v.props); // local / http images → data URLs the phone can show; never echoed back to the bot
      const card = rt.state.renderCard({
        component: a.component, props, msgId: rt.currentMsgId(),
        actions: a.actions?.map((x: any) => ({ id: x.id, label: x.label, style: x.style, requiresApproval: x.requires_approval })),
      });
      return { card_id: card.id };
    },
  },
  {
    name: 'ui_patch',
    description: '更新已渲染卡片的部分 props（浅合并），手机端会以动画过渡。何时用：状态流转（order_card draft→confirming→placed→delivering→done；ticket_card options→holding→booked；booking_card draft→pending→confirmed）、补充信息。比重新渲染一张新卡更好。',
    parameters: obj({ card_id: S('card id'), props: { type: 'object', description: '要更新的 props', additionalProperties: true } }, ['card_id', 'props']),
    async run(a, rt) {
      const card = rt.state.card(a.card_id);
      if (!card) return '没有这张卡片';
      const v = validatePatch(card.component, card.props, a.props);
      if (!v.ok) return `更新失败：${v.error}`;
      const props = await embedCardImages(card.component, a.props); // only the patch: images already in the card are not touched again
      rt.state.patchCard(a.card_id, props);
      return 'ok';
    },
  },
  {
    name: 'ask_user',
    description: '向主人提一个需要回答的问题，渲染成可点选的卡片（给 options → choice_list；给 fields → form）。何时用：真的被卡住（方向性选择、缺少无法合理默认的信息）。何时不要用：能用合理默认值推进时（直接做，并说明「按 xx 处理，要改告诉我」）。一次最多问一个问题。主人的回答会作为 ui_action 事件到达。',
    parameters: obj({
      question: S('问题'),
      options: A(obj({ id: S('选项 id'), label: S('选项'), detail: S('补充说明') }, ['id', 'label']), '选项（2–5 个）'),
      multi: B('是否多选'),
      fields: A(obj({
        key: S('字段 key'), label: S('字段名'), type: S('类型', { enum: ['text', 'number', 'date', 'time', 'select', 'toggle'] }),
        options: A({ type: 'string' }, 'select 的选项'), required: B('必填'), placeholder: S('占位'),
      }, ['key', 'label', 'type']), '表单字段（与 options 二选一）'),
      task_id: S('关联 task，会被标为 waiting_user'),
    }, ['question']),
    async run(a, rt) {
      const component = a.fields?.length ? 'form' : 'choice_list';
      const props = component === 'form' ? { title: a.question, fields: a.fields } : { question: a.question, options: a.options ?? [], multi: !!a.multi };
      const v = validateProps(component, props);
      if (!v.ok) return `提问失败：${v.error}`;
      const card = rt.state.renderCard({ component, props: v.props, msgId: rt.currentMsgId() });
      if (a.task_id) rt.state.updateTask(a.task_id, { status: 'waiting_user' });
      return { card_id: card.id, note: '已显示给主人，等待 ui_action 事件；现在可以 yield' };
    },
  },
  {
    name: 'request_approval',
    description: '请求主人批准一个高风险动作（花钱、下单、对外发送消息/邮件、删除数据、把 session 升级为 auto 完全访问）。会在 App 中显示审批卡片并推送通知。detail 必须写成多行，每行一项「标签：内容」（全角冒号），例如「餐厅：鮨 · 静安店」「时间：10月18日 周六 19:00」「费用：人均约 ¥280，到店付款」；最后单独再写一行以「批准后：」开头，说明主人批准后会发生什么，例如「批准后：我会向餐厅提交预订，并把结果告诉你」。App 会把「标签：内容」行排成表格，所以标签要短、每行只放一项，不要写成一整段话。非阻塞：立即返回 approval_id，主人的决定稍后作为 approval_result 事件到达；在此之前不要执行该动作。',
    parameters: obj({
      title: S('要批准什么，例如「在美团下单：鳗鱼饭 ×2，¥96」'),
      detail: S('多行「标签：内容」，一行一项（金额、对象、时间、内容、影响都按这个写），最后一行以「批准后：」开头说明批准后会发生什么。例如：\n餐厅：鮨 · 静安店\n时间：10月18日 周六 19:00\n费用：人均约 ¥280，到店付款\n批准后：我会向餐厅提交预订，并把结果告诉你'),
      risk: S('风险', { enum: ['low', 'medium', 'high'] }),
      task_id: S('关联 task'),
    }, ['title', 'detail']),
    async run(a, rt) {
      const risk = a.risk ?? 'high';
      const { approval } = rt.state.requestApproval({ title: a.title, detail: a.detail, risk, kind: 'action', requireBiometric: risk === 'high' });
      rt.state.renderCard({ component: 'approval_card', props: { approvalId: approval.id }, msgId: rt.currentMsgId() });
      rt.notifier.notify({ title: '需要你批准', body: a.title, level: 'timeSensitive', approvalId: approval.id });
      if (a.task_id) rt.state.updateTask(a.task_id, { status: 'waiting_user' });
      return { approval_id: approval.id, note: '等待 approval_result 事件' };
    },
  },
  {
    name: 'approval_decide',
    description: '代主人处理一条交给你判断的 Codex 审批（approval_needed 事件里 delegated=true 的中风险请求）。何时批准：明显服务于当前任务、只影响工作区或只读、不花钱不对外发送。拿不准就不要处理，留给主人（它已显示在 App 里）。',
    parameters: obj({ approval_id: S('approval id'), decision: S('决定', { enum: ['approve', 'deny'] }), reason: S('理由（会记录在审计日志）') }, ['approval_id', 'decision', 'reason']),
    async run(a, rt) {
      return rt.state.resolveApproval(a.approval_id, a.decision === 'approve', a.reason, 'butler') ? '已处理' : '该审批已被处理或已过期';
    },
  },
  {
    name: 'notify',
    description: '推送通知到主人手机。level：log=只记录不推送；silent=静默出现在通知中心；normal=普通提醒；timeSensitive=时效性（会突破专注模式，只用于真正紧急的事：马上要出发、票马上要没、日程冲突）。系统会自动处理勿扰时段、每日预算、主人正在看 App 的情况，并告诉你结果。注意：你在对话里输出的文字主人打开 App 就能看到，不需要每条都 notify；主人不在 App 时，你主动发出的消息系统会按 normal 自动推送一次，无需重复调用。',
    parameters: obj({ title: S('标题'), body: S('正文，一两句话'), level: S('级别', { enum: ['log', 'silent', 'normal', 'timeSensitive'] }) }, ['title', 'body', 'level']),
    async run(a, rt) { return rt.notifier.notify({ title: a.title, body: a.body, level: a.level as NotifyLevel }); },
  },

  // ─────────────────────────── 感知 ───────────────────────────
  {
    name: 'device_context_get',
    description: '读取主人手机最近一次上报的完整上下文（时区、位置、网络、专注模式、未来 24 小时日程、未完成提醒事项、上报时间）。状态栏里只有摘要，需要细节时用。邮件、云盘、日历详情等不在这里，用 connector_call 通过 ChatGPT 插件获取。',
    parameters: obj({}),
    async run(_a, rt) { return rt.device() ?? '主人的手机还没有上报过上下文'; },
  },
  {
    name: 'memory_write',
    description: '写入或更新一条关于主人的长期记忆。主人明确说「记住…/以后…/别忘了…」时 source=explicit，立即写入；系统会自动显示 memory_saved 卡片（主人可撤销），你不需要再 ui_render。从对话中推断的偏好用 source=inferred，作为候选，之后轻量确认一次再 memory_confirm。禁止写入密码、验证码、证件号、银行卡号等机密。已有相近记忆时传 replace_id 更新而不是新增。',
    parameters: obj({
      text: S('一句完整、自包含的陈述，例如「主人不吃香菜」「主人的公司地址是…」'),
      kind: S('类别', { enum: ['profile', 'preference', 'fact', 'person', 'place', 'date'] }),
      source: S('来源', { enum: ['explicit', 'inferred'] }),
      replace_id: S('要更新的记忆 id'),
      show_card: B('是否显示 memory_saved 卡片，explicit 默认 true'),
    }, ['text', 'kind', 'source']),
    async run(a, rt) {
      const m = rt.memory.write(a.text, a.kind, a.source, a.replace_id);
      if (a.source === 'explicit' && a.show_card !== false) {
        rt.state.renderCard({ component: 'memory_saved', props: { memoryId: m.id, text: m.text }, actions: [{ id: 'undo', label: '撤销', style: 'secondary' }], msgId: rt.currentMsgId() });
      }
      return { memory_id: m.id, status: a.source === 'explicit' ? 'active' : 'candidate' };
    },
  },
  {
    name: 'memory_confirm',
    description: '主人确认了一条候选记忆（inferred）后，把它转为正式记忆。何时用：你轻量问过一次「要我记住吗」且主人表示同意时。',
    parameters: obj({ memory_id: S('记忆 id') }, ['memory_id']),
    async run(a, rt) { return rt.memory.confirm(a.memory_id) ? '已确认' : '没有这条记忆'; },
  },
  {
    name: 'memory_search',
    description: '在主人的记忆里检索（关键词，支持中文）。何时用：要替主人做选择或写任务单前，查相关偏好/地址/人物/重要日期。系统提示里已有一份记忆摘要，摘要不够时再查。',
    parameters: obj({ query: S('关键词，多个用空格分隔') }, ['query']),
    async run(a, rt) { const r = rt.memory.search(a.query); return r.length ? r : '没有找到相关记忆'; },
  },
  {
    name: 'memory_delete',
    description: '删除一条记忆。何时用：主人要求忘记、记忆已过时或错误。注意：主人说「忘掉 xx」时先 memory_search 找到 id 再删，并告诉主人已删除。',
    parameters: obj({ memory_id: S('记忆 id') }, ['memory_id']),
    async run(a, rt) { return rt.memory.delete(a.memory_id) ? '已删除' : '没有这条记忆'; },
  },
  {
    name: 'import_list',
    description: '列出主人从手机导入的内容（照片、链接、文本/备忘录、文件、提醒事项）。默认只列未处理的。处理方法见 import-triage skill。',
    parameters: obj({ status: S('筛选', { enum: ['new', 'processed', 'ignored', 'all'] }) }),
    async run(a, rt) {
      const items = rt.state.imports(a.status === 'all' ? undefined : a.status ?? 'new');
      return items.map((i: any) => ({ id: i.id, kind: i.kind, title: i.title, text: i.text?.slice(0, 300), url: i.url, mime: i.mime, has_data: i.hasData }));
    },
  },
  {
    name: 'import_read',
    description: '读取一个导入项的完整内容；照片会以图片形式给你查看，文本文件给出正文。何时用：处理 import_received 事件、或主人随消息发来图片时。',
    parameters: obj({ import_id: S('导入项 id') }, ['import_id']),
    async run(a, rt) {
      const it = rt.state.imports().find((i: any) => i.id === a.import_id) ?? undefined;
      if (!it) return '没有这个导入项';
      const meta = { type: 'input_text' as const, text: JSON.stringify({ id: it.id, kind: it.kind, title: it.title, text: it.text, url: it.url, mime: it.mime }) };
      const blob = it.hasData ? rt.state.artifact(`import:${it.id}`) : undefined;
      if (blob && /^image\//.test(blob.mime)) return [meta, { type: 'input_image' as const, image_url: `data:${blob.mime};base64,${blob.body}`, detail: 'auto' as const }];
      if (blob && /^text\//.test(blob.mime)) return [meta, { type: 'input_text' as const, text: Buffer.from(blob.body, 'base64').toString('utf8').slice(0, 20000) }];
      return [meta];
    },
  },
  {
    name: 'import_mark',
    description: '把导入项标为已处理或忽略。何时用：每个导入项处理完（已建日程、已存记忆、已生成表格或判断无需处理）后调用，避免重复处理。',
    parameters: obj({ import_ids: A({ type: 'string' }, 'id 列表'), status: S('状态', { enum: ['processed', 'ignored'] }) }, ['import_ids', 'status']),
    async run(a, rt) { for (const id of a.import_ids) rt.state.markImport(id, a.status); return 'ok'; },
  },
  {
    name: 'artifact_read',
    description: '读取被折叠存放的长内容（工具结果或 session 交付过长时，系统会存为 artifact 并给你 id 和摘要）。',
    parameters: obj({ artifact_id: S('artifact id'), offset: N('起始字符，默认 0'), length: N('长度，默认 8000') }, ['artifact_id']),
    async run(a, rt) {
      const art = rt.state.artifact(a.artifact_id);
      if (!art) return '没有这个 artifact';
      const off = a.offset ?? 0, len = Math.min(a.length ?? 8000, 20000);
      return { title: art.title, total: art.body.length, offset: off, content: art.body.slice(off, off + len) };
    },
  },
];

function checkPermission(p: Permission | undefined, approvalId: string | undefined, rt: Rt): Permission {
  const want = p ?? rt.settings().defaultPermission;
  if (want !== 'auto' || rt.settings().allowAutoFullAccess) return want;
  if (approvalId && rt.state.approvalStatus(approvalId) === 'approved') return 'auto';
  throw new Error('auto（完全访问）需要主人批准：先 request_approval 说明原因，收到 approve 的 approval_result 后再带 approval_id 调用');
}

export const TOOL_MAP = new Map(TOOLS.map((t) => [t.name, t]));
