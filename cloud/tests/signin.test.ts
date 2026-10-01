import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { GET as callback, POST as callbackPost } from "@/app/auth/callback/route";
import { GET as oauthStart } from "@/app/auth/oauth/route";
import { POST as devLogin } from "@/app/auth/dev-login/route";
import { POST as exchange } from "@/app/auth/exchange/route";
import { POST as sendOtp } from "@/app/auth/otp/route";
import { POST as verify } from "@/app/auth/verify/route";
import { verifyAccessToken } from "@/lib/auth";
import {
  classifyAuthError,
  createMemoryAuthBackend,
  MEMORY_OTP_TTL_MS,
  memoryOutbox,
  setAuthBackendForTests,
  SignInError,
  type AuthBackend,
} from "@/lib/auth-backend";
import { getDb, type SessionTokens } from "@/lib/db";
import { authIpLimiter, otpSendEmailLimiter, otpVerifyEmailLimiter } from "@/lib/ratelimit";
import { getSessionProvider, memoryUserForEmail } from "@/lib/sessions";
import { finishSignIn } from "@/lib/signin";
import { decodeSession, SESSION_COOKIE } from "@/lib/web-session";
import { req, setCookies, useMemoryEnv } from "./helpers";

let n = 0;
const freshEmail = () => `user${++n}.${Date.now()}@example.com`;

beforeEach(() => {
  useMemoryEnv({ DEV_LOGIN_SECRET: "dev" });
  setAuthBackendForTests(undefined);
  authIpLimiter.reset();
  otpSendEmailLimiter.reset();
  otpVerifyEmailLimiter.reset();
  vi.spyOn(console, "info").mockImplementation(() => undefined);
});
afterEach(() => vi.restoreAllMocks());

async function body(res: Response) {
  return (await res.json()) as Record<string, unknown>;
}

async function sendCode(email: string, redirect: "navi" | "account") {
  const res = await sendOtp(req("/auth/otp", { json: { email, redirect } }));
  expect(res.status).toBe(200);
  const sent = memoryOutbox(email);
  expect(sent).not.toBeNull();
  return sent!;
}

function appCode(location: string): string {
  const u = new URL(location);
  expect(`${u.protocol}//${u.host}${u.pathname}`).toBe("navi://auth/callback");
  return u.searchParams.get("code")!;
}

async function exchangeCode(code: string) {
  return exchange(req("/auth/exchange", { json: { code } }));
}

describe("email code (OTP) — for mail apps that open links in another browser", () => {
  it("app flow: code → navi://auth/callback?code=… → /auth/exchange → tokens for that email", async () => {
    const email = freshEmail();
    const { code } = await sendCode(email, "navi");
    const res = await verify(req("/auth/verify", { json: { email, code, redirect: "navi" } }));
    expect(res.status).toBe(200);
    const one = appCode(String((await body(res)).redirect));

    const ex = await exchangeCode(one);
    expect(ex.status).toBe(200);
    const tokens = (await ex.json()) as SessionTokens;
    expect((await verifyAccessToken(tokens.accessToken)).email).toBe(email);
    // The profile exists straight away (trial started).
    const db = await getDb();
    const profile = await db.getProfile((await verifyAccessToken(tokens.accessToken)).id);
    expect(profile?.trialEndsAt).toBeTruthy();
  });

  it("web flow: code → /account with the httpOnly session cookie", async () => {
    const email = freshEmail();
    const { code } = await sendCode(email, "account");
    const res = await verify(req("/auth/verify", { json: { email, code: ` ${code.slice(0, 3)} ${code.slice(3)} `, redirect: "account" } }));
    expect(res.status).toBe(200);
    expect((await body(res)).redirect).toBe("/account");
    const line = res.headers.getSetCookie().find((c) => c.startsWith(`${SESSION_COOKIE}=`))!;
    expect(line).toMatch(/HttpOnly/);
    const session = decodeSession(setCookies(res).get(SESSION_COOKIE));
    expect((await verifyAccessToken(session!.accessToken)).email).toBe(email);
  });

  it("a wrong code, a reused code, and a superseded code are all invalid_code", async () => {
    const email = freshEmail();
    const first = await sendCode(email, "navi");
    const wrong = await verify(req("/auth/verify", { json: { email, code: first.code === "000000" ? "111111" : "000000", redirect: "navi" } }));
    expect(wrong.status).toBe(400);
    expect((await body(wrong)).error).toBe("invalid_code");

    // A second email supersedes the first one's code.
    await sendCode(email, "navi");
    const stale = await verify(req("/auth/verify", { json: { email, code: first.code, redirect: "navi" } }));
    expect((await body(stale)).error).toBe("invalid_code");

    const { code } = memoryOutbox(email)!;
    expect((await verify(req("/auth/verify", { json: { email, code, redirect: "navi" } }))).status).toBe(200);
    const again = await verify(req("/auth/verify", { json: { email, code, redirect: "navi" } }));
    expect((await body(again)).error).toBe("invalid_code");
  });

  it("an expired code is refused", async () => {
    let now = Date.now();
    setAuthBackendForTests(createMemoryAuthBackend(() => now));
    const email = freshEmail();
    const { code } = await sendCode(email, "navi");
    now += MEMORY_OTP_TTL_MS + 1;
    const res = await verify(req("/auth/verify", { json: { email, code, redirect: "navi" } }));
    expect(res.status).toBe(400);
    expect((await body(res)).error).toBe("invalid_code");
  });

  it("10 attempts per address, then rate_limited (a 6-digit code can't be walked)", async () => {
    const email = freshEmail();
    await sendCode(email, "navi");
    const statuses: number[] = [];
    for (let i = 0; i < 11; i++) {
      const res = await verify(req("/auth/verify", { json: { email, code: String(100000 + i), redirect: "navi" } }));
      statuses.push(res.status);
    }
    expect(statuses.slice(0, 10).every((s) => s === 400)).toBe(true);
    expect(statuses[10]).toBe(429);
  });

  it("rejects malformed emails and codes before touching the backend", async () => {
    const bad = await sendOtp(req("/auth/otp", { json: { email: "not-an-email", redirect: "navi" } }));
    expect(bad.status).toBe(400);
    expect((await body(bad)).error).toBe("invalid_email");
    const shortCode = await verify(req("/auth/verify", { json: { email: freshEmail(), code: "12", redirect: "navi" } }));
    expect((await body(shortCode)).error).toBe("invalid_code");
  });

  it("5 emails per address per 15 minutes", async () => {
    const email = freshEmail();
    for (let i = 0; i < 5; i++) expect((await sendOtp(req("/auth/otp", { json: { email } }))).status).toBe(200);
    const sixth = await sendOtp(req("/auth/otp", { json: { email } }));
    expect(sixth.status).toBe(429);
    expect(sixth.headers.get("retry-after")).toBe("60");
    expect((await body(sixth)).error).toBe("rate_limited");
  });
});

describe("magic link → /auth/callback", () => {
  it("token_hash link, app flow: 302 navi://auth/callback?code=…, and the link works once", async () => {
    const email = freshEmail();
    const { link } = await sendCode(email, "navi");
    const path = link.replace(/^https?:\/\/[^/]+/, "");
    const res = await callback(req(path));
    expect(res.status).toBe(302);
    const code = appCode(res.headers.get("location")!);
    expect((await exchangeCode(code)).status).toBe(200);

    const reused = await callback(req(path));
    expect(reused.status).toBe(302);
    expect(reused.headers.get("location")).toBe("http://localhost:3100/auth/start?redirect=navi&error=expired");
  });

  it("token_hash link, web flow: cookie + 302 /account", async () => {
    const email = freshEmail();
    const { link } = await sendCode(email, "account");
    const res = await callback(req(link.replace(/^https?:\/\/[^/]+/, "")));
    expect(res.headers.get("location")).toBe("http://localhost:3100/account");
    expect(decodeSession(setCookies(res).get(SESSION_COOKIE))).not.toBeNull();
  });

  it("templates that wrap {{ .RedirectTo }} in next= still reach the right flow", async () => {
    const email = freshEmail();
    const { link } = await sendCode(email, "account");
    const hash = new URL(link).searchParams.get("token_hash")!;
    const next = encodeURIComponent("http://localhost:3100/auth/callback?redirect=account");
    const res = await callback(req(`/auth/callback?token_hash=${hash}&type=email&next=${next}`));
    expect(res.headers.get("location")).toBe("http://localhost:3100/account");
  });

  it("maps provider / link errors to a clear page instead of a raw message", async () => {
    const expired = await callback(req("/auth/callback?redirect=navi&error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired"));
    expect(expired.headers.get("location")).toBe("http://localhost:3100/auth/start?redirect=navi&error=expired");
    const cancelled = await callback(req("/auth/callback?redirect=account&error=access_denied&error_description=user+cancelled"));
    expect(cancelled.headers.get("location")).toBe("http://localhost:3100/auth/start?redirect=account&error=cancelled");
  });

  it("PKCE ?code= path: finishes on success, explains 'other browser' when the verifier is missing, never keeps sb-* cookies", async () => {
    const email = freshEmail();
    const tokens = await getSessionProvider().issue(memoryUserForEmail(email));
    const fake: AuthBackend = {
      kind: "supabase",
      sendEmailOtp: async () => undefined,
      verifyEmailOtp: async () => tokens,
      verifyTokenHash: async () => tokens,
      sessionFromFragment: async () => tokens,
      exchangeCode: async (code) => {
        if (code === "good") return tokens;
        throw new SignInError(classifyAuthError({ name: "AuthPKCECodeVerifierMissingError", message: "PKCE code verifier not found in storage." }));
      },
      oauthUrl: async () => "https://accounts.example/consent",
      providers: async () => ["google"],
    };
    setAuthBackendForTests(fake);

    const ok = await callback(req("/auth/callback?code=good&redirect=navi", { cookie: "sb-abc-auth-token-code-verifier=v; sb-abc-auth-token=base64-x" }));
    expect(ok.status).toBe(302);
    appCode(ok.headers.get("location")!);
    const cleared = setCookies(ok);
    expect(cleared.get("sb-abc-auth-token")).toBe("");
    expect(cleared.get("sb-abc-auth-token-code-verifier")).toBe("");

    const other = await callback(req("/auth/callback?code=from-another-browser&redirect=account"));
    expect(other.headers.get("location")).toBe("http://localhost:3100/auth/start?redirect=account&error=other_browser");
  });
});

describe("default-template link: session in the #fragment, any browser", () => {
  const form = (path: string, fields: Record<string, string>, init: { origin?: string | null } = {}) =>
    callbackPost(
      req(path, {
        method: "POST",
        body: new URLSearchParams(fields).toString(),
        headers: { "content-type": "application/x-www-form-urlencoded" },
        origin: init.origin,
      }),
    );

  it("a bare callback GET answers with the finish page: strips the fragment first, POSTs back here, no tokens in any URL", async () => {
    const res = await callback(req("/auth/callback?redirect=navi"));
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("referrer-policy")).toBe("no-referrer");
    const html = await res.text();
    expect(html.indexOf("history.replaceState")).toBeGreaterThan(-1);
    expect(html.indexOf("history.replaceState")).toBeLessThan(html.indexOf("f.submit()"));
    expect(html).toContain('f.method="POST"');
    expect(html).toContain('"/auth/callback?redirect=navi"');
    expect(html).toContain('"/auth/start?redirect=navi&error=expired"');
  });

  it("app flow: verified tokens → single-use 5-minute code → navi://, never tokens in the URL; the code works once", async () => {
    const email = freshEmail();
    const tokens = await getSessionProvider().issue(memoryUserForEmail(email));
    const res = await form("/auth/callback?redirect=navi", { access_token: tokens.accessToken, refresh_token: tokens.refreshToken });
    expect(res.status).toBe(303);
    const location = res.headers.get("location")!;
    expect(location).not.toContain(tokens.accessToken);
    expect(location).not.toContain(tokens.refreshToken);
    const code = appCode(location);
    const first = await exchangeCode(code);
    expect(first.status).toBe(200);
    const got = (await first.json()) as SessionTokens;
    expect((await verifyAccessToken(got.accessToken)).email).toBe(email);
    expect((await exchangeCode(code)).status).toBe(400);
  });

  it("web flow: verified tokens → httpOnly session cookie + /account", async () => {
    const tokens = await getSessionProvider().issue(memoryUserForEmail(freshEmail()));
    const res = await form("/auth/callback?redirect=account", { access_token: tokens.accessToken, refresh_token: tokens.refreshToken });
    expect(res.status).toBe(303);
    expect(res.headers.get("location")).toBe("http://localhost:3100/account");
    expect(decodeSession(setCookies(res).get(SESSION_COOKIE))).not.toBeNull();
  });

  it("a forged or tampered access token is refused with the 'expired' page, and nothing is issued", async () => {
    const tokens = await getSessionProvider().issue(memoryUserForEmail(freshEmail()));
    const [h, p] = tokens.accessToken.split(".");
    const tampered = `${h}.${p}.${"A".repeat(43)}`;
    for (const access of [tampered, "not-a-jwt-but-long-enough-to-pass"]) {
      const res = await form("/auth/callback?redirect=navi", { access_token: access, refresh_token: tokens.refreshToken });
      expect(res.status).toBe(303);
      expect(res.headers.get("location")).toBe("http://localhost:3100/auth/start?redirect=navi&error=expired");
    }
  });

  it("is same-origin only, and a body that isn't the finish page's form is 'expired'", async () => {
    const tokens = await getSessionProvider().issue(memoryUserForEmail(freshEmail()));
    const fields = { access_token: tokens.accessToken, refresh_token: tokens.refreshToken };
    expect((await form("/auth/callback?redirect=account", fields, { origin: "https://evil.example" })).status).toBe(403);
    expect((await form("/auth/callback?redirect=account", fields, { origin: null })).status).toBe(403);
    const missing = await form("/auth/callback?redirect=account", { access_token: tokens.accessToken });
    expect(missing.headers.get("location")).toBe("http://localhost:3100/auth/start?redirect=account&error=expired");
  });
});

describe("GET /auth/oauth — Google, GitHub, Apple when switched on", () => {
  it("sends GitHub to its consent page when enabled, and refuses providers that are off", async () => {
    const tokens = await getSessionProvider().issue(memoryUserForEmail(freshEmail()));
    const asked: string[] = [];
    setAuthBackendForTests({
      kind: "supabase",
      sendEmailOtp: async () => undefined,
      verifyEmailOtp: async () => tokens,
      verifyTokenHash: async () => tokens,
      sessionFromFragment: async () => tokens,
      exchangeCode: async () => tokens,
      oauthUrl: async (provider, redirectTo) => {
        asked.push(`${provider} ${redirectTo}`);
        return `https://consent.example/${provider}`;
      },
      providers: async () => ["google", "github"],
    });
    const gh = await oauthStart(req("/auth/oauth?provider=github&redirect=account"));
    expect(gh.headers.get("location")).toBe("https://consent.example/github");
    expect(asked).toEqual(["github http://localhost:3100/auth/callback?redirect=account"]);
    const apple = await oauthStart(req("/auth/oauth?provider=apple&redirect=navi"));
    expect(apple.headers.get("location")).toBe("http://localhost:3100/auth/start?redirect=navi&error=provider");
    const junk = await oauthStart(req("/auth/oauth?provider=myspace&redirect=navi"));
    expect(junk.headers.get("location")).toBe("http://localhost:3100/auth/start?redirect=navi&error=provider");
  });
});

describe("POST /auth/exchange — single use, 5 minutes", () => {
  it("a code works once", async () => {
    const tokens = await getSessionProvider().issue(memoryUserForEmail(freshEmail()));
    const done = await finishSignIn("navi", tokens);
    const code = appCode(done.location);
    expect((await exchangeCode(code)).status).toBe(200);
    const second = await exchangeCode(code);
    expect(second.status).toBe(400);
    expect((await body(second)).error).toBe("invalid_code");
  });

  it("a code older than 5 minutes is refused", async () => {
    const tokens = await getSessionProvider().issue(memoryUserForEmail(freshEmail()));
    const done = await finishSignIn("navi", tokens, undefined, new Date(Date.now() - 5 * 60_000 - 1000));
    const res = await exchangeCode(appCode(done.location));
    expect(res.status).toBe(400);
  });

  it("an unknown code is refused", async () => {
    expect((await exchangeCode("nope")).status).toBe(400);
  });
});

describe("POST /auth/dev-login", () => {
  const dev = (json: Record<string, unknown>, secret = "dev") => devLogin(req("/auth/dev-login", { json, headers: { "x-dev-login-secret": secret } }));

  it("returns tokens (smoke.sh), or finishes either flow when asked", async () => {
    const plain = await dev({ email: freshEmail() });
    expect((await body(plain)).accessToken).toBeTruthy();

    const web = await dev({ email: freshEmail(), redirect: "account" });
    expect((await body(web)).redirect).toBe("/account");
    expect(decodeSession(setCookies(web).get(SESSION_COOKIE))).not.toBeNull();

    const app = await dev({ email: freshEmail(), redirect: "navi" });
    expect((await exchangeCode(appCode(String((await body(app)).redirect)))).status).toBe(200);
  });

  it("is refused with a wrong secret and does not exist on production", async () => {
    expect((await dev({ email: freshEmail() }, "wrong")).status).toBe(403);
    const env = process.env as Record<string, string | undefined>;
    const prev = env.NODE_ENV;
    env.NODE_ENV = "production";
    env.VERCEL_ENV = "production";
    try {
      expect((await dev({ email: freshEmail() })).status).toBe(404);
      expect(() => createMemoryAuthBackend()).toThrow();
    } finally {
      env.NODE_ENV = prev;
      delete env.VERCEL_ENV;
    }
  });
});

describe("classifyAuthError", () => {
  it("maps Supabase errors to the copy users see", () => {
    expect(classifyAuthError({ status: 429, code: "over_email_send_rate_limit" }, "send")).toBe("rate_limited");
    expect(classifyAuthError({ code: "otp_expired", message: "Token has expired or is invalid" }, "code")).toBe("invalid_code");
    expect(classifyAuthError({ code: "otp_expired" }, "link")).toBe("expired");
    expect(classifyAuthError({ code: "flow_state_not_found" }, "link")).toBe("expired");
    expect(classifyAuthError({ code: "bad_code_verifier" }, "link")).toBe("other_browser");
    expect(classifyAuthError({ code: "signup_disabled" }, "send")).toBe("signups_closed");
    expect(classifyAuthError({ code: "email_address_invalid" }, "send")).toBe("invalid_email");
    expect(classifyAuthError({ code: "access_denied" }, "oauth")).toBe("cancelled");
    expect(classifyAuthError({ code: "bad_oauth_state" }, "oauth")).toBe("provider");
  });
});
