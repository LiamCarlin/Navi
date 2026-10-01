import { requireAccountUser } from "@/lib/auth";
import { getStripe, INTERVALS, PLANS_FOR_SALE, priceIdFor, stripeConfigured, type Interval, type Plan } from "@/lib/billing";
import { getDb } from "@/lib/db";
import { env } from "@/lib/env";
import { badRequest, handle, HttpError, json, rateLimited, readJson } from "@/lib/http";
import { perUserLimiter } from "@/lib/ratelimit";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * POST /account/billing  (cookie session from /account)
 *   { action: "checkout", plan: "pro"|"pro_recall", interval: "month"|"year" } → { url }
 *   { action: "portal" } → { url }
 * Same Stripe sessions as /billing/checkout and /billing/portal (which the app uses with its
 * Bearer token), but Stripe sends the browser back to /account instead of into the app.
 * 503 billing_unconfigured while Stripe is not set up — the page hides the buttons then.
 */
export const POST = handle(async (req) => {
  const { user } = await requireAccountUser(req);
  const rl = await perUserLimiter.hit(user.id);
  if (!rl.ok) throw rateLimited(rl.retryAfterSeconds);
  if (!stripeConfigured()) throw new HttpError(503, { error: "billing_unconfigured", message: "Upgrades aren’t open yet." });

  const body = await readJson<{ action?: unknown; plan?: unknown; interval?: unknown }>(req);
  const db = await getDb();
  const profile = await db.ensureProfile(user.id, user.email, new Date());
  const back = `${env.baseUrl}/account`;

  if (body.action === "portal") {
    if (!profile.stripeCustomerId) throw new HttpError(400, { error: "no_customer", message: "No subscription yet — pick a plan first." });
    const session = await getStripe().billingPortal.sessions.create({ customer: profile.stripeCustomerId, return_url: `${back}?billing=updated` });
    return json({ url: session.url });
  }

  if (body.action !== "checkout") throw badRequest("action must be checkout or portal");
  const plan = body.plan as Plan;
  const interval = (body.interval ?? "month") as Interval;
  if (!PLANS_FOR_SALE.includes(plan)) throw badRequest(`plan must be one of ${PLANS_FOR_SALE.join(", ")}`);
  if (!INTERVALS.includes(interval)) throw badRequest(`interval must be one of ${INTERVALS.join(", ")}`);
  const price = priceIdFor(plan, interval, env.stripePrices);
  if (!price) throw new HttpError(503, { error: "billing_unconfigured", message: "That plan isn’t available yet." });

  // Already subscribed: changing plans happens in the portal (proration, no double billing).
  if (profile.stripeSubscriptionId && profile.subscriptionStatus && profile.subscriptionStatus !== "canceled" && profile.stripeCustomerId) {
    const session = await getStripe().billingPortal.sessions.create({ customer: profile.stripeCustomerId, return_url: `${back}?billing=updated` });
    return json({ url: session.url });
  }

  const session = await getStripe().checkout.sessions.create({
    mode: "subscription",
    line_items: [{ price, quantity: 1 }],
    client_reference_id: user.id,
    customer: profile.stripeCustomerId ?? undefined,
    customer_email: profile.stripeCustomerId ? undefined : profile.email || user.email || undefined,
    success_url: `${back}?billing=success`,
    cancel_url: `${back}?billing=cancel`,
    allow_promotion_codes: true,
    metadata: { user_id: user.id, plan, interval },
    subscription_data: { metadata: { user_id: user.id, plan, interval } },
  });
  if (!session.url) throw new HttpError(502, { error: "stripe_error", message: "Checkout didn’t open. Try again." });
  return json({ url: session.url });
});
