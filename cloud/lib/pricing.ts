/**
 * Approximate vendor cost per call, in USD. Only used for the `usage.cost_usd`
 * column (ops visibility), never for billing the user.
 */

/** Jev is priced per input token (~$0.042 / 1M) — a routing call is a small flat amount. */
export const JEV_FLAT_USD = 0.00005;

/** Anthropic first-party rates, USD per 1M tokens (claude-api skill table, cached 2026-06). */
export const ANTHROPIC_RATES: Record<string, { input: number; output: number }> = {
  "claude-fable-5-1": { input: 10, output: 50 },
  "claude-fable-5": { input: 10, output: 50 },
  "claude-opus-5": { input: 5, output: 25 },
  "claude-opus-4-8": { input: 5, output: 25 },
  "claude-opus-4-7": { input: 5, output: 25 },
  "claude-opus-4-6": { input: 5, output: 25 },
  "claude-sonnet-5": { input: 2, output: 10 },
  "claude-sonnet-4-6": { input: 3, output: 15 },
  "claude-haiku-4-5": { input: 1, output: 5 },
};

/** Gemini Flash-Lite class rates; close enough for a cost column. */
export const GEMINI_RATES: Record<string, { input: number; output: number }> = {
  "gemini-2.5-flash-lite": { input: 0.1, output: 0.4 },
  "gemini-2.5-flash": { input: 0.3, output: 2.5 },
  "gemini-2.0-flash": { input: 0.1, output: 0.4 },
};

const DEFAULT_ANTHROPIC = ANTHROPIC_RATES["claude-opus-5"];
const DEFAULT_GEMINI = GEMINI_RATES["gemini-2.5-flash-lite"];

function lookup(table: Record<string, { input: number; output: number }>, model: string | undefined, fallback: { input: number; output: number }) {
  if (!model) return fallback;
  if (table[model]) return table[model];
  // Dated snapshots ("claude-sonnet-5-20260401") and aliases fall back to their family.
  const family = Object.keys(table).find((k) => model.startsWith(k));
  return family ? table[family] : fallback;
}

export function anthropicCostUsd(model: string | undefined, inputTokens: number, outputTokens: number): number {
  const r = lookup(ANTHROPIC_RATES, model, DEFAULT_ANTHROPIC);
  return (inputTokens * r.input + outputTokens * r.output) / 1_000_000;
}

export function geminiCostUsd(model: string | undefined, inputTokens: number, outputTokens: number): number {
  const r = lookup(GEMINI_RATES, model, DEFAULT_GEMINI);
  return (inputTokens * r.input + outputTokens * r.output) / 1_000_000;
}

/** Reads `usage` off a non-streaming Anthropic message. */
export function anthropicUsageFromMessage(msg: unknown): { input: number; output: number } {
  const u = (msg as { usage?: { input_tokens?: number; output_tokens?: number } } | null)?.usage;
  return { input: Number(u?.input_tokens ?? 0), output: Number(u?.output_tokens ?? 0) };
}

export function geminiUsageFromResponse(res: unknown): { input: number; output: number } {
  const u = (res as { usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number } } | null)?.usageMetadata;
  return { input: Number(u?.promptTokenCount ?? 0), output: Number(u?.candidatesTokenCount ?? 0) };
}
