import { describe, expect, it } from "vitest";
import {
  checkQuota,
  dayKey,
  effectiveTier,
  entitlementsFor,
  featuresInBucket,
  isInTrial,
  monthKey,
  nextResetFor,
  PLANS,
  resetsAt,
  trialEnd,
  windowFor,
} from "@/lib/plans";

const T = new Date("2026-09-22T15:30:00Z");

describe("tiers", () => {
  it("free has daily caps and no voice/recall", () => {
    expect(PLANS.free.quotas).toEqual({ answersPerDay: 20, tasksPerDay: 5 });
    expect(PLANS.free.entitlements).toEqual({ answers: true, tasks: true, voice: false, recall: false });
  });
  it("pro is fair-use answers, 300 tasks/month, voice", () => {
    expect(PLANS.pro.quotas).toEqual({ answersPerDay: 500, tasksPerMonth: 300 });
    expect(PLANS.pro.entitlements.voice).toBe(true);
    expect(PLANS.pro.entitlements.recall).toBe(false);
  });
  it("pro_recall adds recall only", () => {
    expect(PLANS.pro_recall.quotas).toEqual(PLANS.pro.quotas);
    expect(PLANS.pro_recall.entitlements).toEqual({ ...PLANS.pro.entitlements, recall: true });
  });
});

describe("trial", () => {
  it("lasts 7 days from sign-up", () => {
    expect(trialEnd(T).toISOString()).toBe("2026-09-29T15:30:00.000Z");
  });
  it("serves a free user as pro until the trial ends", () => {
    const p = { tier: "free" as const, trialEndsAt: "2026-09-29T15:30:00Z" };
    expect(effectiveTier(p, T)).toBe("pro");
    expect(isInTrial(p, T)).toBe(true);
    expect(effectiveTier(p, new Date("2026-09-29T15:30:00Z"))).toBe("free");
    expect(effectiveTier(p, new Date("2026-10-01T00:00:00Z"))).toBe("free");
  });
  it("never downgrades a paid tier", () => {
    expect(effectiveTier({ tier: "pro_recall", trialEndsAt: "2020-01-01T00:00:00Z" }, T)).toBe("pro_recall");
    expect(isInTrial({ tier: "pro", trialEndsAt: "2099-01-01T00:00:00Z" }, T)).toBe(false);
  });
});

describe("entitlements", () => {
  it("merges non-expired manual grants on top of the plan", () => {
    const e = entitlementsFor("free", [{ key: "recall", expiresAt: "2026-12-31T00:00:00Z" }, { key: "voice", expiresAt: "2026-01-01T00:00:00Z" }], T);
    expect(e).toEqual({ answers: true, tasks: true, voice: false, recall: true });
  });
  it("ignores unknown keys", () => {
    expect(entitlementsFor("free", [{ key: "admin" }], T)).toEqual(PLANS.free.entitlements);
  });
});

describe("windows and resets", () => {
  it("picks day windows for free and month for pro tasks", () => {
    expect(windowFor("free", "answers")).toEqual({ kind: "day", limit: 20 });
    expect(windowFor("free", "tasks")).toEqual({ kind: "day", limit: 5 });
    expect(windowFor("pro", "answers")).toEqual({ kind: "day", limit: 500 });
    expect(windowFor("pro", "tasks")).toEqual({ kind: "month", limit: 300 });
  });
  it("keys are UTC", () => {
    const lateNight = new Date("2026-09-22T23:59:59Z");
    expect(dayKey(lateNight)).toBe("2026-09-22");
    expect(monthKey(lateNight)).toBe("2026-09");
  });
  it("daily resets at next UTC midnight, monthly on the 1st", () => {
    expect(resetsAt(T, "day").toISOString()).toBe("2026-09-23T00:00:00.000Z");
    expect(resetsAt(T, "month").toISOString()).toBe("2026-10-01T00:00:00.000Z");
    expect(resetsAt(new Date("2026-12-31T23:00:00Z"), "month").toISOString()).toBe("2027-01-01T00:00:00.000Z");
    expect(resetsAt(new Date("2026-12-31T23:00:00Z"), "day").toISOString()).toBe("2027-01-01T00:00:00.000Z");
  });
  it("/v1/me reports the soonest reset", () => {
    expect(nextResetFor("free", T).toISOString()).toBe("2026-09-23T00:00:00.000Z");
    expect(nextResetFor("pro", T).toISOString()).toBe("2026-09-23T00:00:00.000Z");
  });
  it("voice draws from the tasks bucket", () => {
    expect(featuresInBucket("tasks")).toEqual(["task", "voice"]);
    expect(featuresInBucket("answers")).toEqual(["answer"]);
  });
});

describe("checkQuota", () => {
  const free = PLANS.free.entitlements;
  const pro = PLANS.pro.entitlements;

  it("allows under the cap and blocks at it", () => {
    expect(checkQuota({ tier: "free", entitlements: free, feature: "answer", used: 19, runAlreadyCounted: false, now: T }).ok).toBe(true);
    const blocked = checkQuota({ tier: "free", entitlements: free, feature: "answer", used: 20, runAlreadyCounted: false, now: T });
    expect(blocked).toEqual({ ok: false, status: 402, error: "quota_exceeded", feature: "answer", tier: "free", resetsAt: "2026-09-23T00:00:00.000Z" });
  });
  it("never cuts off a run that already holds a unit", () => {
    expect(checkQuota({ tier: "free", entitlements: free, feature: "task", used: 99, runAlreadyCounted: true, now: T }).ok).toBe(true);
  });
  it("403s features the tier lacks, before any quota check", () => {
    expect(checkQuota({ tier: "free", entitlements: free, feature: "voice", used: 0, runAlreadyCounted: false, now: T })).toEqual({
      ok: false, status: 403, error: "not_entitled", feature: "voice", tier: "free",
    });
    expect(checkQuota({ tier: "pro", entitlements: pro, feature: "recall_digest", used: 0, runAlreadyCounted: false, now: T })).toMatchObject({ status: 403 });
  });
  it("route and recall are never capped", () => {
    expect(checkQuota({ tier: "free", entitlements: free, feature: "route", used: 10_000, runAlreadyCounted: false, now: T }).ok).toBe(true);
    expect(checkQuota({ tier: "pro_recall", entitlements: PLANS.pro_recall.entitlements, feature: "recall_triage", used: 10_000, runAlreadyCounted: false, now: T }).ok).toBe(true);
  });
  it("pro tasks reset monthly", () => {
    const r = checkQuota({ tier: "pro", entitlements: pro, feature: "task", used: 300, runAlreadyCounted: false, now: T });
    expect(r).toMatchObject({ status: 402, resetsAt: "2026-10-01T00:00:00.000Z" });
  });
});
