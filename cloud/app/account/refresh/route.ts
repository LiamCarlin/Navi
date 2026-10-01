import { env } from "@/lib/env";
import { clientIp } from "@/lib/http";
import { authIpLimiter } from "@/lib/ratelimit";
import { getSessionProvider } from "@/lib/sessions";
import { jsonWithCookies, redirectResponse, startPath } from "@/lib/signin";
import { readSessionCookie, safeNextPath, sessionClearCookie, sessionSetCookie } from "@/lib/web-session";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

async function refresh(req: Request): Promise<{ ok: true; setCookie: string } | { ok: false; setCookie: string }> {
  const session = readSessionCookie(req.headers.get("cookie"));
  if (session) {
    try {
      const tokens = await getSessionProvider().refresh(session.refreshToken);
      return { ok: true, setCookie: sessionSetCookie(tokens, env.secureCookies) };
    } catch {
      /* fall through: revoked, expired, or the account is gone */
    }
  }
  return { ok: false, setCookie: sessionClearCookie(env.secureCookies) };
}

/** GET /account/refresh?next=/account — the page's server render bounces here when the access token is stale. */
export async function GET(req: Request): Promise<Response> {
  const rl = await authIpLimiter.hit(clientIp(req));
  if (!rl.ok) return redirectResponse(req, startPath("account", { error: "rate_limited" }));
  const r = await refresh(req);
  if (!r.ok) return redirectResponse(req, startPath("account", { error: "session_expired" }), [r.setCookie]);
  return redirectResponse(req, safeNextPath(new URL(req.url).searchParams.get("next")), [r.setCookie]);
}

/** POST /account/refresh → 200 { ok } with a fresh cookie, or 401 — the page's fetch helper retries once with it. */
export async function POST(req: Request): Promise<Response> {
  const origin = req.headers.get("origin");
  if (origin && origin !== new URL(req.url).origin && origin !== new URL(env.baseUrl).origin) {
    return jsonWithCookies({ error: "forbidden" }, 403);
  }
  const rl = await authIpLimiter.hit(clientIp(req));
  if (!rl.ok) return jsonWithCookies({ error: "rate_limited" }, 429, [], { "retry-after": "60" });
  const r = await refresh(req);
  return r.ok ? jsonWithCookies({ ok: true }, 200, [r.setCookie]) : jsonWithCookies({ error: "session_expired" }, 401, [r.setCookie]);
}
