import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as ops from "@/lib/admin/ops";
import { computeOverview } from "@/lib/admin/overview";
import { csvField, withFlash } from "@/lib/admin/format";
import { defaultConfig, invalidateConfigCache } from "@/lib/config";
import { createMemoryDb, type MemoryDb, type Profile } from "@/lib/db";
import { invalidateKeyCache } from "@/lib/keys";
import { authorize } from "@/lib/metering";

const ADMIN = "liam@navi.app";
const T = new Date("2026-10-01T15:00:00Z");
const KEY = "sk-ant-api03-SECRET-SECRET-SECRET-9xyz";
const saved = { ...process.env };
let db: MemoryDb;

beforeEach(async () => {
  db = createMemoryDb();
  invalidateConfigCache();
  invalidateKeyCache();
  process.env.NAVI_KEYS_SECRET = "a-very-long-test-secret-for-navi-keys-0001";
  await db.ensureProfile("u-1", "user@example.com", T);
});
afterEach(() => { process.env = { ...saved }; vi.restoreAllMocks(); });

async function log() {
  return (await db.adminListAudit({ limit: 100, offset: 0 })).rows;
}

describe("every admin action writes the audit log", () => {
  it("user actions", async () => {
    await ops.setTierOverride(db, ADMIN, "u-1", "pro");
    await ops.grantEntitlement(db, ADMIN, "u-1", "recall", "2026-12-31T23:59:59Z");
    await ops.revokeEntitlement(db, ADMIN, "u-1", "recall");
    await ops.extendTrial(db, ADMIN, "u-1", 14, T);
    await ops.resetQuota(db, ADMIN, "u-1", "day", T);
    await ops.setDisabled(db, ADMIN, "u-1", true, "spam", T);
    await ops.setDisabled(db, ADMIN, "u-1", false, null, T);
    await ops.signOutEverywhere(db, ADMIN, "u-1");
    const actions = (await log()).map((e) => e.action).reverse();
    expect(actions).toEqual([
      "user.tier_override", "user.entitlement_grant", "user.entitlement_revoke", "user.trial_extend",
      "user.quota_reset_day", "user.disable", "user.enable", "user.sign_out_all",
    ]);
    for (const e of await log()) {
      expect(e.actor).toBe(ADMIN);
      expect(e.target).toBe("user@example.com");
      expect(e.details.userId).toBe("u-1");
    }
    const p = (await db.getProfile("u-1"))!;
    expect(p.tierOverride).toBe("pro");
    expect(p.disabledAt).toBeNull();
    expect(new Date(p.trialEndsAt!).getTime()).toBe(new Date("2026-10-08T15:00:00Z").getTime() + 14 * 86_400_000);
  });

  it("delete needs the email retyped, then cascades", async () => {
    await authorize(db, { id: "u-1", email: "user@example.com" }, "task", "r1", T);
    await expect(ops.deleteUser(db, ADMIN, "u-1", "wrong@example.com")).rejects.toBeInstanceOf(ops.AdminInputError);
    expect(await db.getProfile("u-1")).not.toBeNull();
    await ops.deleteUser(db, ADMIN, "u-1", "USER@example.com");
    expect(await db.getProfile("u-1")).toBeNull();
    expect(await db.hasUsage("u-1", "task", "r1")).toBe(false);
    expect((await log())[0]).toMatchObject({ action: "user.delete", target: "user@example.com" });
  });

  it("key actions log provider + last4, never the key", async () => {
    await ops.setKey(db, ADMIN, "anthropic", KEY, false);
    await ops.setKey(db, ADMIN, "anthropic", KEY.replace("9xyz", "8abc"), true);
    await ops.testKey(db, ADMIN, "anthropic", async () => new Response("{}", { status: 200 }));
    await ops.removeKey(db, ADMIN, "anthropic");
    const entries = await log();
    expect(entries.map((e) => e.action).reverse()).toEqual(["key.set", "key.rotate", "key.test", "key.remove"]);
    expect(entries.find((e) => e.action === "key.rotate")!.details).toEqual({ last4: "8abc" });
    expect(entries.find((e) => e.action === "key.test")!.details).toMatchObject({ source: "database", ok: true });
    expect(JSON.stringify(entries)).not.toContain("SECRET-SECRET");
  });

  it("config, waitlist and admin changes", async () => {
    await ops.updateConfig(db, ADMIN, defaultConfig(), { features: { ...defaultConfig().features, voice: false } });
    await db.addToWaitlist("w@example.com", "site", null);
    await ops.inviteFromWaitlist(db, ADMIN, "W@example.com", "https://navi.app/download");
    await ops.addAdmin(db, ADMIN, "friend@navi.app");
    await expect(ops.removeAdmin(db, ADMIN, ADMIN)).rejects.toThrow(/yourself/);
    await ops.removeAdmin(db, ADMIN, "friend@navi.app");
    const entries = await log();
    expect(entries.map((e) => e.action).reverse()).toEqual(["config.update", "waitlist.invite", "admin.add", "admin.remove"]);
    expect(entries.find((e) => e.action === "config.update")!.details).toMatchObject({ changed: ["features"] });
    expect((await db.adminListWaitlist({ limit: 10, offset: 0 })).rows[0].invitedAt).not.toBeNull();
  });

  it("bad input fails without writing an audit row", async () => {
    await expect(ops.setTierOverride(db, ADMIN, "u-1", "platinum")).rejects.toThrow();
    await expect(ops.grantEntitlement(db, ADMIN, "u-1", "teleport", null)).rejects.toThrow();
    await expect(ops.extendTrial(db, ADMIN, "u-1", 0)).rejects.toThrow();
    await expect(ops.setDisabled(db, ADMIN, "nobody", true, null)).rejects.toThrow();
    expect(await log()).toEqual([]);
  });
});

describe("overview numbers", () => {
  const base: Omit<Profile, "userId" | "email" | "createdAt"> = {
    tier: "free", trialEndsAt: null, stripeCustomerId: null, stripeSubscriptionId: null, subscriptionStatus: null,
  };
  it("counts signups, trials, paying subs and MRR, and lays out 30 days", () => {
    const profiles: Profile[] = [
      { ...base, userId: "a", email: "a", createdAt: "2026-10-01T01:00:00Z", trialEndsAt: "2026-10-08T01:00:00Z" },
      { ...base, userId: "b", email: "b", createdAt: "2026-09-28T01:00:00Z", tier: "pro", subscriptionStatus: "active" },
      { ...base, userId: "c", email: "c", createdAt: "2026-09-10T01:00:00Z", tier: "pro_recall", subscriptionStatus: "past_due" },
      { ...base, userId: "d", email: "d", createdAt: "2026-08-01T01:00:00Z", tier: "pro", subscriptionStatus: "canceled" },
      { ...base, userId: "e", email: "e", createdAt: "2026-08-01T01:00:00Z", tierOverride: "pro_recall", disabledAt: "2026-09-30T00:00:00Z" },
    ];
    const o = computeOverview({
      profiles,
      usageDaily: [{ day: "2026-10-01", activeUsers: 2, runs: 10, costUsd: 0.5 }, { day: "2026-09-15", activeUsers: 1, runs: 3, costUsd: 0.25 }],
      active1d: 2, active7d: 3, waitlist: 7, now: T,
    });
    expect(o.signups).toEqual({ today: 1, d7: 2, d30: 3 });
    expect(o.trialsRunning).toBe(1);
    expect(o.tierMix).toEqual({ free: 0, trial: 1, pro: 2, pro_recall: 2 });
    expect(o.payingSubs).toEqual({ pro: 1, pro_recall: 1, total: 2 });
    expect(o.pastDue).toBe(1);
    expect(o.mrrUsd).toBe(50);
    expect(o.cost30dUsd).toBeCloseTo(0.75);
    expect(o.costTodayUsd).toBe(0.5);
    expect(o.days).toHaveLength(30);
    expect(o.days[29]).toMatchObject({ day: "2026-10-01", runs: 10, signups: 1 });
    expect(o.disabled).toBe(1);
    expect(o.overrides).toBe(1);
  });
});

describe("helpers", () => {
  it("csvField quotes and defuses spreadsheet formulas", () => {
    expect(csvField("a,b")).toBe('"a,b"');
    expect(csvField('say "hi"')).toBe('"say ""hi"""');
    expect(csvField("=HYPERLINK(1)")).toBe("'=HYPERLINK(1)");
    expect(csvField(null)).toBe("");
  });
  it("withFlash keeps other params", () => {
    expect(withFlash("/admin/waitlist?q=x&ok=old", false, "nope")).toBe("/admin/waitlist?q=x&err=nope");
  });
});
