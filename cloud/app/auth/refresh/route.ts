import { clientIp, handle, HttpError, json, rateLimited, readJson } from "@/lib/http";
import { authIpLimiter } from "@/lib/ratelimit";
import { getSessionProvider } from "@/lib/sessions";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** POST /auth/refresh { refreshToken } → { accessToken, refreshToken, expiresAt }. */
export const POST = handle(async (req) => {
  const rl = authIpLimiter.hit(clientIp(req));
  if (!rl.ok) throw rateLimited(rl.retryAfterSeconds);

  const body = await readJson<{ refreshToken?: unknown }>(req);
  const refreshToken = typeof body.refreshToken === "string" ? body.refreshToken.trim() : "";
  if (!refreshToken) throw new HttpError(400, { error: "bad_request", message: "Missing refreshToken." });

  return json(await getSessionProvider().refresh(refreshToken));
});
