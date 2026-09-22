/**
 * Bearer JWT verification for every /v1/* route. No network call per request:
 *   - HS256 with `SUPABASE_JWT_SECRET` (classic Supabase projects, and the memory
 *     driver's dev-minted tokens), or
 *   - a cached remote JWKS (`SUPABASE_JWKS_URL`, or derived from SUPABASE_URL) for
 *     projects on asymmetric signing keys — jose fetches it once and caches.
 */

import { createRemoteJWKSet, jwtVerify, SignJWT, type JWTPayload } from "jose";
import { env } from "./env";
import { unauthenticated } from "./http";

export interface AuthUser {
  id: string;
  email: string;
}

function hsSecret(): Uint8Array {
  return new TextEncoder().encode(env.supabaseJwtSecret ?? env.devJwtSecret);
}

let jwks: ReturnType<typeof createRemoteJWKSet> | undefined;

function useJwks(): boolean {
  if (env.supabaseJwksUrl) return true;
  // A hosted project with no HS secret configured must be on asymmetric keys.
  return Boolean(env.supabaseUrl) && !env.supabaseJwtSecret;
}

async function verify(token: string): Promise<JWTPayload> {
  if (useJwks()) {
    jwks ??= createRemoteJWKSet(new URL(env.supabaseJwksUrl ?? `${env.supabaseUrl}/auth/v1/.well-known/jwks.json`));
    return (await jwtVerify(token, jwks)).payload;
  }
  return (await jwtVerify(token, hsSecret(), { algorithms: ["HS256"] })).payload;
}

export async function verifyAccessToken(token: string): Promise<AuthUser> {
  let payload: JWTPayload;
  try {
    payload = await verify(token);
  } catch {
    throw unauthenticated("Your Navi session has expired. Sign in again.");
  }
  if (!payload.sub) throw unauthenticated();
  const email = typeof payload.email === "string" ? payload.email : "";
  return { id: payload.sub, email };
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

/**
 * Mints an access token in the same shape Supabase issues (sub, email, aud, role),
 * signed with the HS256 secret. Used only by the memory driver / dev login.
 */
export async function mintAccessToken(user: AuthUser, ttlSeconds = 3600, now = new Date()): Promise<{ token: string; expiresAt: string }> {
  const iat = Math.floor(now.getTime() / 1000);
  const exp = iat + ttlSeconds;
  const token = await new SignJWT({ email: user.email, role: "authenticated" })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setSubject(user.id)
    .setAudience("authenticated")
    .setIssuer("navi-cloud-dev")
    .setIssuedAt(iat)
    .setExpirationTime(exp)
    .sign(hsSecret());
  return { token, expiresAt: new Date(exp * 1000).toISOString() };
}
