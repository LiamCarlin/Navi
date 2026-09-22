/**
 * Session tokens for the app: issue (dev login) and refresh.
 *   - supabase: real Supabase Auth sessions (1 h access JWT + refresh token).
 *   - memory:   HS256 tokens minted here + refresh tokens in a process-local map.
 * `/auth/callback` gets its tokens from the browser sign-in instead (see the route).
 */

import { createClient } from "@supabase/supabase-js";
import { randomBytes, randomUUID } from "node:crypto";
import { mintAccessToken, type AuthUser } from "./auth";
import type { SessionTokens } from "./db";
import { env } from "./env";
import { HttpError, unauthenticated } from "./http";

export interface SessionProvider {
  /** A session for a user with no browser round trip (dev login only). */
  issue(user: AuthUser): Promise<SessionTokens>;
  /** New tokens for a refresh token; throws 401 when it is unknown or revoked. */
  refresh(refreshToken: string): Promise<SessionTokens>;
}

/** Turns a Supabase session into the §3.1 shape. */
export function tokensFromSupabaseSession(s: { access_token: string; refresh_token: string; expires_at?: number; expires_in?: number }): SessionTokens {
  const expiresAtSec = s.expires_at ?? Math.floor(Date.now() / 1000) + (s.expires_in ?? 3600);
  return { accessToken: s.access_token, refreshToken: s.refresh_token, expiresAt: new Date(expiresAtSec * 1000).toISOString() };
}

// MARK: - Memory

interface MemorySessions { refresh: Map<string, AuthUser>; usersByEmail: Map<string, string> }

function memoryStore(): MemorySessions {
  const g = globalThis as unknown as { __naviMemorySessions?: MemorySessions };
  g.__naviMemorySessions ??= { refresh: new Map(), usersByEmail: new Map() };
  return g.__naviMemorySessions;
}

/** Stable fake user ids per email so repeated dev logins hit the same profile. */
export function memoryUserForEmail(email: string): AuthUser {
  const store = memoryStore();
  const key = email.toLowerCase();
  let id = store.usersByEmail.get(key);
  if (!id) {
    id = randomUUID();
    store.usersByEmail.set(key, id);
  }
  return { id, email: key };
}

export function createMemorySessionProvider(): SessionProvider {
  const store = memoryStore();
  async function mint(user: AuthUser): Promise<SessionTokens> {
    const { token, expiresAt } = await mintAccessToken(user);
    const refreshToken = randomBytes(32).toString("base64url");
    store.refresh.set(refreshToken, user);
    return { accessToken: token, refreshToken, expiresAt };
  }
  return {
    issue: mint,
    async refresh(refreshToken) {
      const user = store.refresh.get(refreshToken);
      if (!user) throw unauthenticated("Refresh token is not valid.");
      store.refresh.delete(refreshToken); // rotate
      return mint(user);
    },
  };
}

// MARK: - Supabase

export function createSupabaseSessionProvider(): SessionProvider {
  const url = env.supabaseUrl;
  const anon = env.supabaseAnonKey;
  if (!url || !anon) throw new Error("SUPABASE_URL and SUPABASE_ANON_KEY are required");
  const anonClient = () => createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } });

  return {
    async issue(user) {
      const service = env.supabaseServiceKey;
      if (!service) throw new HttpError(500, { error: "misconfigured", message: "SUPABASE_SERVICE_ROLE_KEY is required for dev login" });
      const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
      // Make sure the user exists (ignore "already registered").
      const created = await admin.auth.admin.createUser({ email: user.email, email_confirm: true });
      if (created.error && !/already|exists/i.test(created.error.message)) {
        throw new HttpError(500, { error: "auth_error", message: created.error.message });
      }
      const link = await admin.auth.admin.generateLink({ type: "magiclink", email: user.email });
      if (link.error || !link.data.properties?.hashed_token) {
        throw new HttpError(500, { error: "auth_error", message: link.error?.message ?? "no token" });
      }
      const verified = await anonClient().auth.verifyOtp({ token_hash: link.data.properties.hashed_token, type: "magiclink" });
      if (verified.error || !verified.data.session) {
        throw new HttpError(500, { error: "auth_error", message: verified.error?.message ?? "no session" });
      }
      return tokensFromSupabaseSession(verified.data.session);
    },
    async refresh(refreshToken) {
      const res = await anonClient().auth.refreshSession({ refresh_token: refreshToken });
      if (res.error || !res.data.session) throw unauthenticated("Refresh token is not valid.");
      return tokensFromSupabaseSession(res.data.session);
    },
  };
}

let cached: SessionProvider | undefined;

export function getSessionProvider(): SessionProvider {
  if (cached) return cached;
  cached = env.dbDriver === "supabase" ? createSupabaseSessionProvider() : createMemorySessionProvider();
  return cached;
}
