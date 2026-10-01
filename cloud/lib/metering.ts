/**
 * Metering: one usage unit per distinct (user, feature, run), quota checked
 * before the proxy call, cost attached after. Pure over an injected `Db`.
 */

import { usedAfterReset } from "./admin/quota";
import type { AuthUser } from "./auth";
import { assertAppVersion, assertFeatureEnabled, effectiveQuotas, meConfig, type ProductConfig } from "./config";
import type { Db, Profile, QuotaReset } from "./db";
import { HttpError } from "./http";
import {
  checkQuota,
  dayKey,
  effectiveTier,
  entitlementsFor,
  FEATURE_RULES,
  featuresInBucket,
  monthKey,
  nextResetFor,
  PLANS,
  windowFor,
  type Entitlements,
  type Feature,
  type Tier,
} from "./plans";

export interface Authorization {
  profile: Profile;
  tier: Tier;
  entitlements: Entitlements;
  feature: Feature;
  runId: string;
  /** True when this call created the run's usage unit (false for later calls in the same run). */
  newUnit: boolean;
}

/** Shown with 403 `account_disabled` (the admin's internal reason is never sent). */
export const ACCOUNT_DISABLED_MESSAGE = "This Navi account has been disabled. Contact hello@navi.app if you think this is a mistake.";

export async function loadAccount(db: Db, user: AuthUser, now: Date): Promise<{ profile: Profile; tier: Tier; entitlements: Entitlements }> {
  const profile = await db.ensureProfile(user.id, user.email, now);
  if (profile.disabledAt) throw new HttpError(403, { error: "account_disabled", message: ACCOUNT_DISABLED_MESSAGE });
  const tier = effectiveTier(profile, now);
  const grants = await db.listEntitlements(user.id);
  return { profile, tier, entitlements: entitlementsFor(tier, grants, now) };
}

/** Admin-console gates applied by `authorize` (lib/config.ts). */
export interface Gates {
  config?: ProductConfig;
  /** The `X-Navi-Version` header. */
  appVersion?: string | null;
}

/**
 * Gate + record. Throws, in this order: 403 `account_disabled`, 426 `upgrade_required`,
 * 503 `feature_disabled`, 403 `not_entitled`, 402 `quota_exceeded`.
 * A run that already holds a unit is always let through — the quota is spent
 * when the run starts, never mid-way.
 */
export async function authorize(db: Db, user: AuthUser, feature: Feature, runId: string, now: Date, gates: Gates = {}): Promise<Authorization> {
  const { profile, tier, entitlements } = await loadAccount(db, user, now);
  if (gates.config) {
    assertAppVersion(gates.config, gates.appVersion);
    assertFeatureEnabled(gates.config, feature);
  }
  const quotas = effectiveQuotas(tier, gates.config);
  const rule = FEATURE_RULES[feature];

  let used = 0;
  const runAlreadyCounted = await db.hasUsage(user.id, feature, runId);
  if (rule.bucket && !runAlreadyCounted) {
    const window = windowFor(tier, rule.bucket, quotas);
    if (window) {
      const key = window.kind === "day" ? { day: dayKey(now) } : { month: monthKey(now) };
      used = await db.countUsage(user.id, featuresInBucket(rule.bucket), key);
      used = usedAfterReset(used, profile.quotaReset, rule.bucket, window.kind, now);
    }
  }

  const decision = checkQuota({ tier, entitlements, feature, used, runAlreadyCounted, now, quotas });
  if (!decision.ok) {
    const { ok: _ok, status, ...body } = decision;
    throw new HttpError(status, body);
  }

  const newUnit = await db.recordUsage({ userId: user.id, feature, runId, day: dayKey(now), month: monthKey(now) });
  return { profile, tier, entitlements, feature, runId, newUnit };
}

export async function recordCost(db: Db, auth: Pick<Authorization, "feature" | "runId">, userId: string, costUsd: number): Promise<void> {
  if (!(costUsd > 0)) return;
  try {
    await db.addUsageCost(userId, auth.feature, auth.runId, costUsd);
  } catch (e) {
    console.warn("[navi-cloud] cost record failed:", e);
  }
}

export interface UsageSummary {
  answersToday: number;
  tasksToday: number;
  tasksThisMonth: number;
  /** ISO-8601: the soonest reset among the tier's active windows. */
  resetsAt: string;
}

export async function usageSummary(db: Db, userId: string, tier: Tier, now: Date, reset?: QuotaReset | null, cfg?: ProductConfig): Promise<UsageSummary> {
  const day = dayKey(now);
  const month = monthKey(now);
  const [answersToday, tasksToday, tasksThisMonth] = await Promise.all([
    db.countUsage(userId, featuresInBucket("answers"), { day }),
    db.countUsage(userId, featuresInBucket("tasks"), { day }),
    db.countUsage(userId, featuresInBucket("tasks"), { month }),
  ]);
  return {
    answersToday: usedAfterReset(answersToday, reset, "answers", "day", now),
    tasksToday: usedAfterReset(tasksToday, reset, "tasks", "day", now),
    tasksThisMonth: usedAfterReset(tasksThisMonth, reset, "tasks", "month", now),
    resetsAt: nextResetFor(tier, now, effectiveQuotas(tier, cfg)).toISOString(),
  };
}

/** The `GET /v1/me` body (§3.1), plus `config` from the admin console. 403 `account_disabled` when disabled. */
export async function meBody(db: Db, user: AuthUser, now: Date, cfg?: ProductConfig) {
  const { profile, tier, entitlements } = await loadAccount(db, user, now);
  const usage = await usageSummary(db, user.id, tier, now, profile.quotaReset, cfg);
  const body: Record<string, unknown> = {
    user: { id: user.id, email: profile.email || user.email },
    tier,
    entitlements,
    quotas: cfg ? effectiveQuotas(tier, cfg) : PLANS[tier].quotas,
    usage,
  };
  if (profile.tier === "free" && !profile.tierOverride && profile.trialEndsAt && new Date(profile.trialEndsAt) > now) {
    body.trialEndsAt = profile.trialEndsAt;
  }
  if (cfg) body.config = meConfig(cfg);
  return body;
}
