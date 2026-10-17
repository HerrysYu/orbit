// Reasoning-effort settings (settings.models.butlerEffort / heartbeatEffort / codexEffort): checking what the owner
// stores, and choosing what is actually sent to Codex. '' / null / missing all mean 自动 — docs/protocol.md §4.5.
import { log } from '../util/log.ts';

/** The three effort keys of `Settings.models`. */
export const EFFORT_SETTING_KEYS = ['butlerEffort', 'heartbeatEffort', 'codexEffort'] as const;

/** Codex names its efforts with plain lowercase words: minimal, low, medium, high, xhigh, max… */
export const EFFORT_RE = /^[a-z]{1,16}$/;

/** What the bot thinks at while the owner leaves its effort on 自动 (it used to be hard-coded in brain.ts). */
export const DEFAULT_BOT_EFFORT = 'medium';

/** `settings.set` input check: '' / null / undefined mean 自动 (stored as ''); anything else must look like an effort name. */
export function parseEffortSetting(v: unknown): string {
  if (v === undefined || v === null || v === '') return '';
  if (typeof v !== 'string' || !EFFORT_RE.test(v)) throw new Error('无效的推理强度');
  return v;
}

/** An effort as the host reads it back (a stored setting, or the bot's tool argument): anything that is not a plausible effort name counts as 自动. */
export function readEffort(v: unknown): string {
  const s = typeof v === 'string' ? v.trim() : '';
  return EFFORT_RE.test(s) ? s : '';
}

export interface EffortChoice {
  /** Whose effort this is, for the log line: 'bot' | '心跳' | '执行任务'. */
  scope: string;
  /** The model the effort will be used with; undefined = Codex's default model. */
  model?: string;
  /** Efforts that model is known to accept (cached catalog). Empty / undefined = unknown, so nothing is filtered out. */
  supported?: readonly string[];
  /** The owner's / the bot's choices in priority order. Blanks are skipped; an unsupported one is dropped with a warning. */
  wanted: readonly (string | undefined)[];
  /** Built-in defaults tried after `wanted`; an unsupported one is dropped silently. */
  fallbacks?: readonly (string | undefined)[];
}

/**
 * The first usable effort: the first non-blank entry of `wanted` that the model supports, else the first supported
 * entry of `fallbacks`, else undefined ("don't send one — Codex decides"). Dropping an unsupported effort beats
 * sending it: Codex would reject the turn, and the owner's pick stays stored for when the model changes back.
 */
export function pickEffort(c: EffortChoice): string | undefined {
  const known = c.supported?.length ? c.supported : undefined;
  const ok = (e: string) => !known || known.includes(e);
  for (const e of c.wanted) {
    if (!e) continue;
    if (ok(e)) return e;
    log.warn('effort', `${c.scope}：${c.model ?? 'Codex 默认模型'} 不支持推理强度 ${e}（支持：${known!.join(' / ')}），已忽略`);
  }
  return c.fallbacks?.find((e): e is string => !!e && ok(e));
}
