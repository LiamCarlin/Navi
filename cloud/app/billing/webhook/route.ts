import { applyProfileUpdate, getStripe, mapStripeEvent, stripeConfigured, type StripeEventLike } from "@/lib/billing";
import { getDb } from "@/lib/db";
import { env } from "@/lib/env";
import { handle, HttpError, json, parseJson } from "@/lib/http";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * POST /billing/webhook — Stripe → profiles.tier / stripe ids.
 * Handles checkout.session.completed, customer.subscription.{created,updated,deleted},
 * invoice.payment_failed. Signature verified with STRIPE_WEBHOOK_SECRET; when that is
 * unset AND MOCK_UPSTREAM=1 (local dev), unsigned JSON events are accepted so the smoke
 * test can flip a user to Pro.
 */
export const POST = handle(async (req) => {
  const raw = await req.text();
  let event: StripeEventLike;

  const secret = env.stripeWebhookSecret;
  if (secret) {
    if (!stripeConfigured()) throw new HttpError(500, { error: "misconfigured", message: "STRIPE_SECRET_KEY missing" });
    const sig = req.headers.get("stripe-signature");
    if (!sig) throw new HttpError(400, { error: "bad_signature", message: "Missing stripe-signature header." });
    try {
      event = getStripe().webhooks.constructEvent(raw, sig, secret) as unknown as StripeEventLike;
    } catch (e) {
      throw new HttpError(400, { error: "bad_signature", message: (e as Error).message });
    }
  } else if (env.mockUpstream && !env.isProduction) {
    event = parseJson<StripeEventLike>(raw);
    if (!event?.type || !event.data?.object) throw new HttpError(400, { error: "bad_request", message: "Not a Stripe event." });
  } else {
    throw new HttpError(500, { error: "misconfigured", message: "STRIPE_WEBHOOK_SECRET is not set." });
  }

  const update = mapStripeEvent(event, env.stripePrices);
  if (!update) return json({ received: true, handled: false, type: event.type });

  const userId = await applyProfileUpdate(await getDb(), update);
  if (!userId) console.warn(`[navi-cloud] webhook ${event.type}: no profile for`, update.userId ?? update.customerId);
  return json({ received: true, handled: true, type: event.type, userId });
});
