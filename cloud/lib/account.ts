/**
 * Export and delete — everything Navi Cloud holds about one person, and how it goes away.
 *
 * What the cloud stores (and so what an export contains): the profile (email, plan, trial end,
 * Stripe customer/subscription ids and status), manual entitlement grants, one usage row per
 * run (feature, run id, day, month, cost), the waitlist row if they signed up there, and the
 * list of signed-in devices (ids + timestamps). Never request or response content, OCR text,
 * screenshots, or anything Recall remembers — those stay on the Mac.
 *
 * Delete order is fail-closed on billing: cancel Stripe first (if that fails, nothing is
 * deleted and the user is not left paying for a vanished account), then our rows, then the
 * auth user (which ends every session).
 */

import type { AuthUser } from "./auth";
import { getStripe, stripeConfigured } from "./billing";
import type { Db, DeletedCounts, EntitlementGrant, UsageRecord, WaitlistRecord } from "./db";
import { env } from "./env";
import { HttpError } from "./http";
import { pseudonym } from "./db";
import { meBody } from "./metering";
import type { DeviceSession, SessionProvider } from "./sessions";

export const EXPORT_FORMAT = "navi-account-export/1";

export const NOT_STORED =
  "Navi's servers never store what you ask, what Navi answers, your screen, OCR text or screenshots. " +
  "Usage is counted once per run (feature, day, cost) and nothing else. Everything Recall remembers stays on your Mac.";

export interface AccountExport {
  format: typeof EXPORT_FORMAT;
  exportedAt: string;
  user: { id: string; email: string };
  profile: {
    email: string;
    plan: string;
    trialEndsAt: string | null;
    subscriptionStatus: string | null;
    stripeCustomerId: string | null;
    stripeSubscriptionId: string | null;
    createdAt: string;
    /** Set by support: a plan that wins over the paid tier and the trial. */
    tierOverride: string | null;
    /** Set when the account was disabled (export and delete keep working). */
    disabledAt: string | null;
  } | null;
  /** The plan as served right now: effective tier, entitlements, quotas, usage this period. Null while disabled. */
  current: Record<string, unknown> | null;
  entitlementGrants: EntitlementGrant[];
  usage: UsageRecord[];
  waitlist: WaitlistRecord | null;
  devices: DeviceSession[];
  notStored: string;
}

/** Cancels a customer's subscriptions and removes the customer (card details) from billing. */
export interface BillingCanceller {
  cancelCustomer(customerId: string, subscriptionId: string | null): Promise<void>;
}

export interface AccountDeps {
  db: Db;
  sessions: SessionProvider;
  /** null when billing is not configured on this deployment. */
  billing: BillingCanceller | null;
  now?: Date;
}

export async function exportAccount(deps: AccountDeps, user: AuthUser): Promise<AccountExport> {
  const now = deps.now ?? new Date();
  const email = (await deps.db.getProfile(user.id))?.email || user.email;
  const raw = await deps.db.exportUserData(user.id, email);
  const devices = await deps.sessions.listSessions(user.id);
  // meBody refuses a disabled account (403 account_disabled); export is a right, so it still runs.
  let current: Record<string, unknown> | null = null;
  if (raw.profile && !raw.profile.disabledAt) {
    try {
      current = await meBody(deps.db, { id: user.id, email }, now);
    } catch (e) {
      if (!(e instanceof HttpError)) throw e;
    }
  }
  return {
    format: EXPORT_FORMAT,
    exportedAt: now.toISOString(),
    user: { id: user.id, email },
    profile: raw.profile
      ? {
          email: raw.profile.email,
          plan: raw.profile.tier,
          trialEndsAt: raw.profile.trialEndsAt,
          subscriptionStatus: raw.profile.subscriptionStatus,
          stripeCustomerId: raw.profile.stripeCustomerId,
          stripeSubscriptionId: raw.profile.stripeSubscriptionId,
          createdAt: raw.profile.createdAt,
          tierOverride: raw.profile.tierOverride ?? null,
          disabledAt: raw.profile.disabledAt ?? null,
        }
      : null,
    current,
    entitlementGrants: raw.entitlements,
    usage: raw.usage,
    waitlist: raw.waitlist,
    devices,
    notStored: NOT_STORED,
  };
}

export interface DeleteResult {
  deleted: DeletedCounts;
  billingCancelled: boolean;
}

/**
 * Deletes everything about `user`. Used by DELETE /v1/account (`by: "self"`) and by the admin
 * console's "Delete user" (lib/admin/ops.ts, which writes its own audit entry). Works for a
 * disabled account: erasure is a right, not a feature.
 */
export async function deleteAccount(deps: AccountDeps, user: AuthUser, by: "self" | "admin" = "self"): Promise<DeleteResult> {
  const profile = await deps.db.getProfile(user.id);
  const email = profile?.email || user.email;

  let billingCancelled = false;
  if (profile?.stripeCustomerId) {
    if (!deps.billing) {
      throw new HttpError(503, {
        error: "billing_unconfigured",
        message: "We couldn’t cancel your subscription right now, so nothing was deleted. Try again later or email support.",
      });
    }
    try {
      await deps.billing.cancelCustomer(profile.stripeCustomerId, profile.stripeSubscriptionId);
      billingCancelled = true;
    } catch (e) {
      console.error("[navi-cloud] account delete: billing cancel failed:", (e as Error).message);
      throw new HttpError(502, {
        error: "billing_error",
        message: "We couldn’t cancel your subscription, so nothing was deleted. Try again in a minute.",
      });
    }
  }

  const deleted = await deps.db.deleteUserData(user.id, email);
  await deps.sessions.deleteUser(user.id);
  if (by === "self") {
    // The admin console sees that an account went, never whose: no email in the entry.
    await deps.db
      .adminWriteAudit({ actor: "self", action: "account.delete", target: pseudonym(user.id), details: { billingCancelled }, at: (deps.now ?? new Date()).toISOString() })
      .catch(() => undefined);
  }
  return { deleted, billingCancelled };
}

// MARK: - Stripe

function isMissing(e: unknown): boolean {
  const x = e as { code?: string; statusCode?: number };
  return x?.code === "resource_missing" || x?.statusCode === 404;
}

export function stripeCanceller(): BillingCanceller {
  return {
    async cancelCustomer(customerId, subscriptionId) {
      const stripe = getStripe();
      const ids = new Set<string>();
      if (subscriptionId) ids.add(subscriptionId);
      try {
        for await (const sub of stripe.subscriptions.list({ customer: customerId, status: "all", limit: 100 })) {
          if (sub.status !== "canceled" && sub.status !== "incomplete_expired") ids.add(sub.id);
        }
      } catch (e) {
        if (!isMissing(e)) throw e;
      }
      for (const id of ids) {
        try {
          await stripe.subscriptions.cancel(id);
        } catch (e) {
          // Already canceled / gone is fine; anything else aborts the delete.
          const x = e as { code?: string; message?: string };
          if (!isMissing(e) && !/canceled/i.test(x.message ?? "")) throw e;
        }
      }
      // Removes the stored payment method and contact details. Invoices stay in Stripe for tax records.
      try {
        await stripe.customers.del(customerId);
      } catch (e) {
        if (!isMissing(e)) throw e;
      }
    },
  };
}

/** The canceller this deployment can use: Stripe, a no-op in local mock mode, else none. */
export function billingCanceller(): BillingCanceller | null {
  if (stripeConfigured()) return stripeCanceller();
  if (env.mockUpstream && !env.isProduction) {
    return {
      async cancelCustomer(customerId) {
        console.info(`[navi-cloud] (mock) would cancel billing for customer ${customerId}`);
      },
    };
  }
  return null;
}
