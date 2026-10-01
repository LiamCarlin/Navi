import { isAdminEmail } from "@/lib/admin/auth";
import { getAuthBackend, SignInError } from "@/lib/auth-backend";
import { assertSameOrigin } from "@/lib/auth";
import { getDb } from "@/lib/db";
import { env } from "@/lib/env";
import { clientIp, HttpError, json, readJson } from "@/lib/http";
import { authIpLimiter, otpSendEmailLimiter } from "@/lib/ratelimit";
import { normalizeEmail } from "@/lib/signin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * POST /admin/auth/email { email } → 200 { ok: true }
 * Sends the console's sign-in link from the server, without PKCE, so it works in whichever
 * browser opens the email (the session comes back in the fragment; see
 * lib/fragment-signin.ts). Only admin addresses get a mail; everyone gets the same answer,
 * so the endpoint can't be used to find out who is an admin.
 */
export async function POST(req: Request): Promise<Response> {
  try {
    assertSameOrigin(req);
  } catch (e) {
    if (e instanceof HttpError) return json({ error: "forbidden" }, 403);
    throw e;
  }
  if (!(await authIpLimiter.hit(clientIp(req))).ok) return json({ error: "rate_limited" }, 429);

  const body = await readJson<{ email?: unknown }>(req).catch(() => ({}) as { email?: unknown });
  const email = normalizeEmail(body.email);
  if (!email) return json({ error: "invalid_email", message: "Enter a valid email address." }, 400);
  if (!(await otpSendEmailLimiter.hit(email)).ok) return json({ error: "rate_limited", message: "Too many emails. Try again in a few minutes." }, 429);

  const backend = getAuthBackend();
  if (!backend || env.dbDriver !== "supabase") return json({ error: "unconfigured" }, 503);

  const db = await getDb();
  if (await isAdminEmail(db, email)) {
    try {
      await backend.sendEmailOtp(email, `${env.baseUrl}/admin/auth/callback`, { getAll: () => [], set: () => undefined });
    } catch (e) {
      const message = e instanceof SignInError ? e.body.message : "Couldn’t send the email.";
      console.error("[navi-cloud] /admin/auth/email failed:", (e as Error).message);
      return json({ error: "failed", message }, 502);
    }
  }
  return json({ ok: true });
}
