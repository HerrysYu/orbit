// Codex Bridge: wraps `codex app-server` into "sessions" the butler can drive — 方案 §3.
import { EventEmitter } from 'node:events';
import { mkdirSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { CodexRpc } from './rpc.ts';
import { log } from '../util/log.ts';
import { OPA_HOME } from '../store/db.ts';
import { DEFAULT_PHONE_SERIAL, phoneConfigStatus, type PhoneMcpConfig } from '../phone/config.ts';
import type { Permission, Risk } from '../types.ts';
import type { ThreadStartParams } from './protocol/v2/ThreadStartParams.ts';
import type { ThreadStartResponse } from './protocol/v2/ThreadStartResponse.ts';
import type { TurnStartParams } from './protocol/v2/TurnStartParams.ts';
import type { TurnStartResponse } from './protocol/v2/TurnStartResponse.ts';
import type { ThreadItem } from './protocol/v2/ThreadItem.ts';
import type { SandboxPolicy } from './protocol/v2/SandboxPolicy.ts';
import type { UserInput } from './protocol/v2/UserInput.ts';
import type { Model } from './protocol/v2/Model.ts';
import type { AppInfo } from './protocol/v2/AppInfo.ts';
import type { TokenUsageBreakdown } from './protocol/v2/TokenUsageBreakdown.ts';
import type { JsonValue } from './protocol/serde_json/JsonValue.ts';

export const SKILLS_DIR = join(import.meta.dirname, '../../../skills');
export const WORKSPACE = join(OPA_HOME, 'workspace');

/** Appended to every worker session so sandbox denials turn into approval requests instead of silent failures. */
const WORKER_INSTRUCTIONS = `你是 Orbit（主人的私人 AI 伙伴）派出的执行者。任务单来自 Orbit，结果也交回给 Orbit。
- 默认工作目录是 ${WORKSPACE}，临时文件放这里。
- 如果操作因为沙箱/权限限制失败（例如 operation not permitted、写入工作区外的路径、需要联网），不要放弃：用提权方式重新请求执行该命令（会进入审批流程，由 Orbit 或主人批准）。
- 不要伪造结果；没完成就说明卡在哪一步。`;

/** What the bridge asks the policy layer to decide. */
export interface ApprovalAsk {
  threadId: string;
  kind: 'command' | 'fileChange' | 'permissions' | 'elicitation' | 'userInput';
  title: string;
  detail: string;
  risk: Risk;
  raw: unknown;
}
export type ApprovalDecision = { approve: boolean; forSession?: boolean; answers?: Record<string, string[]>; content?: unknown };
export type ApprovalHandler = (ask: ApprovalAsk) => Promise<ApprovalDecision>;

export interface LiveSession {
  threadId: string;
  title: string;
  model?: string;
  permission: Permission;
  activeTurnId?: string;
  status: 'running' | 'idle' | 'waiting_approval' | 'error' | 'archived';
  lastAgentText?: string;      // final agentMessage of the last completed turn
  lastActivity?: string;       // short human description of the latest item
  lastError?: string;
  plan?: { step: string; status: string }[];
  turns: number;
  phone?: boolean;
  phoneEndSeen?: boolean;
  phoneBeginInFlight?: boolean;
  phoneLockHeld?: boolean;
  phoneMcpCalls?: Map<string, { tool: string; params: unknown }>;
}

export interface CreateSessionOpts {
  title: string;
  prompt: string;
  model?: string;
  effort?: string;
  cwd?: string;
  permission?: Permission;
  developerInstructions?: string;
  skills?: string[];          // skill folder names under skills/ to attach as skill inputs
  outputSchema?: unknown;     // JSON schema for the final message
  phone?: boolean;
  signal?: AbortSignal;
}

/** One model call of the step-driven phone runner (see `stepTurn`). */
export interface StepTurnOpts {
  model?: string;
  effort?: string;
  baseInstructions: string;
  input: UserInput[];
  outputSchema: unknown;
  signal?: AbortSignal;
  /** Default 120 s. On expiry the turn is interrupted and the call resolves as failed. */
  timeoutMs?: number;
}
export interface StepTurnResult {
  status: 'completed' | 'interrupted' | 'failed';
  /** The last agentMessage of the turn ('' when there was none). */
  text: string;
  /** `thread/tokenUsage/updated` → `last`. */
  usage?: TokenUsageBreakdown;
  error?: string;
  /** The model the throwaway thread actually ran on. */
  model?: string;
}
/** What `mcpServer/tool/call` returns: the MCP result as the server produced it. */
export interface McpToolResult { content?: any[]; structuredContent?: any; isError?: boolean; _meta?: unknown }

export const PHONE_MCP_SERVER = 'orbit_phone';
const STEP_TURN_TIMEOUT_MS = 120_000;
const PHONE_TOOL_TIMEOUT_MS = 150_000;
const STEP_CONFIG_TTL_MS = 10 * 60_000;
/** Built-in Codex abilities a phone step / executor thread must not have: it decides or relays, it never acts on the Mac. */
const STEP_FEATURES_OFF = {
  shell_tool: false, apps: false, plugins: false, multi_agent: false, skill_search: false, computer_use: false, goals: false, sleep_tool: false,
} as const;
type ThreadConfig = NonNullable<ThreadStartParams['config']>;
const isRecord = (v: unknown): v is { [key: string]: JsonValue } => Boolean(v) && typeof v === 'object' && !Array.isArray(v);

/**
 * Bridge events (all carry threadId):
 *  'turn_started' | 'turn_completed' {status, text?, error?} | 'status' {status} | 'activity' {text}
 *  | 'plan' {plan} | 'goal' {goal}
 */
export class CodexBridge extends EventEmitter {
  readonly rpc: CodexRpc;
  readonly sessions = new Map<string, LiveSession>();
  approvalHandler: ApprovalHandler = async () => ({ approve: false });
  audit: (actor: string, action: string, detail: unknown) => void = () => {};
  /** Handles `item/tool/call` for dynamic tools; return undefined if the thread is not yours. */
  dynamicToolHandler: (p: { threadId: string; tool: string; arguments: any; callId: string }) => Promise<{ success: boolean; contentItems: any[] } | undefined> = async () => undefined;
  private subscribed = new Set<string>();
  private elicitationOk = new Set<string>();
  private ready?: Promise<void>;
  private utilThreadId?: string;
  private restartTimer?: NodeJS.Timeout;
  private stepModelCache?: string;
  private mcpNamesCache?: { names: string[]; at: number };
  private mcpOverrideBroken = false;

  constructor(rpc = new CodexRpc()) {
    super();
    this.rpc = rpc;
    rpc.on('notification', (m: string, p: any) => this.onNotification(m, p));
    rpc.on('request', (id: number | string, m: string, p: any) => void this.onServerRequest(id, m, p));
    rpc.on('exit', (code: number) => {
      this.ready = undefined;
      this.subscribed.clear();
      this.emit('restarted');
      for (const s of this.sessions.values()) {
        if (s.phone && (s.activeTurnId || s.status === 'running' || s.status === 'waiting_approval')) markPhoneCancellation(s);
        if (s.status === 'running') this.setStatus(s, 'error', 'codex 进程重启');
      }
      // One pending restart at most: a start() from elsewhere that fails in the meantime must not add a second loop.
      if (this.restartTimer) return;
      log.warn('codex', `app-server exited (${code}); restarting in 3s`);
      this.restartTimer = setTimeout(() => {
        this.restartTimer = undefined;
        void this.start().catch((e) => log.error('codex', e?.message ?? e));
      }, 3000);
    });
  }

  start(): Promise<void> {
    if (this.ready) return this.ready;
    mkdirSync(WORKSPACE, { recursive: true });
    this.ready = (async () => {
      this.rpc.start();
      await this.rpc.request('initialize', {
        clientInfo: { name: 'opa', title: 'OpenPersonalAgent', version: '0.1.0' },
        capabilities: { experimentalApi: true },
      });
      this.rpc.notify('initialized');
      this.utilThreadId = undefined;
      log.info('codex', 'app-server ready');
    })();
    return this.ready;
  }

  isSubscribed(threadId: string) { return this.subscribed.has(threadId); }
  markSubscribed(threadId: string) { this.subscribed.add(threadId); }

  // ───────────── permissions ─────────────

  private policyFor(p: Permission): { approvalPolicy: 'on-request' | 'never'; sandbox: 'workspace-write' | 'danger-full-access'; sandboxPolicy: SandboxPolicy } {
    return p === 'auto'
      ? { approvalPolicy: 'never', sandbox: 'danger-full-access', sandboxPolicy: { type: 'dangerFullAccess' } }
      : {
        approvalPolicy: 'on-request', sandbox: 'workspace-write',
        sandboxPolicy: { type: 'workspaceWrite', writableRoots: [WORKSPACE], networkAccess: true, excludeTmpdirEnvVar: false, excludeSlashTmp: false },
      };
  }

  // ───────────── sessions ─────────────

  async createSession(o: CreateSessionOpts): Promise<LiveSession> {
    throwIfAborted(o.signal);
    const phoneStatus = o.phone ? phoneConfigStatus() : undefined;
    if (o.phone && !phoneStatus?.config) {
      throw new Error(phoneStatus?.reason ?? '手机工具不可用；请运行 opa phone setup。');
    }
    await this.start();
    const model = o.model ?? await this.defaultModel();
    throwIfAborted(o.signal);
    const permission = o.permission ?? 'manual';
    const pol = this.policyFor(permission);
    const params: ThreadStartParams = {
      model,
      cwd: o.cwd ?? WORKSPACE,
      approvalPolicy: pol.approvalPolicy,
      sandbox: pol.sandbox,
      developerInstructions: o.developerInstructions ? `${WORKER_INSTRUCTIONS}\n\n${o.developerInstructions}` : WORKER_INSTRUCTIONS,
      serviceName: 'opa',
      ...(phoneStatus?.config ? {
        config: phoneThreadConfig(phoneStatus.config),
      } : {}),
    };
    const res = await this.rpc.request<ThreadStartResponse>('thread/start', params);
    if (o.signal?.aborted) {
      await this.rpc.request('thread/archive', { threadId: res.thread.id }).catch(() => {});
      throw phoneTaskAbortError();
    }
    const sessionTitle = o.phone && !isPhoneTitle(o.title) ? `📱 ${o.title}` : o.title;
    const s: LiveSession = {
      threadId: res.thread.id, title: sessionTitle, model: res.model, permission, status: 'idle', turns: 0,
      phone: Boolean(o.phone || isPhoneTitle(o.title)), phoneMcpCalls: new Map(),
    };
    this.sessions.set(s.threadId, s);
    this.subscribed.add(s.threadId);
    await this.rpc.request('thread/name/set', { threadId: s.threadId, name: `🤵 ${sessionTitle}` }).catch(() => {});
    const abortListener = () => { void this.interrupt(s.threadId).catch(() => {}); };
    o.signal?.addEventListener('abort', abortListener, { once: true });
    try {
      throwIfAborted(o.signal);
      await this.send(s.threadId, o.prompt, { effort: o.effort, skills: o.skills, outputSchema: o.outputSchema, signal: o.signal });
      throwIfAborted(o.signal);
    } catch (e) {
      if (o.signal?.aborted) {
        await this.archive(s.threadId).catch(() => {});
        this.sessions.delete(s.threadId);
        this.subscribed.delete(s.threadId);
        throw phoneTaskAbortError();
      }
      if (s.phone) await this.cancelPhoneWorker(s);
      throw e;
    } finally {
      o.signal?.removeEventListener('abort', abortListener);
    }
    return s;
  }

  /** Start a new turn, or steer the active one. */
  async send(threadId: string, text: string, o: { effort?: string; model?: string; skills?: string[]; outputSchema?: unknown; permission?: Permission; signal?: AbortSignal } = {}): Promise<'started' | 'steered'> {
    throwIfAborted(o.signal);
    await this.start();
    const s = await this.ensureLoaded(threadId);
    throwIfAborted(o.signal);
    const input: UserInput[] = [{ type: 'text', text, text_elements: [] }];
    for (const name of o.skills ?? []) input.push({ type: 'skill', name, path: join(SKILLS_DIR, name, 'SKILL.md') });

    if (s.activeTurnId) {
      await this.rpc.request('turn/steer', { threadId, input, expectedTurnId: s.activeTurnId });
      return 'steered';
    }
    if (o.permission) s.permission = o.permission;
    const pol = this.policyFor(s.permission);
    const params: TurnStartParams = {
      threadId, input,
      approvalPolicy: pol.approvalPolicy,
      sandboxPolicy: pol.sandboxPolicy,
      model: o.model ?? null,
      effort: (o.effort as any) ?? null,
      outputSchema: (o.outputSchema as any) ?? null,
    };
    throwIfAborted(o.signal);
    s.phoneEndSeen = false;
    s.phoneMcpCalls?.clear();
    let res: TurnStartResponse;
    try {
      res = await this.rpc.request<TurnStartResponse>('turn/start', params);
    } catch (e) {
      if (s.phone) markPhoneCancellation(s);
      throw e;
    }
    s.activeTurnId = res.turn.id;
    s.turns++;
    // turn/start with a model switches the thread to it from this turn on, so what the app shows must follow.
    // Set before setStatus: that emits 'status', which the butler turns into a session sync.
    if (o.model) s.model = o.model;
    this.setStatus(s, 'running');
    throwIfAborted(o.signal);
    return 'started';
  }

  async interrupt(threadId: string): Promise<boolean> {
    const s = this.sessions.get(threadId);
    const beginInFlight = Boolean(s?.phoneBeginInFlight);
    const interruptedActiveTurn = Boolean(s?.activeTurnId);
    if (s?.phone && (s.phoneLockHeld || beginInFlight || s.activeTurnId)) await this.cancelPhoneWorker(s);
    if (!s?.activeTurnId) return false;
    await this.rpc.request('turn/interrupt', { threadId, turnId: s.activeTurnId });
    if (s.phone && (beginInFlight || interruptedActiveTurn)) await this.cancelPhoneWorker(s);
    return true;
  }

  async archive(threadId: string): Promise<void> {
    await this.interrupt(threadId).catch(() => {});
    await this.rpc.request('thread/archive', { threadId });
    const s = this.sessions.get(threadId);
    if (s) this.setStatus(s, 'archived');
  }

  async setGoal(threadId: string, objective: string, tokenBudget?: number): Promise<unknown> {
    return this.rpc.request('thread/goal/set', { threadId, objective, status: 'active', tokenBudget: tokenBudget ?? null });
  }

  /** Recent items rendered as short lines (for butler reading and the app's session detail). */
  async recentItems(threadId: string, limit = 30): Promise<{ kind: string; text: string; ts: number }[]> {
    await this.start();
    const res = await this.rpc.request<any>('thread/items/list', { threadId, limit, sortDirection: 'desc' });
    const out: { kind: string; text: string; ts: number }[] = [];
    for (const e of res.data ?? []) {
      const item: ThreadItem = e.item ?? e;
      const line = describeItem(item, true);
      if (line) out.push({ kind: item.type, text: line, ts: (e.completedAtMs ?? e.startedAtMs ?? Date.now()) });
    }
    return out.reverse();
  }

  private async ensureLoaded(threadId: string, phoneHint = false): Promise<LiveSession> {
    let s = this.sessions.get(threadId);
    if (s && this.subscribed.has(threadId)) return s;
    // Thread created elsewhere (or before a restart) — resume it so we receive its events.
    const knownPhone = Boolean(s?.phone || phoneHint);
    const knownPhoneStatus = knownPhone ? phoneConfigStatus() : undefined;
    if (knownPhone && !knownPhoneStatus?.config) {
      throw new Error(knownPhoneStatus?.reason ?? '手机工具不可用；请运行 opa phone setup。');
    }
    let res = await this.rpc.request<any>('thread/resume', {
      threadId,
      ...(knownPhoneStatus?.config ? { config: phoneThreadConfig(knownPhoneStatus.config) } : {}),
    });
    this.subscribed.add(threadId);
    if (s) return s;
    const title = res.thread?.name ?? res.thread?.preview?.slice(0, 40) ?? threadId;
    const phone = phoneHint || isPhoneTitle(title);
    if (phone) {
      const phoneStatus = phoneConfigStatus();
      if (!phoneStatus.config) {
        throw new Error(phoneStatus.reason ?? '手机工具不可用；请运行 opa phone setup。');
      }
      // The title is only available after the first resume for an unknown thread.
      // Re-resume with thread-scoped overrides before treating it as a phone session.
      if (!knownPhone) {
        res = await this.rpc.request<any>('thread/resume', { threadId, config: phoneThreadConfig(phoneStatus.config) });
        this.subscribed.add(threadId);
      }
    }
    s = { threadId, title, model: res.model, permission: 'manual', status: 'idle', turns: 0, phone, phoneMcpCalls: new Map() };
    this.sessions.set(threadId, s);
    return s;
  }

  /** Attach to an existing thread without sending anything. */
  async attach(threadId: string, title?: string, permission: Permission = 'manual'): Promise<LiveSession> {
    await this.start();
    const s = await this.ensureLoaded(threadId, Boolean(title && isPhoneTitle(title)));
    if (title) s.title = title;
    if (isPhoneTitle(s.title)) s.phone = true;
    s.permission = permission;
    return s;
  }

  // ───────────── catalog ─────────────

  /** The catalog's default model. config.toml may name a model the account can't use, so never rely on it implicitly. */
  async defaultModel(): Promise<string | null> {
    try {
      const ms = await this.models();
      return (ms.find((m) => m.isDefault) ?? ms.find((m) => !m.hidden))?.id ?? null;
    } catch {
      return null;
    }
  }

  async models(): Promise<Model[]> {
    await this.start();
    const r = await this.rpc.request<{ data: Model[] }>('model/list', {});
    return r.data;
  }

  async apps(): Promise<AppInfo[]> {
    await this.start();
    const r = await this.rpc.request<{ data: AppInfo[] }>('app/list', {});
    return r.data;
  }

  async mcpServers(): Promise<{ name: string; tools: string[]; auth: string }[]> {
    await this.start();
    const r = await this.rpc.request<any>('mcpServerStatus/list', {});
    return (r.data ?? []).map((s: any) => ({ name: s.name, tools: Object.keys(s.tools ?? {}), auth: s.authStatus }));
  }

  /** Direct MCP tool call (connectors), bypassing a full agent turn. Needs a loaded thread; we keep one utility thread. */
  async callTool(server: string, tool: string, args: unknown): Promise<unknown> {
    await this.start();
    if (!this.utilThreadId) {
      const r = await this.rpc.request<ThreadStartResponse>('thread/start', {
        cwd: WORKSPACE, ephemeral: true, approvalPolicy: 'never', sandbox: 'read-only', serviceName: 'opa',
      } satisfies ThreadStartParams);
      this.utilThreadId = r.thread.id;
      this.subscribed.add(r.thread.id);
    }
    return this.rpc.request('mcpServer/tool/call', { threadId: this.utilThreadId, server, tool, arguments: args });
  }

  // ───────────── phone steps (host-driven phone runner) ─────────────

  /**
   * One model call for the step-driven phone runner. Every call is its own throwaway thread, so the model never sees an
   * earlier screenshot: the caller puts everything it needs into `input`. The thread has no tools at all and its answer is
   * constrained by `outputSchema`. Failures and aborts are reported in `status`, not thrown.
   */
  async stepTurn(o: StepTurnOpts): Promise<StepTurnResult> {
    if (o.signal?.aborted) return { status: 'interrupted', text: '' };
    let threadId: string | undefined;
    try {
      await this.start();
      const model = o.model ?? await this.stepDefaultModel();
      if (o.signal?.aborted) return { status: 'interrupted', text: '' };
      const res = await this.startLockedThread({
        ...(model ? { model } : {}),
        cwd: WORKSPACE, approvalPolicy: 'never', sandbox: 'read-only', ephemeral: true,
        baseInstructions: o.baseInstructions, serviceName: 'orbit-phone-step',
      });
      threadId = res.thread.id;
      return { ...(await this.awaitStepTurn(threadId, o)), model: res.model };
    } catch (e: any) {
      return o.signal?.aborted ? { status: 'interrupted', text: '' } : { status: 'failed', text: '', error: e?.message ?? String(e) };
    } finally {
      if (threadId) this.unloadThread(threadId);
    }
  }

  private awaitStepTurn(threadId: string, o: StepTurnOpts): Promise<StepTurnResult> {
    const timeoutMs = o.timeoutMs ?? STEP_TURN_TIMEOUT_MS;
    return new Promise<StepTurnResult>((resolve) => {
      let settled = false;
      let cut = false; // ended by timeout / abort: the turn may still be running on the server
      let turnId: string | undefined;
      let text = '';
      let commentary = '';
      let usage: TokenUsageBreakdown | undefined;
      let lastError: string | undefined;
      let timer: NodeJS.Timeout | undefined;

      const interrupt = () => {
        if (turnId) void this.rpc.request('turn/interrupt', { threadId, turnId }, 10_000).catch(() => {});
      };
      const finish = (r: StepTurnResult) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        this.rpc.off('notification', onNotification);
        this.rpc.off('exit', onExit);
        o.signal?.removeEventListener('abort', onAbort);
        resolve({ ...r, text: r.text || text || commentary, ...(r.usage || usage ? { usage: r.usage ?? usage } : {}) });
      };
      const onNotification = (method: string, p: any) => {
        if (p?.threadId !== threadId) return;
        switch (method) {
          case 'turn/started':
            turnId ??= p.turn?.id;
            break;
          case 'item/completed':
            if (p.item?.type === 'agentMessage' && typeof p.item.text === 'string') {
              if (p.item.phase === 'commentary') commentary = p.item.text;
              else text = p.item.text;
            }
            break;
          case 'thread/tokenUsage/updated':
            if (p.tokenUsage?.last) usage = p.tokenUsage.last;
            break;
          case 'error':
            if (!p.willRetry && p.error?.message) lastError = p.error.message;
            break;
          case 'turn/completed': {
            const turn = p.turn ?? {};
            const status: StepTurnResult['status'] = turn.status === 'completed' ? 'completed' : turn.status === 'interrupted' ? 'interrupted' : 'failed';
            if (!text) {
              const msgs = (turn.items ?? []).filter((i: ThreadItem) => i.type === 'agentMessage') as any[];
              if (msgs.length) text = msgs[msgs.length - 1].text ?? '';
            }
            const error = turn.error?.message ?? (status === 'completed' ? undefined : lastError);
            finish({ status, text, ...(error ? { error } : {}) });
            break;
          }
        }
      };
      const onExit = () => finish({ status: 'failed', text, error: 'codex 进程退出' });
      const onAbort = () => { cut = true; interrupt(); finish({ status: 'interrupted', text: '' }); };

      if (o.signal?.aborted) return finish({ status: 'interrupted', text: '' });
      this.rpc.on('notification', onNotification);
      this.rpc.on('exit', onExit);
      o.signal?.addEventListener('abort', onAbort, { once: true });
      timer = setTimeout(() => {
        cut = true;
        interrupt();
        finish({ status: 'failed', text, error: `单步模型调用超过 ${Math.round(timeoutMs / 1000)} 秒` });
      }, timeoutMs);

      const params: TurnStartParams = {
        threadId, input: o.input,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'readOnly', networkAccess: false },
        effort: (o.effort as any) ?? null,
        outputSchema: (o.outputSchema as any) ?? null,
      };
      this.rpc.request<TurnStartResponse>('turn/start', params, timeoutMs).then(
        (r) => { turnId ??= r.turn?.id; if (cut) interrupt(); },
        (e) => finish({ status: 'failed', text, error: e?.message ?? String(e) }),
      );
    });
  }

  /**
   * A temporary thread that exists only to call `orbit_phone` tools directly (`phoneTool`); no turn is ever run on it.
   * Only orbit_phone is mounted and every built-in ability is off. Close it with `closePhoneExecutor`.
   */
  async openPhoneExecutor(): Promise<string> {
    const phoneStatus = phoneConfigStatus();
    if (!phoneStatus.config) throw new Error(phoneStatus.reason ?? '手机工具不可用；请运行 opa phone setup。');
    await this.start();
    const res = await this.startLockedThread({
      cwd: WORKSPACE, approvalPolicy: 'never', sandbox: 'read-only', ephemeral: true, serviceName: 'orbit-phone-exec',
    }, phoneThreadConfig(phoneStatus.config));
    return res.thread.id;
  }

  async closePhoneExecutor(threadId: string): Promise<void> {
    this.unloadThread(threadId);
  }

  /** Direct `orbit_phone` tool call on an executor thread; returns the raw MCP result. */
  async phoneTool(threadId: string, tool: string, args: Record<string, unknown> = {}): Promise<McpToolResult> {
    return this.rpc.request<McpToolResult>('mcpServer/tool/call', { threadId, server: PHONE_MCP_SERVER, tool, arguments: args }, PHONE_TOOL_TIMEOUT_MS);
  }

  /** thread/start with every built-in ability off; falls back to no MCP overrides if Codex rejects them. */
  private async startLockedThread(params: ThreadStartParams, base: ThreadConfig = {}): Promise<ThreadStartResponse> {
    const config = await this.lockedConfig(base, !this.mcpOverrideBroken);
    try {
      return await this.rpc.request<ThreadStartResponse>('thread/start', { ...params, config } satisfies ThreadStartParams);
    } catch (e) {
      // Only the overrides that switch off the user's own MCP servers can be the culprit; without them there is nothing to retry.
      const switchedOff = isRecord(config.mcp_servers) && Object.keys(config.mcp_servers).some((k) => k !== PHONE_MCP_SERVER);
      if (!switchedOff) throw e;
      const res = await this.rpc.request<ThreadStartResponse>('thread/start', { ...params, config: await this.lockedConfig(base, false) } satisfies ThreadStartParams);
      log.warn('codex', 'thread/start rejected the MCP overrides; phone threads now start without them', e);
      this.mcpOverrideBroken = true;
      return res;
    }
  }

  private async lockedConfig(base: ThreadConfig, disableOtherMcp: boolean): Promise<ThreadConfig> {
    const mcp: { [key: string]: JsonValue } = {};
    if (disableOtherMcp) for (const name of await this.configuredMcpServers()) mcp[name] = { enabled: false };
    if (isRecord(base.mcp_servers)) Object.assign(mcp, base.mcp_servers);
    return {
      ...base,
      features: { ...(isRecord(base.features) ? base.features : {}), ...STEP_FEATURES_OFF },
      web_search: 'disabled',
      ...(Object.keys(mcp).length ? { mcp_servers: mcp } : {}),
    };
  }

  /** MCP servers from the user's own Codex config: a fresh thread would start them all, so they get switched off. */
  private async configuredMcpServers(): Promise<string[]> {
    const cached = this.mcpNamesCache;
    if (cached && Date.now() - cached.at < STEP_CONFIG_TTL_MS) return cached.names;
    let names: string[] = [];
    try {
      const r = await this.rpc.request<any>('config/read', { includeLayers: false, cwd: WORKSPACE }, 10_000);
      if (isRecord(r?.config?.mcp_servers)) names = Object.keys(r.config.mcp_servers);
    } catch { /* unknown config: leave MCP alone */ }
    this.mcpNamesCache = { names, at: Date.now() };
    return names;
  }

  private async stepDefaultModel(): Promise<string | undefined> {
    if (!this.stepModelCache) this.stepModelCache = (await this.defaultModel()) ?? undefined;
    return this.stepModelCache;
  }

  /** Lets the server drop a throwaway thread (ephemeral threads vanish with their last subscriber). Best effort. */
  private unloadThread(threadId: string): void {
    void this.rpc.request('thread/unsubscribe', { threadId }, 10_000).catch(() => {});
  }
  // ───────────── events ─────────────

  private setStatus(s: LiveSession, status: LiveSession['status'], err?: string) {
    if (err) s.lastError = err;
    if (s.status === status) return;
    s.status = status;
    this.emit('status', { threadId: s.threadId, status });
  }

  private onNotification(method: string, p: any) {
    const s = p?.threadId ? this.sessions.get(p.threadId) : undefined;
    if (!s) return;
    switch (method) {
      case 'turn/started':
        s.activeTurnId = p.turn.id;
        s.phoneEndSeen = false;
        s.phoneMcpCalls?.clear();
        this.setStatus(s, 'running');
        this.emit('turn_started', { threadId: s.threadId });
        break;
      case 'turn/completed': {
        const turn = p.turn;
        if (s.activeTurnId === turn.id) s.activeTurnId = undefined;
        const msgs = (turn.items ?? []).filter((i: ThreadItem) => i.type === 'agentMessage') as any[];
        const text = msgs.length ? msgs[msgs.length - 1].text : s.lastAgentText;
        if (text) s.lastAgentText = text;
        const status = turn.status as string;
        const items = turn.items ?? [];
        const phoneEndInTurn = s.phoneEndSeen || items.some((i: any) =>
          i?.type === 'mcpToolCall' && i.server === 'orbit_phone' && i.tool === 'phone_end' &&
          i.status === 'completed' && ['ended', 'cancelled', 'not_started'].includes(phoneToolResultStatus(i) ?? ''),
        );
        const finishTurn = () => {
          this.setStatus(s, status === 'failed' ? 'error' : 'idle', turn.error?.message);
          this.emit('turn_completed', { threadId: s.threadId, status, text, error: turn.error?.message });
        };
        if (s.phone && (status === 'failed' || !phoneEndInTurn) && (s.phoneLockHeld || s.phoneBeginInFlight)) {
          // The known-lock marker is written synchronously before this async call yields.
          void this.cancelPhoneWorker(s).finally(finishTurn);
        } else finishTurn();
        break;
      }
      case 'thread/status/changed': {
        const st = p.status;
        if (st.type === 'active') this.setStatus(s, st.activeFlags?.includes('waitingOnApproval') || st.activeFlags?.includes('waitingOnUserInput') ? 'waiting_approval' : 'running');
        else if (st.type === 'systemError') {
          if (s.phone && (s.phoneLockHeld || s.phoneBeginInFlight)) {
            void this.cancelPhoneWorker(s).finally(() => this.setStatus(s, 'error'));
          } else this.setStatus(s, 'error');
        }
        break;
      }
      case 'item/started':
      case 'item/completed': {
        if (s.phone && p.item?.type === 'mcpToolCall' && p.item.server === 'orbit_phone') {
          const itemId = p.item.id;
          const turnId = p.turnId ?? s.activeTurnId;
          if (itemId && turnId) {
            const key = phoneMcpCallKey(turnId, itemId);
            if (method === 'item/started') {
              const call = { tool: p.item.tool, params: p.item.arguments };
              s.phoneMcpCalls?.set(key, call);
              if (call.tool === 'phone_begin') s.phoneBeginInFlight = true;
              try {
                this.audit('phone', 'tool-call', { thread: s.threadId, tool: call.tool, params: redactPhoneParams(call.tool, call.params) });
              } catch (e) { log.error('phone', `failed to audit ${call.tool}`, e); }
            }
            if (method === 'item/completed') {
              const resultStatus = phoneToolResultStatus(p.item);
              if (p.item.tool === 'phone_begin') {
                s.phoneBeginInFlight = false;
                s.phoneLockHeld = resultStatus === 'started' || resultStatus === 'already_started';
              }
              if (p.item.tool === 'phone_end' && p.item.status === 'completed' && ['ended', 'cancelled', 'not_started'].includes(resultStatus ?? '')) {
                s.phoneEndSeen = true;
                s.phoneLockHeld = false;
              }
            }
          }
        }
        const line = describeItem(p.item, false);
        if (p.item?.type === 'agentMessage' && method === 'item/completed') s.lastAgentText = p.item.text;
        if (line && line !== s.lastActivity) {
          s.lastActivity = line;
          this.emit('activity', { threadId: s.threadId, text: line });
        }
        break;
      }
      case 'item/mcpToolCall/progress':
        this.emit('activity', { threadId: s.threadId, text: String(p.message).slice(0, 120) });
        break;
      case 'turn/plan/updated':
        s.plan = p.plan;
        this.emit('plan', { threadId: s.threadId, plan: p.plan });
        break;
      case 'thread/goal/updated':
        this.emit('goal', { threadId: s.threadId, goal: p.goal });
        break;
      case 'error':
        if (!p.willRetry) s.lastError = p.error?.message;
        break;
    }
  }

  private async onServerRequest(id: number | string, method: string, p: any) {
    try {
      switch (method) {
        case 'item/commandExecution/requestApproval': {
          const cmd = p.command ?? '(命令)';
          const d = await this.approvalHandler({
            threadId: p.threadId, kind: 'command', title: '执行命令', raw: p,
            detail: `${cmd}${p.reason ? `\n原因：${p.reason}` : ''}${p.cwd ? `\n目录：${p.cwd}` : ''}`,
            risk: classifyCommand(cmd),
          });
          return this.rpc.respond(id, { decision: d.approve ? (d.forSession ? 'acceptForSession' : 'accept') : 'decline' });
        }
        case 'item/fileChange/requestApproval': {
          const d = await this.approvalHandler({
            threadId: p.threadId, kind: 'fileChange', title: '修改文件', raw: p,
            detail: p.reason ?? (p.grantRoot ? `申请写入 ${p.grantRoot}` : '修改工作区文件'), risk: p.grantRoot ? 'medium' : 'low',
          });
          return this.rpc.respond(id, { decision: d.approve ? (d.forSession ? 'acceptForSession' : 'accept') : 'decline' });
        }
        case 'item/permissions/requestApproval': {
          const phoneCall = this.phoneMcpCallForApproval(p);
          if (phoneCall) {
            this.audit('phone', 'auto-accept', {
              thread: p.threadId,
              tool: phoneCall.tool,
              params: redactPhoneParams(phoneCall.tool, phoneCall.params),
            });
            return this.rpc.respond(id, { permissions: p.permissions, scope: 'turn' });
          }
          const d = await this.approvalHandler({
            threadId: p.threadId, kind: 'permissions', title: '申请额外权限', raw: p,
            detail: `${p.reason ?? ''}\n${JSON.stringify(p.permissions)}`.trim(), risk: 'medium',
          });
          return this.rpc.respond(id, d.approve ? { permissions: p.permissions, scope: d.forSession ? 'session' : 'turn' } : { permissions: {}, scope: 'turn' });
        }
        case 'mcpServer/elicitation/request': {
          const meta = p._meta ?? {};
          if (p.serverName === 'orbit_phone') {
            const tool = typeof meta.tool_name === 'string' ? meta.tool_name : undefined;
            this.audit('phone', 'auto-accept', {
              thread: p.threadId,
              tool,
              params: redactPhoneParams(tool, meta.tool_params_display),
            });
            return this.rpc.respond(id, { action: 'accept', content: {}, _meta: null });
          }
          // Same question already approved in this session (e.g. computer use asking per action) → answer from cache.
          const key = `${p.threadId}|${p.serverName}|${p.message}`;
          if (this.elicitationOk.has(key)) {
            return this.rpc.respond(id, { action: 'accept', content: {}, _meta: Array.isArray(meta.persist) && meta.persist.includes('session') ? { persist: 'session' } : null });
          }
          const params = (meta.tool_params_display ?? []).map((x: any) => `${x.display_name ?? x.name}：${x.value}`).join('\n');
          const risk: Risk = meta.riskLevel === 'high' ? 'high' : meta.riskLevel === 'low' ? 'low' : 'medium';
          const d = await this.approvalHandler({
            threadId: p.threadId, kind: 'elicitation', title: `${meta.connector_name ?? p.serverName} 需要确认`, raw: p,
            detail: [p.message, meta.tool_name && `操作：${meta.tool_name}`, params, p.url].filter(Boolean).join('\n'), risk,
          });
          if (d.approve) this.elicitationOk.add(key);
          const persist = d.approve && Array.isArray(meta.persist) && meta.persist.includes('session') ? { persist: 'session' } : null;
          return this.rpc.respond(id, { action: d.approve ? 'accept' : 'decline', content: d.approve ? (d.content ?? {}) : null, _meta: persist });
        }
        case 'item/tool/requestUserInput': {
          const qs = (p.questions ?? []).map((q: any) => `${q.header}: ${q.question}${q.options ? ' [' + q.options.map((o: any) => o.label).join(' / ') + ']' : ''}`).join('\n');
          const d = await this.approvalHandler({ threadId: p.threadId, kind: 'userInput', title: 'Codex 在提问', raw: p, detail: qs, risk: 'low' });
          const answers: Record<string, { answers: string[] }> = {};
          for (const q of p.questions ?? []) answers[q.id] = { answers: d.answers?.[q.id] ?? [] };
          return this.rpc.respond(id, { answers });
        }
        case 'item/tool/call': {
          const r = await this.dynamicToolHandler(p);
          if (r) return this.rpc.respond(id, r);
          return this.rpc.respond(id, { success: false, contentItems: [{ type: 'inputText', text: `unknown tool ${p.tool}` }] });
        }
        case 'applyPatchApproval':
        case 'execCommandApproval':
          return this.rpc.respond(id, { decision: 'denied' });
        default:
          return this.rpc.respondError(id, -32601, `opa does not handle ${method}`);
      }
    } catch (e) {
      log.error('codex', 'server request failed', method, e);
      try { this.rpc.respondError(id, -32603, String(e)); } catch { /* process gone */ }
    }
  }

  private phoneMcpCallForApproval(p: any): { tool: string; params: unknown } | undefined {
    const s = this.sessions.get(p?.threadId);
    if (!s?.phone || typeof p?.turnId !== 'string' || typeof p?.itemId !== 'string') return;
    return s.phoneMcpCalls?.get(phoneMcpCallKey(p.turnId, p.itemId));
  }

  private async cancelPhoneWorker(s: LiveSession): Promise<void> {
    if (!s.phone) return;
    const hadKnownLock = Boolean(s.phoneLockHeld);
    if (hadKnownLock) markPhoneCancellation(s);
    try {
      const result = await this.rpc.request<any>('mcpServer/tool/call', {
        threadId: s.threadId,
        server: 'orbit_phone',
        tool: 'phone_cancel',
        arguments: { only_owned: true },
      }, 5_000);
      if (result?.isError) throw new Error('phone_cancel returned an MCP error');
      s.phoneLockHeld = false;
    } catch (e) {
      log.warn('phone', `phone_cancel failed for ${s.threadId}`, e);
      // Only use the global serial marker as a fallback after this thread has
      // positively acquired the lock; an in-flight begin can belong to another worker.
      if (hadKnownLock && s.phoneLockHeld) markPhoneCancellation(s);
    }
  }
}

/** Atomically signal the active phone worker for the configured device. */
export function cancelPhoneTask(): void {
  const serial = process.env.OPA_PHONE_SERIAL ?? DEFAULT_PHONE_SERIAL;
  const safeSerial = serial.replace(/[^A-Za-z0-9_.:-]/g, '_');
  const dir = join(OPA_HOME, 'phone');
  const target = join(dir, `${safeSerial}.cancel`);
  const temporary = `${target}.${process.pid}.${randomUUID()}.tmp`;
  mkdirSync(dir, { recursive: true });
  try {
    writeFileSync(temporary, 'cancelled\n', { flag: 'wx' });
    renameSync(temporary, target);
  } catch (e) {
    try { unlinkSync(temporary); } catch { /* temporary file was not created */ }
    throw e;
  }
}

function markPhoneCancellation(s: LiveSession): void {
  if (!s.phone || !s.phoneLockHeld) return;
  try { cancelPhoneTask(); s.phoneLockHeld = false; }
  catch (e) { log.error('phone', `failed to write cancellation marker for ${s.threadId}`, e); }
}

function phoneMcpCallKey(turnId: string, itemId: string): string { return `${turnId}|${itemId}`; }

function phoneTaskAbortError(): Error {
  const error = new Error('手机任务已取消');
  error.name = 'AbortError';
  return error;
}

function throwIfAborted(signal?: AbortSignal): void {
  if (signal?.aborted) throw phoneTaskAbortError();
}

function phoneThreadConfig(config: PhoneMcpConfig): NonNullable<ThreadStartParams['config']> {
  return {
    mcp_servers: {
      orbit_phone: { ...config, args: [...config.args], env: { ...config.env } },
    },
    features: { computer_use: false },
  };
}

function phoneToolResultStatus(item: any): string | undefined {
  const structured = item?.result?.structuredContent;
  if (structured && typeof structured === 'object' && typeof structured.status === 'string') return structured.status;
  for (const content of item?.result?.content ?? []) {
    if (typeof content?.text !== 'string') continue;
    try {
      const parsed = JSON.parse(content.text);
      if (parsed && typeof parsed.status === 'string') return parsed.status;
    } catch { /* non-JSON content */ }
  }
  return undefined;
}

function isPhoneTitle(title: string): boolean { return title.trimStart().startsWith('📱') || title.trimStart().startsWith('🤵 📱'); }

const SENSITIVE_PHONE_PARAM = /(?:text|input|password|passwd|secret|token|credential|phone|mobile|code|otp|pin|message|content|query|search|task|summary|address|location|姓名|手机号|电话|文本|输入|密码|验证码|令牌|密钥|消息|内容|查询|搜索|任务|地址|位置|备注|卡号)/i;

export function redactPhoneParams(tool: string | undefined, params: unknown): unknown {
  const redact = (value: unknown, name: string): unknown => {
    if (tool === 'phone_type' || SENSITIVE_PHONE_PARAM.test(name)) return '[redacted]';
    if (Array.isArray(value)) return value.map((item) => redact(item, name));
    if (value && typeof value === 'object') {
      return Object.fromEntries(Object.entries(value as Record<string, unknown>).map(([key, item]) => [key, redact(item, key)]));
    }
    if (typeof value === 'string') return '[redacted]';
    if (typeof value === 'number' || typeof value === 'boolean' || value === null) return value;
    return undefined;
  };

  if (Array.isArray(params)) {
    return params.map((entry: any) => {
      if (!entry || typeof entry !== 'object') return '[redacted]';
      const name = String(entry.display_name ?? entry.name ?? 'param');
      return { name, value: redact(entry.value, name) };
    });
  }
  return redact(params, 'params');
}

/** Heuristic risk for shell commands Codex wants to run outside the sandbox. */
export function classifyCommand(cmd: string): Risk {
  const c = cmd.toLowerCase();
  if (/\brm\s+-[a-z]*r|\bsudo\b|mkfs|dd\s+if=|>\s*\/dev\/|chmod\s+-r|chown\s+-r|launchctl|defaults\s+write|security\s+(delete|add)|osascript.*(delete|send)|curl[^|]*\|\s*(ba|z)?sh|git\s+push|npm\s+publish|kill(all)?\s/.test(c)) return 'high';
  if (/\b(rm|mv|cp|curl|wget|pip|npm|brew|git|open)\b/.test(c)) return 'medium';
  return 'low';
}

function describeItem(item: any, verbose: boolean): string | undefined {
  if (!item) return;
  const cut = (s: string, n = verbose ? 400 : 100) => (s.length > n ? s.slice(0, n) + '…' : s);
  switch (item.type) {
    case 'agentMessage': return item.text ? cut(item.text) : undefined;
    case 'userMessage': return verbose ? cut((item.content ?? []).map((c: any) => c.text ?? `[${c.type}]`).join(' ')) : undefined;
    case 'commandExecution': return `执行：${cut(item.command ?? '', 80)}`;
    case 'fileChange': return `修改 ${(item.changes ?? []).length} 个文件`;
    case 'mcpToolCall': return `调用 ${item.server}.${item.tool}`;
    case 'dynamicToolCall': return `调用 ${item.tool}`;
    case 'webSearch': return `搜索：${cut(item.query ?? '', 60)}`;
    case 'plan': return verbose ? cut(item.text ?? '') : '更新计划';
    case 'reasoning': return verbose && item.summary?.length ? `思考：${cut(item.summary.join(' '))}` : undefined;
    case 'imageView': return '查看截图';
    case 'imageGeneration': return '生成图片';
    case 'subAgentActivity':
    case 'collabAgentToolCall': return '子代理工作中';
    default: return undefined;
  }
}
