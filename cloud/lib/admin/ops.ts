/**
 * Every admin action, pure over a Db, and each one writes `admin_audit`. The server
 * actions in app/admin are thin wrappers (guard → op → redirect), so these are what
 * the tests exercise. Audit details are metadata only — never key material.
 */

import { billingCanceller, deleteAccount, type BillingCanceller } from "../account";
import { saveConfig, type ProductConfig } from "../config";
import type { Db, Profile, QuotaReset } from "../db";
import { removeVendorKey, resolveVendorKey, storeVendorKey, testVendorKey, type KeyTestResult, type VendorProvider } from "../keys";
import { getSessionProvider, type SessionProvider } from "../sessions";
import { dayKey, ENTITLEMENT_KEYS, featuresInBucket, isTier, monthKey, type Tier } from "../plans";

export class AdminInputError extends Error {}

export async function audit(db: Db, actor: string, action: string, target: string | null, details: Record<string, unknown> = {}, now = new Date()): Promise<void> {
  await db.adminWriteAudit({ actor, action, target, details, at: now.toISOString() });
}

async function mustProfile(db: Db, userId: string): Promise<Profile> {
  const p = await db.getProfile(userId);
  if (!p) throw new AdminInputError("No such user.");
  return p;
}

// MARK: - Users

export async function setTierOverride(db: Db, actor: string, userId: string, tier: string | null): Promise<void> {
  const p = await mustProfile(db, userId);
  const next: Tier | null = tier && tier !== "none" ? (isTier(tier) ? tier : null) : null;
  if (tier && tier !== "none" && !next) throw new AdminInputError(`Unknown tier "${tier}".`);
  await db.updateProfile(userId, { tierOverride: next });
  await audit(db, actor, "user.tier_override", p.email, { userId, from: p.tierOverride ?? null, to: next });
}

export async function grantEntitlement(db: Db, actor: string, userId: string, key: string, expiresAt: string | null): Promise<void> {
  const p = await mustProfile(db, userId);
  if (!(ENTITLEMENT_KEYS as readonly string[]).includes(key)) throw new AdminInputError(`Unknown entitlement "${key}".`);
  let exp: string | null = null;
  if (expiresAt) {
    const d = new Date(expiresAt);
    if (Number.isNaN(d.getTime())) throw new AdminInputError("Bad expiry date.");
    exp = d.toISOString();
  }
  await db.grantEntitlement(userId, key, `admin:${actor}`, exp);
  await audit(db, actor, "user.entitlement_grant", p.email, { userId, key, expiresAt: exp });
}

export async function revokeEntitlement(db: Db, actor: string, userId: string, key: string): Promise<void> {
  const p = await mustProfile(db, userId);
  await db.adminRevokeEntitlement(userId, key);
  await audit(db, actor, "user.entitlement_revoke", p.email, { userId, key });
}

/** Adds days to the trial, counting from the later of now and the current end. */
export async function extendTrial(db: Db, actor: string, userId: string, days: number, now = new Date()): Promise<string> {
  const p = await mustProfile(db, userId);
  if (!Number.isFinite(days) || days < 1 || days > 365) throw new AdminInputError("Days must be 1–365.");
  const from = Math.max(now.getTime(), p.trialEndsAt ? new Date(p.trialEndsAt).getTime() : 0);
  const trialEndsAt = new Date(from + Math.round(days) * 86_400_000).toISOString();
  await db.updateProfile(userId, { trialEndsAt });
  await audit(db, actor, "user.trial_extend", p.email, { userId, days: Math.round(days), from: p.trialEndsAt, to: trialEndsAt }, now);
  return trialEndsAt;
}

/** "Reset today's quota" (`day`) or this month's tasks (`month`); usage rows (cost history) stay. */
export async function resetQuota(db: Db, actor: string, userId: string, scope: "day" | "month", now = new Date()): Promise<QuotaReset> {
  const p = await mustProfile(db, userId);
  const day = dayKey(now);
  const month = monthKey(now);
  const prev = p.quotaReset ?? {};
  let next: QuotaReset;
  if (scope === "day") {
    const [answersDay, tasksDay] = await Promise.all([
      db.countUsage(userId, featuresInBucket("answers"), { day }),
      db.countUsage(userId, featuresInBucket("tasks"), { day }),
    ]);
    next = { ...(prev.month === month ? { month: prev.month, tasksMonth: prev.tasksMonth } : {}), day, answersDay, tasksDay };
  } else {
    const tasksMonth = await db.countUsage(userId, featuresInBucket("tasks"), { month });
    next = { ...(prev.day === day ? { day: prev.day, answersDay: prev.answersDay, tasksDay: prev.tasksDay } : {}), month, tasksMonth };
  }
  await db.updateProfile(userId, { quotaReset: next });
  await audit(db, actor, scope === "day" ? "user.quota_reset_day" : "user.quota_reset_month", p.email, { userId, ...next }, now);
  return next;
}

export async function setDisabled(db: Db, actor: string, userId: string, disabled: boolean, reason: string | null, now = new Date()): Promise<void> {
  const p = await mustProfile(db, userId);
  const r = reason?.trim().slice(0, 500) || null;
  await db.updateProfile(userId, disabled ? { disabledAt: now.toISOString(), disabledReason: r } : { disabledAt: null, disabledReason: null });
  await audit(db, actor, disabled ? "user.disable" : "user.enable", p.email, disabled ? { userId, reason: r } : { userId }, now);
}

export async function signOutEverywhere(db: Db, actor: string, userId: string): Promise<void> {
  const p = await mustProfile(db, userId);
  await db.adminSignOutUser(userId);
  await audit(db, actor, "user.sign_out_all", p.email, { userId });
}

/**
 * Deletes the account the same way the user's own "Delete account" does (lib/account.ts):
 * Stripe subscriptions cancelled first (nothing is deleted if that fails), then every row,
 * then the auth user. The admin must retype the email.
 */
export async function deleteUser(
  db: Db,
  actor: string,
  userId: string,
  confirmEmail: string,
  deps: { sessions?: SessionProvider; billing?: BillingCanceller | null } = {},
): Promise<void> {
  const p = await mustProfile(db, userId);
  if (confirmEmail.trim().toLowerCase() !== p.email.toLowerCase()) throw new AdminInputError("Type the user's email exactly to confirm.");
  const billing = deps.billing !== undefined ? deps.billing : billingCanceller();
  await deleteAccount({ db, sessions: deps.sessions ?? getSessionProvider(), billing }, { id: userId, email: p.email }, "admin");
  await audit(db, actor, "user.delete", p.email, {
    userId,
    tier: p.tier,
    hadSubscription: Boolean(p.stripeSubscriptionId),
    subscriptionStatus: p.subscriptionStatus,
  });
}

// MARK: - Keys

export async function setKey(db: Db, actor: string, provider: VendorProvider, rawKey: unknown, rotating: boolean): Promise<void> {
  const { last4 } = await storeVendorKey(db, provider, rawKey, actor);
  await audit(db, actor, rotating ? "key.rotate" : "key.set", provider, { last4 });
}

export async function removeKey(db: Db, actor: string, provider: VendorProvider): Promise<void> {
  await removeVendorKey(db, provider, actor);
  await audit(db, actor, "key.remove", provider, { fallback: "env" });
}

/** Tests whichever key the proxy would use right now and records the result. */
export async function testKey(db: Db, actor: string, provider: VendorProvider, fetchImpl?: Parameters<typeof testVendorKey>[2]): Promise<KeyTestResult & { source: string }> {
  const { key, source } = await resolveVendorKey(provider, db, { fresh: true });
  const result: KeyTestResult = key ? await testVendorKey(provider, key, fetchImpl) : { ok: false, latencyMs: 0, error: "No key configured (database or env)." };
  await db.adminUpdateVendorKeyMeta(provider, {
    lastTestAt: new Date().toISOString(),
    lastTestOk: result.ok,
    lastTestLatencyMs: result.latencyMs,
    lastTestError: result.error ?? null,
  }).catch(() => undefined);
  await audit(db, actor, "key.test", provider, { source, ok: result.ok, latencyMs: result.latencyMs, status: result.status ?? null });
  return { ...result, source };
}

// MARK: - Config

function diffKeys(a: ProductConfig, b: ProductConfig): string[] {
  const changed: string[] = [];
  for (const k of ["features", "notice", "minAppVersion", "latestVersion", "downloadURL", "quotas", "models"] as const) {
    if (JSON.stringify(a[k]) !== JSON.stringify(b[k])) changed.push(k);
  }
  return changed;
}

export async function updateConfig(db: Db, actor: string, before: ProductConfig, next: Partial<ProductConfig>): Promise<ProductConfig> {
  const saved = await saveConfig(db, { ...before, ...next }, actor);
  const changed = diffKeys(before, saved);
  const details: Record<string, unknown> = { changed };
  if (changed.includes("features")) details.features = saved.features;
  if (changed.includes("notice")) details.notice = saved.notice ? { level: saved.notice.level, id: saved.notice.id } : null;
  if (changed.includes("minAppVersion")) details.minAppVersion = saved.minAppVersion;
  if (changed.includes("latestVersion")) details.latestVersion = saved.latestVersion;
  if (changed.includes("models")) details.models = saved.models;
  if (changed.includes("quotas")) details.quotas = saved.quotas;
  await audit(db, actor, "config.update", null, details);
  return saved;
}

// MARK: - Waitlist

export async function inviteFromWaitlist(db: Db, actor: string, email: string, redirectTo: string, now = new Date()): Promise<void> {
  const e = email.trim().toLowerCase();
  if (!e.includes("@")) throw new AdminInputError("Bad email.");
  await db.adminInviteUser(e, redirectTo);
  await db.adminMarkInvited(e, now.toISOString());
  await audit(db, actor, "waitlist.invite", e, { driver: db.driver }, now);
}

export async function markInvited(db: Db, actor: string, email: string, now = new Date()): Promise<void> {
  const e = email.trim().toLowerCase();
  await db.adminMarkInvited(e, now.toISOString());
  await audit(db, actor, "waitlist.mark_invited", e, {}, now);
}

// MARK: - Admins

export async function addAdmin(db: Db, actor: string, email: string): Promise<void> {
  const e = email.trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(e)) throw new AdminInputError("Bad email.");
  await db.adminAddAdmin(e, actor);
  await audit(db, actor, "admin.add", e);
}

export async function removeAdmin(db: Db, actor: string, email: string): Promise<void> {
  const e = email.trim().toLowerCase();
  if (e === actor.toLowerCase()) throw new AdminInputError("You can't remove yourself.");
  await db.adminRemoveAdmin(e);
  await audit(db, actor, "admin.remove", e);
}
