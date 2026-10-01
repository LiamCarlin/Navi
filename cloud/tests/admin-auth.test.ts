import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { adminFromSession, isAdminEmail, mintAdminSession, verifyAdminSession } from "@/lib/admin/auth";
import { mintAccessToken } from "@/lib/auth";
import { createMemoryDb, type MemoryDb } from "@/lib/db";

const saved = { ...process.env };
let db: MemoryDb;

beforeEach(() => {
  db = createMemoryDb();
  process.env.ADMIN_EMAILS = "Liam@BuildNavi.com, ops@buildnavi.com";
  process.env.DB_DRIVER = "memory";
  delete process.env.SUPABASE_URL;
});
afterEach(() => { process.env = { ...saved }; });

describe("who is an admin", () => {
  it("accepts ADMIN_EMAILS (case-insensitive) and rows in the admins table", async () => {
    expect(await isAdminEmail(db, "liam@buildnavi.com")).toBe(true);
    expect(await isAdminEmail(db, " OPS@buildnavi.com ")).toBe(true);
    expect(await isAdminEmail(db, "someone@else.com")).toBe(false);
    await db.adminAddAdmin("Friend@BuildNavi.com", "liam@buildnavi.com");
    expect(await isAdminEmail(db, "friend@buildnavi.com")).toBe(true);
  });

  it("fails closed: empty, malformed, or a broken admins lookup", async () => {
    expect(await isAdminEmail(db, "")).toBe(false);
    expect(await isAdminEmail(db, null)).toBe(false);
    expect(await isAdminEmail(db, "not-an-email")).toBe(false);
    const broken = { ...db, adminIsListedAdmin: async () => { throw new Error("db down"); } } as unknown as MemoryDb;
    expect(await isAdminEmail(broken, "friend@buildnavi.com")).toBe(false);
  });

  it("is empty when ADMIN_EMAILS is unset", async () => {
    delete process.env.ADMIN_EMAILS;
    expect(await isAdminEmail(db, "liam@buildnavi.com")).toBe(false);
  });
});

describe("the console session cookie", () => {
  const now = new Date("2026-10-01T12:00:00Z");

  it("round-trips", async () => {
    const t = await mintAdminSession({ email: "liam@buildnavi.com", sub: "u-1" }, now);
    expect(await verifyAdminSession(t, now)).toEqual({ email: "liam@buildnavi.com", sub: "u-1" });
  });

  it("expires after 12 h", async () => {
    const t = await mintAdminSession({ email: "liam@buildnavi.com", sub: "u-1" }, now);
    expect(await verifyAdminSession(t, new Date(now.getTime() + 13 * 3600_000))).toBeNull();
  });

  it("rejects tampering and an app access token", async () => {
    const t = await mintAdminSession({ email: "liam@buildnavi.com", sub: "u-1" }, now);
    const [h, p, sig] = t.split(".");
    const forged = Buffer.from(JSON.stringify({ ...JSON.parse(Buffer.from(p, "base64url").toString()), email: "evil@x.com" })).toString("base64url");
    expect(await verifyAdminSession(`${h}.${forged}.${sig}`, now)).toBeNull();
    // A perfectly valid *app* token (same signing secret family) is not an admin session.
    const { token } = await mintAccessToken({ id: "u-1", email: "liam@buildnavi.com" }, 3600, now);
    expect(await verifyAdminSession(token, now)).toBeNull();
    expect(await verifyAdminSession("garbage", now)).toBeNull();
    expect(await verifyAdminSession(undefined, now)).toBeNull();
  });

  it("stops working the moment the email stops being an admin", async () => {
    await db.adminAddAdmin("friend@buildnavi.com", "liam@buildnavi.com");
    const t = await mintAdminSession({ email: "friend@buildnavi.com", sub: "u-2" });
    expect(await adminFromSession(db, t)).toEqual({ email: "friend@buildnavi.com", sub: "u-2" });
    await db.adminRemoveAdmin("friend@buildnavi.com");
    expect(await adminFromSession(db, t)).toBeNull();
  });

  it("a non-admin's valid session gets nothing", async () => {
    const t = await mintAdminSession({ email: "user@example.com", sub: "u-3" });
    expect(await verifyAdminSession(t)).not.toBeNull();
    expect(await adminFromSession(db, t)).toBeNull();
  });
});
