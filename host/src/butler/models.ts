// Bot model catalog: the brain runs on Codex, so the list follows Codex's `model/list` (OpenAI's current lineup
// for the user's ChatGPT plan). '' in settings = Codex default.
import type { CodexBridge } from '../codex/bridge.ts';
import { log } from '../util/log.ts';
import { mergeModelOptions, type ModelOption } from './model-options.ts';

export interface ModelEntry {
  id: string;
  displayName: string;
  description?: string;
  isDefault: boolean;
  /** Reasoning efforts the model supports; empty = unknown. */
  efforts: string[];
  /** The model's own default reasoning effort, when Codex says. */
  defaultEffort?: string;
}

const toEntry = ({ id, displayName, description, isDefault, efforts, defaultEffort }: ModelOption): ModelEntry =>
  ({ id, displayName, description, isDefault, efforts: [...efforts], defaultEffort });

export class ModelCatalog {
  private cache: ModelEntry[] = mergeModelOptions([]).map(toEntry);
  private fetchedAt = 0;
  private failedAt = 0;

  constructor(private bridge: CodexBridge) {}

  /** Cached for an hour. After a failed fetch the stale cache is served for a minute, so a broken Codex isn't asked on every round; `force` always asks. */
  async list(force = false): Promise<ModelEntry[]> {
    if (!force) {
      if (this.fetchedAt && Date.now() - this.fetchedAt < 3600_000) return this.cache;
      if (this.failedAt && Date.now() - this.failedAt < 60_000) return this.cache;
    }
    try {
      this.cache = mergeModelOptions(await this.bridge.models()).map(toEntry);
      this.fetchedAt = Date.now();
      this.failedAt = 0;
    } catch (e: any) {
      this.failedAt = Date.now();
      log.warn('models', 'model/list failed:', e?.message ?? e);
    }
    return this.cache;
  }

  /**
   * The cached entry for `modelId` (undefined = Codex's default model) — a plain lookup, it never asks Codex. What it
   * knows is as fresh as the last `list()`: a round primes it, and the app's `models.list` refreshes it.
   */
  peek(modelId?: string | null): ModelEntry | undefined {
    return modelId ? this.cache.find((m) => m.id === modelId) : this.cache.find((m) => m.isDefault);
  }
}
