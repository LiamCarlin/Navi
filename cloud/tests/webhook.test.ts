import { beforeEach, describe, expect, it } from "vitest";
import { applyProfileUpdate, mapStripeEvent, planFromPriceId, priceIdFor, tierForSubscription, type PriceTable } from "@/lib/billing";
import { createMemoryDb, type MemoryDb } from "@/lib/db";

const prices: PriceTable = {
  pro_month: "price_pro_m",
  pro_year: "price_pro_y",
  pro_recall_month: "price_rec_m",
  pro_recall_year: "price_rec_y",
};

const T = new Date("2026-09-22T15:30:00Z");

describe("price ids", () => {
  it("round-trips plan × interval", () => {
    expect(priceIdFor("pro", "month", prices)).toBe("price_pro_m");
    expect(priceIdFor("pro_recall", "year", prices)).toBe("price_rec_y");
    expect(planFromPriceId("price_rec_m", prices)).toBe("pro_recall");
    expect(planFromPriceId("price_pro_y", prices)).toBe("pro");
    expect(planFromPriceId("price_unknown", prices)).toBeNull();
    expect(planFromPriceId(undefined, prices)).toBeNull();
  });
  it("maps subscription status to a tier", () => {
    expect(tierForSubscription("active", "pro")).toBe("pro");
    expect(tierForSubscription("trialing", "pro_recall")).toBe("pro_recall");
    expect(tierForSubscription("past_due", "pro")).toBe("pro");
    expect(tierForSubscription("canceled", "pro")).toBe("free");
    expect(tierForSubscription("unpaid", "pro_recall")).toBe("free");
    expect(tierForSubscription("active", null)).toBe("free");
  });
});

describe("mapStripeEvent", () => {
  it("checkout.session.completed → tier from metadata, stores customer + subscription", () => {
    const u = mapStripeEvent({
      type: "checkout.session.completed",
      data: { object: { mode: "subscription", client_reference_id: "u-1", customer: "cus_1", subscription: "sub_1", metadata: { plan: "pro_recall", user_id: "u-1" } } },
    }, prices);
    expect(u).toEqual({ userId: "u-1", customerId: "cus_1", patch: { tier: "pro_recall", stripeCustomerId: "cus_1", stripeSubscriptionId: "sub_1", subscriptionStatus: "active" } });
  });
  it("ignores one-off payment checkouts", () => {
    expect(mapStripeEvent({ type: "checkout.session.completed", data: { object: { mode: "payment", customer: "cus_1" } } }, prices)).toBeNull();
  });
  it("customer.subscription.updated → tier from the price id and status", () => {
    const u = mapStripeEvent({
      type: "customer.subscription.updated",
      data: { object: { id: "sub_1", customer: "cus_1", status: "active", items: { data: [{ price: { id: "price_pro_y" } }] } } },
    }, prices);
    expect(u).toEqual({ userId: undefined, customerId: "cus_1", patch: { tier: "pro", stripeSubscriptionId: "sub_1", subscriptionStatus: "active" } });
  });
  it("customer.subscription.updated with canceled status → free", () => {
    const u = mapStripeEvent({
      type: "customer.subscription.updated",
      data: { object: { id: "sub_1", customer: { id: "cus_1" }, status: "canceled", items: { data: [{ price: { id: "price_rec_m" } }] } } },
    }, prices);
    expect(u?.patch.tier).toBe("free");
  });
  it("falls back to subscription metadata when the price is unknown", () => {
    const u = mapStripeEvent({
      type: "customer.subscription.created",
      data: { object: { id: "sub_2", customer: "cus_1", status: "trialing", metadata: { plan: "pro", user_id: "u-1" }, items: { data: [{ price: { id: "price_legacy" } }] } } },
    }, prices);
    expect(u).toMatchObject({ userId: "u-1", patch: { tier: "pro", subscriptionStatus: "trialing" } });
  });
  it("customer.subscription.deleted → free", () => {
    const u = mapStripeEvent({ type: "customer.subscription.deleted", data: { object: { id: "sub_1", customer: "cus_1" } } }, prices);
    expect(u).toEqual({ customerId: "cus_1", patch: { tier: "free", stripeSubscriptionId: null, subscriptionStatus: "canceled" } });
  });
  it("invoice.payment_failed → past_due, tier untouched", () => {
    const u = mapStripeEvent({ type: "invoice.payment_failed", data: { object: { customer: "cus_1" } } }, prices);
    expect(u).toEqual({ customerId: "cus_1", patch: { subscriptionStatus: "past_due" } });
    expect(u?.patch.tier).toBeUndefined();
  });
  it("ignores everything else", () => {
    expect(mapStripeEvent({ type: "payment_intent.succeeded", data: { object: { customer: "cus_1" } } }, prices)).toBeNull();
  });
});

describe("applyProfileUpdate", () => {
  let db: MemoryDb;
  beforeEach(async () => {
    db = createMemoryDb();
    await db.ensureProfile("u-1", "liam@example.com", T);
  });

  it("upgrades on checkout, then downgrades on deletion by customer id", async () => {
    const checkout = mapStripeEvent({
      type: "checkout.session.completed",
      data: { object: { mode: "subscription", client_reference_id: "u-1", customer: "cus_1", subscription: "sub_1", metadata: { plan: "pro" } } },
    }, prices)!;
    expect(await applyProfileUpdate(db, checkout)).toBe("u-1");
    expect(await db.getProfile("u-1")).toMatchObject({ tier: "pro", stripeCustomerId: "cus_1", stripeSubscriptionId: "sub_1" });

    const deleted = mapStripeEvent({ type: "customer.subscription.deleted", data: { object: { id: "sub_1", customer: "cus_1" } } }, prices)!;
    expect(await applyProfileUpdate(db, deleted)).toBe("u-1");
    expect(await db.getProfile("u-1")).toMatchObject({ tier: "free", stripeSubscriptionId: null, subscriptionStatus: "canceled" });
  });

  it("returns null for unknown customers instead of throwing", async () => {
    const u = mapStripeEvent({ type: "invoice.payment_failed", data: { object: { customer: "cus_nobody" } } }, prices)!;
    expect(await applyProfileUpdate(db, u)).toBeNull();
  });
});
