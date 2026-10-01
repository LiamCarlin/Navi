import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  assertAppVersion,
  CONFIG_KEY,
  compareVersions,
  defaultConfig,
  effectiveQuotas,
  getConfig,
  invalidateConfigCache,
  makeNotice,
  modelOverride,
  normalizeConfig,
  saveConfig,
  type ProductConfig,
} from "@/lib/config";
import { createMemoryDb, type MemoryDb } from "@/lib/db";
import { HttpError } from "@/lib/http";
import { authorize, meBody } from "@/lib/metering";
import { resetQuota } from "@/lib/admin/ops";

const T = new Date("2026-10-01T15:00:00Z");
const user = { id: "u-1", email: "user@example.com" };
let db: MemoryDb;

beforeEach(() => {
  db = createMemoryDb();
  invalidateConfigCache();
});
afterEach(() => vi.restoreAllMocks());

function cfg(patch: Partial<ProductConfig>): ProductConfig {
  return { ...defaultConfig(), ...patch };
}

async function freeUser() {
  await db.ensureProfile(user.id, user.email, T);
  await db.updateProfile(user.id, { trialEndsAt: null });
}

async function expectHttp(p: Promise<unknown>, status: number, error: string) {
  try {
    await p;
  } catch (e) {
    expect(e).toBeInstanceOf(HttpError);
    expect({ status: (e as HttpError).status, error: (e as HttpError).body.error }).toEqual({ status, error });
    return e as HttpError;
  }
  throw new Error(`expected HTTP ${status} ${error}`);
}

describe("normalizeConfig", () => {
  it("defaults everything on and empty", () => {
    expect(normalizeConfig(null)).toEqual(defaultConfig());
    expect(defaultConfig().features).toEqual({ answers: true, tasks: true, voice: true, recall: true });
  });

  it("drops bad values instead of failing", () => {
    const c = normalizeConfig({
      features: { answers: false, tasks: "no", bogus: false },
      minAppVersion: "1.2.x",
      latestVersion: "1.3.0",
      downloadURL: "javascript:alert(1)",
      quotas: { free: { answersPerDay: 50, tasksPerDay: -1, tasksPerMonth: null }, nope: { answersPerDay: 1 } },
      models: { answer: "claude-sonnet-5", task: "rm -rf /", digest: "" },
      notice: { message: "  Heads up  ", level: "loud", url: "https://buildnavi.com/status" },
    });
    expect(c.features).toEqual({ answers: false, tasks: true, voice: true, recall: true });
    expect(c.minAppVersion).toBeNull();
    expect(c.latestVersion).toBe("1.3.0");
    expect(c.downloadURL).toBeNull();
    expect(c.quotas).toEqual({ free: { answersPerDay: 50, tasksPerMonth: null } });
    expect(c.models).toEqual({ answer: "claude-sonnet-5", task: null, digest: null });
    expect(c.notice).toMatchObject({ message: "Heads up", level: "info", url: "https://buildnavi.com/status" });
  });

  it("gives the notice a content id that changes with the content", () => {
    const a = makeNotice("Down for maintenance", "warning")!;
    expect(a.id).toMatch(/^[0-9a-f]{12}$/);
    expect(makeNotice("Down for maintenance", "warning")!.id).toBe(a.id);
    expect(makeNotice("Down for maintenance", "critical")!.id).not.toBe(a.id);
    expect(makeNotice("   ", "info")).toBeNull();
  });
});

describe("config cache", () => {
  it("serves the cached value for 30 s, then re-reads; saving invalidates", async () => {
    await db.adminSetConfig(CONFIG_KEY, { features: { voice: false } }, "t");
    const spy = vi.spyOn(db, "adminGetConfig");
    expect((await getConfig(db, 0)).features.voice).toBe(false);
    await db.adminSetConfig(CONFIG_KEY, { features: { voice: true } }, "t");
    expect((await getConfig(db, 10_000)).features.voice).toBe(false); // cached
    expect((await getConfig(db, 31_000)).features.voice).toBe(true); // expired
    expect(spy).toHaveBeenCalledTimes(2);

    await saveConfig(db, { ...defaultConfig(), features: { ...defaultConfig().features, answers: false } }, "liam@buildnavi.com");
    const now = await getConfig(db, 31_500);
    expect(now.features.answers).toBe(false);
    expect(now.updatedBy).toBe("liam@buildnavi.com");
  });

  it("keeps serving the last known config when the read fails", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
    await db.adminSetConfig(CONFIG_KEY, { features: { recall: false } }, "t");
    expect((await getConfig(db, 0)).features.recall).toBe(false);
    vi.spyOn(db, "adminGetConfig").mockRejectedValue(new Error("db down"));
    expect((await getConfig(db, 40_000)).features.recall).toBe(false);
  });

  it("falls back to defaults when there was never a config", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
    vi.spyOn(db, "adminGetConfig").mockRejectedValue(new Error("relation app_config does not exist"));
    expect(await getConfig(db, 0)).toEqual(defaultConfig());
  });
});

describe("kill switches → 503 feature_disabled", () => {
  it("blocks the switched-off feature before any quota is spent", async () => {
    await freeUser();
    const config = cfg({ features: { answers: false, tasks: true, voice: true, recall: true } });
    const e = await expectHttp(authorize(db, user, "answer", "r1", T, { config }), 503, "feature_disabled");
    expect(e.body).toMatchObject({ feature: "answers" });
    expect(typeof e.body.message).toBe("string");
    expect(await db.hasUsage(user.id, "answer", "r1")).toBe(false);
    // Other features still work, and routing has no switch.
    await authorize(db, user, "task", "r2", T, { config });
    await authorize(db, user, "route", "r3", T, { config: cfg({ features: { answers: false, tasks: false, voice: false, recall: false } }) });
  });

  it("recall_* features follow the recall switch", async () => {
    await db.ensureProfile(user.id, user.email, T);
    await db.updateProfile(user.id, { tier: "pro_recall" });
    const config = cfg({ features: { answers: true, tasks: true, voice: true, recall: false } });
    await expectHttp(authorize(db, user, "recall_digest", "r1", T, { config }), 503, "feature_disabled");
  });
});

describe("app version gate → 426 upgrade_required", () => {
  it("compares dotted versions numerically", () => {
    expect(compareVersions("1.10.0", "1.9.9")).toBe(1);
    expect(compareVersions("1.2", "1.2.0")).toBe(0);
    expect(compareVersions("0.9.12", "1.0")).toBe(-1);
    expect(compareVersions("1.2.0-beta", "1.2.0")).toBe(0);
  });

  it("426s older apps with minAppVersion + downloadURL", async () => {
    await freeUser();
    const config = cfg({ minAppVersion: "1.2.0", downloadURL: "https://buildnavi.com/download" });
    const e = await expectHttp(authorize(db, user, "answer", "r1", T, { config, appVersion: "1.1.9" }), 426, "upgrade_required");
    expect(e.body).toMatchObject({ minAppVersion: "1.2.0", downloadURL: "https://buildnavi.com/download" });
    await authorize(db, user, "answer", "r2", T, { config, appVersion: "1.2.0" });
    await authorize(db, user, "answer", "r3", T, { config, appVersion: "2.0" });
  });

  it("lets a missing or unparseable header through (curl, scripts, pre-header builds)", () => {
    const config = cfg({ minAppVersion: "1.2.0" });
    expect(() => assertAppVersion(config, null)).not.toThrow();
    expect(() => assertAppVersion(config, "dev")).not.toThrow();
    expect(() => assertAppVersion(defaultConfig(), "0.0.1")).not.toThrow();
  });

  it("/v1/me never 426s and carries the config block", async () => {
    await freeUser();
    const notice = makeNotice("New version out", "info", "https://buildnavi.com/download")!;
    const config = cfg({ minAppVersion: "9.0.0", latestVersion: "9.1.0", downloadURL: "https://buildnavi.com/download", notice });
    const body = await meBody(db, user, T, config);
    expect(body.config).toEqual({
      features: { answers: true, tasks: true, voice: true, recall: true },
      notice: { id: notice.id, message: "New version out", level: "info", url: "https://buildnavi.com/download" },
      minAppVersion: "9.0.0",
      latestVersion: "9.1.0",
      downloadURL: "https://buildnavi.com/download",
    });
    expect((await meBody(db, user, T, defaultConfig())).config).toEqual({ features: { answers: true, tasks: true, voice: true, recall: true } });
  });
});

describe("disabled account → 403 account_disabled", () => {
  it("blocks every metered call and /v1/me, without leaking the internal reason", async () => {
    await freeUser();
    await db.updateProfile(user.id, { disabledAt: T.toISOString(), disabledReason: "chargeback #123" });
    const e = await expectHttp(authorize(db, user, "route", "r1", T, { config: defaultConfig() }), 403, "account_disabled");
    expect(String(e.body.message)).not.toContain("chargeback");
    await expectHttp(meBody(db, user, T, defaultConfig()), 403, "account_disabled");
    await db.updateProfile(user.id, { disabledAt: null, disabledReason: null });
    await authorize(db, user, "route", "r1", T, { config: defaultConfig() });
  });

  it("is checked before the version gate and kill switches", async () => {
    await freeUser();
    await db.updateProfile(user.id, { disabledAt: T.toISOString() });
    const config = cfg({ minAppVersion: "5.0", features: { answers: false, tasks: true, voice: true, recall: true } });
    await expectHttp(authorize(db, user, "answer", "r1", T, { config, appVersion: "1.0" }), 403, "account_disabled");
  });
});

describe("quota overrides, tier override, quota reset", () => {
  it("per-tier overrides replace plan defaults (and null uncaps)", async () => {
    expect(effectiveQuotas("free", defaultConfig())).toEqual({ answersPerDay: 20, tasksPerDay: 5 });
    const config = cfg({ quotas: { free: { tasksPerDay: 2, answersPerDay: null } } });
    expect(effectiveQuotas("free", config)).toEqual({ tasksPerDay: 2 });

    await freeUser();
    await authorize(db, user, "task", "t1", T, { config });
    await authorize(db, user, "task", "t2", T, { config });
    await expectHttp(authorize(db, user, "task", "t3", T, { config }), 402, "quota_exceeded");
    for (let i = 0; i < 30; i++) await authorize(db, user, "answer", `a${i}`, T, { config }); // uncapped
    expect((await meBody(db, user, T, config)).quotas).toEqual({ tasksPerDay: 2 });
  });

  it("a tier override wins over the paid tier and hides the trial", async () => {
    await db.ensureProfile(user.id, user.email, T); // in trial → pro
    await db.updateProfile(user.id, { tierOverride: "pro_recall" });
    const body = await meBody(db, user, T, defaultConfig());
    expect(body.tier).toBe("pro_recall");
    expect(body.trialEndsAt).toBeUndefined();
    await authorize(db, user, "recall_digest", "d1", T, { config: defaultConfig() });
  });

  it("resetting today's quota lets a capped user run again, keeping the usage rows", async () => {
    await freeUser();
    for (let i = 0; i < 5; i++) await authorize(db, user, "task", `t${i}`, T);
    await expectHttp(authorize(db, user, "task", "t5", T), 402, "quota_exceeded");
    await resetQuota(db, "liam@buildnavi.com", user.id, "day", T);
    expect(((await meBody(db, user, T)).usage as { tasksToday: number }).tasksToday).toBe(0);
    await authorize(db, user, "task", "t5", T);
    expect(((await meBody(db, user, T)).usage as { tasksToday: number }).tasksToday).toBe(1);
    expect(await db.hasUsage(user.id, "task", "t0")).toBe(true); // cost history kept
    // Tomorrow the offset no longer applies.
    const tomorrow = new Date("2026-10-02T09:00:00Z");
    expect(((await meBody(db, user, tomorrow)).usage as { tasksToday: number }).tasksToday).toBe(0);
  });
});

describe("model per feature", () => {
  it("only overrides when set, and only for the matching vendor", () => {
    const config = cfg({ models: { answer: "claude-sonnet-5", task: null, digest: "gemini-2.5-flash" } });
    expect(modelOverride(config, "answer", "anthropic")).toBe("claude-sonnet-5");
    expect(modelOverride(config, "task", "anthropic")).toBeNull();
    expect(modelOverride(config, "route", "anthropic")).toBeNull();
    expect(modelOverride(config, "recall_digest", "gemini")).toBe("gemini-2.5-flash");
    expect(modelOverride(config, "recall_digest", "anthropic")).toBeNull();
    expect(modelOverride(undefined, "answer", "anthropic")).toBeNull();
  });
});
