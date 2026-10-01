/**
 * Every sign-in call /auth/* makes, behind one interface:
 *
 *   sendEmailOtp     one email carrying both a magic link and a 6-digit code
 *   verifyEmailOtp   the typed code → session (works in any browser, on any device)
 *   verifyTokenHash  the magic link, when the email template links with `token_hash`
 *                    (works in any browser — see DEPLOY.md "Email template")
 *   exchangeCode     the magic link / OAuth return in PKCE form (`?code=`); needs the verifier
 *                    cookie set when the flow started, so it only works in the same browser
 *   oauthUrl         "Continue with Google / Apple" → the provider's consent page
 *
 * Drivers: `supabase` (Supabase Auth, server-side — the browser never talks to Supabase, so
 * the CSP stays `connect-src 'self'`), and `memory` for local dev and tests: codes are kept in
 * process and printed to the server log. The memory backend refuses to run in production.
 */

import { createServerClient } from "@supabase/ssr";
import { createClient } from "@supabase/supabase-js";
import { createHash, randomBytes, randomInt } from "node:crypto";
import type { SessionTokens } from "./db";
import { env } from "./env";
import { createMemorySessionProvider, memoryUserForEmail, tokensFromSupabaseSession } from "./sessions";
import type { CookieOptions } from "./web-session";

// MARK: - Errors (the copy users see — never names a vendor)

export type SignInErrorKind =
  | "expired"
  | "other_browser"
  | "invalid_code"
  | "invalid_email"
  | "rate_limited"
  | "cancelled"
  | "provider"
  | "signups_closed"
  | "unconfigured"
  | "session_expired"
  | "failed";

export const SIGN_IN_ERRORS: Record<SignInErrorKind, { status: number; title: string; message: string }> = {
  expired: {
    status: 400,
    title: "That link has expired",
    message: "Sign-in links work once and expire after an hour. Send a new one, or type the 6-digit code from the latest email.",
  },
  other_browser: {
    status: 400,
    title: "Opened in a different browser",
    message: "This link was opened in a different browser than the one you started in. Type the 6-digit code from the email here instead.",
  },
  invalid_code: {
    status: 400,
    title: "That code didn’t work",
    message: "The code is wrong or has expired. Check the most recent email from Navi, or send a new code.",
  },
  invalid_email: { status: 400, title: "Check your email address", message: "Enter a valid email address." },
  rate_limited: {
    status: 429,
    title: "Too many attempts",
    message: "Wait a minute, then try again. If you asked for several emails, use the newest one.",
  },
  cancelled: { status: 400, title: "Sign-in cancelled", message: "Nothing was changed. Pick a way to sign in when you’re ready." },
  provider: {
    status: 502,
    title: "That didn’t go through",
    message: "We couldn’t finish signing you in with that account. Try again, or use your email instead.",
  },
  signups_closed: { status: 403, title: "Sign-ups are closed", message: "Navi isn’t open to new accounts yet. Join the waitlist and we’ll email you." },
  unconfigured: { status: 503, title: "Sign-in is unavailable", message: "Sign-in isn’t set up on this server yet." },
  session_expired: { status: 401, title: "You were signed out", message: "Your session ended. Sign in again to continue." },
  failed: { status: 500, title: "Something went wrong", message: "We couldn’t sign you in. Try again in a moment." },
};

export class SignInError extends Error {
  constructor(public readonly kind: SignInErrorKind, detail?: string) {
    super(detail ?? kind);
  }
  get status() { return SIGN_IN_ERRORS[this.kind].status; }
  get body() { return { error: this.kind, message: SIGN_IN_ERRORS[this.kind].message }; }
}

export function isSignInErrorKind(v: unknown): v is SignInErrorKind {
  return typeof v === "string" && v in SIGN_IN_ERRORS;
}

/** Maps a Supabase Auth error (or a callback's `error_code`) to what we tell the user. */
export function classifyAuthError(e: { name?: string; status?: number; code?: string; message?: string } | null | undefined, context: "code" | "link" | "send" | "oauth" = "link"): SignInErrorKind {
  if (!e) return "failed";
  const code = e.code ?? "";
  const msg = e.message ?? "";
  if (e.status === 429 || code.startsWith("over_") || /rate limit|too many/i.test(msg)) return "rate_limited";
  if (e.name === "AuthPKCECodeVerifierMissingError" || code === "bad_code_verifier" || /code verifier/i.test(msg)) return "other_browser";
  if (code === "signup_disabled" || /signups? not allowed/i.test(msg)) return "signups_closed";
  if (context === "send" && (code === "email_address_invalid" || code === "validation_failed" || /invalid.*email|email.*invalid/i.test(msg))) return "invalid_email";
  if (code === "access_denied" && context === "oauth") return "cancelled";
  if (code === "otp_expired" || code === "flow_state_expired" || code === "flow_state_not_found" || /expired|invalid/i.test(msg)) {
    return context === "code" ? "invalid_code" : "expired";
  }
  if (context === "oauth") return "provider";
  return "failed";
}

// MARK: - Interface

export type OAuthProvider = "google" | "apple";
export const OAUTH_PROVIDERS: readonly OAuthProvider[] = ["google", "apple"];

/** Request cookies in, response cookies out (the PKCE verifier lives in one). */
export interface CookieJar {
  getAll(): { name: string; value: string }[];
  set(name: string, value: string, options: CookieOptions): void;
}

export interface AuthBackend {
  readonly kind: "supabase" | "memory";
  sendEmailOtp(email: string, emailRedirectTo: string, jar: CookieJar): Promise<void>;
  verifyEmailOtp(email: string, code: string): Promise<SessionTokens>;
  verifyTokenHash(tokenHash: string, type: string): Promise<SessionTokens>;
  exchangeCode(code: string, jar: CookieJar): Promise<SessionTokens>;
  oauthUrl(provider: OAuthProvider, redirectTo: string, jar: CookieJar): Promise<string>;
  /** The "Continue with …" buttons to show. */
  providers(): Promise<OAuthProvider[]>;
}

// MARK: - Supabase

const OTP_TYPES = new Set(["email", "magiclink", "signup", "invite", "recovery", "email_change"]);

export function createSupabaseAuthBackend(): AuthBackend {
  const url = env.supabaseUrl;
  const anon = env.supabaseAnonKey;
  if (!url || !anon) throw new SignInError("unconfigured");

  const plain = () => createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false, flowType: "implicit" } });

  /** A PKCE client whose cookie writes go to `jar`. `onlyDeletes` keeps the session itself out of cookies. */
  const pkce = (jar: CookieJar, onlyDeletes = false) =>
    createServerClient(url, anon, {
      cookies: {
        getAll: () => jar.getAll(),
        setAll: (list: { name: string; value: string; options?: { path?: string; maxAge?: number } }[]) => {
          for (const c of list) {
            const deleting = c.value === "" || c.options?.maxAge === 0;
            if (onlyDeletes && !deleting) continue;
            jar.set(c.name, c.value, {
              path: c.options?.path ?? "/",
              maxAge: deleting ? 0 : Math.min(Number(c.options?.maxAge ?? 3600), 3600),
              sameSite: "lax",
              httpOnly: true,
              secure: env.secureCookies,
            });
          }
        },
      },
    });

  let providerCache: { at: number; list: OAuthProvider[] } | undefined;

  return {
    kind: "supabase",

    async sendEmailOtp(email, emailRedirectTo, jar) {
      const { error } = await pkce(jar).auth.signInWithOtp({ email, options: { emailRedirectTo, shouldCreateUser: true } });
      if (error) throw new SignInError(classifyAuthError(error, "send"), error.message);
    },

    async verifyEmailOtp(email, code) {
      const { data, error } = await plain().auth.verifyOtp({ email, token: code, type: "email" });
      if (error || !data.session) throw new SignInError(classifyAuthError(error, "code"), error?.message);
      return tokensFromSupabaseSession(data.session);
    },

    async verifyTokenHash(tokenHash, type) {
      const t = OTP_TYPES.has(type) ? type : "email";
      const { data, error } = await plain().auth.verifyOtp({ token_hash: tokenHash, type: t as "email" });
      if (error || !data.session) throw new SignInError(classifyAuthError(error, "link"), error?.message);
      return tokensFromSupabaseSession(data.session);
    },

    async exchangeCode(code, jar) {
      const { data, error } = await pkce(jar, true).auth.exchangeCodeForSession(code);
      if (error || !data.session) throw new SignInError(classifyAuthError(error, "link"), error?.message);
      return tokensFromSupabaseSession(data.session);
    },

    async oauthUrl(provider, redirectTo, jar) {
      const { data, error } = await pkce(jar).auth.signInWithOAuth({ provider, options: { redirectTo, skipBrowserRedirect: true } });
      if (error || !data.url) throw new SignInError(classifyAuthError(error, "oauth"), error?.message);
      return data.url;
    },

    async providers() {
      const forced = env.authProviders;
      if (forced) return OAUTH_PROVIDERS.filter((p) => forced.includes(p));
      if (providerCache && Date.now() - providerCache.at < 5 * 60_000) return providerCache.list;
      let list: OAuthProvider[];
      try {
        // Public endpoint: which external providers are switched on in the dashboard.
        const res = await fetch(`${url.replace(/\/+$/, "")}/auth/v1/settings`, { headers: { apikey: anon }, signal: AbortSignal.timeout(2000) });
        const external = ((await res.json()) as { external?: Record<string, boolean> }).external ?? {};
        list = OAUTH_PROVIDERS.filter((p) => external[p] === true);
      } catch {
        list = env.googleConfigured ? ["google"] : [];
      }
      providerCache = { at: Date.now(), list };
      return list;
    },
  };
}

// MARK: - Memory (dev + tests)

interface MemoryOtp {
  email: string;
  code: string;
  tokenHash: string;
  expiresAt: number;
  used: boolean;
}

interface MemoryAuthState { otps: MemoryOtp[]; lastLink: Map<string, string> }

function memoryAuthState(): MemoryAuthState {
  const g = globalThis as unknown as { __naviMemoryAuth?: MemoryAuthState };
  g.__naviMemoryAuth ??= { otps: [], lastLink: new Map() };
  return g.__naviMemoryAuth;
}

/** Test/dev hook: the latest code + magic link sent to an address on the memory backend. */
export function memoryOutbox(email: string): { code: string; link: string } | null {
  const s = memoryAuthState();
  const key = email.toLowerCase();
  const otp = [...s.otps].reverse().find((o) => o.email === key);
  const link = s.lastLink.get(key);
  return otp && link ? { code: otp.code, link } : null;
}

export const MEMORY_OTP_TTL_MS = 60 * 60_000;

export function createMemoryAuthBackend(clock: () => number = Date.now): AuthBackend {
  if (env.isProduction) throw new SignInError("unconfigured", "memory auth backend refused in production");
  const state = memoryAuthState();
  const sessions = createMemorySessionProvider();

  async function sessionFor(email: string): Promise<SessionTokens> {
    return sessions.issue(memoryUserForEmail(email));
  }

  function take(match: (o: MemoryOtp) => boolean, kindIfMissing: SignInErrorKind): MemoryOtp {
    const otp = state.otps.find(match);
    if (!otp) throw new SignInError(kindIfMissing);
    if (otp.used || otp.expiresAt <= clock()) throw new SignInError(kindIfMissing === "invalid_code" ? "invalid_code" : "expired");
    otp.used = true;
    // Like Supabase: using a code spends the link from the same email, and vice versa.
    return otp;
  }

  return {
    kind: "memory",

    async sendEmailOtp(email, emailRedirectTo) {
      const key = email.toLowerCase();
      const code = String(randomInt(0, 1_000_000)).padStart(6, "0");
      const tokenHash = createHash("sha256").update(randomBytes(32)).digest("hex");
      // A new email supersedes the old ones, as in Supabase.
      for (const o of state.otps) if (o.email === key) o.used = true;
      state.otps.push({ email: key, code, tokenHash, expiresAt: clock() + MEMORY_OTP_TTL_MS, used: false });
      if (state.otps.length > 500) state.otps.splice(0, state.otps.length - 500);
      const sep = emailRedirectTo.includes("?") ? "&" : "?";
      const link = `${emailRedirectTo}${sep}token_hash=${tokenHash}&type=email`;
      state.lastLink.set(key, link);
      // Dev only (refused in production above): there is no mail server, so print it.
      console.info(`[navi-cloud] dev sign-in for ${key}: code ${code} · link ${link}`);
    },

    async verifyEmailOtp(email, code) {
      const key = email.toLowerCase();
      take((o) => o.email === key && o.code === code && !o.used, "invalid_code");
      return sessionFor(key);
    },

    async verifyTokenHash(tokenHash) {
      const otp = take((o) => o.tokenHash === tokenHash, "expired");
      return sessionFor(otp.email);
    },

    async exchangeCode() {
      // No PKCE in memory mode; only the token_hash link form exists here.
      throw new SignInError("expired");
    },

    async oauthUrl() {
      throw new SignInError("unconfigured");
    },

    async providers() {
      return [];
    },
  };
}

// MARK: - Factory

let override: AuthBackend | undefined;
let cached: AuthBackend | undefined;

/** Test hook: inject a fake backend (pass undefined to go back to the env-chosen one). */
export function setAuthBackendForTests(b: AuthBackend | undefined): void {
  override = b;
  cached = undefined;
}

/** The env-chosen backend, or null when neither Supabase nor dev mode is available. */
export function getAuthBackend(): AuthBackend | null {
  if (override) return override;
  if (cached) return cached;
  if (env.dbDriver === "supabase" && env.supabaseUrl && env.supabaseAnonKey) {
    cached = createSupabaseAuthBackend();
  } else if (env.dbDriver === "memory" && !env.isProduction) {
    cached = createMemoryAuthBackend();
  } else {
    return null;
  }
  return cached;
}
