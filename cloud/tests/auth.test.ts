import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { exportJWK, generateKeyPair, SignJWT, type JWK } from "jose";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { assertSameOrigin, mintAccessToken, requireAccountUser, resetJwksCache, verifyAccessToken } from "@/lib/auth";
import { HttpError } from "@/lib/http";
import { decodeSession, encodeSession, parseCookies, safeNextPath, serializeCookie, SESSION_COOKIE } from "@/lib/web-session";
import { BASE, req, useMemoryEnv } from "./helpers";

const HS_SECRET = "super-secret-jwt-token-with-at-least-32-characters-long";

async function hs256(claims: Record<string, unknown>, secret = HS_SECRET, expSeconds = 3600) {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT(claims).setProtectedHeader({ alg: "HS256" }).setIssuedAt(now).setExpirationTime(now + expSeconds).sign(new TextEncoder().encode(secret));
}

async function expect401(p: Promise<unknown>, error = "unauthenticated") {
  await expect(p).rejects.toBeInstanceOf(HttpError);
  await p.catch((e: HttpError) => {
    expect(e.status).toBe(401);
    expect(e.body.error).toBe(error);
  });
}

// MARK: - A JWKS endpoint like Supabase's /auth/v1/.well-known/jwks.json

let server: Server;
let jwksUrl: string;
let es256: { privateKey: CryptoKey; jwk: JWK };
let rotated: { privateKey: CryptoKey; jwk: JWK };
let served: JWK[] = [];
let fetches = 0;

beforeAll(async () => {
  const a = await generateKeyPair("ES256", { extractable: true });
  es256 = { privateKey: a.privateKey as CryptoKey, jwk: { ...(await exportJWK(a.publicKey)), kid: "key-1", alg: "ES256", use: "sig" } };
  const b = await generateKeyPair("ES256", { extractable: true });
  rotated = { privateKey: b.privateKey as CryptoKey, jwk: { ...(await exportJWK(b.publicKey)), kid: "key-2", alg: "ES256", use: "sig" } };
  served = [es256.jwk];
  server = createServer((_req, res) => {
    fetches += 1;
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ keys: served }));
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  jwksUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}/auth/v1/.well-known/jwks.json`;
});

afterAll(() => new Promise<void>((r) => server.close(() => r())));

async function es(claims: Record<string, unknown>, key = es256, expSeconds = 3600) {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT(claims)
    .setProtectedHeader({ alg: "ES256", kid: key.jwk.kid })
    .setIssuedAt(now)
    .setExpirationTime(now + expSeconds)
    .sign(key.privateKey);
}

const supabaseClaims = { sub: "11111111-2222-3333-4444-555555555555", email: "liam@example.com", aud: "authenticated", role: "authenticated", session_id: "sess-1" };

beforeEach(() => {
  resetJwksCache();
  served = [es256.jwk];
  fetches = 0;
});

describe("asymmetric keys (SUPABASE_JWKS_URL) — what new Supabase projects issue", () => {
  beforeEach(() => useMemoryEnv({ DB_DRIVER: "supabase", SUPABASE_URL: "https://example.supabase.co", SUPABASE_JWKS_URL: jwksUrl }));

  it("verifies an ES256 token against the remote key set and reads sub, email, session_id", async () => {
    const user = await verifyAccessToken(await es(supabaseClaims));
    expect(user).toEqual({ id: supabaseClaims.sub, email: "liam@example.com", sessionId: "sess-1" });
  });

  it("caches the key set (one fetch for many verifications)", async () => {
    for (let i = 0; i < 5; i++) await verifyAccessToken(await es(supabaseClaims));
    expect(fetches).toBe(1);
  });

  it("accepts a rotated key (new kid) once the key set is refetched", async () => {
    await verifyAccessToken(await es(supabaseClaims));
    served = [es256.jwk, rotated.jwk];
    await new Promise((r) => setTimeout(r, 10));
    resetJwksCache(); // jose's cooldown is 30 s; a fresh cache stands in for "after the cooldown"
    const user = await verifyAccessToken(await es(supabaseClaims, rotated));
    expect(user.id).toBe(supabaseClaims.sub);
  });

  it("rejects a token signed by a key that is not in the set", async () => {
    const other = await generateKeyPair("ES256");
    const now = Math.floor(Date.now() / 1000);
    const forged = await new SignJWT(supabaseClaims).setProtectedHeader({ alg: "ES256", kid: "key-1" }).setIssuedAt(now).setExpirationTime(now + 60).sign(other.privateKey);
    await expect401(verifyAccessToken(forged));
  });

  it("rejects expired tokens, the wrong audience, and non-user roles", async () => {
    await expect401(verifyAccessToken(await es(supabaseClaims, es256, -10)));
    await expect401(verifyAccessToken(await es({ ...supabaseClaims, aud: "something-else" })));
    await expect401(verifyAccessToken(await es({ ...supabaseClaims, role: "service_role" })));
  });

  it("does not accept HS256 tokens when no JWT secret is configured (no dev-secret fallback on a real project)", async () => {
    const t = await hs256(supabaseClaims, "navi-dev-jwt-secret-change-me");
    await expect401(verifyAccessToken(t));
  });

  it("derives the JWKS URL from SUPABASE_URL when SUPABASE_JWKS_URL is unset", async () => {
    useMemoryEnv({ DB_DRIVER: "supabase", SUPABASE_URL: jwksUrl.replace("/auth/v1/.well-known/jwks.json", "") });
    const user = await verifyAccessToken(await es(supabaseClaims));
    expect(user.id).toBe(supabaseClaims.sub);
  });

  it("mid-migration: HS256 (old sessions) and ES256 (new) both verify when both are configured", async () => {
    useMemoryEnv({ DB_DRIVER: "supabase", SUPABASE_URL: "https://example.supabase.co", SUPABASE_JWKS_URL: jwksUrl, SUPABASE_JWT_SECRET: HS_SECRET });
    expect((await verifyAccessToken(await hs256(supabaseClaims))).id).toBe(supabaseClaims.sub);
    expect((await verifyAccessToken(await es(supabaseClaims))).id).toBe(supabaseClaims.sub);
  });
});

describe("HS256 (legacy JWT secret)", () => {
  beforeEach(() => useMemoryEnv({ DB_DRIVER: "supabase", SUPABASE_URL: "https://example.supabase.co", SUPABASE_JWT_SECRET: HS_SECRET }));

  it("verifies with the secret and rejects another secret", async () => {
    expect((await verifyAccessToken(await hs256(supabaseClaims))).email).toBe("liam@example.com");
    await expect401(verifyAccessToken(await hs256(supabaseClaims, "x".repeat(40))));
  });

  it("rejects the project's anon key (a JWT with no sub)", async () => {
    await expect401(verifyAccessToken(await hs256({ role: "anon", aud: "authenticated" })));
  });
});

describe("memory driver dev tokens", () => {
  beforeEach(() => useMemoryEnv());
  it("round-trips a minted token including the session id", async () => {
    const { token } = await mintAccessToken({ id: "u1", email: "a@b.co", sessionId: "s9" });
    expect(await verifyAccessToken(token)).toEqual({ id: "u1", email: "a@b.co", sessionId: "s9" });
  });
});

describe("web session cookie", () => {
  beforeEach(() => useMemoryEnv());

  it("encodes, parses and rejects junk", () => {
    const v = encodeSession({ accessToken: "a.b.c", refreshToken: "r1" });
    expect(decodeSession(v)).toEqual({ accessToken: "a.b.c", refreshToken: "r1" });
    expect(decodeSession("not-base64-json")).toBeNull();
    expect(decodeSession(Buffer.from(JSON.stringify({ a: 1 })).toString("base64url"))).toBeNull();
    const line = serializeCookie(SESSION_COOKIE, v, { maxAge: 60, secure: true });
    expect(line).toMatch(/HttpOnly/);
    expect(line).toMatch(/Secure/);
    expect(line).toMatch(/SameSite=Lax/);
    expect(parseCookies(`x=1; ${SESSION_COOKIE}=${v}; y=2`).get(SESSION_COOKIE)).toBe(v);
  });

  it("only allows same-site relative next paths", () => {
    expect(safeNextPath("/account")).toBe("/account");
    expect(safeNextPath("//evil.example")).toBe("/account");
    expect(safeNextPath("https://evil.example")).toBe("/account");
    expect(safeNextPath("/\\evil.example")).toBe("/account");
    expect(safeNextPath(null)).toBe("/account");
  });

  it("requireAccountUser: Bearer, then cookie; cookie writes need our Origin", async () => {
    const { token } = await mintAccessToken({ id: "u1", email: "a@b.co" });
    const cookie = `${SESSION_COOKIE}=${encodeSession({ accessToken: token, refreshToken: "r" })}`;

    expect((await requireAccountUser(req("/v1/account/export", { bearer: token }))).via).toBe("bearer");
    expect((await requireAccountUser(req("/v1/account/export", { cookie }))).via).toBe("cookie");
    expect((await requireAccountUser(req("/v1/account", { method: "DELETE", cookie }))).user.id).toBe("u1");

    const cross = requireAccountUser(req("/v1/account", { method: "DELETE", cookie, origin: "https://evil.example" }));
    await expect(cross).rejects.toMatchObject({ status: 403 });
    const none = requireAccountUser(req("/v1/account", { method: "DELETE", cookie, origin: null }));
    await expect(none).rejects.toMatchObject({ status: 403 });

    await expect401(requireAccountUser(req("/v1/account/export")));
  });

  it("an expired cookie token says session_expired so the page can refresh", async () => {
    const { token } = await mintAccessToken({ id: "u1", email: "a@b.co" }, -60);
    const cookie = `${SESSION_COOKIE}=${encodeSession({ accessToken: token, refreshToken: "r" })}`;
    await expect401(requireAccountUser(req("/v1/account/export", { cookie })), "session_expired");
  });

  it("assertSameOrigin lets safe methods through without an Origin", () => {
    expect(() => assertSameOrigin(new Request(`${BASE}/x`))).not.toThrow();
  });
});
