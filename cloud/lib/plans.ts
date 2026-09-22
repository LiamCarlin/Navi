/**
 * Tiers → entitlements → quotas. Pure: no I/O, no env, no Date.now() —
 * every function takes `now` so the tests can pin time.
 *
 * Tier table (docs/LAUNCH_ROADMAP.md §2):
 *   free        20 answers/day, 5 tasks/day, no voice, no recall
 *   pro         answers unlimited-fair-use (cap 500/day), 300 tasks/month, voice
 *   pro_recall  pro + recall
 * New users get a 7-day Pro trial (`profiles.trial_ends_at`).
 */

export type Tier = "free" | "pro" | "pro_recall";
export const TIERS: readonly Tier[] = ["free", "pro", "pro_recall"];

export type Feature = "route" | "answer" | "task" | "voice" | "recall_triage" | "recall_digest";
export const FEATURES: readonly Feature[] = ["route", "answer", "task", "voice", "recall_triage", "recall_digest"];

export type EntitlementKey = "answers" | "tasks" | "voice" | "recall";
export const ENTITLEMENT_KEYS: readonly EntitlementKey[] = ["answers", "tasks", "voice", "recall"];

/** Which counter a feature draws down. `null` = recorded for cost only, never capped. */
export type Bucket = "answers" | "tasks";

export type Entitlements = Record<EntitlementKey, boolean>;

export interface Quotas {
  answersPerDay?: number;
  tasksPerDay?: number;
  tasksPerMonth?: number;
}

export interface Plan {
  tier: Tier;
  entitlements: Entitlements;
  quotas: Quotas;
}

export const PLANS: Record<Tier, Plan> = {
  free: {
    tier: "free",
    entitlements: { answers: true, tasks: true, voice: false, recall: false },
    quotas: { answersPerDay: 20, tasksPerDay: 5 },
  },
  pro: {
    tier: "pro",
    entitlements: { answers: true, tasks: true, voice: true, recall: false },
    quotas: { answersPerDay: 500, tasksPerMonth: 300 },
  },
  pro_recall: {
    tier: "pro_recall",
    entitlements: { answers: true, tasks: true, voice: true, recall: true },
    quotas: { answersPerDay: 500, tasksPerMonth: 300 },
  },
};

export const TRIAL_DAYS = 7;

/**
 * What each `X-Navi-Feature` needs and what it counts against.
 *  - route:         Jev routing while typing. Free for everyone, cost-tracked only.
 *  - answer:        one streamed answer = one unit of `answers`.
 *  - task:          one computer-use run = one unit of `tasks` (however many calls it makes).
 *  - voice:         needs the voice entitlement; a spoken task draws from `tasks`.
 *  - recall_*:      need the recall entitlement; cost-tracked, not capped.
 */
export const FEATURE_RULES: Record<Feature, { entitlement: EntitlementKey | null; bucket: Bucket | null }> = {
  route: { entitlement: null, bucket: null },
  answer: { entitlement: "answers", bucket: "answers" },
  task: { entitlement: "tasks", bucket: "tasks" },
  voice: { entitlement: "voice", bucket: "tasks" },
  recall_triage: { entitlement: "recall", bucket: null },
  recall_digest: { entitlement: "recall", bucket: null },
};

/** Features that share a bucket (a task and a spoken task both spend `tasks`). */
export function featuresInBucket(bucket: Bucket): Feature[] {
  return FEATURES.filter((f) => FEATURE_RULES[f].bucket === bucket);
}

export function isTier(x: unknown): x is Tier {
  return typeof x === "string" && (TIERS as readonly string[]).includes(x);
}

export function isFeature(x: unknown): x is Feature {
  return typeof x === "string" && (FEATURES as readonly string[]).includes(x);
}

// MARK: - Trial

export interface TierSource {
  tier: Tier;
  /** ISO-8601, or null when the trial is over / never existed. */
  trialEndsAt?: string | null;
}

/** The tier a user is actually served at: a Free user inside their trial window is Pro. */
export function effectiveTier(profile: TierSource, now: Date): Tier {
  if (profile.tier !== "free") return profile.tier;
  if (profile.trialEndsAt && new Date(profile.trialEndsAt).getTime() > now.getTime()) return "pro";
  return "free";
}

export function isInTrial(profile: TierSource, now: Date): boolean {
  return profile.tier === "free" && effectiveTier(profile, now) === "pro";
}

export function trialEnd(signupAt: Date): Date {
  return new Date(signupAt.getTime() + TRIAL_DAYS * 86_400_000);
}

// MARK: - Entitlements

/** Plan entitlements plus any manual grants (rows in `entitlements` that have not expired). */
export function entitlementsFor(tier: Tier, grants: readonly { key: string; expiresAt?: string | null }[] = [], now: Date = new Date(0)): Entitlements {
  const out: Entitlements = { ...PLANS[tier].entitlements };
  for (const g of grants) {
    if (!(ENTITLEMENT_KEYS as readonly string[]).includes(g.key)) continue;
    if (g.expiresAt && new Date(g.expiresAt).getTime() <= now.getTime()) continue;
    out[g.key as EntitlementKey] = true;
  }
  return out;
}

// MARK: - Windows and resets

export type WindowKind = "day" | "month";

export interface QuotaWindow {
  kind: WindowKind;
  limit: number;
}

/** The cap that applies to a bucket at a tier, or null when that bucket is uncapped. */
export function windowFor(tier: Tier, bucket: Bucket): QuotaWindow | null {
  const q = PLANS[tier].quotas;
  if (bucket === "answers") {
    return q.answersPerDay != null ? { kind: "day", limit: q.answersPerDay } : null;
  }
  if (q.tasksPerDay != null) return { kind: "day", limit: q.tasksPerDay };
  if (q.tasksPerMonth != null) return { kind: "month", limit: q.tasksPerMonth };
  return null;
}

/** `YYYY-MM-DD` in UTC — the `usage.day` column. */
export function dayKey(now: Date): string {
  return now.toISOString().slice(0, 10);
}

/** `YYYY-MM` in UTC — the `usage.month` column. */
export function monthKey(now: Date): string {
  return now.toISOString().slice(0, 7);
}

/** Next UTC midnight for daily windows; first of next month 00:00 UTC for monthly. */
export function resetsAt(now: Date, kind: WindowKind): Date {
  if (kind === "day") {
    return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1));
  }
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1));
}

// MARK: - Decision

export type QuotaDecision =
  | { ok: true; bucket: Bucket | null; window: QuotaWindow | null }
  | { ok: false; status: 402; error: "quota_exceeded"; feature: Feature; tier: Tier; resetsAt: string }
  | { ok: false; status: 403; error: "not_entitled"; feature: Feature; tier: Tier };

export interface QuotaInput {
  tier: Tier;
  entitlements: Entitlements;
  feature: Feature;
  /** Units already spent in the bucket's current window (day or month). */
  used: number;
  /** True when this run already holds a unit — a continuing run is never cut off mid-way. */
  runAlreadyCounted: boolean;
  now: Date;
}

/** The one place the 402/403 rules live. */
export function checkQuota(input: QuotaInput): QuotaDecision {
  const rule = FEATURE_RULES[input.feature];
  if (rule.entitlement && !input.entitlements[rule.entitlement]) {
    return { ok: false, status: 403, error: "not_entitled", feature: input.feature, tier: input.tier };
  }
  if (!rule.bucket) return { ok: true, bucket: null, window: null };
  const window = windowFor(input.tier, rule.bucket);
  if (!window) return { ok: true, bucket: rule.bucket, window: null };
  if (!input.runAlreadyCounted && input.used >= window.limit) {
    return {
      ok: false,
      status: 402,
      error: "quota_exceeded",
      feature: input.feature,
      tier: input.tier,
      resetsAt: resetsAt(input.now, window.kind).toISOString(),
    };
  }
  return { ok: true, bucket: rule.bucket, window };
}

/** The `resetsAt` reported by `/v1/me`: the soonest reset among the tier's active windows. */
export function nextResetFor(tier: Tier, now: Date): Date {
  const kinds = new Set<WindowKind>();
  for (const b of ["answers", "tasks"] as Bucket[]) {
    const w = windowFor(tier, b);
    if (w) kinds.add(w.kind);
  }
  if (kinds.size === 0) return resetsAt(now, "day");
  return new Date(Math.min(...[...kinds].map((k) => resetsAt(now, k).getTime())));
}
