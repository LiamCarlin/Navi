import { NextResponse } from "next/server";
import { ADMIN_COOKIE, ADMIN_COOKIE_PATH } from "@/lib/admin/auth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** POST /admin/auth/logout — clears the console cookie. */
export async function POST(req: Request): Promise<Response> {
  const res = NextResponse.redirect(new URL("/admin/login", req.url), 303);
  res.cookies.set(ADMIN_COOKIE, "", { path: ADMIN_COOKIE_PATH, maxAge: 0, httpOnly: true, sameSite: "lax" });
  return res;
}
