import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { POST as signout } from "@/app/account/signout/route";
import { GET as purge } from "@/app/auth/purge/route";
import { POST as refresh } from "@/app/auth/refresh/route";
import { DELETE as deleteRoute } from "@/app/v1/account/route";
import { GET as exportRoute } from "@/app/v1/account/export/route";
import { deleteAccount, exportAccount, NOT_STORED, type BillingCanceller } from "@/lib/account";
import { verifyAccessToken } from "@/lib/auth";
import { createMemoryDb, getDb, type MemoryDb, type SessionTokens } from "@/lib/db";
import { HttpError } from "@/lib/http";
import { authorize } from "@/lib/metering";
import { authIpLimiter, perUserLimiter } from "@/lib/ratelimit";
import { createMemorySessionProvider, getSessionProvider, memoryUserForEmail } from "@/lib/sessions";
import { finishSignIn } from "@/lib/signin";
import { encodeSession, SESSION_COOKIE } from "@/lib/web-session";
import { req, setCookies, useMemoryEnv } from "./helpers";

let n = 0;
const freshEmail = () => `acct${++n}.${Date.now()}@example.com`;

beforeEach(() => {
  useMemoryEnv({ MOCK_UPSTREAM: undefined });
  authIpLimiter.reset();
  perUserLimiter.reset();
  vi.spyOn(console, "info").mockImplementation(() => undefined);
});
afterEach(() => vi.restoreAllMocks());

/** A signed-in user with some history: usage across features, a grant, a waitlist row, a pending app code. */
async function seededUser(email = freshEmail()) {
  const tokens = await getSessionProvider().issue(memoryUserForEmail(email));
  const user = await verifyAccessToken(tokens.accessToken);
  const db = await getDb();
  const now = new Date();
  await db.ensureProfile(user.id, email, now);
  await authorize(db, user, "answer", "run-a", now);
  await authorize(db, user, "task", "run-t", now);
  await authorize(db, user, "route", "run-r", now);
  await db.addUsageCost(user.id, "answer", "run-a", 0.0123);
  await db.grantEntitlement(user.id, "recall", "beta", null);
  await db.addToWaitlist(email, "hero", "can't wait");
  await finishSignIn("navi", tokens, db); // an app code that was never exchanged
  return { user, tokens, email, db };
}

const cookieFor = (t: SessionTokens) => `${SESSION_COOKIE}=${encodeSession(t)}`;

describe("GET /v1/account/export", () => {
  it("returns everything the cloud holds about the user (Bearer)", async () => {
    const { user, tokens, email } = await seededUser();
    const res = await exportRoute(req("/v1/account/export", { bearer: tokens.accessToken }));
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, any>;
    expect(body.format).toBe("navi-account-export/1");
    expect(body.user).toEqual({ id: user.id, email });
    expect(body.profile.plan).toBe("free");
    expect(body.profile.trialEndsAt).toBeTruthy();
    expect(body.current.tier).toBe("pro"); // in the trial
    expect(body.current.usage.answersToday).toBe(1);
    expect(body.entitlementGrants).toEqual([{ key: "recall", grantedBy: "beta", expiresAt: null }]);
    expect(body.usage.map((u: { feature: string }) => u.feature).sort()).toEqual(["answer", "route", "task"]);
    expect(body.usage.find((u: { feature: string }) => u.feature === "answer").costUsd).toBeCloseTo(0.0123);
    expect(body.waitlist).toMatchObject({ email, source: "hero", note: "can't wait" });
    expect(body.devices).toHaveLength(1);
    expect(body.notStored).toBe(NOT_STORED);
    // Never tokens or sign-in codes.
    const text = JSON.stringify(body);
    expect(text).not.toContain(tokens.accessToken);
    expect(text).not.toContain(tokens.refreshToken);
  });

  it("works with the /account cookie, and ?download=1 makes it a file", async () => {
    const { tokens } = await seededUser();
    const res = await exportRoute(req("/v1/account/export?download=1", { cookie: cookieFor(tokens) }));
    expect(res.status).toBe(200);
    expect(res.headers.get("content-disposition")).toMatch(/^attachment; filename="navi-account-\d{4}-\d{2}-\d{2}\.json"$/);
  });

  it("401 without credentials", async () => {
    expect((await exportRoute(req("/v1/account/export"))).status).toBe(401);
  });
});

describe("DELETE /v1/account", () => {
  it("204, removes every row, the pending app code and the auth user; the token can't resurrect it", async () => {
    const { user, tokens, email, db } = await seededUser();
    const pending = [...(await db.exportUserData(user.id, email)).usage];
    expect(pending.length).toBe(3);

    const res = await deleteRoute(req("/v1/account", { method: "DELETE", bearer: tokens.accessToken }));
    expect(res.status).toBe(204);

    const left = await db.exportUserData(user.id, email);
    expect(left).toEqual({ profile: null, entitlements: [], usage: [], waitlist: null });
    expect(await getSessionProvider().userExists(user.id)).toBe(false);
    // Every session is gone: the refresh token no longer works.
    const r = await refresh(req("/auth/refresh", { json: { refreshToken: tokens.refreshToken } }));
    expect(r.status).toBe(401);
    // A still-unexpired access token gets 401 on export, not a fresh empty account.
    expect((await exportRoute(req("/v1/account/export", { bearer: tokens.accessToken }))).status).toBe(401);
    // Idempotent.
    expect((await deleteRoute(req("/v1/account", { method: "DELETE", bearer: tokens.accessToken }))).status).toBe(204);
  });

  it("deletes the app's never-exchanged sign-in code too", async () => {
    const db = createMemoryDb();
    const sessions = createMemorySessionProvider();
    const email = freshEmail();
    const tokens = await sessions.issue(memoryUserForEmail(email));
    const user = await verifyAccessToken(tokens.accessToken);
    const done = await finishSignIn("navi", tokens, db);
    const code = new URL(done.location).searchParams.get("code")!;
    const { deleted } = await deleteAccount({ db, sessions, billing: null }, user);
    expect(deleted.authCodes).toBe(1);
    expect(await db.consumeAuthCode(code, new Date())).toBeNull();
  });

  it("with the cookie: needs our Origin, and clears the cookie", async () => {
    const { tokens } = await seededUser();
    const cross = await deleteRoute(req("/v1/account", { method: "DELETE", cookie: cookieFor(tokens), origin: "https://evil.example" }));
    expect(cross.status).toBe(403);
    const ok = await deleteRoute(req("/v1/account", { method: "DELETE", cookie: cookieFor(tokens) }));
    expect(ok.status).toBe(204);
    expect(setCookies(ok).get(SESSION_COOKIE)).toBe("");
  });

  it("cancels billing first, and deletes nothing if that fails", async () => {
    const db: MemoryDb = createMemoryDb();
    const sessions = createMemorySessionProvider();
    const email = freshEmail();
    const user = await verifyAccessToken((await sessions.issue(memoryUserForEmail(email))).accessToken);
    await db.ensureProfile(user.id, email, new Date());
    await db.updateProfile(user.id, { tier: "pro", stripeCustomerId: "cus_1", stripeSubscriptionId: "sub_1", subscriptionStatus: "active" });

    const failing: BillingCanceller = { cancelCustomer: vi.fn(async () => { throw new Error("stripe down"); }) };
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    await expect(deleteAccount({ db, sessions, billing: failing }, user)).rejects.toMatchObject({ status: 502 });
    expect(await db.getProfile(user.id)).not.toBeNull();
    expect(await sessions.userExists(user.id)).toBe(true);

    await expect(deleteAccount({ db, sessions, billing: null }, user)).rejects.toBeInstanceOf(HttpError);
    expect(await db.getProfile(user.id)).not.toBeNull();

    const ok: BillingCanceller = { cancelCustomer: vi.fn(async () => undefined) };
    const result = await deleteAccount({ db, sessions, billing: ok }, user);
    expect(ok.cancelCustomer).toHaveBeenCalledWith("cus_1", "sub_1");
    expect(result.billingCancelled).toBe(true);
    expect(await db.getProfile(user.id)).toBeNull();
  });
});

describe("exportAccount over a bare memory db", () => {
  it("a user with no profile yet exports empty sections, not an error", async () => {
    const db = createMemoryDb();
    const sessions = createMemorySessionProvider();
    const user = { id: "u-none", email: "none@example.com" };
    const out = await exportAccount({ db, sessions, billing: null }, user);
    expect(out.profile).toBeNull();
    expect(out.current).toBeNull();
    expect(out.usage).toEqual([]);
  });
});

describe("POST /account/signout", () => {
  it("'everywhere' ends every session of the user", async () => {
    const email = freshEmail();
    const sessions = getSessionProvider();
    const a = await sessions.issue(memoryUserForEmail(email));
    const b = await sessions.issue(memoryUserForEmail(email));
    const res = await signout(req("/account/signout", { json: { scope: "everywhere" }, cookie: cookieFor(a) }));
    expect(res.status).toBe(200);
    expect(setCookies(res).get(SESSION_COOKIE)).toBe("");
    for (const t of [a, b]) {
      expect((await refresh(req("/auth/refresh", { json: { refreshToken: t.refreshToken } }))).status).toBe(401);
    }
  });

  it("'this' ends only this browser's session", async () => {
    const email = freshEmail();
    const sessions = getSessionProvider();
    const a = await sessions.issue(memoryUserForEmail(email));
    const b = await sessions.issue(memoryUserForEmail(email));
    await signout(req("/account/signout", { json: { scope: "this" }, cookie: cookieFor(a) }));
    expect((await refresh(req("/auth/refresh", { json: { refreshToken: a.refreshToken } }))).status).toBe(401);
    expect((await refresh(req("/auth/refresh", { json: { refreshToken: b.refreshToken } }))).status).toBe(200);
  });
});

describe("GET /auth/purge (Vercel Cron)", () => {
  it("404 without CRON_SECRET, 401 with a wrong one, purges expired codes with the right one", async () => {
    expect((await purge(req("/auth/purge"))).status).toBe(404);
    useMemoryEnv({ CRON_SECRET: "cron-secret-123" });
    expect((await purge(req("/auth/purge", { bearer: "nope" }))).status).toBe(401);

    const tokens = await getSessionProvider().issue(memoryUserForEmail(freshEmail()));
    await finishSignIn("navi", tokens, undefined, new Date(Date.now() - 10 * 60_000));
    const res = await purge(req("/auth/purge", { bearer: "cron-secret-123" }));
    expect(res.status).toBe(200);
    const body = (await res.json()) as { purged: { authCodes: number } };
    expect(body.purged.authCodes).toBeGreaterThanOrEqual(1);
  });
});
