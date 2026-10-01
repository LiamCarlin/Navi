/**
 * Vendor keys — "where Liam manages the keys". A key set from the admin console lives
 * in `vendor_keys`, encrypted at rest with AES-256-GCM under a key derived from
 * `NAVI_KEYS_SECRET`; without that secret the console refuses to store anything.
 *
 * `getVendorKey(provider)` is what the proxy calls: the database key first (cached in
 * process for 60 s), then the env var. Full keys never leave the server: the console
 * only ever sees `maskKey()` output, and nothing here logs a key.
 */

import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from "node:crypto";
import { getDb, type Db, type VendorKeyRow } from "./db";
import { env } from "./env";

export type VendorProvider = "typesafe" | "anthropic" | "gemini" | "ai_gateway" | "vercel" | "supabase";
export const VENDOR_PROVIDERS: readonly VendorProvider[] = ["typesafe", "anthropic", "gemini", "ai_gateway", "vercel", "supabase"];

/** `ai` keys are what the proxy calls with; `billing` tokens only let the Overview read spend. */
export type KeyGroup = "ai" | "billing";

export const PROVIDER_INFO: Record<VendorProvider, { label: string; envVar: string; purpose: string; group: KeyGroup }> = {
  typesafe: { label: "TypeSafe (Jev)", envVar: "TYPESAFE_API_KEY", purpose: "Routing and every agent step (/v1/jev)", group: "ai" },
  anthropic: { label: "Anthropic", envVar: "ANTHROPIC_API_KEY", purpose: "Answers, tasks, digests (/v1/claude, /v1/digest)", group: "ai" },
  gemini: { label: "Gemini", envVar: "GEMINI_API_KEY", purpose: "Cheap Recall digests (/v1/digest provider:gemini)", group: "ai" },
  ai_gateway: { label: "Vercel AI Gateway", envVar: "AI_GATEWAY_API_KEY", purpose: "Jev through the gateway when no TypeSafe key is set", group: "ai" },
  vercel: {
    label: "Vercel",
    envVar: "VERCEL_API_TOKEN",
    purpose: "Hosting spend on the Overview (reads /v1/billing/charges; a token with the Billing or Viewer role is enough)",
    group: "billing",
  },
  supabase: {
    label: "Supabase",
    envVar: "SUPABASE_ACCESS_TOKEN",
    purpose: "Database plan + add-ons on the Overview (Management API personal access token, sbp_…)",
    group: "billing",
  },
};

export function isVendorProvider(x: unknown): x is VendorProvider {
  return typeof x === "string" && (VENDOR_PROVIDERS as readonly string[]).includes(x);
}

export class KeysSecretError extends Error {
  constructor() {
    super("NAVI_KEYS_SECRET is not set (or shorter than 32 characters) — keys cannot be stored in the database.");
  }
}

// MARK: - Encryption

const FORMAT = "v1";
const MIN_SECRET_CHARS = 32;

function aesKey(secret: string | undefined): Buffer {
  if (!secret || secret.length < MIN_SECRET_CHARS) throw new KeysSecretError();
  return Buffer.from(hkdfSync("sha256", Buffer.from(secret, "utf8"), Buffer.alloc(0), Buffer.from("navi-vendor-keys/aes-256-gcm/v1"), 32));
}

export function keysSecretConfigured(secret: string | undefined = env.keysSecret): boolean {
  return Boolean(secret && secret.length >= MIN_SECRET_CHARS);
}

/** `v1.<base64url(iv ‖ tag ‖ ciphertext)>`; the provider is bound as AAD so rows can't be swapped. */
export function encryptKey(plain: string, provider: string, secret: string | undefined = env.keysSecret): string {
  const key = aesKey(secret);
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  cipher.setAAD(Buffer.from(`navi-vendor-key:${provider}`));
  const ct = Buffer.concat([cipher.update(plain, "utf8"), cipher.final()]);
  return `${FORMAT}.${Buffer.concat([iv, cipher.getAuthTag(), ct]).toString("base64url")}`;
}

/** Throws on a wrong secret, a tampered blob or a blob from another provider. */
export function decryptKey(blob: string, provider: string, secret: string | undefined = env.keysSecret): string {
  const key = aesKey(secret);
  const [fmt, data] = blob.split(".", 2);
  if (fmt !== FORMAT || !data) throw new Error("vendor key: unknown ciphertext format");
  const raw = Buffer.from(data, "base64url");
  if (raw.length < 12 + 16 + 1) throw new Error("vendor key: ciphertext too short");
  const decipher = createDecipheriv("aes-256-gcm", key, raw.subarray(0, 12));
  decipher.setAAD(Buffer.from(`navi-vendor-key:${provider}`));
  decipher.setAuthTag(raw.subarray(12, 28));
  return Buffer.concat([decipher.update(raw.subarray(28)), decipher.final()]).toString("utf8");
}

export function last4(key: string): string {
  return key.trim().slice(-4);
}

/** What the browser is allowed to see of a key. */
export function maskKey(key: string | null | undefined): string {
  if (!key) return "—";
  return `••••${last4(key)}`;
}

/** Removes any occurrence of the key from text (vendor error bodies) before it is shown or stored. */
export function scrubKey(text: string, key: string | undefined): string {
  if (!key || key.length < 6) return text;
  return text.split(key).join(maskKey(key));
}

/** Basic shape check before we encrypt something pasted into the console. */
export function validateKeyInput(raw: unknown): string {
  const key = typeof raw === "string" ? raw.trim() : "";
  if (key.length < 8 || key.length > 1024) throw new Error("That doesn't look like an API key (8–1024 characters).");
  if (/\s/.test(key)) throw new Error("API keys don't contain spaces or line breaks.");
  return key;
}

// MARK: - Lookup (what the proxy uses)

export type KeySource = "database" | "env" | "none";

function envKey(provider: VendorProvider): string | undefined {
  switch (provider) {
    case "typesafe": return env.typesafeApiKey;
    case "anthropic": return env.anthropicApiKey;
    case "gemini": return env.geminiApiKey;
    case "ai_gateway": return env.aiGatewayApiKey;
    case "vercel": return env.vercelApiToken;
    case "supabase": return env.supabaseAccessToken;
  }
}

export const KEY_CACHE_TTL_MS = 60_000;

interface CachedKey { value: string | undefined; source: KeySource; at: number }

function cache(): Map<VendorProvider, CachedKey> {
  const g = globalThis as unknown as { __naviKeyCache?: Map<VendorProvider, CachedKey> };
  g.__naviKeyCache ??= new Map();
  return g.__naviKeyCache;
}

export function invalidateKeyCache(provider?: VendorProvider): void {
  if (provider) cache().delete(provider);
  else cache().clear();
}

/** The key to use and where it came from: database (decrypted) first, then the env var. */
export async function resolveVendorKey(
  provider: VendorProvider,
  db?: Db,
  opts: { nowMs?: number; fresh?: boolean } = {},
): Promise<{ key: string | undefined; source: KeySource }> {
  const nowMs = opts.nowMs ?? Date.now();
  const hit = cache().get(provider);
  if (!opts.fresh && hit && nowMs - hit.at < KEY_CACHE_TTL_MS) return { key: hit.value, source: hit.source };

  let resolved: { key: string | undefined; source: KeySource } | null = null;
  try {
    const store = db ?? (await getDb());
    const row = await store.adminGetVendorKey(provider);
    if (row?.ciphertext) {
      if (keysSecretConfigured()) {
        resolved = { key: decryptKey(row.ciphertext, provider), source: "database" };
      } else {
        console.warn(`[navi-cloud] vendor key for ${provider} is stored but NAVI_KEYS_SECRET is unset; using the env var`);
      }
    }
  } catch (e) {
    // Never include the error object verbatim for decrypt failures — keep it to the message.
    console.warn(`[navi-cloud] vendor key lookup for ${provider} failed, using the env var:`, e instanceof Error ? e.message : "error");
  }
  if (!resolved) {
    const fromEnv = envKey(provider);
    resolved = { key: fromEnv, source: fromEnv ? "env" : "none" };
  }
  cache().set(provider, { value: resolved.key, source: resolved.source, at: nowMs });
  return resolved;
}

export async function getVendorKey(provider: VendorProvider, db?: Db): Promise<string | undefined> {
  return (await resolveVendorKey(provider, db)).key;
}

const USED_WRITE_EVERY_MS = 5 * 60_000;

/** Records "last used" at most every 5 minutes per instance; fire-and-forget. */
export function noteKeyUsed(provider: VendorProvider, db?: Db, nowMs: number = Date.now()): void {
  const g = globalThis as unknown as { __naviKeyUsed?: Map<VendorProvider, number> };
  g.__naviKeyUsed ??= new Map();
  const last = g.__naviKeyUsed.get(provider) ?? 0;
  if (nowMs - last < USED_WRITE_EVERY_MS) return;
  g.__naviKeyUsed.set(provider, nowMs);
  void (async () => {
    try {
      const store = db ?? (await getDb());
      await store.adminUpdateVendorKeyMeta(provider, { lastUsedAt: new Date(nowMs).toISOString() });
    } catch {
      /* metadata only; the migration may not be applied yet */
    }
  })();
}

// MARK: - Console operations

export interface KeyStatus {
  provider: VendorProvider;
  label: string;
  envVar: string;
  purpose: string;
  group: KeyGroup;
  source: KeySource;
  /** Masked: "••••abcd". Never the key. */
  masked: string;
  envPresent: boolean;
  dbPresent: boolean;
  /** Stored but cannot be decrypted with the current NAVI_KEYS_SECRET. */
  dbUnreadable: boolean;
  rotatedAt: string | null;
  rotatedBy: string | null;
  lastUsedAt: string | null;
  lastTestAt: string | null;
  lastTestOk: boolean | null;
  lastTestLatencyMs: number | null;
  lastTestError: string | null;
}

export async function keyStatuses(db: Db): Promise<KeyStatus[]> {
  let rows: VendorKeyRow[] = [];
  try {
    rows = await db.adminGetVendorKeys();
  } catch (e) {
    console.warn("[navi-cloud] vendor_keys read failed:", e instanceof Error ? e.message : "error");
  }
  return VENDOR_PROVIDERS.map((provider) => {
    const row = rows.find((r) => r.provider === provider);
    const fromEnv = envKey(provider);
    let dbUnreadable = false;
    if (row?.ciphertext) {
      try {
        decryptKey(row.ciphertext, provider);
      } catch {
        dbUnreadable = true;
      }
    }
    const dbUsable = Boolean(row?.ciphertext) && !dbUnreadable;
    const source: KeySource = dbUsable ? "database" : fromEnv ? "env" : "none";
    const masked = source === "database" ? `••••${row?.last4 ?? ""}` : source === "env" ? maskKey(fromEnv) : "—";
    const info = PROVIDER_INFO[provider];
    return {
      provider,
      ...info,
      source,
      masked,
      envPresent: Boolean(fromEnv),
      dbPresent: Boolean(row?.ciphertext),
      dbUnreadable,
      rotatedAt: row?.ciphertext ? row.rotatedAt : null,
      rotatedBy: row?.ciphertext ? row.rotatedBy : null,
      lastUsedAt: row?.lastUsedAt ?? null,
      lastTestAt: row?.lastTestAt ?? null,
      lastTestOk: row?.lastTestOk ?? null,
      lastTestLatencyMs: row?.lastTestLatencyMs ?? null,
      lastTestError: row?.lastTestError ?? null,
    };
  });
}

/** Encrypts and stores a key (rotate = store again). Returns the last 4 characters for the audit log. */
export async function storeVendorKey(db: Db, provider: VendorProvider, rawKey: unknown, by: string, now = new Date()): Promise<{ last4: string }> {
  if (!keysSecretConfigured()) throw new KeysSecretError();
  const key = validateKeyInput(rawKey);
  const blob = encryptKey(key, provider);
  await db.adminSetVendorKey(provider, blob, last4(key), by, now.toISOString());
  invalidateKeyCache(provider);
  return { last4: last4(key) };
}

/** Deletes the stored key; the proxy falls back to the env var. */
export async function removeVendorKey(db: Db, provider: VendorProvider, by: string, now = new Date()): Promise<void> {
  await db.adminSetVendorKey(provider, null, null, by, now.toISOString());
  invalidateKeyCache(provider);
}

// MARK: - Test

export interface KeyTestResult {
  ok: boolean;
  latencyMs: number;
  status?: number;
  error?: string;
}

type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

/** The cheapest real call per vendor that proves the key works. */
export function testRequest(provider: VendorProvider, key: string): { url: string; init: RequestInit } {
  switch (provider) {
    case "typesafe":
      return {
        url: env.typesafeUrl,
        init: {
          method: "POST",
          headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
          body: JSON.stringify({
            state: { check: "navi-admin key test" },
            model: "jev-latest",
            questions: { ok: { type: "noul", instructions: "Is this a connectivity check?" } },
          }),
        },
      };
    case "anthropic":
      return {
        url: env.anthropicUrl.replace(/\/messages\/?$/, "/models") + "?limit=1",
        init: { method: "GET", headers: { "x-api-key": key, "anthropic-version": "2023-06-01" } },
      };
    case "gemini":
      return { url: `${env.geminiBaseUrl}?pageSize=1`, init: { method: "GET", headers: { "x-goog-api-key": key } } };
    case "ai_gateway":
      return {
        url: env.aiGatewayEvalUrl,
        init: {
          method: "POST",
          headers: {
            authorization: `Bearer ${key}`,
            "content-type": "application/json",
            "ai-model-id": "typesafe-ai/jev",
            "ai-evaluation-model-specification-version": "4",
            "ai-gateway-protocol-version": "0.0.1",
            "ai-gateway-auth-method": "api-key",
          },
          body: JSON.stringify({
            state: { check: "navi-admin key test" },
            questions: { ok: { type: "boolean", instructions: "Is this a connectivity check?" } },
          }),
        },
      };
    case "vercel":
      return { url: "https://api.vercel.com/v2/teams?limit=1", init: { method: "GET", headers: { authorization: `Bearer ${key}` } } };
    case "supabase":
      return { url: "https://api.supabase.com/v1/organizations", init: { method: "GET", headers: { authorization: `Bearer ${key}` } } };
  }
}

export async function testVendorKey(provider: VendorProvider, key: string, fetchImpl: FetchLike = fetch): Promise<KeyTestResult> {
  const { url, init } = testRequest(provider, key);
  const t0 = Date.now();
  try {
    const res = await fetchImpl(url, { ...init, signal: AbortSignal.timeout(15_000) });
    const latencyMs = Date.now() - t0;
    if (res.ok) {
      await res.body?.cancel().catch(() => undefined);
      return { ok: true, latencyMs, status: res.status };
    }
    const text = scrubKey((await res.text().catch(() => "")).slice(0, 300), key);
    return { ok: false, latencyMs, status: res.status, error: `HTTP ${res.status}${text ? ` — ${text}` : ""}` };
  } catch (e) {
    return { ok: false, latencyMs: Date.now() - t0, error: scrubKey(e instanceof Error ? e.message : String(e), key) };
  }
}
