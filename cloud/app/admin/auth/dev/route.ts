import { timingSafeEqual } from "node:crypto";
import { NextResponse } from "next/server";
import { isAdminEmail } from "@/lib/admin/auth";
import { getDb } from "@/lib/db";
import { env } from "@/lib/env";
import { clientIp } from "@/lib/http";
import { authIpLimiter } from "@/lib/ratelimit";
import { notFound, startAdminSession } from "../session";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function secretMatches(given: string): boolean {
  const expected = env.devLoginSecret;
  if (!expected || !given) return false;
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

/**
 * POST /admin/auth/dev (form: email, secret) — the console's dev login. Exists only
 * while DEV_LOGIN_SECRET is set; the email must still be an admin.
 */
export async function POST(req: Request): Promise<Response> {
  if (!env.devLoginSecret) return notFound();
  if (!(await authIpLimiter.hit(clientIp(req))).ok) return new Response("Too many attempts", { status: 429 });

  const form = await req.formData().catch(() => null);
  const email = String(form?.get("email") ?? "").trim().toLowerCase();
  const secret = String(form?.get("secret") ?? "");
  const back = (message: string) => NextResponse.redirect(new URL(`/admin/login?error=${encodeURIComponent(message)}`, req.url), 303);

  if (!secretMatches(secret)) return back("Wrong dev login secret.");
  const db = await getDb();
  if (!(await isAdminEmail(db, email))) return notFound();
  return startAdminSession(req, db, { email, sub: `dev:${email}` }, "dev_login");
}
