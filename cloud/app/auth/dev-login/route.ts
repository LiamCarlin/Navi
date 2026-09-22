import { timingSafeEqual } from "node:crypto";
import { verifyAccessToken } from "@/lib/auth";
import { getDb } from "@/lib/db";
import { env } from "@/lib/env";
import { clientIp, handle, HttpError, json, rateLimited, readJson } from "@/lib/http";
import { authIpLimiter } from "@/lib/ratelimit";
import { getSessionProvider, memoryUserForEmail } from "@/lib/sessions";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function secretMatches(given: string | null): boolean {
  const expected = env.devLoginSecret;
  if (!expected || !given) return false;
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

/**
 * POST /auth/dev-login { email }  (header `x-dev-login-secret: $DEV_LOGIN_SECRET`)
 * → { accessToken, refreshToken, expiresAt }
 * Exists only while DEV_LOGIN_SECRET is set. Never set it on production.
 */
export const POST = handle(async (req) => {
  if (!env.devLoginSecret) return new Response("Not found", { status: 404 });
  const rl = authIpLimiter.hit(clientIp(req));
  if (!rl.ok) throw rateLimited(rl.retryAfterSeconds);

  const body = await readJson<{ email?: unknown; secret?: unknown; trial?: unknown }>(req);
  const given = req.headers.get("x-dev-login-secret") ?? (typeof body.secret === "string" ? body.secret : null);
  if (!secretMatches(given)) throw new HttpError(403, { error: "forbidden", message: "Bad dev login secret." });

  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  if (!email.includes("@")) throw new HttpError(400, { error: "bad_request", message: "email required" });

  const tokens = await getSessionProvider().issue(memoryUserForEmail(email));
  // The JWT's `sub` is authoritative (Supabase assigns ids); create the profile now so /v1/me is instant.
  const user = await verifyAccessToken(tokens.accessToken);
  const db = await getDb();
  await db.ensureProfile(user.id, user.email || email, new Date());
  // `trial: false` skips the 7-day Pro trial so a smoke test can exercise Free-tier limits.
  if (body.trial === false) await db.updateProfile(user.id, { trialEndsAt: null });
  return json(tokens);
});
