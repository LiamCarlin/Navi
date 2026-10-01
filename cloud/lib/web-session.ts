/**
 * The /account web session: one httpOnly cookie holding the same access + refresh token pair
 * the app gets, so the browser and the app are authenticated by exactly the same machinery
 * (JWT verification in lib/auth.ts, refresh through lib/sessions.ts) on both drivers.
 *
 *   navi_session = base64url(JSON { a: accessToken, r: refreshToken })
 *   HttpOnly · SameSite=Lax · Path=/ · Secure on https · 30 days (the refresh token's horizon)
 *
 * Nothing here touches the network; route handlers set and clear the cookie on their responses.
 */

import type { SessionTokens } from "./db";

export const SESSION_COOKIE = "navi_session";
const MAX_AGE_SECONDS = 30 * 86_400;

export interface WebSession {
  accessToken: string;
  refreshToken: string;
}

export function encodeSession(tokens: Pick<SessionTokens, "accessToken" | "refreshToken">): string {
  return Buffer.from(JSON.stringify({ a: tokens.accessToken, r: tokens.refreshToken }), "utf8").toString("base64url");
}

export function decodeSession(value: string | undefined | null): WebSession | null {
  if (!value) return null;
  try {
    const o = JSON.parse(Buffer.from(value, "base64url").toString("utf8")) as { a?: unknown; r?: unknown };
    if (typeof o.a !== "string" || typeof o.r !== "string" || !o.a || !o.r) return null;
    return { accessToken: o.a, refreshToken: o.r };
  } catch {
    return null;
  }
}

/** Parses a `Cookie:` header into a map (last one wins, values URI-decoded). */
export function parseCookies(header: string | null | undefined): Map<string, string> {
  const out = new Map<string, string>();
  if (!header) return out;
  for (const part of header.split(";")) {
    const i = part.indexOf("=");
    if (i < 0) continue;
    const name = part.slice(0, i).trim();
    if (!name) continue;
    const raw = part.slice(i + 1).trim();
    try { out.set(name, decodeURIComponent(raw)); } catch { out.set(name, raw); }
  }
  return out;
}

export function readSessionCookie(cookieHeader: string | null | undefined): WebSession | null {
  return decodeSession(parseCookies(cookieHeader).get(SESSION_COOKIE));
}

export interface CookieOptions {
  maxAge?: number;
  path?: string;
  httpOnly?: boolean;
  secure?: boolean;
  sameSite?: "lax" | "strict" | "none";
}

/** Serializes one `Set-Cookie` value. */
export function serializeCookie(name: string, value: string, o: CookieOptions = {}): string {
  const parts = [`${name}=${encodeURIComponent(value)}`, `Path=${o.path ?? "/"}`];
  if (o.maxAge !== undefined) {
    parts.push(`Max-Age=${Math.max(0, Math.floor(o.maxAge))}`);
    if (o.maxAge <= 0) parts.push("Expires=Thu, 01 Jan 1970 00:00:00 GMT");
  }
  if (o.httpOnly !== false) parts.push("HttpOnly");
  if (o.secure) parts.push("Secure");
  const ss = o.sameSite ?? "lax";
  parts.push(`SameSite=${ss.charAt(0).toUpperCase()}${ss.slice(1)}`);
  return parts.join("; ");
}

export function sessionSetCookie(tokens: Pick<SessionTokens, "accessToken" | "refreshToken">, secure: boolean): string {
  return serializeCookie(SESSION_COOKIE, encodeSession(tokens), { maxAge: MAX_AGE_SECONDS, secure, httpOnly: true, sameSite: "lax" });
}

export function sessionClearCookie(secure: boolean): string {
  return serializeCookie(SESSION_COOKIE, "", { maxAge: 0, secure, httpOnly: true, sameSite: "lax" });
}

/** Seconds until a JWT's `exp` (negative when past); null when it is not a readable JWT. */
export function secondsUntilExpiry(jwt: string, now = Date.now()): number | null {
  const payload = jwt.split(".")[1];
  if (!payload) return null;
  try {
    const exp = (JSON.parse(Buffer.from(payload, "base64url").toString("utf8")) as { exp?: unknown }).exp;
    return typeof exp === "number" ? exp - Math.floor(now / 1000) : null;
  } catch {
    return null;
  }
}

/** Only same-site relative paths survive as a post-sign-in destination (no open redirects). */
export function safeNextPath(next: string | null | undefined, fallback = "/account"): string {
  if (!next || !next.startsWith("/") || next.startsWith("//") || next.startsWith("/\\")) return fallback;
  return next;
}
