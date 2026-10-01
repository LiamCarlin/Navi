import { billingCanceller, deleteAccount } from "@/lib/account";
import { requireAccountUser } from "@/lib/auth";
import { getDb } from "@/lib/db";
import { env } from "@/lib/env";
import { handle, rateLimited } from "@/lib/http";
import { perUserLimiter } from "@/lib/ratelimit";
import { getSessionProvider } from "@/lib/sessions";
import { sessionClearCookie } from "@/lib/web-session";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * DELETE /v1/account  (Bearer, or the /account cookie session) → 204
 * Cancels any Stripe subscription (and removes the card on file), deletes usage, entitlement
 * grants, unexchanged sign-in codes, the waitlist row and the profile, then the auth user —
 * which ends every session. Idempotent. If billing can't be cancelled nothing is deleted
 * (502 billing_error / 503 billing_unconfigured).
 */
export const DELETE = handle(async (req) => {
  const caller = await requireAccountUser(req);
  const rl = await perUserLimiter.hit(caller.user.id);
  if (!rl.ok) throw rateLimited(rl.retryAfterSeconds);

  const result = await deleteAccount(
    { db: await getDb(), sessions: getSessionProvider(), billing: billingCanceller() },
    caller.user,
  );
  const d = result.deleted;
  console.info(
    `[navi-cloud] account deleted: usage=${d.usage} grants=${d.entitlements} codes=${d.authCodes} waitlist=${d.waitlist} billing=${result.billingCancelled}`,
  );

  const headers = new Headers({ "cache-control": "no-store" });
  if (caller.via === "cookie") headers.append("set-cookie", sessionClearCookie(env.secureCookies));
  return new Response(null, { status: 204, headers });
});
