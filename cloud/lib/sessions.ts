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

  // MARK: account
  /** The signed-in devices (Supabase sessions) of a user, newest activity first. */
  listSessions(userId: string): Promise<DeviceSession[]>;
  /** Ends the session the access token belongs to (its refresh token stops working). */
  revokeSession(user: AuthUser, accessToken: string): Promise<void>;
  /** Ends every session of the user — "Sign out everywhere". */
  revokeAll(user: AuthUser, accessToken: string): Promise<void>;
  /** False once the auth user is gone (deleted account) — a still-valid JWT must not resurrect it. */
  userExists(userId: string): Promise<boolean>;
  /** Hard-deletes the auth user (and with it, every session). Idempotent. */
  deleteUser(userId: string): Promise<void>;
}

export interface DeviceSession {
  id: string;
  /** ISO-8601 */
  createdAt: string;
  /** ISO-8601: the last token refresh, i.e. roughly when the device was last active. */
  lastActiveAt: string;
}

/** Turns a Supabase session into the §3.1 shape. */
export function tokensFromSupabaseSession(s: { access_token: string; refresh_token: string; expires_at?: number; expires_in?: number }): SessionTokens {
  const expiresAtSec = s.expires_at ?? Math.floor(Date.now() / 1000) + (s.expires_in ?? 3600);
  return { accessToken: s.access_token, refreshToken: s.refresh_token, expiresAt: new Date(expiresAtSec * 1000).toISOString() };
}

// MARK: - Memory

interface MemorySessionRow { userId: string; createdAt: string; lastActiveAt: string }
interface MemorySessions {
  refresh: Map<string, { user: AuthUser; sessionId: string }>;
  usersByEmail: Map<string, string>;
  sessions: Map<string, MemorySessionRow>;
}

function memoryStore(): MemorySessions {
  const g = globalThis as unknown as { __naviMemorySessions2?: MemorySessions };
  g.__naviMemorySessions2 ??= { refresh: new Map(), usersByEmail: new Map(), sessions: new Map() };
  return g.__naviMemorySessions2;
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
  async function mint(user: AuthUser, sessionId: string): Promise<SessionTokens> {
    const { token, expiresAt } = await mintAccessToken({ ...user, sessionId });
    const refreshToken = randomBytes(32).toString("base64url");
    store.refresh.set(refreshToken, { user: { id: user.id, email: user.email }, sessionId });
    return { accessToken: token, refreshToken, expiresAt };
  }
  function dropSessions(match: (sessionId: string, row: MemorySessionRow) => boolean) {
    for (const [sid, row] of store.sessions) if (match(sid, row)) store.sessions.delete(sid);
    for (const [rt, v] of store.refresh) if (!store.sessions.has(v.sessionId)) store.refresh.delete(rt);
  }
  return {
    async issue(user) {
      const sessionId = randomUUID();
      const now = new Date().toISOString();
      store.sessions.set(sessionId, { userId: user.id, createdAt: now, lastActiveAt: now });
      return mint(user, sessionId);
    },
    async refresh(refreshToken) {
      const hit = store.refresh.get(refreshToken);
      if (!hit || !store.sessions.has(hit.sessionId)) throw unauthenticated("Refresh token is not valid.");
      store.refresh.delete(refreshToken); // rotate
      store.sessions.get(hit.sessionId)!.lastActiveAt = new Date().toISOString();
      return mint(hit.user, hit.sessionId);
    },
    async listSessions(userId) {
      return [...store.sessions.entries()]
        .filter(([, r]) => r.userId === userId)
        .map(([id, r]) => ({ id, createdAt: r.createdAt, lastActiveAt: r.lastActiveAt }))
        .sort((a, b) => b.lastActiveAt.localeCompare(a.lastActiveAt));
    },
    async revokeSession(user) {
      if (user.sessionId) dropSessions((sid) => sid === user.sessionId);
    },
    async revokeAll(user) {
      dropSessions((_, r) => r.userId === user.id);
    },
    async userExists(userId) {
      for (const id of store.usersByEmail.values()) if (id === userId) return true;
      return false;
    },
    async deleteUser(userId) {
      dropSessions((_, r) => r.userId === userId);
      for (const [email, id] of store.usersByEmail) if (id === userId) store.usersByEmail.delete(email);
    },
  };
}

// MARK: - Supabase

export function createSupabaseSessionProvider(): SessionProvider {
  const url = env.supabaseUrl;
  const anon = env.supabaseAnonKey;
  if (!url || !anon) throw new Error("SUPABASE_URL and SUPABASE_ANON_KEY are required");
  const anonClient = () => createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } });
  const adminClient = () => {
    const service = env.supabaseServiceKey;
    if (!service) throw new HttpError(500, { error: "misconfigured", message: "SUPABASE_SERVICE_ROLE_KEY is required" });
    return createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
  };

  return {
    async issue(user) {
      const admin = adminClient();
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

    // MARK: account
    async listSessions(userId) {
      // auth.sessions is not exposed over PostgREST; 0003_account.sql adds a service-role-only RPC.
      const { data, error } = await adminClient().rpc("account_sessions", { p_user_id: userId });
      if (error) {
        console.warn("[navi-cloud] account_sessions failed:", error.message);
        return [];
      }
      return ((data ?? []) as { id: string; created_at: string; last_active_at: string | null }[]).map((r) => ({
        id: r.id,
        createdAt: r.created_at,
        lastActiveAt: r.last_active_at ?? r.created_at,
      }));
    },
    async revokeSession(_user, accessToken) {
      const { error } = await adminClient().auth.admin.signOut(accessToken, "local");
      if (error && !isGone(error)) throw new HttpError(502, { error: "auth_error", message: "Could not sign out. Try again." });
    },
    async revokeAll(_user, accessToken) {
      const { error } = await adminClient().auth.admin.signOut(accessToken, "global");
      if (error && !isGone(error)) throw new HttpError(502, { error: "auth_error", message: "Could not sign out everywhere. Try again." });
    },
    async userExists(userId) {
      const { data, error } = await adminClient().auth.admin.getUserById(userId);
      if (error) {
        if (isGone(error)) return false;
        throw new HttpError(502, { error: "auth_error", message: "Could not reach sign-in. Try again." });
      }
      return Boolean(data.user);
    },
    async deleteUser(userId) {
      const { error } = await adminClient().auth.admin.deleteUser(userId);
      if (error && !isGone(error)) throw new HttpError(502, { error: "auth_error", message: "Could not delete the sign-in record. Try again." });
    },
  };
}

/** "Already gone" answers from GoTrue: unknown user / session, or a 404. */
function isGone(e: { status?: number; code?: string; message?: string }): boolean {
  return e.status === 404 || e.code === "user_not_found" || e.code === "session_not_found" || /not found/i.test(e.message ?? "");
}

let cached: SessionProvider | undefined;

export function getSessionProvider(): SessionProvider {
  if (cached) return cached;
  cached = env.dbDriver === "supabase" ? createSupabaseSessionProvider() : createMemorySessionProvider();
  return cached;
}
