import { requireUser } from "@/lib/auth";
import { getConfig } from "@/lib/config";
import { getDb } from "@/lib/db";
import { handle, json, rateLimited } from "@/lib/http";
import { meBody } from "@/lib/metering";
import { perUserLimiter } from "@/lib/ratelimit";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** GET /v1/me — tier, entitlements, quotas, usage and product config for the signed-in user (§3.1). 403 `account_disabled`. */
export const GET = handle(async (req) => {
  const user = await requireUser(req);
  const rl = await perUserLimiter.hit(user.id);
  if (!rl.ok) throw rateLimited(rl.retryAfterSeconds);
  const db = await getDb();
  // Adds `config` (kill switches, notice, versions). Never 426 here: an old app must still learn it is too old.
  return json(await meBody(db, user, new Date(), await getConfig(db)));
});
