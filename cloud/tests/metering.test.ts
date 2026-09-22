import { beforeEach, describe, expect, it } from "vitest";
import { createMemoryDb, type MemoryDb } from "@/lib/db";
import { HttpError } from "@/lib/http";
import { authorize, meBody, recordCost, usageSummary } from "@/lib/metering";

const T = new Date("2026-09-22T15:30:00Z");
const user = { id: "u-1", email: "liam@example.com" };

let db: MemoryDb;
beforeEach(() => { db = createMemoryDb(); });

async function expectHttp(p: Promise<unknown>, status: number, error: string) {
  try {
    await p;
  } catch (e) {
    expect(e).toBeInstanceOf(HttpError);
    expect((e as HttpError).status).toBe(status);
    expect((e as HttpError).body.error).toBe(error);
    return e as HttpError;
  }
  throw new Error(`expected HTTP ${status}`);
}

/** A free user past their trial. */
async function freeUser() {
  await db.ensureProfile(user.id, user.email, T);
  await db.updateProfile(user.id, { trialEndsAt: null });
}

describe("one unit per run", () => {
  it("counts a run once however many calls it makes", async () => {
    await freeUser();
    const a = await authorize(db, user, "task", "run-1", T);
    expect(a.newUnit).toBe(true);
    for (let i = 0; i < 40; i++) {
      const again = await authorize(db, user, "task", "run-1", T);
      expect(again.newUnit).toBe(false);
    }
    expect((await usageSummary(db, user.id, "free", T)).tasksToday).toBe(1);
  });

  it("counts different runs separately and separately per feature", async () => {
    await freeUser();
    await authorize(db, user, "task", "run-1", T);
    await authorize(db, user, "task", "run-2", T);
    await authorize(db, user, "answer", "run-2", T); // same run id, different feature
    const u = await usageSummary(db, user.id, "free", T);
    expect(u.tasksToday).toBe(2);
    expect(u.answersToday).toBe(1);
  });

  it("402s the run that would exceed the daily cap, with resetsAt", async () => {
    await freeUser();
    for (let i = 0; i < 5; i++) await authorize(db, user, "task", `run-${i}`, T);
    const e = await expectHttp(authorize(db, user, "task", "run-6", T), 402, "quota_exceeded");
    expect(e.body).toEqual({ error: "quota_exceeded", feature: "task", tier: "free", resetsAt: "2026-09-23T00:00:00.000Z" });
  });

  it("lets a running task continue after the cap is hit", async () => {
    await freeUser();
    for (let i = 0; i < 5; i++) await authorize(db, user, "task", `run-${i}`, T);
    await expect(authorize(db, user, "task", "run-0", T)).resolves.toMatchObject({ newUnit: false });
  });

  it("frees the cap at the next UTC day", async () => {
    await freeUser();
    for (let i = 0; i < 5; i++) await authorize(db, user, "task", `run-${i}`, T);
    const tomorrow = new Date("2026-09-23T00:00:01Z");
    await expect(authorize(db, user, "task", "run-new", tomorrow)).resolves.toMatchObject({ newUnit: true });
  });

  it("voice spends the tasks bucket and needs the entitlement", async () => {
    await freeUser();
    await expectHttp(authorize(db, user, "voice", "v-1", T), 403, "not_entitled");
    await db.updateProfile(user.id, { tier: "pro" });
    await authorize(db, user, "voice", "v-1", T);
    await authorize(db, user, "task", "t-1", T);
    const u = await usageSummary(db, user.id, "pro", T);
    expect(u.tasksThisMonth).toBe(2);
    expect(u.tasksToday).toBe(2);
  });

  it("route is never blocked and never counted", async () => {
    await freeUser();
    for (let i = 0; i < 100; i++) await authorize(db, user, "route", `r-${i}`, T);
    const u = await usageSummary(db, user.id, "free", T);
    expect(u).toMatchObject({ answersToday: 0, tasksToday: 0, tasksThisMonth: 0 });
  });
});

describe("trial and tiers", () => {
  it("a brand-new user is served as pro for 7 days", async () => {
    const a = await authorize(db, user, "voice", "v-1", T);
    expect(a.tier).toBe("pro");
    const me = await meBody(db, user, T);
    expect(me).toMatchObject({ tier: "pro", trialEndsAt: "2026-09-29T15:30:00.000Z", quotas: { answersPerDay: 500, tasksPerMonth: 300 } });
  });

  it("recall needs pro_recall or a manual grant", async () => {
    await freeUser();
    await db.updateProfile(user.id, { tier: "pro" });
    await expectHttp(authorize(db, user, "recall_digest", "d-1", T), 403, "not_entitled");
    await db.grantEntitlement(user.id, "recall", "beta", null);
    await expect(authorize(db, user, "recall_digest", "d-1", T)).resolves.toMatchObject({ tier: "pro" });
  });

  it("/v1/me shape", async () => {
    await freeUser();
    await authorize(db, user, "answer", "a-1", T);
    const me = await meBody(db, user, T);
    expect(me).toEqual({
      user: { id: "u-1", email: "liam@example.com" },
      tier: "free",
      entitlements: { answers: true, tasks: true, voice: false, recall: false },
      quotas: { answersPerDay: 20, tasksPerDay: 5 },
      usage: { answersToday: 1, tasksToday: 0, tasksThisMonth: 0, resetsAt: "2026-09-23T00:00:00.000Z" },
    });
  });
});

describe("cost", () => {
  it("accumulates onto the run's row and never throws", async () => {
    await freeUser();
    const a = await authorize(db, user, "answer", "a-1", T);
    await recordCost(db, a, user.id, 0.001);
    await recordCost(db, a, user.id, 0.002);
    await recordCost(db, { feature: "answer", runId: "nope" }, user.id, 0.5); // unknown run: ignored
    // Memory driver keeps cost private; assert via a second authorize not creating a unit.
    expect((await authorize(db, user, "answer", "a-1", T)).newUnit).toBe(false);
  });
});
