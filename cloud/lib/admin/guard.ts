/**
 * Next.js glue for the admin guard: every /admin page, server action and route
 * handler calls `requireAdmin()`. Anyone who isn't a signed-in admin gets a plain 404 —
 * the console does not admit it exists.
 */

import { cookies } from "next/headers";
import { notFound } from "next/navigation";
import { cache } from "react";
import { getDb } from "../db";
import { ADMIN_COOKIE, adminFromSession, type AdminIdentity } from "./auth";

/** The signed-in admin for this request, or null. Memoized per request. */
export const currentAdmin = cache(async (): Promise<AdminIdentity | null> => {
  const jar = await cookies();
  const token = jar.get(ADMIN_COOKIE)?.value;
  if (!token) return null;
  return adminFromSession(await getDb(), token);
});

export async function requireAdmin(): Promise<AdminIdentity> {
  const who = await currentAdmin();
  if (!who) notFound();
  return who;
}

/** For route handlers: the admin, or a 404 Response to return. */
export async function adminOr404(): Promise<AdminIdentity | Response> {
  const who = await currentAdmin();
  return who ?? new Response("Not found", { status: 404, headers: { "content-type": "text/plain" } });
}
