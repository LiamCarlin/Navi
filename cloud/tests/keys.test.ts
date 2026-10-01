import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createMemoryDb, type MemoryDb } from "@/lib/db";
import {
  decryptKey,
  encryptKey,
  invalidateKeyCache,
  KeysSecretError,
  keyStatuses,
  maskKey,
  resolveVendorKey,
  scrubKey,
  storeVendorKey,
  testVendorKey,
  validateKeyInput,
} from "@/lib/keys";

const SECRET = "0123456789abcdef0123456789abcdef-test-secret";
const KEY = "sk-ant-api03-THIS-IS-A-FAKE-KEY-abcd";

let db: MemoryDb;
const saved = { ...process.env };

beforeEach(() => {
  db = createMemoryDb();
  invalidateKeyCache();
  process.env.NAVI_KEYS_SECRET = SECRET;
  delete process.env.ANTHROPIC_API_KEY;
  delete process.env.TYPESAFE_API_KEY;
});
afterEach(() => {
  process.env = { ...saved };
  vi.restoreAllMocks();
});

describe("encryption at rest", () => {
  it("round-trips and never contains the plaintext", () => {
    const blob = encryptKey(KEY, "anthropic", SECRET);
    expect(blob.startsWith("v1.")).toBe(true);
    expect(blob).not.toContain(KEY);
    expect(blob).not.toContain("abcd");
    expect(decryptKey(blob, "anthropic", SECRET)).toBe(KEY);
  });

  it("uses a fresh IV every time", () => {
    expect(encryptKey(KEY, "anthropic", SECRET)).not.toBe(encryptKey(KEY, "anthropic", SECRET));
  });

  it("fails with the wrong secret, another provider's row, or a tampered blob", () => {
    const blob = encryptKey(KEY, "anthropic", SECRET);
    expect(() => decryptKey(blob, "anthropic", SECRET + "x")).toThrow();
    expect(() => decryptKey(blob, "typesafe", SECRET)).toThrow();
    const raw = Buffer.from(blob.slice(3), "base64url");
    raw[raw.length - 1] ^= 1;
    expect(() => decryptKey(`v1.${raw.toString("base64url")}`, "anthropic", SECRET)).toThrow();
  });

  it("refuses without NAVI_KEYS_SECRET (or with a short one)", async () => {
    expect(() => encryptKey(KEY, "anthropic", "short")).toThrow(KeysSecretError);
    delete process.env.NAVI_KEYS_SECRET;
    expect(() => encryptKey(KEY, "anthropic")).toThrow(KeysSecretError);
    await expect(storeVendorKey(db, "anthropic", KEY, "admin@navi.app")).rejects.toBeInstanceOf(KeysSecretError);
    expect(await db.adminGetVendorKey("anthropic")).toBeNull();
  });
});

describe("masking", () => {
  it("shows only the last four characters", () => {
    expect(maskKey(KEY)).toBe("••••abcd");
    expect(maskKey(null)).toBe("—");
    expect(scrubKey(`bad key ${KEY} rejected`, KEY)).toBe("bad key ••••abcd rejected");
  });

  it("rejects things that are not keys", () => {
    expect(() => validateKeyInput("short")).toThrow();
    expect(() => validateKeyInput("has a space in it")).toThrow();
    expect(validateKeyInput(`  ${KEY}\n`)).toBe(KEY);
  });

  it("keyStatuses never exposes a full key", async () => {
    process.env.TYPESAFE_API_KEY = "ts-env-key-0000-wxyz";
    await storeVendorKey(db, "anthropic", KEY, "admin@navi.app");
    const statuses = await keyStatuses(db);
    const json = JSON.stringify(statuses);
    expect(json).not.toContain(KEY);
    expect(json).not.toContain("ts-env-key-0000-wxyz");
    const a = statuses.find((s) => s.provider === "anthropic")!;
    expect(a).toMatchObject({ source: "database", masked: "••••abcd", rotatedBy: "admin@navi.app" });
    expect(statuses.find((s) => s.provider === "typesafe")).toMatchObject({ source: "env", masked: "••••wxyz" });
    expect(statuses.find((s) => s.provider === "gemini")).toMatchObject({ source: "none" });
  });
});

describe("getVendorKey: database first, then env, cached", () => {
  it("falls back to the env var, prefers the stored key, and caches for 60 s", async () => {
    process.env.ANTHROPIC_API_KEY = "env-anthropic-key-1234";
    expect(await resolveVendorKey("anthropic", db, { nowMs: 0 })).toEqual({ key: "env-anthropic-key-1234", source: "env" });

    await storeVendorKey(db, "anthropic", KEY, "admin@navi.app"); // invalidates the cache
    expect(await resolveVendorKey("anthropic", db, { nowMs: 1_000 })).toEqual({ key: KEY, source: "database" });

    // Changed underneath without invalidation: still the cached value inside 60 s…
    await db.adminSetVendorKey("anthropic", null, null, "x", new Date().toISOString());
    expect((await resolveVendorKey("anthropic", db, { nowMs: 30_000 })).source).toBe("database");
    // …and the env var once the cache expires.
    expect(await resolveVendorKey("anthropic", db, { nowMs: 62_000 })).toEqual({ key: "env-anthropic-key-1234", source: "env" });
  });

  it("uses env when the stored key can't be decrypted (secret rotated)", async () => {
    process.env.ANTHROPIC_API_KEY = "env-anthropic-key-1234";
    await db.adminSetVendorKey("anthropic", encryptKey(KEY, "anthropic", "another-secret-that-is-long-enough-123"), "abcd", "x", "t");
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
    expect(await resolveVendorKey("anthropic", db, { fresh: true })).toEqual({ key: "env-anthropic-key-1234", source: "env" });
    const st = (await keyStatuses(db)).find((s) => s.provider === "anthropic")!;
    expect(st.dbUnreadable).toBe(true);
    expect(st.source).toBe("env");
  });

  it("never logs the key", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    await db.adminSetVendorKey("anthropic", "v1.garbage", "abcd", "x", "t");
    await resolveVendorKey("anthropic", db, { fresh: true });
    for (const call of warn.mock.calls) expect(JSON.stringify(call)).not.toContain(KEY);
  });
});

describe("Test button", () => {
  it("reports OK with latency", async () => {
    const fetchImpl = vi.fn(async () => new Response("{}", { status: 200 }));
    const r = await testVendorKey("anthropic", KEY, fetchImpl);
    expect(r.ok).toBe(true);
    expect(r.latencyMs).toBeGreaterThanOrEqual(0);
    const [url, init] = fetchImpl.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toContain("/v1/models");
    expect((init.headers as Record<string, string>)["x-api-key"]).toBe(KEY);
  });

  it("reports the vendor error with the key scrubbed", async () => {
    const fetchImpl = vi.fn(async () => new Response(`invalid key ${KEY}`, { status: 401 }));
    const r = await testVendorKey("typesafe", KEY, fetchImpl);
    expect(r.ok).toBe(false);
    expect(r.status).toBe(401);
    expect(r.error).toContain("HTTP 401");
    expect(r.error).not.toContain(KEY);
  });
});
