import { requireUser } from "@/lib/auth";
import { getDb } from "@/lib/db";
import { handle, json, rateLimited } from "@/lib/http";
import { meBody } from "@/lib/metering";
import { perUserLimiter } from "@/lib/ratelimit";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** GET /v1/me — tier, entitlements, quotas and usage for the signed-in user (§3.1). */
export const GET = handle(async (req) => {
  const user = await requireUser(req);
  const rl = perUserLimiter.hit(user.id);
  if (!rl.ok) throw rateLimited(rl.retryAfterSeconds);
  const db = await getDb();
  return json(await meBody(db, user, new Date()));
});
