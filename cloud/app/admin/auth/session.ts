import { NextResponse } from "next/server";
import { ADMIN_COOKIE, adminCookieOptions, mintAdminSession, type AdminIdentity } from "@/lib/admin/auth";
import { audit } from "@/lib/admin/ops";
import type { Db } from "@/lib/db";

/** 303 to /admin with the console's session cookie set, and an audit row for the sign-in. */
export async function startAdminSession(req: Request, db: Db, who: AdminIdentity, method: string): Promise<Response> {
  const token = await mintAdminSession(who);
  await audit(db, who.email, "admin.sign_in", who.email, { method }).catch(() => undefined);
  const res = NextResponse.redirect(new URL("/admin", req.url), 303);
  res.cookies.set(ADMIN_COOKIE, token, adminCookieOptions(new URL(req.url).protocol === "https:"));
  return res;
}

export function notFound(): Response {
  return new Response("Not found", { status: 404, headers: { "content-type": "text/plain" } });
}
