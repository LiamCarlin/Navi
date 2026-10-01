import { getAuthBackend, SignInError } from "@/lib/auth-backend";
import { clientIp, readJson } from "@/lib/http";
import { authIpLimiter, otpSendEmailLimiter } from "@/lib/ratelimit";
import { callbackUrl, cookieJar, jsonWithCookies, normalizeEmail, parseFlow, signInErrorJson } from "@/lib/signin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * POST /auth/otp { email, redirect: "navi"|"account" } → 200 { ok: true }
 * Sends one email with a magic link and a 6-digit code. The PKCE verifier for the link
 * rides back as a cookie, so the link works straight away in this browser; the code (or a
 * `token_hash` email template) works anywhere.
 * Errors: 400 invalid_email · 429 rate_limited · 403 signups_closed · 503 unconfigured.
 */
export async function POST(req: Request): Promise<Response> {
  try {
    const ip = await authIpLimiter.hit(clientIp(req));
    if (!ip.ok) throw new SignInError("rate_limited");

    const body = await readJson<{ email?: unknown; redirect?: unknown }>(req).catch(() => ({}) as { email?: unknown; redirect?: unknown });
    const email = normalizeEmail(body.email);
    if (!email) throw new SignInError("invalid_email");
    const flow = parseFlow(typeof body.redirect === "string" ? body.redirect : null);

    const perEmail = await otpSendEmailLimiter.hit(email);
    if (!perEmail.ok) throw new SignInError("rate_limited");

    const backend = getAuthBackend();
    if (!backend) throw new SignInError("unconfigured");
    const jar = cookieJar(req);
    await backend.sendEmailOtp(email, callbackUrl(flow), jar);
    return jsonWithCookies({ ok: true }, 200, jar.setCookies);
  } catch (e) {
    if (e instanceof SignInError) return signInErrorJson(e);
    console.error("[navi-cloud] /auth/otp failed:", (e as Error).message);
    return signInErrorJson(new SignInError("failed"));
  }
}
