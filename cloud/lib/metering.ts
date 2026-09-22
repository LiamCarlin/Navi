/**
 * Metering: one usage unit per distinct (user, feature, run), quota checked
 * before the proxy call, cost attached after. Pure over an injected `Db`.
 */

import type { AuthUser } from "./auth";
import type { Db, Profile } from "./db";
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

export async function loadAccount(db: Db, user: AuthUser, now: Date): Promise<{ profile: Profile; tier: Tier; entitlements: Entitlements }> {
  const profile = await db.ensureProfile(user.id, user.email, now);
  const tier = effectiveTier(profile, now);
  const grants = await db.listEntitlements(user.id);
  return { profile, tier, entitlements: entitlementsFor(tier, grants, now) };
}

/**
 * Gate + record. Throws HttpError 402 (`quota_exceeded`) or 403 (`not_entitled`).
 * A run that already holds a unit is always let through — the quota is spent
 * when the run starts, never mid-way.
 */
export async function authorize(db: Db, user: AuthUser, feature: Feature, runId: string, now: Date): Promise<Authorization> {
  const { profile, tier, entitlements } = await loadAccount(db, user, now);
  const rule = FEATURE_RULES[feature];

  let used = 0;
  const runAlreadyCounted = await db.hasUsage(user.id, feature, runId);
  if (rule.bucket && !runAlreadyCounted) {
    const window = windowFor(tier, rule.bucket);
    if (window) {
      const key = window.kind === "day" ? { day: dayKey(now) } : { month: monthKey(now) };
      used = await db.countUsage(user.id, featuresInBucket(rule.bucket), key);
    }
  }

  const decision = checkQuota({ tier, entitlements, feature, used, runAlreadyCounted, now });
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

export async function usageSummary(db: Db, userId: string, tier: Tier, now: Date): Promise<UsageSummary> {
  const day = dayKey(now);
  const month = monthKey(now);
  const [answersToday, tasksToday, tasksThisMonth] = await Promise.all([
    db.countUsage(userId, featuresInBucket("answers"), { day }),
    db.countUsage(userId, featuresInBucket("tasks"), { day }),
    db.countUsage(userId, featuresInBucket("tasks"), { month }),
  ]);
  return { answersToday, tasksToday, tasksThisMonth, resetsAt: nextResetFor(tier, now).toISOString() };
}

/** The `GET /v1/me` body (§3.1). */
export async function meBody(db: Db, user: AuthUser, now: Date) {
  const { profile, tier, entitlements } = await loadAccount(db, user, now);
  const usage = await usageSummary(db, user.id, tier, now);
  const body: Record<string, unknown> = {
    user: { id: user.id, email: profile.email || user.email },
    tier,
    entitlements,
    quotas: PLANS[tier].quotas,
    usage,
  };
  if (profile.tier === "free" && profile.trialEndsAt && new Date(profile.trialEndsAt) > now) {
    body.trialEndsAt = profile.trialEndsAt;
  }
  return body;
}
