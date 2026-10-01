/**
 * The two places a sign-in can end, shared by every /auth/* entry point:
 *
 *   flow "navi"     → a single-use, 5-minute code → navi://auth/callback?code=…
 *                     (the app swaps it at POST /auth/exchange; §3.1)
 *   flow "account"  → the httpOnly `navi_session` cookie → /account
 *
 * Plus the small response helpers the route handlers use so they can be called directly
 * from tests (no next/headers, cookies are read from and written to plain Request/Response).
 */

import { randomBytes } from "node:crypto";
import { verifyAccessToken } from "./auth";
import { SIGN_IN_ERRORS, SignInError, type CookieJar, type SignInErrorKind } from "./auth-backend";
import { getDb, type Db, type SessionTokens } from "./db";
import { env } from "./env";
import { json } from "./http";
import { parseCookies, serializeCookie, sessionSetCookie, type CookieOptions } from "./web-session";

export type Flow = "navi" | "account";

export const APP_CALLBACK = "navi://auth/callback";
export const AUTH_CODE_TTL_MS = 5 * 60_000;

/** `redirect=account` is the web portal; anything else (incl. missing) is the app, as in §3.1. */
export function parseFlow(v: string | null | undefined): Flow {
  return v === "account" ? "account" : "navi";
}

/** Where Supabase sends the browser back to (must be in the project's Redirect URLs allow-list). */
export function callbackUrl(flow: Flow): string {
  return `${env.baseUrl}/auth/callback?redirect=${flow}`;
}

export function startPath(flow: Flow, extra: { error?: SignInErrorKind; email?: string } = {}): string {
  const q = new URLSearchParams({ redirect: flow });
  if (extra.error) q.set("error", extra.error);
  if (extra.email) q.set("email", extra.email);
  return `/auth/start?${q.toString()}`;
}

export const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

export function normalizeEmail(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const e = v.trim().toLowerCase();
  return e.length <= 254 && EMAIL_RE.test(e) ? e : null;
}

/** 6-digit codes by default; Supabase lets a project pick up to 10. Spaces/dashes are forgiven. */
export function normalizeCode(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const c = v.replace(/[\s-]/g, "");
  return /^\d{6,10}$/.test(c) ? c : null;
}

export interface Finished {
  /** Absolute (`navi://…`) or same-origin path (`/account`). */
  location: string;
  setCookies: string[];
  userId: string;
}

/**
 * Turns fresh tokens into the end of the flow. Creates the profile on first sight (the
 * Supabase trigger normally already has), so /v1/me and /account are instant afterwards.
 */
export async function finishSignIn(flow: Flow, tokens: SessionTokens, db?: Db, now = new Date()): Promise<Finished> {
  const user = await verifyAccessToken(tokens.accessToken);
  const store = db ?? (await getDb());
  await store.ensureProfile(user.id, user.email, now);

  if (flow === "account") {
    return { location: "/account", setCookies: [sessionSetCookie(tokens, env.secureCookies)], userId: user.id };
  }
  const code = randomBytes(24).toString("base64url");
  await store.createUserAuthCode(user.id, { code, tokens, expiresAt: new Date(now.getTime() + AUTH_CODE_TTL_MS).toISOString() });
  return { location: `${APP_CALLBACK}?${new URLSearchParams({ code }).toString()}`, setCookies: [], userId: user.id };
}

// MARK: - Cookies on plain Request / Response

/** A CookieJar over the request's Cookie header that collects Set-Cookie lines. */
export function cookieJar(req: Request): CookieJar & { setCookies: string[] } {
  const current = parseCookies(req.headers.get("cookie"));
  const setCookies: string[] = [];
  return {
    setCookies,
    getAll: () => [...current.entries()].map(([name, value]) => ({ name, value })),
    set(name: string, value: string, options: CookieOptions) {
      if (value === "" || options.maxAge === 0) current.delete(name); else current.set(name, value);
      setCookies.push(serializeCookie(name, value, options));
    },
  };
}

/**
 * The browser never keeps Supabase's own session cookies: the app owns its tokens, the web
 * portal uses `navi_session`. Clears any `sb-*` cookie the request carried (except the PKCE
 * verifier of a flow that is still in progress, when `keepVerifier`).
 */
export function clearSupabaseCookies(req: Request, keepVerifier = false): string[] {
  const out: string[] = [];
  for (const name of parseCookies(req.headers.get("cookie")).keys()) {
    if (!name.startsWith("sb-")) continue;
    if (keepVerifier && name.includes("-code-verifier")) continue;
    out.push(serializeCookie(name, "", { maxAge: 0, secure: env.secureCookies }));
  }
  return out;
}

export function redirectResponse(req: Request, location: string, setCookies: string[] = [], status = 302): Response {
  const headers = new Headers({ "cache-control": "no-store", "referrer-policy": "no-referrer" });
  headers.set("location", /^[a-z][a-z0-9+.-]*:/i.test(location) ? location : new URL(location, req.url).toString());
  for (const c of dedupeCookies(setCookies)) headers.append("set-cookie", c);
  return new Response(null, { status, headers });
}

export function jsonWithCookies(body: unknown, status: number, setCookies: string[] = [], extra: Record<string, string> = {}): Response {
  const res = json(body, { status, headers: extra });
  for (const c of dedupeCookies(setCookies)) res.headers.append("set-cookie", c);
  return res;
}

/** Last write per cookie name wins (a clear followed by a set must not both be sent). */
function dedupeCookies(list: string[]): string[] {
  const byName = new Map<string, string>();
  for (const c of list) byName.set(c.slice(0, c.indexOf("=")), c);
  return [...byName.values()];
}

export function signInErrorJson(e: SignInError, setCookies: string[] = []): Response {
  const headers: Record<string, string> = {};
  if (e.kind === "rate_limited") headers["retry-after"] = "60";
  return jsonWithCookies(e.body, e.status, setCookies, headers);
}

export { SIGN_IN_ERRORS };
