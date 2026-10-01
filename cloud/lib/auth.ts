/**
 * Bearer JWT verification for every /v1/* route. No network call per request:
 *   - HS256 tokens are checked with `SUPABASE_JWT_SECRET` (legacy Supabase projects; the
 *     memory driver's dev-minted tokens use `DEV_JWT_SECRET`), and
 *   - asymmetric tokens (ES256 / RS256 / EdDSA — what new Supabase projects issue) against a
 *     cached remote JWKS: `SUPABASE_JWKS_URL`, else `${SUPABASE_URL}/auth/v1/.well-known/jwks.json`.
 *     jose fetches it once, caches it, and refetches when it sees an unknown `kid` (key rotation).
 * The token's own `alg` header picks the path, so a project mid-migration (old HS256 sessions
 * still alive, new ones on ES256) keeps working with both configured.
 *
 * `requireAccountUser` additionally accepts the /account web cookie session (lib/web-session.ts),
 * with a same-origin check on anything that changes state.
 */

import { createRemoteJWKSet, decodeProtectedHeader, jwtVerify, SignJWT, type JWTPayload } from "jose";
import { env } from "./env";
import { HttpError, unauthenticated } from "./http";
import { readSessionCookie, type WebSession } from "./web-session";

export interface AuthUser {
  id: string;
  email: string;
  /** Supabase's `session_id` claim (one per signed-in device); absent on very old tokens. */
  sessionId?: string;
}

const AUDIENCE = "authenticated";

function hsSecret(): Uint8Array | null {
  if (env.supabaseJwtSecret) return new TextEncoder().encode(env.supabaseJwtSecret);
  // The dev secret only ever signs tokens the memory driver minted itself.
  if (env.dbDriver === "memory") return new TextEncoder().encode(env.devJwtSecret);
  return null;
}

function jwksUrl(): string | null {
  if (env.supabaseJwksUrl) return env.supabaseJwksUrl;
  if (env.supabaseUrl) return `${env.supabaseUrl.replace(/\/+$/, "")}/auth/v1/.well-known/jwks.json`;
  return null;
}

let jwks: { url: string; set: ReturnType<typeof createRemoteJWKSet> } | undefined;

/** Test hook: forget the cached key set (e.g. after changing SUPABASE_JWKS_URL). */
export function resetJwksCache(): void {
  jwks = undefined;
}

function remoteKeys(url: string) {
  if (!jwks || jwks.url !== url) {
    jwks = { url, set: createRemoteJWKSet(new URL(url), { cooldownDuration: 30_000, cacheMaxAge: 10 * 60_000 }) };
  }
  return jwks.set;
}

async function verify(token: string): Promise<JWTPayload> {
  const { alg } = decodeProtectedHeader(token);
  if (alg === "HS256") {
    const secret = hsSecret();
    if (!secret) throw new Error("HS256 token but no SUPABASE_JWT_SECRET configured");
    return (await jwtVerify(token, secret, { algorithms: ["HS256"], audience: AUDIENCE })).payload;
  }
  const url = jwksUrl();
  if (!url) throw new Error(`${alg} token but no JWKS configured`);
  return (await jwtVerify(token, remoteKeys(url), { algorithms: ["ES256", "RS256", "EdDSA"], audience: AUDIENCE })).payload;
}

export async function verifyAccessToken(token: string): Promise<AuthUser> {
  let payload: JWTPayload;
  try {
    payload = await verify(token);
  } catch {
    throw unauthenticated("Your Navi session has expired. Sign in again.");
  }
  // The project's anon / service-role keys are JWTs too: they have no `sub` and a different role.
  if (!payload.sub) throw unauthenticated();
  if (payload.role !== undefined && payload.role !== "authenticated") throw unauthenticated();
  const email = typeof payload.email === "string" ? payload.email : "";
  const sessionId = typeof payload.session_id === "string" ? payload.session_id : undefined;
  return { id: payload.sub, email, sessionId };
}

export function bearerToken(req: Request): string | null {
  const h = req.headers.get("authorization") ?? "";
  const m = /^Bearer\s+(.+)$/i.exec(h.trim());
  return m ? m[1].trim() : null;
}

export async function requireUser(req: Request): Promise<AuthUser> {
  const token = bearerToken(req);
  if (!token) throw unauthenticated();
  return verifyAccessToken(token);
}

// MARK: account — Bearer or the /account cookie session

export interface AccountCaller {
  user: AuthUser;
  /** The verified access token (needed to revoke the session at Supabase). */
  accessToken: string;
  via: "bearer" | "cookie";
  /** Present when `via === "cookie"`. */
  session?: WebSession;
}

const SAFE_METHODS = new Set(["GET", "HEAD", "OPTIONS"]);

/** Origins a browser may legitimately send for /account requests. */
function allowedOrigins(req: Request): Set<string> {
  const out = new Set<string>([new URL(req.url).origin]);
  try { out.add(new URL(env.baseUrl).origin); } catch { /* ignore */ }
  return out;
}

/**
 * Cookie-authenticated state changes must come from our own pages: the cookie is SameSite=Lax
 * (no cross-site POST/DELETE carries it) and we additionally require a same-origin `Origin`.
 */
export function assertSameOrigin(req: Request): void {
  if (SAFE_METHODS.has(req.method.toUpperCase())) return;
  const origin = req.headers.get("origin");
  if (!origin || !allowedOrigins(req).has(origin)) {
    throw new HttpError(403, { error: "forbidden", message: "Cross-site request refused." });
  }
}

/**
 * Bearer token (the app) or the web cookie (`/account`). Throws 401 when neither verifies;
 * a cookie whose access token has expired gets `error: "session_expired"` so the page can
 * refresh it (`POST /account/refresh`) and retry once.
 */
export async function requireAccountUser(req: Request): Promise<AccountCaller> {
  const token = bearerToken(req);
  if (token) return { user: await verifyAccessToken(token), accessToken: token, via: "bearer" };

  const session = readSessionCookie(req.headers.get("cookie"));
  if (!session) throw unauthenticated();
  assertSameOrigin(req);
  try {
    return { user: await verifyAccessToken(session.accessToken), accessToken: session.accessToken, via: "cookie", session };
  } catch {
    throw new HttpError(401, { error: "session_expired", message: "Your session expired. Refresh the page." }, { "www-authenticate": "Bearer" });
  }
}

/**
 * Mints an access token in the same shape Supabase issues (sub, email, aud, role, session_id),
 * signed with the HS256 dev secret. Used only by the memory driver / dev login.
 */
export async function mintAccessToken(
  user: AuthUser,
  ttlSeconds = 3600,
  now = new Date(),
): Promise<{ token: string; expiresAt: string }> {
  const secret = hsSecret();
  if (!secret) throw new Error("mintAccessToken: no HS256 secret (memory driver only)");
  const iat = Math.floor(now.getTime() / 1000);
  const exp = iat + ttlSeconds;
  const claims: Record<string, unknown> = { email: user.email, role: "authenticated" };
  if (user.sessionId) claims.session_id = user.sessionId;
  const token = await new SignJWT(claims)
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setSubject(user.id)
    .setAudience(AUDIENCE)
    .setIssuer("navi-cloud-dev")
    .setIssuedAt(iat)
    .setExpirationTime(exp)
    .sign(secret);
  return { token, expiresAt: new Date(exp * 1000).toISOString() };
}
