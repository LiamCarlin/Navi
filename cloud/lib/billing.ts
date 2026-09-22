/**
 * Stripe: plan ↔ price ids, and the pure webhook-event → profile mapping that
 * the tests cover. `getStripe()` is the only thing that touches the SDK.
 */

import Stripe from "stripe";
import type { Db, ProfilePatch } from "./db";
import { env } from "./env";
import type { Tier } from "./plans";

export type Plan = "pro" | "pro_recall";
export type Interval = "month" | "year";
export const PLANS_FOR_SALE: readonly Plan[] = ["pro", "pro_recall"];
export const INTERVALS: readonly Interval[] = ["month", "year"];

export type PriceTable = Record<`${Plan}_${Interval}`, string | undefined>;

export function priceIdFor(plan: Plan, interval: Interval, prices: PriceTable): string | undefined {
  return prices[`${plan}_${interval}`];
}

export function planFromPriceId(priceId: string | undefined, prices: PriceTable): Plan | null {
  if (!priceId) return null;
  for (const plan of PLANS_FOR_SALE) {
    for (const interval of INTERVALS) {
      if (prices[`${plan}_${interval}`] === priceId) return plan;
    }
  }
  return null;
}

/** Statuses under which the customer keeps what they paid for. `past_due` stays paid while Stripe duns. */
const PAID_STATUSES = new Set(["active", "trialing", "past_due"]);

export function tierForSubscription(status: string | null | undefined, plan: Plan | null): Tier {
  if (!plan) return "free";
  return status && PAID_STATUSES.has(status) ? plan : "free";
}

/** What a webhook wants changed, addressed by user id (checkout) or Stripe customer (everything else). */
export interface ProfileUpdate {
  userId?: string;
  customerId?: string;
  patch: ProfilePatch;
}

/** A structural subset of Stripe.Event so tests can hand in plain objects. */
export interface StripeEventLike {
  type: string;
  data: { object: Record<string, unknown> };
}

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

function customerId(obj: Record<string, unknown>): string | undefined {
  const c = obj.customer;
  if (typeof c === "string") return c;
  if (c && typeof c === "object" && "id" in c) return str((c as { id?: unknown }).id);
  return undefined;
}

function firstPriceId(obj: Record<string, unknown>): string | undefined {
  const items = (obj.items as { data?: { price?: { id?: unknown } }[] } | undefined)?.data;
  return str(items?.[0]?.price?.id);
}

function metadataPlan(obj: Record<string, unknown>): Plan | null {
  const p = str((obj.metadata as Record<string, unknown> | undefined)?.plan);
  return p && (PLANS_FOR_SALE as readonly string[]).includes(p) ? (p as Plan) : null;
}

/**
 * Pure mapping. Returns null for events we do not act on.
 *   checkout.session.completed        → tier from the session's plan metadata; store customer + subscription ids
 *   customer.subscription.created/updated → tier from price id (or metadata) × status
 *   customer.subscription.deleted     → free
 *   invoice.payment_failed            → mark past_due (tier unchanged; Stripe's dunning decides)
 */
export function mapStripeEvent(event: StripeEventLike, prices: PriceTable): ProfileUpdate | null {
  const obj = event.data.object;
  switch (event.type) {
    case "checkout.session.completed": {
      if (obj.mode !== "subscription") return null;
      const userId = str(obj.client_reference_id) ?? str((obj.metadata as Record<string, unknown> | undefined)?.user_id);
      const plan = metadataPlan(obj);
      const patch: ProfilePatch = {
        stripeCustomerId: customerId(obj) ?? null,
        stripeSubscriptionId: str(obj.subscription) ?? null,
        subscriptionStatus: "active",
      };
      if (plan) patch.tier = plan;
      if (!userId && !patch.stripeCustomerId) return null;
      return { userId, customerId: patch.stripeCustomerId ?? undefined, patch };
    }
    case "customer.subscription.created":
    case "customer.subscription.updated": {
      const status = str(obj.status) ?? null;
      const plan = planFromPriceId(firstPriceId(obj), prices) ?? metadataPlan(obj);
      const cid = customerId(obj);
      if (!cid) return null;
      return {
        userId: str((obj.metadata as Record<string, unknown> | undefined)?.user_id),
        customerId: cid,
        patch: { tier: tierForSubscription(status, plan), stripeSubscriptionId: str(obj.id) ?? null, subscriptionStatus: status },
      };
    }
    case "customer.subscription.deleted": {
      const cid = customerId(obj);
      if (!cid) return null;
      return { customerId: cid, patch: { tier: "free", stripeSubscriptionId: null, subscriptionStatus: "canceled" } };
    }
    case "invoice.payment_failed": {
      const cid = customerId(obj);
      if (!cid) return null;
      return { customerId: cid, patch: { subscriptionStatus: "past_due" } };
    }
    default:
      return null;
  }
}

/** Applies a mapped update. Returns the user id touched, or null when no profile matched. */
export async function applyProfileUpdate(db: Db, update: ProfileUpdate): Promise<string | null> {
  let userId = update.userId ?? null;
  if (!userId && update.customerId) {
    userId = (await db.getProfileByStripeCustomer(update.customerId))?.userId ?? null;
  }
  if (!userId) return null;
  if (!(await db.getProfile(userId))) return null;
  await db.updateProfile(userId, update.patch);
  return userId;
}

// MARK: - SDK

let stripe: Stripe | undefined;

export function getStripe(): Stripe {
  if (stripe) return stripe;
  const key = env.stripeSecretKey;
  if (!key) throw new Error("STRIPE_SECRET_KEY is not set");
  stripe = new Stripe(key, { typescript: true });
  return stripe;
}

export function stripeConfigured(): boolean {
  return Boolean(env.stripeSecretKey);
}
