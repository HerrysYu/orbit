// Host-driven phone tasks. The Host owns the loop: every step is one fresh, tool-less model call that sees the task, the
// text conclusions of the earlier steps, the current UI tree and the latest screenshot — never an old screenshot. The old
// way (a Codex worker thread driving orbit_phone itself, re-sending every screenshot each step) stays as `OPA_PHONE_MODE=codex`.
import { log, uid } from '../util/log.ts';
import { redactPhoneParams, type McpToolResult, type StepTurnOpts, type StepTurnResult } from '../codex/bridge.ts';
import type { Session } from '../types.ts';
import {
  STEP_OUTPUT_SCHEMA, buildStepInput, buildStepSystemPrompt, cutText, historyLine, parseStepOutput, type StepDecision,
} from './step-prompt.ts';

/** The slice of CodexBridge the runner uses (a fake one in tests). */
export interface PhoneRunnerBridge {
  stepTurn(o: StepTurnOpts): Promise<StepTurnResult>;
  openPhoneExecutor(): Promise<string>;
  closePhoneExecutor?(threadId: string): Promise<void> | void;
  phoneTool(threadId: string, tool: string, args?: Record<string, unknown>): Promise<McpToolResult>;
  emit(event: string, payload: unknown): unknown;
}

export interface PhoneRunnerOptions {
  bridge: PhoneRunnerBridge;
  /** Model and effort for the next step call; looked up again every step so a changed setting applies at once. */
  resolve(): { model?: string; effort?: string };
  syncSession(id: string, patch: Partial<Session>): unknown;
  audit(actor: string, action: string, detail: unknown): void;
  now?: () => number;
  /** Overrides OPA_PHONE_MAX_STEPS (default 60). */
  maxSteps?: number;
  /** Per model call; defaults to the bridge's 120 s. */
  stepTimeoutMs?: number;
}

export interface PhoneStartOpts { title: string; goal: string; china: boolean; deliverable?: string; taskId?: string }

export type PhoneRunEnd = 'done' | 'partial' | 'needs_human' | 'failed' | 'cancelled' | 'busy';
export type PhoneRunState = 'running' | PhoneRunEnd;

export interface PhoneRunInfo {
  id: string;
  title: string;
  status: PhoneRunState;
  steps: number;
  maxSteps: number;
  /** What the model is shown as history, one line per step. */
  notes: string[];
  model?: string;
  summary?: string;
  startedAt: number;
  endedAt?: number;
  usage: { calls: number; inputTokens: number; cachedInputTokens: number; outputTokens: number };
}

const DEFAULT_MAX_STEPS = 60;
const MAX_CONSECUTIVE_ERRORS = 3;
const MAX_MODEL_TRIES = 2;
const LIFECYCLE_TIMEOUT_MS = 30_000;
const KEEP_FINISHED_RUNS = 30;

/** Session ids of step-driven runs; they are not Codex threads, so the Codex-session tools hand them to the runner. */
export const isPhoneRunId = (id: unknown): boolean => typeof id === 'string' && id.startsWith('phone_');

/** `OPA_PHONE_MAX_STEPS`: how many steps a run may take before it ends as `partial`. */
export function phoneMaxSteps(env: NodeJS.ProcessEnv = process.env): number {
  const n = Number.parseInt(env.OPA_PHONE_MAX_STEPS ?? '', 10);
  return Number.isFinite(n) && n > 0 ? Math.min(n, 500) : DEFAULT_MAX_STEPS;
}

interface Shot { data: string; mimeType: string }
interface Observation { shot: Shot; json: Record<string, any> }
interface ToolOut { status: string; message?: string; isError: boolean; json: Record<string, any>; shot?: Shot }
interface Outcome { status: PhoneRunEnd; summary: string; result?: unknown; needs?: string; error?: string }
type Begin = { kind: 'ok'; obs: Observation } | { kind: 'busy'; owner: unknown } | { kind: 'cancelled' } | { kind: 'fail'; message: string };
type Decision = { kind: 'step'; step: StepDecision } | { kind: 'cancelled' } | { kind: 'fail'; message: string };

interface Run {
  id: string;
  title: string;
  goal: string;
  china: boolean;
  deliverable?: string;
  taskId?: string;
  abort: AbortController;
  state: PhoneRunState;
  maxSteps: number;
  steps: number;
  notes: string[];
  items: { kind: string; text: string; ts: number }[];
  model?: string;
  summary?: string;
  executor?: string;
  startedAt: number;
  endedAt?: number;
  usage: PhoneRunInfo['usage'];
  done: Promise<void>;
}

const isObj = (v: unknown): v is Record<string, any> => Boolean(v) && typeof v === 'object' && !Array.isArray(v);
const errMsg = (e: unknown) => (e instanceof Error ? e.message : String(e));

/** Pull the screenshot and the status JSON out of a raw MCP tool result. */
export function parseToolResult(raw: unknown): ToolOut {
  const r = (isObj(raw) ? raw : {}) as McpToolResult;
  let json: Record<string, any> = isObj(r.structuredContent) ? { ...r.structuredContent } : {};
  let shot: Shot | undefined;
  for (const c of Array.isArray(r.content) ? r.content : []) {
    if (!isObj(c)) continue;
    if (c.type === 'image' && typeof c.data === 'string' && c.data) {
      shot ??= { data: c.data, mimeType: String(c.mimeType ?? c.mime_type ?? 'image/jpeg') };
    } else if (c.type === 'text' && typeof c.text === 'string' && Object.keys(json).length === 0) {
      try {
        const v = JSON.parse(c.text);
        if (isObj(v)) json = v;
      } catch { /* not JSON: ignore */ }
    }
  }
  const isError = Boolean(r.isError);
  const status = typeof json.status === 'string' ? json.status : isError ? 'error' : 'ok';
  return { status, message: typeof json.message === 'string' ? json.message : undefined, isError, json, shot };
}

/** What the model decided → the orbit_phone tool and arguments (matching phone/orbit_phone/server.py). */
function toolFor(step: StepDecision): { tool: string; args: Record<string, unknown> } {
  switch (step.action) {
    case 'tap': return { tool: 'phone_tap', args: { x: step.x, y: step.y } };
    case 'double_tap': return { tool: 'phone_double_tap', args: { x: step.x, y: step.y } };
    case 'long_press': return { tool: 'phone_long_press', args: { x: step.x, y: step.y, ...(step.ms ? { ms: step.ms } : {}) } };
    case 'swipe': return { tool: 'phone_swipe', args: { x1: step.x, y1: step.y, x2: step.x2, y2: step.y2, ...(step.ms ? { ms: step.ms } : {}) } };
    case 'type': return { tool: 'phone_type', args: { text: step.text } };
    case 'clear_text': return { tool: 'phone_clear_text', args: {} };
    case 'back': return { tool: 'phone_back', args: {} };
    case 'home': return { tool: 'phone_home', args: {} };
    case 'launch': return { tool: 'phone_launch', args: { app: step.app } };
    case 'wait': return { tool: 'phone_wait', args: { seconds: step.seconds ?? 2 } };
    default: throw new Error(`${step.action} is not a phone action`);
  }
}

/** `result` may itself be a JSON string (the deliverable); hand structured data on as structured data. */
function resultValue(result: string | undefined): unknown {
  if (result === undefined) return undefined;
  try { return JSON.parse(result); } catch { return result; }
}

async function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  try {
    return await Promise.race([p, new Promise<T>((_, reject) => { timer = setTimeout(() => reject(new Error(`timed out after ${ms} ms`)), ms); })]);
  } finally {
    clearTimeout(timer);
  }
}

export class PhoneRunner {
  private readonly runs = new Map<string, Run>();
  private readonly o: PhoneRunnerOptions;
  private readonly now: () => number;

  constructor(o: PhoneRunnerOptions) {
    this.o = o;
    this.now = o.now ?? Date.now;
  }

  /** Starts a run in the background and returns at once; the outcome arrives as the bridge's `turn_completed`. */
  start(opts: PhoneStartOpts): { id: string } {
    const id = uid('phone_');
    const run: Run = {
      id, title: opts.title, goal: opts.goal, china: opts.china, deliverable: opts.deliverable, taskId: opts.taskId,
      abort: new AbortController(), state: 'running', maxSteps: this.o.maxSteps ?? phoneMaxSteps(), steps: 0,
      notes: [], items: [], startedAt: this.now(),
      usage: { calls: 0, inputTokens: 0, cachedInputTokens: 0, outputTokens: 0 },
      done: Promise.resolve(),
    };
    this.prune();
    this.runs.set(id, run);
    run.done = this.execute(run).catch((e) => log.error('phone', `run ${id} crashed`, e));
    return { id };
  }

  /** Stop a running run: the loop ends at the next check, the phone is told to cancel now. False if there is no such running run. */
  cancel(id: string): boolean {
    const run = this.runs.get(id);
    if (!run || run.state !== 'running') return false;
    if (!run.abort.signal.aborted) {
      run.abort.abort();
      if (run.executor) void this.tool(run, 'phone_cancel', { only_owned: true }, 'tool-call');
    }
    return true;
  }

  cancelAll(): number {
    let n = 0;
    for (const id of this.runs.keys()) if (this.cancel(id)) n++;
    return n;
  }

  has(id: string): boolean { return this.runs.has(id); }

  /** Ids of the runs that have not ended yet. */
  running(): string[] { return [...this.runs.values()].filter((r) => r.state === 'running').map((r) => r.id); }

  status(id: string): PhoneRunInfo | undefined {
    const r = this.runs.get(id);
    if (!r) return undefined;
    return {
      id: r.id, title: r.title, status: r.state, steps: r.steps, maxSteps: r.maxSteps, notes: [...r.notes], model: r.model,
      summary: r.summary, startedAt: r.startedAt, endedAt: r.endedAt, usage: { ...r.usage },
    };
  }

  /** The action log for the app's session detail. */
  history(id: string): { kind: string; text: string; ts: number }[] {
    return (this.runs.get(id)?.items ?? []).map((i) => ({ ...i }));
  }

  /** Resolves when the run (or, without an id, every run) has ended and delivered. */
  async finished(id?: string): Promise<void> {
    if (id) { await this.runs.get(id)?.done; return; }
    await Promise.all([...this.runs.values()].map((r) => r.done));
  }

  // ───────────── the run ─────────────

  private async execute(run: Run): Promise<void> {
    const cfg = this.resolveModel();
    run.model = cfg.model;
    this.sync(run.id, {
      title: run.title.trimStart().startsWith('📱') ? run.title : `📱 ${run.title}`,
      status: 'running', permission: 'manual', taskId: run.taskId, model: run.model,
    });
    this.item(run, 'userMessage', `任务：${cutText(run.goal, 300)}`);
    let outcome: Outcome;
    try {
      outcome = await this.drive(run);
    } catch (e) {
      log.error('phone', `run ${run.id} failed`, e);
      outcome = { status: 'failed', summary: `手机任务出错：${errMsg(e)}`, error: errMsg(e) };
    }
    await this.deliver(run, outcome);
  }

  private async drive(run: Run): Promise<Outcome> {
    const signal = run.abort.signal;
    const cancelled = (): Outcome => ({ status: 'cancelled', summary: '手机任务已取消。' });
    const fail = (message: string): Outcome => ({ status: 'failed', summary: message, error: message });
    const busy = (owner: unknown): Outcome => ({ status: 'busy', summary: '手机正被另一个任务占用，本任务没有开始。', result: owner, error: '手机忙' });

    try {
      run.executor = await this.o.bridge.openPhoneExecutor();
    } catch (e) {
      return fail(`手机工具不可用：${errMsg(e)}`);
    }
    if (signal.aborted) return cancelled();

    const first = await this.begin(run);
    if (first.kind === 'cancelled') return cancelled();
    if (first.kind === 'busy') return busy(first.owner);
    if (first.kind === 'fail') return fail(first.message);
    let obs = first.obs;

    let errors = 0;
    for (let n = 1; n <= run.maxSteps; n++) {
      if (signal.aborted) return cancelled();
      const decided = await this.decide(run, n, obs);
      if (decided.kind === 'cancelled') return cancelled();
      if (decided.kind === 'fail') return fail(decided.message);
      const step = decided.step;
      run.steps = n;

      if (step.action === 'done' || step.action === 'needs_human' || step.action === 'fail') {
        this.record(run, n, step, '', true);
        const note = step.note || (step.action === 'done' ? '任务完成。' : '');
        if (step.action === 'done') return { status: 'done', summary: note, result: resultValue(step.result) };
        if (step.action === 'needs_human') return { status: 'needs_human', summary: note || '需要主人处理。', needs: step.result ?? note };
        const why = [note, step.result].filter(Boolean).join('：');
        return { status: 'failed', summary: why || '任务无法继续。', result: resultValue(step.result), error: why };
      }

      const { tool, args } = toolFor(step);
      this.auditCall(run, 'step', tool, args);
      const out = await this.call(run, tool, { ...args, include_tree: true });
      if (signal.aborted || out.status === 'cancelled') return cancelled();

      if (!out.isError && out.status === 'ok') {
        errors = 0;
        if (out.shot) obs = { shot: out.shot, json: out.json };
        this.record(run, n, step, 'ok');
        continue;
      }
      errors++;
      const why = out.message ?? out.status;
      this.record(run, n, step, `错误：${cutText(why, 80)}`);
      if (errors >= MAX_CONSECUTIVE_ERRORS) return fail(`手机工具连续出错 ${errors} 次：${why}`);
      // An ADB failure makes the phone service let go of the device, so the next call would only say "not started": take it again.
      if (out.status === 'error' || out.status === 'not_started') {
        const again = await this.begin(run);
        if (again.kind === 'cancelled') return cancelled();
        if (again.kind === 'busy') return busy(again.owner);
        if (again.kind === 'fail') return fail(`手机连接中断：${again.message}`);
        obs = again.obs;
      }
    }

    const last = run.notes.slice(-5);
    return {
      status: 'partial',
      summary: `已走完 ${run.maxSteps} 步上限，任务还没结束。最后进展：${last[last.length - 1] ?? '（无）'}`,
      result: last,
    };
  }

  /** phone_begin: take the device and get the first observation. */
  private async begin(run: Run): Promise<Begin> {
    this.auditCall(run, 'tool-call', 'phone_begin', { task: run.title });
    const out = await this.call(run, 'phone_begin', { task: cutText(run.title, 80) });
    if (run.abort.signal.aborted && out.status === 'cancelled') return { kind: 'cancelled' };
    switch (out.status) {
      case 'started':
      case 'already_started':
        return out.shot ? { kind: 'ok', obs: { shot: out.shot, json: out.json } } : { kind: 'fail', message: '手机没有返回截图' };
      case 'busy': return { kind: 'busy', owner: out.json.owner ?? null };
      case 'cancelled': return { kind: 'cancelled' };
      case 'unavailable': return { kind: 'fail', message: `手机不可用：${out.message ?? '没有可用的设备'}` };
      default: return { kind: 'fail', message: `手机启动失败：${out.message ?? out.status}` };
    }
  }

  /** One model call (retried once if it failed or answered with something unusable). */
  private async decide(run: Run, n: number, obs: Observation): Promise<Decision> {
    const signal = run.abort.signal;
    const system = buildStepSystemPrompt({ china: run.china });
    let correction: string | undefined;
    let problem = '';
    for (let attempt = 0; attempt < MAX_MODEL_TRIES; attempt++) {
      if (signal.aborted) return { kind: 'cancelled' };
      const cfg = this.resolveModel();
      const input = buildStepInput({
        goal: run.goal, deliverable: run.deliverable, history: run.notes, step: n, maxSteps: run.maxSteps,
        foreground: obs.json.foreground, screen: obs.json.screen, isSensitive: obs.json.is_sensitive === true,
        uiTree: obs.json.ui_tree, image: obs.shot, correction,
      });
      let r: StepTurnResult;
      try {
        r = await this.o.bridge.stepTurn({
          model: cfg.model, effort: cfg.effort, baseInstructions: system, input, outputSchema: STEP_OUTPUT_SCHEMA, signal,
          ...(this.o.stepTimeoutMs ? { timeoutMs: this.o.stepTimeoutMs } : {}),
        });
      } catch (e) {
        r = { status: 'failed', text: '', error: errMsg(e) };
      }
      this.addUsage(run, r);
      if (signal.aborted) return { kind: 'cancelled' };
      if (r.status !== 'completed') {
        problem = r.error ?? `模型调用没有完成（${r.status}）`;
        correction = undefined;
        continue;
      }
      const parsed = parseStepOutput(r.text);
      if (parsed.ok) return { kind: 'step', step: parsed.step };
      problem = `模型的输出不合法（${parsed.reason}）`;
      correction = `你上一次的输出不能用：${parsed.reason}。这次只输出一个符合 schema 的 JSON 对象，不要加其他文字。`;
    }
    return { kind: 'fail', message: `第 ${n} 步没能得到可执行的动作：${problem}` };
  }

  // ───────────── finishing ─────────────

  private async deliver(run: Run, outcome: Outcome): Promise<void> {
    let evidence: string | undefined;
    if (run.executor) {
      if (outcome.status === 'cancelled') await this.lifecycle(run, 'phone_cancel', { only_owned: true });
      const end = await this.lifecycle(run, 'phone_end', { summary: cutText(outcome.summary, 300) });
      const path = end?.json.evidence ?? end?.json.screenshot;
      if (typeof path === 'string' && path) evidence = path;
      try { await this.o.bridge.closePhoneExecutor?.(run.executor); } catch { /* best effort */ }
    }

    run.state = outcome.status;
    run.summary = outcome.summary;
    run.endedAt = this.now();
    const payload = {
      status: outcome.status,
      summary: outcome.summary,
      result: outcome.result ?? null,
      needs: outcome.needs ?? null,
      evidence: evidence ?? null,
      steps: run.steps,
      model: run.model ?? null,
    };
    const text = `\`\`\`json\n${JSON.stringify(payload, null, 2)}\n\`\`\``;
    this.item(run, 'agentMessage', `${outcome.status}：${cutText(outcome.summary, 300)}`);
    try {
      this.o.audit('phone', 'run-end', { run: run.id, status: outcome.status, steps: run.steps, usage: run.usage });
    } catch (e) { log.error('phone', 'audit failed', e); }

    const failed = outcome.status === 'failed' || outcome.status === 'busy';
    // The session settles first: the event below wakes the butler, and it must not see the phone as still busy.
    this.sync(run.id, { status: failed ? 'error' : 'idle', lastActivity: cutText(outcome.summary, 100) });
    const status = outcome.status === 'cancelled' ? 'interrupted' : failed ? 'failed' : 'completed';
    this.emit('turn_completed', { threadId: run.id, status, text, ...(failed ? { error: outcome.error ?? outcome.summary } : {}) });
  }

  // ───────────── helpers ─────────────

  /** Remember one finished step: history line for the next prompt, action log for the app, progress for the butler. */
  private record(run: Run, n: number, step: StepDecision, outcome: string, terminal = false): void {
    const note = step.note || (terminal ? '' : '（模型没有写说明）');
    const line = historyLine(n, step, outcome || step.action, note);
    if (!terminal) run.notes.push(line);
    this.item(run, 'mcpToolCall', line);
    const text = cutText(note, 200);
    if (text) this.emit('activity', { threadId: run.id, text });
    this.sync(run.id, { lastActivity: cutText(`第 ${n} 步：${note}`, 100), ...(run.model ? { model: run.model } : {}) });
  }

  private item(run: Run, kind: string, text: string): void {
    run.items.push({ kind, text, ts: this.now() });
    if (run.items.length > 200) run.items.splice(0, run.items.length - 200);
  }

  private addUsage(run: Run, r: StepTurnResult): void {
    run.usage.calls++;
    run.usage.inputTokens += r.usage?.inputTokens ?? 0;
    run.usage.cachedInputTokens += r.usage?.cachedInputTokens ?? 0;
    run.usage.outputTokens += r.usage?.outputTokens ?? 0;
    // The first answer tells which model "自动" really picked.
    if (r.model && !run.model) {
      run.model = r.model;
      this.sync(run.id, { model: r.model });
    }
  }

  private resolveModel(): { model?: string; effort?: string } {
    try { return this.o.resolve() ?? {}; } catch (e) { log.warn('phone', `resolve failed: ${errMsg(e)}`); return {}; }
  }

  /** A phone tool call on the run's executor thread; never throws. */
  private async call(run: Run, tool: string, args: Record<string, unknown>): Promise<ToolOut> {
    try {
      return parseToolResult(await this.o.bridge.phoneTool(run.executor!, tool, args));
    } catch (e) {
      return { status: 'error', message: errMsg(e), isError: true, json: {} };
    }
  }

  /** begin / end / cancel: audited, bounded in time, never throws. */
  private async lifecycle(run: Run, tool: string, args: Record<string, unknown>): Promise<ToolOut | undefined> {
    this.auditCall(run, 'tool-call', tool, args);
    try {
      return parseToolResult(await withTimeout(this.o.bridge.phoneTool(run.executor!, tool, args), LIFECYCLE_TIMEOUT_MS));
    } catch (e) {
      log.warn('phone', `${tool} failed for ${run.id}: ${errMsg(e)}`);
      return undefined;
    }
  }

  private async tool(run: Run, tool: string, args: Record<string, unknown>, action: string): Promise<void> {
    this.auditCall(run, action, tool, args);
    try { await withTimeout(this.o.bridge.phoneTool(run.executor!, tool, args), LIFECYCLE_TIMEOUT_MS); } catch { /* the loop's own cleanup covers it */ }
  }

  private auditCall(run: Run, action: string, tool: string, args: Record<string, unknown>): void {
    try {
      this.o.audit('phone', action, { run: run.id, tool, params: redactPhoneParams(tool, args) });
    } catch (e) { log.error('phone', `failed to audit ${tool}`, e); }
  }

  private sync(id: string, patch: Partial<Session>): void {
    try { this.o.syncSession(id, patch); } catch (e) { log.error('phone', `syncSession failed for ${id}`, e); }
  }

  private emit(event: string, payload: unknown): void {
    try { this.o.bridge.emit(event, payload); } catch (e) { log.error('phone', `listener for ${event} failed`, e); }
  }

  /** Keep the table of finished runs small. */
  private prune(): void {
    const done = [...this.runs.values()].filter((r) => r.state !== 'running');
    for (const r of done.slice(0, Math.max(0, done.length - KEEP_FINISHED_RUNS + 1))) this.runs.delete(r.id);
  }
}
