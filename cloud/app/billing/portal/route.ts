import { requireUser } from "@/lib/auth";
import { getStripe, stripeConfigured } from "@/lib/billing";
import { getDb } from "@/lib/db";
import { env } from "@/lib/env";
import { handle, HttpError, json, rateLimited } from "@/lib/http";
import { perUserLimiter } from "@/lib/ratelimit";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** POST /billing/portal → { url } — Stripe Customer Portal for the signed-in user. */
export const POST = handle(async (req) => {
  const user = await requireUser(req);
  const rl = perUserLimiter.hit(user.id);
  if (!rl.ok) throw rateLimited(rl.retryAfterSeconds);
  if (!stripeConfigured()) throw new HttpError(503, { error: "billing_unconfigured", message: "Billing is not set up on this deployment." });

  const db = await getDb();
  const profile = await db.ensureProfile(user.id, user.email, new Date());
  if (!profile.stripeCustomerId) {
    throw new HttpError(400, { error: "no_customer", message: "No subscription yet — start one from Upgrade." });
  }
  const session = await getStripe().billingPortal.sessions.create({
    customer: profile.stripeCustomerId,
    return_url: `${env.baseUrl}/billing/return?status=portal`,
  });
  return json({ url: session.url });
});
