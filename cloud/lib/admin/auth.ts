/**
 * Who may open /admin, and the console's own session cookie.
 *
 * Identity comes from Supabase sign-in (magic link / Google) or, in development, the
 * `DEV_LOGIN_SECRET` dev login. Either way the console then sets `navi_admin`: an HS256
 * JWT (audience `navi-admin`, 12 h) signed with a key derived from a server secret, so an
 * app access token can never pass as one. Admin status is re-checked on every request
 * (env `ADMIN_EMAILS` or a row in `admins`), so removing an admin takes effect at once.
 * Pure over env + Db; the Next.js glue is lib/admin/guard.ts.
 */

import { createHmac } from "node:crypto";
import { jwtVerify, SignJWT } from "jose";
import type { Db } from "../db";
import { env } from "../env";

export const ADMIN_COOKIE = "navi_admin";
export const ADMIN_COOKIE_PATH = "/admin";
export const ADMIN_SESSION_TTL_S = 12 * 3600;
const AUDIENCE = "navi-admin";
const ISSUER = "navi-cloud-admin";

export interface AdminIdentity {
  email: string;
  /** Supabase user id, or "dev:<email>" for the dev login. */
  sub: string;
}

function baseSecret(): string {
  const s =
    env.adminSessionSecret ??
    env.keysSecret ??
    env.supabaseJwtSecret ??
    env.supabaseServiceKey ??
    (env.dbDriver === "memory" ? env.devJwtSecret : undefined);
  if (!s) throw new Error("No secret to sign admin sessions with (set ADMIN_SESSION_SECRET).");
  return s;
}

/** A dedicated key: HMAC(server secret, label) — never the raw Supabase JWT secret. */
function sessionKey(): Uint8Array {
  return new Uint8Array(createHmac("sha256", baseSecret()).update("navi-admin-session/v1").digest());
}

export async function mintAdminSession(who: AdminIdentity, now = new Date(), ttlSeconds = ADMIN_SESSION_TTL_S): Promise<string> {
  const iat = Math.floor(now.getTime() / 1000);
  return new SignJWT({ email: who.email.toLowerCase() })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setSubject(who.sub)
    .setAudience(AUDIENCE)
    .setIssuer(ISSUER)
    .setIssuedAt(iat)
    .setExpirationTime(iat + ttlSeconds)
    .sign(sessionKey());
}

export async function verifyAdminSession(token: string | undefined | null, now = new Date()): Promise<AdminIdentity | null> {
  if (!token) return null;
  try {
    const { payload } = await jwtVerify(token, sessionKey(), {
      algorithms: ["HS256"],
      audience: AUDIENCE,
      issuer: ISSUER,
      currentDate: now,
    });
    const email = typeof payload.email === "string" ? payload.email : "";
    if (!payload.sub || !email.includes("@")) return null;
    return { email, sub: payload.sub };
  } catch {
    return null;
  }
}

/** Admin = listed in `ADMIN_EMAILS` or in the `admins` table. Fails closed. */
export async function isAdminEmail(db: Db | null, email: string | null | undefined, envList: string[] = env.adminEmails): Promise<boolean> {
  const e = email?.trim().toLowerCase();
  if (!e || !e.includes("@")) return false;
  if (envList.includes(e)) return true;
  if (!db) return false;
  try {
    return await db.adminIsListedAdmin(e);
  } catch {
    return false;
  }
}

/** Cookie value → the admin behind it, or null (bad/expired cookie, or no longer an admin). */
export async function adminFromSession(db: Db | null, token: string | undefined | null, now = new Date()): Promise<AdminIdentity | null> {
  const who = await verifyAdminSession(token, now);
  if (!who) return null;
  return (await isAdminEmail(db, who.email)) ? who : null;
}

export function adminCookieOptions(secure: boolean) {
  return {
    httpOnly: true,
    secure,
    sameSite: "lax" as const,
    path: ADMIN_COOKIE_PATH,
    maxAge: ADMIN_SESSION_TTL_S,
  };
}
