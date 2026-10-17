import type { Model } from '../codex/protocol/v2/Model.ts';

export interface ModelOption {
  id: string;
  displayName: string;
  description?: string;
  isDefault: boolean;
  /** Reasoning efforts the model supports (Model.supportedReasoningEfforts); empty = the catalog did not say. */
  efforts: string[];
  /** The model's own default effort (Model.defaultReasoningEffort), when known. */
  defaultEffort?: string;
}

/** A manually offered model name is a UI option, not proof that the account can call it. */
export const GPT_6_1_SOL_OPTION: Readonly<ModelOption> = {
  id: 'gpt-6.1-sol',
  displayName: 'GPT-6.1 Sol',
  description: '适合复杂编码、电脑操作与专业任务。',
  isDefault: false,
  efforts: ['low', 'medium', 'high', 'xhigh', 'max'],
  defaultEffort: 'medium',
};

/** Project the protocol catalog into Host-facing model options and add the requested Sol option once. */
export function mergeModelOptions(models: readonly Model[]): ModelOption[] {
  const options = models.filter((m) => !m.hidden).map((m): ModelOption => ({
    id: m.id,
    displayName: m.displayName?.trim() || (m.id === GPT_6_1_SOL_OPTION.id ? GPT_6_1_SOL_OPTION.displayName : m.id),
    description: m.description?.trim() || undefined,
    isDefault: m.isDefault,
    efforts: Array.isArray(m.supportedReasoningEfforts)
      ? m.supportedReasoningEfforts.map((e) => e.reasoningEffort).filter(Boolean)
      : [],
    defaultEffort: m.defaultReasoningEffort || undefined,
  }));

  const solIndex = options.findIndex((m) => m.id === GPT_6_1_SOL_OPTION.id);
  if (solIndex === -1) {
    options.push({ ...GPT_6_1_SOL_OPTION, efforts: [...GPT_6_1_SOL_OPTION.efforts] });
    return options;
  }

  const sol = options[solIndex]!;
  options[solIndex] = {
    ...sol,
    displayName: sol.displayName.trim() || GPT_6_1_SOL_OPTION.displayName,
    description: sol.description?.trim() || undefined,
    efforts: sol.efforts.length ? sol.efforts : [...GPT_6_1_SOL_OPTION.efforts],
    defaultEffort: sol.defaultEffort || GPT_6_1_SOL_OPTION.defaultEffort,
    // Keep the server's default flag. The manual fallback above is the only source marked non-default.
    isDefault: sol.isDefault,
  };
  return options;
}
