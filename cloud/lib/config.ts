/**
 * Product config the admin console edits (`app_config` row "product"): kill switches,
 * the in-app notice, app version gates, per-tier quota overrides, model per feature.
 *
 * Read on every metered request, so it is cached in process for 30 s. Saving from the
 * console invalidates this instance's cache; other serverless instances pick the change
 * up within 30 s. A config read that fails never blocks traffic — the last known (or
 * default) config is served.
 */

import { createHash } from "node:crypto";
import { getDb, type Db } from "./db";
import { HttpError } from "./http";
import { PLANS, type Feature, type Quotas, type Tier, TIERS } from "./plans";

export type FeatureSwitch = "answers" | "tasks" | "voice" | "recall";
export const FEATURE_SWITCHES: readonly FeatureSwitch[] = ["answers", "tasks", "voice", "recall"];

export type NoticeLevel = "info" | "warning" | "critical";
export const NOTICE_LEVELS: readonly NoticeLevel[] = ["info", "warning", "critical"];

export interface Notice {
  /** Content hash — changes whenever the text, level or link changes, so the app can remember dismissals. */
  id: string;
  message: string;
  level: NoticeLevel;
  url?: string;
}

/** Per field: absent = plan default, a number = that cap, null = uncapped. */
export type QuotaOverride = { [K in keyof Quotas]?: number | null };

export type ModelFeature = "answer" | "task" | "digest";
export const MODEL_FEATURES: readonly ModelFeature[] = ["answer", "task", "digest"];

export interface ProductConfig {
  features: Record<FeatureSwitch, boolean>;
  notice: Notice | null;
  minAppVersion: string | null;
  latestVersion: string | null;
  downloadURL: string | null;
  quotas: Partial<Record<Tier, QuotaOverride>>;
  /** null = pass the app's `model` through untouched. */
  models: Record<ModelFeature, string | null>;
  updatedAt: string | null;
  updatedBy: string | null;
}

export const CONFIG_KEY = "product";
export const CONFIG_TTL_MS = 30_000;

export function defaultConfig(): ProductConfig {
  return {
    features: { answers: true, tasks: true, voice: true, recall: true },
    notice: null,
    minAppVersion: null,
    latestVersion: null,
    downloadURL: null,
    quotas: {},
    models: { answer: null, task: null, digest: null },
    updatedAt: null,
    updatedBy: null,
  };
}

// MARK: - Validation

const VERSION = /^\d+(\.\d+){0,3}$/;
const MODEL_ID = /^[\w.:/-]{1,100}$/;

function cleanString(v: unknown, max: number): string | null {
  if (typeof v !== "string") return null;
  const t = v.trim();
  return t ? t.slice(0, max) : null;
}

function cleanUrl(v: unknown): string | null {
  const s = cleanString(v, 2000);
  if (!s) return null;
  try {
    const u = new URL(s);
    return u.protocol === "https:" || u.protocol === "http:" ? u.toString() : null;
  } catch {
    return null;
  }
}

function cleanVersion(v: unknown): string | null {
  const s = cleanString(v, 32);
  return s && VERSION.test(s) ? s : null;
}

function cleanCap(v: unknown): number | null | undefined {
  if (v === null) return null;
  if (typeof v === "number" && Number.isFinite(v) && v >= 0) return Math.floor(v);
  return undefined;
}

export function noticeId(message: string, level: NoticeLevel, url?: string | null): string {
  return createHash("sha256").update(`${level}\n${message}\n${url ?? ""}`).digest("hex").slice(0, 12);
}

export function makeNotice(message: unknown, level: unknown, url?: unknown): Notice | null {
  const m = cleanString(message, 500);
  if (!m) return null;
  const l: NoticeLevel = (NOTICE_LEVELS as readonly unknown[]).includes(level) ? (level as NoticeLevel) : "info";
  const u = cleanUrl(url);
  const n: Notice = { id: noticeId(m, l, u), message: m, level: l };
  if (u) n.url = u;
  return n;
}

/** Anything (a DB row, a form) → a valid config. Unknown or bad values fall back to defaults. */
export function normalizeConfig(raw: unknown): ProductConfig {
  const out = defaultConfig();
  if (!raw || typeof raw !== "object") return out;
  const r = raw as Record<string, unknown>;

  const features = (r.features ?? {}) as Record<string, unknown>;
  for (const f of FEATURE_SWITCHES) if (typeof features[f] === "boolean") out.features[f] = features[f] as boolean;

  const n = r.notice as Record<string, unknown> | null | undefined;
  out.notice = n && typeof n === "object" ? makeNotice(n.message, n.level, n.url) : null;

  out.minAppVersion = cleanVersion(r.minAppVersion);
  out.latestVersion = cleanVersion(r.latestVersion);
  out.downloadURL = cleanUrl(r.downloadURL);

  const quotas = (r.quotas ?? {}) as Record<string, unknown>;
  for (const tier of TIERS) {
    const q = quotas[tier] as Record<string, unknown> | undefined;
    if (!q || typeof q !== "object") continue;
    const o: QuotaOverride = {};
    for (const k of ["answersPerDay", "tasksPerDay", "tasksPerMonth"] as const) {
      const c = cleanCap(q[k]);
      if (c !== undefined) o[k] = c;
    }
    if (Object.keys(o).length) out.quotas[tier] = o;
  }

  const models = (r.models ?? {}) as Record<string, unknown>;
  for (const f of MODEL_FEATURES) {
    const m = cleanString(models[f], 100);
    out.models[f] = m && MODEL_ID.test(m) ? m : null;
  }

  out.updatedAt = cleanString(r.updatedAt, 40);
  out.updatedBy = cleanString(r.updatedBy, 254);
  return out;
}

// MARK: - Cache

interface CacheSlot { value: ProductConfig; at: number }

function slot(): { current?: CacheSlot } {
  const g = globalThis as unknown as { __naviConfigCache?: { current?: CacheSlot } };
  g.__naviConfigCache ??= {};
  return g.__naviConfigCache;
}

export function invalidateConfigCache(): void {
  slot().current = undefined;
}

/** The live config (cached ≤ 30 s). `db` defaults to the process Db. */
export async function getConfig(db?: Db, nowMs: number = Date.now()): Promise<ProductConfig> {
  const s = slot();
  if (s.current && nowMs - s.current.at < CONFIG_TTL_MS) return s.current.value;
  try {
    const store = db ?? (await getDb());
    const value = normalizeConfig(await store.adminGetConfig(CONFIG_KEY));
    s.current = { value, at: nowMs };
    return value;
  } catch (e) {
    console.warn("[navi-cloud] app_config read failed, serving last known config:", e instanceof Error ? e.message : e);
    const fallback = s.current?.value ?? defaultConfig();
    // Retry soon, but not on every request.
    s.current = { value: fallback, at: nowMs - CONFIG_TTL_MS + 5_000 };
    return fallback;
  }
}

/** Validates, stamps and stores; this instance sees the change at once. */
export async function saveConfig(db: Db, next: unknown, by: string, now = new Date()): Promise<ProductConfig> {
  const value = normalizeConfig({ ...(next as object), updatedAt: now.toISOString(), updatedBy: by });
  await db.adminSetConfig(CONFIG_KEY, value, by);
  invalidateConfigCache();
  return value;
}

// MARK: - Quotas

/** The plan's quotas with the console's per-tier overrides applied. */
export function effectiveQuotas(tier: Tier, cfg: ProductConfig | undefined): Quotas {
  const base: Quotas = { ...PLANS[tier].quotas };
  const o = cfg?.quotas[tier];
  if (!o) return base;
  for (const k of ["answersPerDay", "tasksPerDay", "tasksPerMonth"] as const) {
    if (!(k in o)) continue;
    const v = o[k];
    if (v === null) delete base[k];
    else if (typeof v === "number") base[k] = v;
  }
  return base;
}

// MARK: - Kill switches

/** Which switch turns a metered feature off. `route` (typing-time routing) has none. */
export function featureSwitchFor(feature: Feature): FeatureSwitch | null {
  switch (feature) {
    case "answer": return "answers";
    case "task": return "tasks";
    case "voice": return "voice";
    case "recall_triage":
    case "recall_digest": return "recall";
    default: return null;
  }
}

const SWITCH_LABEL: Record<FeatureSwitch, string> = {
  answers: "Answers are",
  tasks: "Tasks are",
  voice: "Voice control is",
  recall: "Recall is",
};

/** 503 `feature_disabled` when the console has switched this feature off. */
export function assertFeatureEnabled(cfg: ProductConfig, feature: Feature): void {
  const sw = featureSwitchFor(feature);
  if (!sw || cfg.features[sw]) return;
  throw new HttpError(503, {
    error: "feature_disabled",
    feature: sw,
    message: `${SWITCH_LABEL[sw]} paused for a moment while we fix something. Try again soon.`,
  });
}

// MARK: - App version gate

/** Numeric dotted compare ("1.10" > "1.9"); anything after a non-digit is ignored ("1.2.0-beta" = 1.2.0). */
export function compareVersions(a: string, b: string): number {
  const parse = (v: string) => v.trim().split(".").map((p) => parseInt(p, 10)).map((n) => (Number.isFinite(n) ? n : 0));
  const x = parse(a);
  const y = parse(b);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (x[i] ?? 0) - (y[i] ?? 0);
    if (d !== 0) return d < 0 ? -1 : 1;
  }
  return 0;
}

/**
 * 426 `upgrade_required` when `X-Navi-Version` is below `minAppVersion`. A missing or
 * unparseable header passes (curl, scripts, builds from before the header existed).
 */
export function assertAppVersion(cfg: ProductConfig, versionHeader: string | null | undefined): void {
  if (!cfg.minAppVersion) return;
  const v = versionHeader?.trim();
  if (!v || !/^\d/.test(v)) return;
  if (compareVersions(v, cfg.minAppVersion) >= 0) return;
  const body: Record<string, unknown> = {
    error: "upgrade_required",
    minAppVersion: cfg.minAppVersion,
    message: "This version of Navi is no longer supported. Update to keep going.",
  };
  if (cfg.downloadURL) body.downloadURL = cfg.downloadURL;
  throw new HttpError(426, body);
}

// MARK: - Model per feature

/**
 * The model to force for a call, or null to pass the request's own through. Only
 * applies when the configured id belongs to the vendor the call is going to.
 */
export function modelOverride(cfg: ProductConfig | undefined, feature: Feature, vendor: "anthropic" | "gemini"): string | null {
  if (!cfg) return null;
  const slotFor: ModelFeature | null =
    feature === "answer" ? "answer"
    : feature === "task" || feature === "voice" ? "task"
    : feature === "recall_digest" || feature === "recall_triage" ? "digest"
    : null;
  const m = slotFor ? cfg.models[slotFor] : null;
  if (!m) return null;
  const isGemini = m.startsWith("gemini");
  return (vendor === "gemini") === isGemini ? m : null;
}

// MARK: - /v1/me

/** The `config` block of `GET /v1/me`. */
export function meConfig(cfg: ProductConfig): Record<string, unknown> {
  const out: Record<string, unknown> = { features: { ...cfg.features } };
  if (cfg.notice) out.notice = { ...cfg.notice };
  if (cfg.minAppVersion) out.minAppVersion = cfg.minAppVersion;
  if (cfg.latestVersion) out.latestVersion = cfg.latestVersion;
  if (cfg.downloadURL) out.downloadURL = cfg.downloadURL;
  return out;
}
