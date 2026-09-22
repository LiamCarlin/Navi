/**
 * Canned upstream responses for `MOCK_UPSTREAM=1`, in the exact wire shapes
 * the app's JevClient / ClaudeClient / GeminiClient parse. Lets the Swift side
 * exercise sign-in, metering and streaming with no vendor keys.
 */

interface JevQuestion { type?: string; criteria?: unknown }

/** Answers every question in the request: first criteria key for choices, mid-scale scores, "no" for nouls. */
export function mockJevResponse(body: unknown): Record<string, unknown> {
  const questions = ((body as { questions?: Record<string, JevQuestion> })?.questions) ?? {};
  const answers: Record<string, unknown> = {};
  for (const [name, q] of Object.entries(questions)) {
    switch (q?.type) {
      case "choice": {
        const keys = q.criteria && typeof q.criteria === "object" && !Array.isArray(q.criteria) ? Object.keys(q.criteria) : ["a", "b"];
        const probabilities: Record<string, number> = {};
        keys.forEach((k, i) => { probabilities[k] = i === 0 ? 0.82 : Number((0.18 / Math.max(1, keys.length - 1)).toFixed(4)); });
        answers[name] = { type: "choice", choice: keys[0], probabilities, confidence: 0.82 };
        break;
      }
      case "score": {
        const levels = Array.isArray(q.criteria) ? q.criteria : ["low", "high"];
        const legend: Record<string, string> = {};
        levels.forEach((l, i) => { legend[String(i)] = typeof l === "string" ? l : JSON.stringify(l); });
        answers[name] = { type: "score", score: (levels.length - 1) / 2, legend, confidence: 0.7 };
        break;
      }
      case "noul":
      case "boolean":
        answers[name] = { type: "noul", noul: 0.08 };
        break;
      default:
        break;
    }
  }
  return {
    id: `mock_${Date.now().toString(36)}`,
    model: (body as { model?: string })?.model ?? "jev-latest",
    answers,
    usage: { input_tokens: 64, output_tokens: 0 },
    mock: true,
  };
}

export const MOCK_CLAUDE_TEXT = "This is a canned answer from Navi Cloud (MOCK_UPSTREAM=1). Nothing was sent to a model.";

export function mockClaudeMessage(body: unknown): Record<string, unknown> {
  const model = (body as { model?: string })?.model ?? "claude-opus-5";
  return {
    id: "msg_mock_navi",
    type: "message",
    role: "assistant",
    model,
    content: [{ type: "text", text: MOCK_CLAUDE_TEXT }],
    stop_reason: "end_turn",
    stop_sequence: null,
    usage: { input_tokens: 40, output_tokens: 24 },
  };
}

function sse(event: string, data: unknown): string {
  return `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
}

/** A Messages-API SSE stream: message_start → text deltas → message_delta (usage) → message_stop. */
export function mockClaudeStream(body: unknown, delayMs = 30): ReadableStream<Uint8Array> {
  const model = (body as { model?: string })?.model ?? "claude-opus-5";
  const words = MOCK_CLAUDE_TEXT.split(" ");
  const enc = new TextEncoder();
  return new ReadableStream<Uint8Array>({
    async start(controller) {
      const push = (s: string) => controller.enqueue(enc.encode(s));
      push(sse("message_start", {
        type: "message_start",
        message: { id: "msg_mock_navi", type: "message", role: "assistant", model, content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 40, output_tokens: 1 } },
      }));
      push(sse("content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }));
      push(sse("ping", { type: "ping" }));
      for (let i = 0; i < words.length; i++) {
        await new Promise((r) => setTimeout(r, delayMs));
        push(sse("content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: (i ? " " : "") + words[i] } }));
      }
      push(sse("content_block_stop", { type: "content_block_stop", index: 0 }));
      push(sse("message_delta", { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: words.length } }));
      push(sse("message_stop", { type: "message_stop" }));
      controller.close();
    },
  });
}

export function mockGeminiResponse(): Record<string, unknown> {
  return {
    candidates: [{ content: { parts: [{ text: MOCK_CLAUDE_TEXT }], role: "model" }, finishReason: "STOP", index: 0 }],
    usageMetadata: { promptTokenCount: 40, candidatesTokenCount: 24, totalTokenCount: 64 },
    modelVersion: "mock",
  };
}
