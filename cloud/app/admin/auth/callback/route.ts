import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { cookies } from "next/headers";
import { NextResponse } from "next/server";
import { isAdminEmail } from "@/lib/admin/auth";
import { getDb } from "@/lib/db";
import { env } from "@/lib/env";
import { clientIp } from "@/lib/http";
import { fragmentFinishPage, readFragmentPost } from "@/lib/fragment-signin";
import { HttpError } from "@/lib/http";
import { authIpLimiter } from "@/lib/ratelimit";
import { notFound, startAdminSession } from "../session";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * GET /admin/auth/callback — Supabase lands here after the console's magic link or
 * Google sign-in. Finishes the PKCE exchange, checks the email is an admin, drops the
 * Supabase cookie session and sets the console's own cookie. Non-admins get a 404.
 * A bare GET is the default email template's link (session in the #fragment, any
 * browser): it gets the page that POSTs the tokens back here (lib/fragment-signin.ts).
 */
export async function GET(req: Request): Promise<Response> {
  if (!(await authIpLimiter.hit(clientIp(req))).ok) return new Response("Too many attempts", { status: 429 });
  if (env.dbDriver !== "supabase" || !env.supabaseUrl || !env.supabaseAnonKey) return notFound();

  const url = new URL(req.url);
  const back = (message: string) => NextResponse.redirect(new URL(`/admin/login?error=${encodeURIComponent(message)}`, req.url), 303);
  const errorParam = url.searchParams.get("error_description") ?? url.searchParams.get("error");
  if (errorParam) return back(errorParam);

  const jar = await cookies();
  const supabase = createServerClient(env.supabaseUrl, env.supabaseAnonKey, {
    cookies: {
      getAll: () => jar.getAll(),
      setAll: (list: { name: string; value: string; options?: CookieOptions }[]) => {
        for (const c of list) {
          try { jar.set(c.name, c.value, c.options); } catch { /* read-only */ }
        }
      },
    },
  });

  const code = url.searchParams.get("code");
  const tokenHash = url.searchParams.get("token_hash");
  const type = url.searchParams.get("type");
  let user: { id: string; email?: string } | null = null;
  if (code) {
    const res = await supabase.auth.exchangeCodeForSession(code);
    if (res.error) return back(res.error.message);
    user = res.data.user;
  } else if (tokenHash && type) {
    const res = await supabase.auth.verifyOtp({ token_hash: tokenHash, type: type as "magiclink" | "email" });
    if (res.error) return back(res.error.message);
    user = res.data.user;
  } else {
    return fragmentFinishPage({
      postTo: "/admin/auth/callback",
      errorTo: `/admin/login?error=${encodeURIComponent("That link didn’t work — request a new one.")}`,
    });
  }

  // The console keeps its own cookie; the Supabase browser session is not needed.
  await supabase.auth.signOut({ scope: "local" }).catch(() => undefined);

  const email = user?.email?.toLowerCase();
  const db = await getDb();
  if (!user || !email || !(await isAdminEmail(db, email))) return notFound();
  return startAdminSession(req, db, { email, sub: user.id }, "supabase");
}

/**
 * POST /admin/auth/callback — the fragment page's form { access_token, refresh_token }.
 * Same origin only; the token is verified with Supabase, the email must be an admin, and
 * the Supabase session is then signed out (the console keeps its own cookie).
 */
export async function POST(req: Request): Promise<Response> {
  if (!(await authIpLimiter.hit(clientIp(req))).ok) return new Response("Too many attempts", { status: 429 });
  if (env.dbDriver !== "supabase" || !env.supabaseUrl || !env.supabaseAnonKey) return notFound();
  const back = (message: string) => NextResponse.redirect(new URL(`/admin/login?error=${encodeURIComponent(message)}`, req.url), 303);

  let posted;
  try {
    posted = await readFragmentPost(req);
  } catch (e) {
    if (e instanceof HttpError) return new Response("Cross-site request refused.", { status: 403 });
    throw e;
  }
  if (!posted) return back("That link didn’t work — request a new one.");

  // Verify with the auth server (getUser), never from the JWT payload alone.
  const who = await fetch(`${env.supabaseUrl.replace(/\/+$/, "")}/auth/v1/user`, {
    headers: { apikey: env.supabaseAnonKey, authorization: `Bearer ${posted.accessToken}` },
    signal: AbortSignal.timeout(5000),
  })
    .then((r) => (r.ok ? (r.json() as Promise<{ id?: string; email?: string }>) : null))
    .catch(() => null);

  // The console keeps its own cookie; end the Supabase session the link created (best effort).
  await fetch(`${env.supabaseUrl.replace(/\/+$/, "")}/auth/v1/logout?scope=local`, {
    method: "POST",
    headers: { apikey: env.supabaseAnonKey, authorization: `Bearer ${posted.accessToken}` },
    signal: AbortSignal.timeout(5000),
  }).catch(() => undefined);

  if (!who?.id) return back("That link has expired or was already used — request a new one.");
  const email = who.email?.toLowerCase();
  const db = await getDb();
  if (!email || !(await isAdminEmail(db, email))) return notFound();
  return startAdminSession(req, db, { email, sub: who.id }, "supabase");
}
