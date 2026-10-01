/**
 * The Overview page's numbers. Metadata only: profiles (tier, trial, subscription
 * status, created_at), per-day usage aggregates (runs, distinct users, cost) and the
 * waitlist count. `computeOverview` is pure so it can be tested with a pinned clock.
 */

import type { AdminUsageDay, Db, Profile } from "../db";
import { dayKey, effectiveTier, isInTrial, LIST_PRICES_USD, type Tier } from "../plans";

/** Subscriptions that are being paid for (Stripe keeps dunning `past_due`). */
export const PAYING_STATUSES = new Set(["active", "past_due"]);

export interface DayPoint { day: string; costUsd: number; revenueUsd: number; runs: number; activeUsers: number; signups: number }

export interface Overview {
  signups: { today: number; d7: number; d30: number };
  activeUsers: { d1: number; d7: number };
  totalUsers: number;
  /** Effective tiers right now; `trial` = free users inside their Pro trial. */
  tierMix: Record<"free" | "trial" | "pro" | "pro_recall", number>;
  trialsRunning: number;
  disabled: number;
  overrides: number;
  payingSubs: { pro: number; pro_recall: number; total: number };
  pastDue: number;
  /** Monthly list price × paying subscriptions (yearly subs counted at the monthly price). */
  mrrUsd: number;
  cost30dUsd: number;
  costTodayUsd: number;
  waitlist: number;
  days: DayPoint[];
}

export function daysBack(now: Date, n: number): string {
  return dayKey(new Date(now.getTime() - n * 86_400_000));
}

export function computeOverview(input: {
  profiles: Profile[];
  usageDaily: AdminUsageDay[];
  active1d: number;
  active7d: number;
  waitlist: number;
  now: Date;
  days?: number;
}): Overview {
  const { profiles, usageDaily, now } = input;
  const nDays = input.days ?? 30;
  const today = dayKey(now);
  const since7 = daysBack(now, 6);
  const since30 = daysBack(now, nDays - 1);

  const tierMix = { free: 0, trial: 0, pro: 0, pro_recall: 0 };
  const paying = { pro: 0, pro_recall: 0, total: 0 };
  let trials = 0, disabled = 0, overrides = 0, pastDue = 0, mrr = 0;
  const signupsByDay = new Map<string, number>();
  const signups = { today: 0, d7: 0, d30: 0 };

  for (const p of profiles) {
    const created = p.createdAt.slice(0, 10);
    signupsByDay.set(created, (signupsByDay.get(created) ?? 0) + 1);
    if (created === today) signups.today += 1;
    if (created >= since7) signups.d7 += 1;
    if (created >= since30) signups.d30 += 1;

    if (p.disabledAt) disabled += 1;
    if (p.tierOverride) overrides += 1;
    const inTrial = isInTrial(p, now);
    if (inTrial) trials += 1;
    const eff: Tier = effectiveTier(p, now);
    tierMix[inTrial ? "trial" : eff] += 1;

    if (p.tier !== "free" && p.subscriptionStatus && PAYING_STATUSES.has(p.subscriptionStatus)) {
      paying[p.tier] += 1;
      paying.total += 1;
      mrr += LIST_PRICES_USD[p.tier].month;
      if (p.subscriptionStatus === "past_due") pastDue += 1;
    }
  }

  const usageByDay = new Map(usageDaily.map((d) => [d.day, d]));
  const revenuePerDay = (mrr * 12) / 365;
  const days: DayPoint[] = [];
  for (let i = nDays - 1; i >= 0; i--) {
    const day = daysBack(now, i);
    const u = usageByDay.get(day);
    days.push({
      day,
      costUsd: u?.costUsd ?? 0,
      revenueUsd: revenuePerDay,
      runs: u?.runs ?? 0,
      activeUsers: u?.activeUsers ?? 0,
      signups: signupsByDay.get(day) ?? 0,
    });
  }

  return {
    signups,
    activeUsers: { d1: input.active1d, d7: input.active7d },
    totalUsers: profiles.length,
    tierMix,
    trialsRunning: trials,
    disabled,
    overrides,
    payingSubs: paying,
    pastDue,
    mrrUsd: mrr,
    cost30dUsd: days.reduce((s, d) => s + d.costUsd, 0),
    costTodayUsd: usageByDay.get(today)?.costUsd ?? 0,
    waitlist: input.waitlist,
    days,
  };
}

export async function loadOverview(db: Db, now = new Date()): Promise<Overview> {
  const [profiles, usageDaily, active1d, active7d, waitlist] = await Promise.all([
    db.adminAllProfiles(),
    db.adminUsageDaily(daysBack(now, 29)),
    db.adminActiveUsers(dayKey(now)),
    db.adminActiveUsers(daysBack(now, 6)),
    db.adminCountWaitlist(),
  ]);
  return computeOverview({ profiles, usageDaily, active1d, active7d, waitlist, now });
}
