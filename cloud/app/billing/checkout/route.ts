import { requireUser } from "@/lib/auth";
import { getStripe, INTERVALS, PLANS_FOR_SALE, priceIdFor, stripeConfigured, type Interval, type Plan } from "@/lib/billing";
import { getDb } from "@/lib/db";
import { env } from "@/lib/env";
import { badRequest, handle, HttpError, json, rateLimited, readJson } from "@/lib/http";
import { perUserLimiter } from "@/lib/ratelimit";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * POST /billing/checkout { plan: "pro"|"pro_recall", interval: "month"|"year" } → { url }
 * Stripe Checkout in subscription mode. `client_reference_id` = user id; the plan rides in
 * metadata on both the session and the subscription so the webhook can set the tier.
 * Return URLs go through /billing/return, which bounces to navi://billing/success|cancel
 * (Stripe only accepts http(s) return URLs).
 */
export const POST = handle(async (req) => {
  const user = await requireUser(req);
  const rl = perUserLimiter.hit(user.id);
  if (!rl.ok) throw rateLimited(rl.retryAfterSeconds);

  const body = await readJson<{ plan?: unknown; interval?: unknown }>(req);
  const plan = body.plan as Plan;
  const interval = (body.interval ?? "month") as Interval;
  if (!PLANS_FOR_SALE.includes(plan)) throw badRequest(`plan must be one of ${PLANS_FOR_SALE.join(", ")}`);
  if (!INTERVALS.includes(interval)) throw badRequest(`interval must be one of ${INTERVALS.join(", ")}`);
  if (!stripeConfigured()) throw new HttpError(503, { error: "billing_unconfigured", message: "Billing is not set up on this deployment." });

  const price = priceIdFor(plan, interval, env.stripePrices);
  if (!price) throw new HttpError(503, { error: "billing_unconfigured", message: `No Stripe price configured for ${plan}/${interval}.` });

  const db = await getDb();
  const profile = await db.ensureProfile(user.id, user.email, new Date());

  const session = await getStripe().checkout.sessions.create({
    mode: "subscription",
    line_items: [{ price, quantity: 1 }],
    client_reference_id: user.id,
    customer: profile.stripeCustomerId ?? undefined,
    customer_email: profile.stripeCustomerId ? undefined : user.email || undefined,
    success_url: `${env.baseUrl}/billing/return?status=success&session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${env.baseUrl}/billing/return?status=cancel`,
    allow_promotion_codes: true,
    metadata: { user_id: user.id, plan, interval },
    subscription_data: { metadata: { user_id: user.id, plan, interval } },
  });
  if (!session.url) throw new HttpError(502, { error: "stripe_error", message: "Stripe returned no checkout URL." });
  return json({ url: session.url });
});
