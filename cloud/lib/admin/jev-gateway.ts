/**
 * Jev over the Vercel AI Gateway, used by the proxy when the console has an
 * `ai_gateway` key and no TypeSafe key. The app always speaks the TypeSafe shape to
 * /v1/jev; this translates both ways (docs/JEV_INTEGRATION.md § Transports):
 *   request:  drop `model`, yes/no questions `noul` → `boolean`
 *   response: `{type:"boolean", probability}` → `{type:"noul", noul}`; confidence from
 *             `providerMetadata.typesafe.confidence[name]`, else top − runner-up.
 */

export const GATEWAY_HEADERS: Record<string, string> = {
  "ai-model-id": "typesafe-ai/jev",
  "ai-evaluation-model-specification-version": "4",
  "ai-gateway-protocol-version": "0.0.1",
  "ai-gateway-auth-method": "api-key",
};

export function toGatewayBody(body: Record<string, unknown>): Record<string, unknown> {
  const questions = (body.questions ?? {}) as Record<string, Record<string, unknown>>;
  const out: Record<string, Record<string, unknown>> = {};
  for (const [name, q] of Object.entries(questions)) {
    out[name] = q && typeof q === "object" && q.type === "noul" ? { ...q, type: "boolean" } : q;
  }
  const rest = { ...body };
  delete rest.model;
  return { ...rest, questions: out };
}

function spread(probs: Record<string, unknown> | undefined): number | undefined {
  if (!probs) return undefined;
  const v = Object.values(probs).map(Number).filter(Number.isFinite).sort((a, b) => b - a);
  if (!v.length) return undefined;
  return Number(((v[0] ?? 0) - (v[1] ?? 0)).toFixed(4));
}

export function fromGatewayResponse(res: unknown, model = "jev-latest"): Record<string, unknown> {
  const r = (res ?? {}) as Record<string, unknown>;
  const answers = (r.answers ?? {}) as Record<string, Record<string, unknown>>;
  const conf = ((r.providerMetadata as Record<string, Record<string, Record<string, unknown>>> | undefined)?.typesafe?.confidence ?? {}) as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  for (const [name, a] of Object.entries(answers)) {
    if (!a || typeof a !== "object") continue;
    if (a.type === "boolean") {
      out[name] = { type: "noul", noul: Number(a.probability ?? a.noul ?? 0) };
      continue;
    }
    const confidence = typeof conf[name] === "number" ? conf[name] : typeof a.confidence === "number" ? a.confidence : spread(a.probabilities as Record<string, unknown>);
    out[name] = confidence === undefined ? { ...a } : { ...a, confidence };
  }
  const translated: Record<string, unknown> = { model, answers: out };
  if (r.usage) translated.usage = r.usage;
  return translated;
}
