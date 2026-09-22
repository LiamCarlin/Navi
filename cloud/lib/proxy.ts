/**
 * The metered vendor proxy behind /v1/jev, /v1/claude and /v1/digest.
 *
 *   request ─▶ bearer auth ─▶ per-user rate limit ─▶ feature/run headers
 *           ─▶ authorize (403 / 402) ─▶ upstream (or mock) ─▶ cost ─▶ passthrough
 *
 * Bodies pass through byte-for-byte. Claude streams (`stream: true`) are piped
 * unbuffered through a TransformStream that only *reads* the SSE to tally usage.
 */

import { randomUUID } from "node:crypto";
import { requireUser, type AuthUser } from "./auth";
import { getDb, type Db } from "./db";
import { env } from "./env";
import { badRequest, HttpError, json, parseJson, rateLimited } from "./http";
import { authorize, recordCost, type Authorization } from "./metering";
import { mockClaudeMessage, mockClaudeStream, mockGeminiResponse, mockJevResponse } from "./mock";
import { isFeature, type Feature } from "./plans";
import { anthropicCostUsd, anthropicUsageFromMessage, geminiCostUsd, geminiUsageFromResponse, JEV_FLAT_USD } from "./pricing";
import { perUserLimiter } from "./ratelimit";

export type Upstream = "jev" | "claude" | "digest";

const DEFAULT_FEATURE: Record<Upstream, Feature> = { jev: "route", claude: "answer", digest: "recall_digest" };

interface Ctx {
  db: Db;
  user: AuthUser;
  auth: Authorization;
}

/** Validates `X-Navi-Feature`; /v1/digest only ever meters as a recall feature. */
export function resolveFeature(header: string | null, upstream: Upstream): Feature {
  if (!header) return DEFAULT_FEATURE[upstream];
  if (!isFeature(header)) throw badRequest(`Unknown X-Navi-Feature "${header}".`, { allowed: ["route", "answer", "task", "voice", "recall_triage", "recall_digest"] });
  if (upstream === "digest" && !header.startsWith("recall_")) return "recall_digest";
  return header;
}

export function resolveRunId(header: string | null): string {
  const v = header?.trim();
  if (!v) return randomUUID();
  if (v.length > 128 || !/^[\w.:-]+$/.test(v)) throw badRequest("X-Navi-Run must be a UUID-like token (≤128 chars).");
  return v;
}

function withNaviHeaders(res: Response, ctx: Ctx): Response {
  const headers = new Headers(res.headers);
  headers.set("x-navi-tier", ctx.auth.tier);
  headers.set("x-navi-run", ctx.auth.runId);
  headers.set("x-navi-feature", ctx.auth.feature);
  headers.set("cache-control", "no-store");
  return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
}

export async function handleMeteredProxy(req: Request, upstream: Upstream): Promise<Response> {
  const user = await requireUser(req);
  const rl = perUserLimiter.hit(user.id);
  if (!rl.ok) throw rateLimited(rl.retryAfterSeconds);

  const feature = resolveFeature(req.headers.get("x-navi-feature"), upstream);
  const runId = resolveRunId(req.headers.get("x-navi-run"));
  const bodyText = await req.text();
  const body = parseJson<Record<string, unknown>>(bodyText);

  const db = await getDb();
  const auth = await authorize(db, user, feature, runId, new Date());
  const ctx: Ctx = { db, user, auth };

  let res: Response;
  switch (upstream) {
    case "jev":
      res = await proxyJev(bodyText, body, ctx);
      break;
    case "claude":
      res = await proxyClaude(bodyText, body, req.headers, ctx);
      break;
    case "digest":
      res = body.provider === "gemini" && (env.geminiApiKey || env.mockUpstream)
        ? await proxyGemini(body, ctx)
        : await proxyClaude(stripKeys(bodyText, body, ["provider"]), body, req.headers, ctx);
      break;
  }
  return withNaviHeaders(res, ctx);
}

function stripKeys(text: string, body: Record<string, unknown>, keys: string[]): string {
  if (!keys.some((k) => k in body)) return text;
  const copy = { ...body };
  for (const k of keys) delete copy[k];
  return JSON.stringify(copy);
}

function unconfigured(vendor: string): HttpError {
  return new HttpError(503, { error: "upstream_unconfigured", message: `${vendor} is not configured on this Navi Cloud deployment.` });
}

/** Timeout for the upstream connection; long Claude runs stream, so this bounds headers-received. */
const UPSTREAM_TIMEOUT_MS = 120_000;

// MARK: - Jev

async function proxyJev(bodyText: string, body: unknown, ctx: Ctx): Promise<Response> {
  if (env.mockUpstream) {
    await recordCost(ctx.db, ctx.auth, ctx.user.id, JEV_FLAT_USD);
    return json(mockJevResponse(body));
  }
  const key = env.typesafeApiKey;
  if (!key) throw unconfigured("Jev");
  const up = await fetch(env.typesafeUrl, {
    method: "POST",
    headers: { authorization: `Bearer ${key}`, "content-type": "application/json", accept: "application/json" },
    body: bodyText,
    signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
  });
  const text = await up.text();
  if (up.ok) await recordCost(ctx.db, ctx.auth, ctx.user.id, JEV_FLAT_USD);
  return new Response(text, { status: up.status, headers: { "content-type": up.headers.get("content-type") ?? "application/json" } });
}

// MARK: - Claude

const SSE_HEADERS = { "content-type": "text/event-stream; charset=utf-8", "cache-control": "no-cache, no-transform", connection: "keep-alive", "x-accel-buffering": "no" };

async function proxyClaude(bodyText: string, body: Record<string, unknown>, reqHeaders: Headers, ctx: Ctx): Promise<Response> {
  const stream = body.stream === true;
  const model = typeof body.model === "string" ? body.model : undefined;

  if (env.mockUpstream) {
    if (stream) {
      const tallied = mockClaudeStream(body).pipeThrough(usageTally((u) => recordCost(ctx.db, ctx.auth, ctx.user.id, anthropicCostUsd(model, u.input, u.output))));
      return new Response(tallied, { status: 200, headers: SSE_HEADERS });
    }
    const msg = mockClaudeMessage(body);
    const u = anthropicUsageFromMessage(msg);
    await recordCost(ctx.db, ctx.auth, ctx.user.id, anthropicCostUsd(model, u.input, u.output));
    return json(msg);
  }

  const key = env.anthropicApiKey;
  if (!key) throw unconfigured("Claude");
  const headers: Record<string, string> = {
    "x-api-key": key,
    "anthropic-version": reqHeaders.get("anthropic-version") ?? "2023-06-01",
    "content-type": "application/json",
    accept: stream ? "text/event-stream" : "application/json",
  };
  const beta = reqHeaders.get("anthropic-beta");
  if (beta) headers["anthropic-beta"] = beta;

  const up = await fetch(env.anthropicUrl, {
    method: "POST",
    headers,
    body: bodyText,
    signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
  });

  if (!up.ok || !stream || !up.body) {
    const text = await up.text();
    if (up.ok) {
      const u = anthropicUsageFromMessage(safeJson(text));
      await recordCost(ctx.db, ctx.auth, ctx.user.id, anthropicCostUsd(model, u.input, u.output));
    }
    const passthrough: Record<string, string> = { "content-type": up.headers.get("content-type") ?? "application/json" };
    const reqId = up.headers.get("request-id");
    if (reqId) passthrough["x-upstream-request-id"] = reqId;
    return new Response(text, { status: up.status, headers: passthrough });
  }

  const tallied = up.body.pipeThrough(usageTally((u) => recordCost(ctx.db, ctx.auth, ctx.user.id, anthropicCostUsd(model, u.input, u.output))));
  return new Response(tallied, { status: 200, headers: SSE_HEADERS });
}

function safeJson(text: string): unknown {
  try { return JSON.parse(text); } catch { return null; }
}

/**
 * Passes SSE bytes through untouched while reading `message_start.usage.input_tokens`
 * and `message_delta.usage.output_tokens`; reports once at end of stream.
 */
export function usageTally(onDone: (u: { input: number; output: number }) => Promise<void> | void): TransformStream<Uint8Array, Uint8Array> {
  const dec = new TextDecoder();
  let pending = "";
  let input = 0;
  let output = 0;
  let reported = false;

  const scan = (chunk: string) => {
    pending += chunk;
    const lines = pending.split("\n");
    pending = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.startsWith("data:")) continue;
      const evt = safeJson(line.slice(5).trim()) as { type?: string; message?: { usage?: { input_tokens?: number } }; usage?: { output_tokens?: number } } | null;
      if (!evt) continue;
      if (evt.type === "message_start") input = Number(evt.message?.usage?.input_tokens ?? input);
      if (evt.type === "message_delta") output = Number(evt.usage?.output_tokens ?? output);
    }
  };
  const report = async () => {
    if (reported) return;
    reported = true;
    await onDone({ input, output });
  };

  // `cancel` (client went away mid-stream) is in the Streams spec and Node ≥ 21, but not yet
  // in TypeScript's lib.dom Transformer type — hence the cast.
  const transformer: Transformer<Uint8Array, Uint8Array> & { cancel?: () => Promise<void> } = {
    transform(chunk, controller) {
      controller.enqueue(chunk);
      scan(dec.decode(chunk, { stream: true }));
    },
    async flush() {
      scan(dec.decode());
      await report();
    },
    async cancel() {
      await report();
    },
  };
  return new TransformStream<Uint8Array, Uint8Array>(transformer);
}

// MARK: - Gemini (digest only)

async function proxyGemini(body: Record<string, unknown>, ctx: Ctx): Promise<Response> {
  const model = typeof body.model === "string" ? body.model : env.geminiDefaultModel;
  if (env.mockUpstream) {
    const res = mockGeminiResponse();
    const u = geminiUsageFromResponse(res);
    await recordCost(ctx.db, ctx.auth, ctx.user.id, geminiCostUsd(model, u.input, u.output));
    return json(res);
  }
  const key = env.geminiApiKey;
  if (!key) throw unconfigured("Gemini");
  const payload = { ...body };
  delete payload.provider;
  delete payload.model;
  const up = await fetch(`${env.geminiBaseUrl}/${encodeURIComponent(model)}:generateContent`, {
    method: "POST",
    headers: { "x-goog-api-key": key, "content-type": "application/json" },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
  });
  const text = await up.text();
  if (up.ok) {
    const u = geminiUsageFromResponse(safeJson(text));
    await recordCost(ctx.db, ctx.auth, ctx.user.id, geminiCostUsd(model, u.input, u.output));
  }
  return new Response(text, { status: up.status, headers: { "content-type": up.headers.get("content-type") ?? "application/json" } });
}
