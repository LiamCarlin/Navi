import { getAuthBackend, SignInError } from "@/lib/auth-backend";
import { clientIp, readJson } from "@/lib/http";
import { authIpLimiter, otpVerifyEmailLimiter } from "@/lib/ratelimit";
import { clearSupabaseCookies, finishSignIn, jsonWithCookies, normalizeCode, normalizeEmail, parseFlow, signInErrorJson } from "@/lib/signin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * POST /auth/verify { email, code, redirect: "navi"|"account" } → 200 { ok: true, redirect }
 * The typed 6-digit code from the sign-in email — for mail apps that open links in another
 * browser (or on a phone). `redirect` is `navi://auth/callback?code=…` for the app flow, or
 * `/account` (with the session cookie set on this response) for the web flow.
 * Errors: 400 invalid_code · 429 rate_limited (10 tries per address per 15 min).
 */
export async function POST(req: Request): Promise<Response> {
  try {
    const ip = await authIpLimiter.hit(clientIp(req));
    if (!ip.ok) throw new SignInError("rate_limited");

    const body = await readJson<{ email?: unknown; code?: unknown; redirect?: unknown }>(req).catch(() => ({}) as Record<string, unknown>);
    const email = normalizeEmail(body.email);
    if (!email) throw new SignInError("invalid_email");
    const code = normalizeCode(body.code);
    if (!code) throw new SignInError("invalid_code");
    const flow = parseFlow(typeof body.redirect === "string" ? body.redirect : null);

    const perEmail = await otpVerifyEmailLimiter.hit(email);
    if (!perEmail.ok) throw new SignInError("rate_limited");

    const backend = getAuthBackend();
    if (!backend) throw new SignInError("unconfigured");
    const tokens = await backend.verifyEmailOtp(email, code);
    const done = await finishSignIn(flow, tokens);
    return jsonWithCookies({ ok: true, redirect: done.location }, 200, [...clearSupabaseCookies(req), ...done.setCookies]);
  } catch (e) {
    if (e instanceof SignInError) return signInErrorJson(e);
    console.error("[navi-cloud] /auth/verify failed:", (e as Error).message);
    return signInErrorJson(new SignInError("failed"));
  }
}
