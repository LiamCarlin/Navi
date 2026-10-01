import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { cookies } from "next/headers";
import { NextResponse } from "next/server";
import { isAdminEmail } from "@/lib/admin/auth";
import { getDb } from "@/lib/db";
import { env } from "@/lib/env";
import { clientIp } from "@/lib/http";
import { authIpLimiter } from "@/lib/ratelimit";
import { notFound, startAdminSession } from "../session";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * GET /admin/auth/callback — Supabase lands here after the console's magic link or
 * Google sign-in. Finishes the PKCE exchange, checks the email is an admin, drops the
 * Supabase cookie session and sets the console's own cookie. Non-admins get a 404.
 */
export async function GET(req: Request): Promise<Response> {
  if (!authIpLimiter.hit(clientIp(req)).ok) return new Response("Too many attempts", { status: 429 });
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
    return back("Missing sign-in code — request a new link.");
  }

  // The console keeps its own cookie; the Supabase browser session is not needed.
  await supabase.auth.signOut({ scope: "local" }).catch(() => undefined);

  const email = user?.email?.toLowerCase();
  const db = await getDb();
  if (!user || !email || !(await isAdminEmail(db, email))) return notFound();
  return startAdminSession(req, db, { email, sub: user.id }, "supabase");
}
