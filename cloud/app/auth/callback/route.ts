import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { cookies } from "next/headers";
import { randomBytes } from "node:crypto";
import { getDb } from "@/lib/db";
import { env } from "@/lib/env";
import { clientIp, rateLimited } from "@/lib/http";
import { authIpLimiter } from "@/lib/ratelimit";
import { tokensFromSupabaseSession } from "@/lib/sessions";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const AUTH_CODE_TTL_MS = 5 * 60_000;
const APP_CALLBACK = "navi://auth/callback";

function toApp(params: Record<string, string>): Response {
  const q = new URLSearchParams(params).toString();
  return Response.redirect(`${APP_CALLBACK}?${q}`, 302);
}

function page(title: string, body: string, status = 200): Response {
  return new Response(
    `<!doctype html><meta charset="utf-8"><title>${title}</title><body style="margin:0;background:#0b0b0d;color:#f2f2f4;font-family:-apple-system,system-ui,sans-serif"><main style="max-width:480px;margin:18vh auto;padding:0 24px"><h1 style="font-size:24px;font-weight:600">${title}</h1><p style="color:#9a9aa3">${body}</p></main>`,
    { status, headers: { "content-type": "text/html; charset=utf-8" } },
  );
}

/**
 * GET /auth/callback — Supabase lands here after a magic link or Google sign-in
 * (`?code=` PKCE, or `?token_hash=&type=` for OTP-style email templates).
 * We finish the exchange server-side, mint a single-use 5-minute code, and
 * bounce to `navi://auth/callback?code=…`. The app swaps it at /auth/exchange.
 */
export async function GET(req: Request): Promise<Response> {
  const rl = authIpLimiter.hit(clientIp(req));
  if (!rl.ok) {
    const e = rateLimited(rl.retryAfterSeconds);
    return Response.json(e.body, { status: e.status, headers: e.headers });
  }

  const url = new URL(req.url);
  const errorParam = url.searchParams.get("error_description") ?? url.searchParams.get("error");
  if (errorParam) return toApp({ error: "sign_in_failed", message: errorParam });

  if (env.dbDriver !== "supabase" || !env.supabaseUrl || !env.supabaseAnonKey) {
    return page("Sign-in is not configured", "This Navi Cloud instance has no Supabase project. Use <code>POST /auth/dev-login</code> in development.", 501);
  }

  const cookieStore = await cookies();
  const supabase = createServerClient(env.supabaseUrl, env.supabaseAnonKey, {
    cookies: {
      getAll: () => cookieStore.getAll(),
      setAll: (list: { name: string; value: string; options?: CookieOptions }[]) => {
        for (const c of list) {
          try { cookieStore.set(c.name, c.value, c.options); } catch { /* headers already sent */ }
        }
      },
    },
  });

  const code = url.searchParams.get("code");
  const tokenHash = url.searchParams.get("token_hash");
  const type = url.searchParams.get("type");

  let session;
  if (code) {
    const res = await supabase.auth.exchangeCodeForSession(code);
    if (res.error) return toApp({ error: "sign_in_failed", message: res.error.message });
    session = res.data.session;
  } else if (tokenHash && type) {
    const res = await supabase.auth.verifyOtp({ token_hash: tokenHash, type: type as "magiclink" | "email" | "signup" | "recovery" });
    if (res.error) return toApp({ error: "sign_in_failed", message: res.error.message });
    session = res.data.session;
  } else {
    return page("Missing sign-in code", "Open the link from your email again, or go back to Navi and retry.", 400);
  }
  if (!session) return toApp({ error: "sign_in_failed", message: "No session returned" });

  const tokens = tokensFromSupabaseSession(session);
  const oneTime = randomBytes(24).toString("base64url");
  const db = await getDb();
  await db.createAuthCode({ code: oneTime, tokens, expiresAt: new Date(Date.now() + AUTH_CODE_TTL_MS).toISOString() });

  // Sign the browser out of the cookie session: the app owns the tokens from here.
  await supabase.auth.signOut({ scope: "local" }).catch(() => undefined);

  return toApp({ code: oneTime });
}
