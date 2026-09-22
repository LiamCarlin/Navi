import { getDb } from "@/lib/db";
import { clientIp, handle, HttpError, json, rateLimited, readJson } from "@/lib/http";
import { authIpLimiter } from "@/lib/ratelimit";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** POST /auth/exchange { code } → { accessToken, refreshToken, expiresAt }. Single use, 5-minute TTL. */
export const POST = handle(async (req) => {
  const rl = authIpLimiter.hit(clientIp(req));
  if (!rl.ok) throw rateLimited(rl.retryAfterSeconds);

  const body = await readJson<{ code?: unknown }>(req);
  const code = typeof body.code === "string" ? body.code.trim() : "";
  if (!code) throw new HttpError(400, { error: "bad_request", message: "Missing code." });

  const db = await getDb();
  const tokens = await db.consumeAuthCode(code, new Date());
  if (!tokens) throw new HttpError(400, { error: "invalid_code", message: "This sign-in link has expired or was already used. Sign in again." });
  return json(tokens);
});
