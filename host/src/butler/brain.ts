// The bot's "brain" runs as a dedicated Codex thread (billed to the user's ChatGPT/Codex plan — no API key).
// Our tool catalog is exposed as Codex dynamic tools; Codex calls them back over `item/tool/call`.
// Codex's own built-ins (shell, apps, plugins…) are disabled on this thread so the brain stays an orchestrator.
import { EventEmitter } from 'node:events';
import type { CodexBridge } from '../codex/bridge.ts';
import type { Db } from '../store/db.ts';
import { WORKSPACE } from '../codex/bridge.ts';
import { log } from '../util/log.ts';

export interface BrainTool { name: string; description: string; parameters: Record<string, unknown> }
export type ToolRunner = (name: string, args: any) => Promise<{ text: string; images?: string[] }>;

const BRAIN_CONFIG = {
  features: {
    shell_tool: false, apps: false, plugins: false, multi_agent: false, skill_search: false,
    computer_use: false, goals: false, sleep_tool: false,
  },
  web_search: 'live',
};

/** How long `compact()` waits for Codex to finish compacting the thread before it gives up. */
export const COMPACT_TIMEOUT_MS = 180_000;
/** Once Codex reports the history as compacted, how long to wait for the compaction turn to close before calling it done. */
const COMPACT_SETTLE_MS = 5_000;

/** The one `thread/compact/start` `compact()` is waiting on. */
interface Compaction {
  /** The turn Codex opened for it (the first `turn/started` on the thread after we asked). */
  turnId?: string;
  /** Codex said the history was compacted (`thread/compacted` or a `contextCompaction` item). */
  marked: boolean;
  settle?: NodeJS.Timeout;
  done: Promise<boolean>;
  finish(ok: boolean): void;
}

export interface BrainResetTarget { threadId?: string; turnId?: string }

/** Events: 'delta' (text) | 'message' (fullText) | 'tool' (name) | 'turn_done' (status, error?) | 'compacted' (the thread's history was compacted — by us or by Codex itself) */
export class Brain extends EventEmitter {
  threadId?: string;
  private turnId?: string;
  private turnDone?: (status: string) => void;
  private configKey = '';
  /** The thread `rotate()` gave up on: the next `ensure()` archives it and carries a summary of it over. */
  private retiredId?: string;
  private tokens = 0;
  private window: number | null = null;
  private compaction?: Compaction;
  /** `compact()` gives up after this long. A field so tests can shorten it. */
  compactTimeoutMs = COMPACT_TIMEOUT_MS;
  private generation = 0;
  private resetWaiters = new Set<() => void>();
  runner: ToolRunner = async () => ({ text: 'no runner' });

  constructor(private bridge: CodexBridge, private db: Db) {
    super();
    this.threadId = db.get<string>('brain.threadId');
    this.configKey = db.get<string>('brain.configKey') ?? '';
    bridge.rpc.on('notification', (m: string, p: any) => this.onNotification(m, p));
    bridge.dynamicToolHandler = async (p) => {
      if (p.threadId !== this.threadId) return undefined;
      this.emit('tool', p.tool);
      const r = await this.runner(p.tool, p.arguments ?? {});
      return {
        success: true,
        contentItems: [{ type: 'inputText', text: r.text }, ...(r.images ?? []).map((u) => ({ type: 'inputImage', imageUrl: u }))],
      };
    };
    bridge.on('restarted', () => { this.turnId = undefined; this.turnDone?.('failed'); this.compaction?.finish(false); });
  }

  get busy() { return !!this.turnId; }

  /** How big the context is: the input of the thread's latest model request (Codex's `last.inputTokens`). 0 = unknown until Codex reports again. */
  get contextTokens(): number { return this.tokens; }

  /** The model's context window in tokens, when Codex says. */
  get contextWindow(): number | null { return this.window; }

  /**
   * Ensure the brain thread exists with the given instructions/tools/model. Instructions and tools are fixed per thread,
   * so when they change we start a new thread and seed it with a carry-over summary.
   */
  async ensure(o: { instructions: string; tools: BrainTool[]; model?: string; carryOver: () => Promise<string | undefined> }): Promise<string> {
    const generation = this.generation;
    let wake!: () => void;
    const reset = new Promise<never>((_, reject) => {
      wake = () => reject(new Error('brain context was cleared'));
      this.resetWaiters.add(wake);
    });
    const work = this.ensureInGeneration(o, generation);
    try { return await Promise.race([work, reset]); }
    finally { this.resetWaiters.delete(wake); }
  }

  private async ensureInGeneration(o: { instructions: string; tools: BrainTool[]; model?: string; carryOver: () => Promise<string | undefined> }, generation: number): Promise<string> {
    await this.bridge.start();
    this.assertGeneration(generation);
    const key = hash(o.instructions + JSON.stringify(o.tools.map((t) => [t.name, t.description, t.parameters])) + (o.model ?? ''));
    const dynamicTools = o.tools.map((t) => ({ type: 'function', name: t.name, description: t.description, inputSchema: t.parameters }));
    if (this.threadId && key === this.configKey) {
      const existing = this.threadId;
      if (!(await this.resume(existing))) {
        this.assertGeneration(generation);
        log.warn('brain', 'starting a fresh brain thread');
        if (this.threadId === existing) this.threadId = undefined;
      }
      this.assertGeneration(generation);
      if (this.threadId) return this.threadId;
    }
    const replaced = this.threadId ?? this.retiredId;
    const carry = replaced ? await o.carryOver().catch(() => undefined) : undefined;
    this.assertGeneration(generation);
    const model = o.model || await this.bridge.defaultModel();
    this.assertGeneration(generation);
    const r = await this.bridge.rpc.request<any>('thread/start', {
      model, cwd: WORKSPACE, approvalPolicy: 'never', sandbox: 'read-only',
      baseInstructions: o.instructions, config: BRAIN_CONFIG, dynamicTools, serviceName: 'orbit-brain',
    });
    if (generation !== this.generation) {
      void this.bridge.rpc.request('thread/archive', { threadId: r.thread.id }, 5_000).catch(() => {});
      throw new Error('brain context was cleared');
    }
    if (replaced) await this.bridge.rpc.request('thread/archive', { threadId: replaced }).catch(() => {});
    this.assertGeneration(generation);
    this.retiredId = undefined;
    this.threadId = r.thread.id;
    this.tokens = 0;
    this.bridge.markSubscribed(this.threadId!);
    await this.bridge.rpc.request('thread/name/set', { threadId: this.threadId, name: '🪐 Orbit brain' }).catch(() => {});
    this.configKey = key;
    this.db.set('brain.threadId', this.threadId);
    this.db.set('brain.configKey', key);
    this.pendingCarry = carry;
    log.info('brain', `brain thread ${this.threadId} (model ${r.model})`);
    return this.threadId!;
  }

  private assertGeneration(generation: number): void {
    if (generation !== this.generation) throw new Error('brain context was cleared');
  }

  /** Detach only the dedicated conversational brain. Other Codex sessions and phone workers are unaffected. */
  resetForClear(): BrainResetTarget {
    const target = { threadId: this.threadId, turnId: this.turnId };
    this.generation++;
    for (const wake of this.resetWaiters) wake();
    this.resetWaiters.clear();
    this.compaction?.finish(false);
    this.threadId = undefined;
    this.turnId = undefined;
    const done = this.turnDone;
    this.turnDone = undefined;
    done?.('interrupted');
    this.configKey = '';
    this.retiredId = undefined;
    this.tokens = 0;
    this.window = null;
    this.pendingCarry = undefined;
    return target;
  }

  /** Best-effort cleanup of the third-party brain thread after its local identity has been detached. */
  interruptAndArchive(target: BrainResetTarget): void {
    if (!target.threadId) return;
    void (async () => {
      if (target.turnId) {
        await this.bridge.rpc.request('turn/interrupt', { threadId: target.threadId, turnId: target.turnId }, 5_000)
          .catch((e: any) => log.debug('brain', `could not interrupt cleared thread ${target.threadId}: ${e?.message ?? e}`));
      }
      await this.bridge.rpc.request('thread/archive', { threadId: target.threadId }, 10_000)
        .catch((e: any) => log.debug('brain', `could not archive cleared thread ${target.threadId}: ${e?.message ?? e}`));
    })();
  }

  private pendingCarry?: string;

  /** Re-subscribe to a thread this app-server process has not loaded yet (after a Codex restart). False when Codex cannot resume it. */
  private async resume(threadId: string): Promise<boolean> {
    if (this.bridge.isSubscribed(threadId)) return true;
    try {
      await this.bridge.rpc.request('thread/resume', { threadId, config: BRAIN_CONFIG, cwd: WORKSPACE });
      this.bridge.markSubscribed(threadId);
      return true;
    } catch (e: any) {
      log.warn('brain', 'resume failed:', e?.message);
      return false;
    }
  }

  /**
   * Run one turn with the given event text; resolves when the turn ends. `model` / `effort` override the thread's for
   * this turn *and the ones after it* (Codex keeps them), so the caller passes both every round. No effort = leave it to Codex.
   */
  async turn(text: string, o: { model?: string; effort?: string } = {}): Promise<string> {
    const generation = this.generation;
    const threadId = this.threadId;
    if (!threadId) throw new Error('brain thread is not ready');
    const input: any[] = [];
    const carry = this.pendingCarry;
    if (carry) {
      input.push({ type: 'text', text: `<carry_over>\n（系统）之前对话的摘要：\n${carry}\n</carry_over>`, text_elements: [] });
      this.pendingCarry = undefined;
    }
    input.push({ type: 'text', text, text_elements: [] });
    let resolveDone!: (status: string) => void;
    const done = new Promise<string>((resolve) => { resolveDone = resolve; this.turnDone = resolve; });
    const start = (async () => {
      try {
        const r = await this.bridge.rpc.request<any>('turn/start', {
          threadId, input, model: o.model || null, effort: o.effort || null,
          approvalPolicy: 'never', sandboxPolicy: { type: 'readOnly', networkAccess: false },
        });
        if (generation !== this.generation || this.threadId !== threadId) {
          void this.bridge.rpc.request('turn/interrupt', { threadId, turnId: r.turn.id }, 5_000).catch(() => {});
          return 'interrupted';
        }
        this.turnId = r.turn.id;
        return await done;
      } catch (e) {
        if (generation === this.generation) {
          this.pendingCarry ??= carry; // the turn never started: the thread has not seen the summary yet
          if (this.turnDone === resolveDone) this.turnDone = undefined;
          throw e;
        }
        return 'interrupted';
      }
    })();
    // `resetForClear()` resolves `done` immediately, even while turn/start is awaiting its RPC response.
    return Promise.race([start, done]);
  }

  /** Append more input to the running turn (e.g. a new user message arrived). Returns false if no turn is active. */
  async steer(text: string): Promise<boolean> {
    if (!this.turnId || this.compaction) return false; // a compaction turn cannot take input
    try {
      await this.bridge.rpc.request('turn/steer', { threadId: this.threadId, input: [{ type: 'text', text, text_elements: [] }], expectedTurnId: this.turnId });
      return true;
    } catch {
      return false;
    }
  }

  async interrupt(): Promise<void> {
    // Stopping the bot (or a late `yield` interrupt) must not abort a compaction: that would only throw the history away.
    if (!this.turnId || this.compaction) return;
    await this.bridge.rpc.request('turn/interrupt', { threadId: this.threadId, turnId: this.turnId }).catch(() => {});
  }

  /**
   * Have Codex compact the thread's history into a summary (`thread/compact/start`) and wait until it is done. Codex
   * reports the end as the compaction's own `turn/started` + `turn/completed`, a `contextCompaction` item, or the
   * deprecated `thread/compacted` notification; any of them counts. Resolves true once the history is compacted, false when
   * Codex refuses, the compaction turn fails, or nothing finishes within `compactTimeoutMs` (the caller then `rotate()`s).
   * Throws when Codex cannot be reached at all: that says nothing about the thread, so the caller leaves it alone.
   */
  async compact(): Promise<boolean> {
    if (this.compaction) return this.compaction.done;
    const generation = this.generation;
    const threadId = this.threadId;
    if (!threadId) return false;
    await this.bridge.start();
    this.assertGeneration(generation);
    if (this.threadId !== threadId) return false;
    const resumed = await this.resume(threadId);
    this.assertGeneration(generation);
    if (!resumed || this.threadId !== threadId) return false;
    let timer: NodeJS.Timeout | undefined;
    let settle!: (ok: boolean) => void;
    const c: Compaction = {
      marked: false,
      done: new Promise<boolean>((resolve) => { settle = resolve; }),
      finish: (ok) => {
        if (this.compaction !== c) return;
        this.compaction = undefined;
        clearTimeout(timer);
        clearTimeout(c.settle);
        if (c.turnId && this.turnId === c.turnId) this.turnId = undefined;
        if (ok) this.tokens = 0; // the old count no longer applies; Codex reports the new one with the next request
        settle(ok);
      },
    };
    // Registered before the request: Codex may start reporting before it has answered.
    this.compaction = c;
    timer = setTimeout(() => { log.warn('brain', `compacting ${threadId} timed out`); c.finish(false); }, this.compactTimeoutMs);
    timer.unref();
    const request = this.bridge.rpc.request('thread/compact/start', { threadId }, this.compactTimeoutMs + 5_000)
      .then(() => true, (e: any) => {
        log.warn('brain', 'thread/compact/start failed:', e?.message ?? e);
        c.finish(false);
        return false;
      });
    const first = await Promise.race([
      c.done.then((ok) => ({ kind: 'finished' as const, ok })),
      request.then((ok) => ({ kind: 'request' as const, ok })),
    ]);
    if (first.kind === 'finished') return first.ok;
    if (!first.ok) return c.done;
    return c.done;
  }

  /**
   * Give up on the current thread (a compaction that failed): the next `ensure()` starts a fresh one, seeded with the
   * carry-over summary, and archives this one. Survives a Host restart.
   */
  rotate(): void {
    this.compaction?.finish(false);
    if (this.threadId) this.retiredId = this.threadId;
    this.threadId = undefined;
    this.configKey = '';
    this.turnId = undefined;
    this.tokens = 0;
    this.db.set('brain.configKey', '');
  }

  private onNotification(method: string, p: any) {
    if (!this.threadId || p?.threadId !== this.threadId) return;
    switch (method) {
      case 'thread/tokenUsage/updated': {
        const u = p.tokenUsage;
        this.tokens = Math.max(0, Math.round(Number(u?.last?.inputTokens) || 0));
        const window = Number(u?.modelContextWindow);
        this.window = window > 0 ? window : null;
        break;
      }
      case 'turn/started':
        this.turnId = p.turn.id;
        if (this.compaction && !this.compaction.turnId) this.compaction.turnId = p.turn.id;
        break;
      case 'item/agentMessage/delta': this.emit('delta', p.delta, p.itemId); break;
      case 'item/completed':
        if (p.item?.type === 'agentMessage') this.emit('message', p.item.text, p.item.id);
        else if (p.item?.type === 'contextCompaction') this.onCompacted();
        break;
      case 'thread/compacted': this.onCompacted(); break; // deprecated in favour of the item above, but still sent
      case 'turn/completed': {
        this.turnId = undefined;
        const status = p.turn.status as string;
        this.emit('turn_done', status, p.turn.error?.message);
        const r = this.turnDone; this.turnDone = undefined; r?.(status);
        const c = this.compaction;
        if (c && c.turnId === p.turn.id) c.finish(status === 'completed' || c.marked);
        break;
      }
    }
  }

  /** Codex says this thread's history was compacted — at our request, or on its own when the context filled up. */
  private onCompacted() {
    this.tokens = 0;
    this.emit('compacted');
    const c = this.compaction;
    if (!c) return;
    c.marked = true;
    if (!c.turnId) c.finish(true); // no compaction turn to wait for
    else if (!c.settle) { c.settle = setTimeout(() => c.finish(true), COMPACT_SETTLE_MS); c.settle.unref(); } // give its turn/completed a moment to arrive
  }
}

function hash(s: string): string {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
  return (h >>> 0).toString(16);
}
