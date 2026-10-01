/**
 * Where the account API meets the admin console: a disabled account keeps its privacy rights,
 * an old app (426 elsewhere) can still export/delete, deletion clears admin-side traces, and the
 * admin's "Delete user" runs the same delete path (billing first, fail-closed).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { POST as refresh } from "@/app/auth/refresh/route";
import { DELETE as deleteRoute } from "@/app/v1/account/route";
import { GET as exportRoute } from "@/app/v1/account/export/route";
import { GET as meRoute } from "@/app/v1/me/route";
import type { BillingCanceller } from "@/lib/account";
import * as ops from "@/lib/admin/ops";
import { verifyAccessToken } from "@/lib/auth";
import { invalidateConfigCache, saveConfig } from "@/lib/config";
import { getDb, pseudonym } from "@/lib/db";
import { authIpLimiter, perUserLimiter } from "@/lib/ratelimit";
import { getSessionProvider, memoryUserForEmail } from "@/lib/sessions";
import { req, useMemoryEnv } from "./helpers";

let n = 0;
const freshEmail = () => `adm${++n}.${Date.now()}@example.com`;
const ADMIN = "liam@buildnavi.com";

beforeEach(() => {
  useMemoryEnv({ MOCK_UPSTREAM: undefined });
  authIpLimiter.reset();
  perUserLimiter.reset();
  invalidateConfigCache();
  vi.spyOn(console, "info").mockImplementation(() => undefined);
});
afterEach(() => vi.restoreAllMocks());

async function signedIn(email = freshEmail()) {
  const tokens = await getSessionProvider().issue(memoryUserForEmail(email));
  const user = await verifyAccessToken(tokens.accessToken);
  const db = await getDb();
  await db.ensureProfile(user.id, email, new Date());
  return { tokens, user, email, db };
}

describe("a disabled account keeps export and delete", () => {
  it("/v1/me is 403 account_disabled, export is 200 (with disabledAt), delete is 204", async () => {
    const { tokens, user, db } = await signedIn();
    await ops.setDisabled(db, ADMIN, user.id, true, "chargeback");

    const me = await meRoute(req("/v1/me", { bearer: tokens.accessToken }));
    expect(me.status).toBe(403);
    expect(((await me.json()) as { error: string }).error).toBe("account_disabled");

    const ex = await exportRoute(req("/v1/account/export", { bearer: tokens.accessToken }));
    expect(ex.status).toBe(200);
    const body = (await ex.json()) as { profile: { disabledAt: string | null }; current: unknown };
    expect(body.profile.disabledAt).toBeTruthy();
    expect(body.current).toBeNull();
    expect(JSON.stringify(body)).not.toContain("chargeback"); // the admin's internal note stays internal

    expect((await deleteRoute(req("/v1/account", { method: "DELETE", bearer: tokens.accessToken }))).status).toBe(204);
    expect(await db.getProfile(user.id)).toBeNull();
  });

  it("an app below minAppVersion (426 on /v1/*) can still export and delete", async () => {
    const { tokens, db } = await signedIn();
    await saveConfig(db, { minAppVersion: "9.0.0" }, ADMIN);
    invalidateConfigCache();
    const old = { "x-navi-version": "1.0.0" };
    expect((await exportRoute(req("/v1/account/export", { bearer: tokens.accessToken, headers: old }))).status).toBe(200);
    expect((await deleteRoute(req("/v1/account", { method: "DELETE", bearer: tokens.accessToken, headers: old }))).status).toBe(204);
    await saveConfig(db, { minAppVersion: null }, ADMIN);
    invalidateConfigCache();
  });
});

describe("deleting an account clears admin-side traces", () => {
  it("grants and admin profile fields go, audit entries lose the email, a DB admin role goes", async () => {
    const { tokens, user, email, db } = await signedIn();
    await ops.grantEntitlement(db, ADMIN, user.id, "recall", null);
    await ops.setTierOverride(db, ADMIN, user.id, "pro_recall");
    await db.adminAddAdmin(email, ADMIN);
    expect((await db.adminListAudit({ limit: 50, offset: 0, query: email })).total).toBeGreaterThan(0);

    expect((await deleteRoute(req("/v1/account", { method: "DELETE", bearer: tokens.accessToken }))).status).toBe(204);

    expect(await db.listEntitlements(user.id)).toEqual([]);
    expect(await db.getProfile(user.id)).toBeNull();
    expect(await db.adminIsListedAdmin(email)).toBe(false);
    const all = (await db.adminListAudit({ limit: 500, offset: 0 })).rows;
    expect(JSON.stringify(all)).not.toContain(email);
    // The actions are still there, under a pseudonym, plus one self-delete entry with no email.
    expect(all.filter((e) => e.target === pseudonym(user.id)).map((e) => e.action)).toEqual(
      expect.arrayContaining(["user.entitlement_grant", "user.tier_override", "account.delete"]),
    );
  });
});

describe("admin 'Delete user' uses the account delete path", () => {
  it("cancels billing first and deletes nothing if that fails; then deletes everything incl. the auth user", async () => {
    const { tokens, user, email, db } = await signedIn();
    await db.updateProfile(user.id, { tier: "pro", stripeCustomerId: "cus_9", stripeSubscriptionId: "sub_9", subscriptionStatus: "active" });
    vi.spyOn(console, "error").mockImplementation(() => undefined);

    const failing: BillingCanceller = { cancelCustomer: vi.fn(async () => { throw new Error("stripe down"); }) };
    await expect(ops.deleteUser(db, ADMIN, user.id, email, { billing: failing })).rejects.toMatchObject({ status: 502 });
    expect(await db.getProfile(user.id)).not.toBeNull();

    const ok: BillingCanceller = { cancelCustomer: vi.fn(async () => undefined) };
    await ops.deleteUser(db, ADMIN, user.id, email, { billing: ok });
    expect(ok.cancelCustomer).toHaveBeenCalledWith("cus_9", "sub_9");
    expect(await db.getProfile(user.id)).toBeNull();
    expect(await getSessionProvider().userExists(user.id)).toBe(false);
    expect((await refresh(req("/auth/refresh", { json: { refreshToken: tokens.refreshToken } }))).status).toBe(401);
    const last = (await db.adminListAudit({ limit: 1, offset: 0 })).rows[0];
    expect(last).toMatchObject({ action: "user.delete", actor: ADMIN });
  });

  it("admin 'Sign out everywhere' revokes this app's sessions (memory driver)", async () => {
    const { tokens, user, db } = await signedIn();
    await ops.signOutEverywhere(db, ADMIN, user.id);
    expect((await refresh(req("/auth/refresh", { json: { refreshToken: tokens.refreshToken } }))).status).toBe(401);
  });
});
