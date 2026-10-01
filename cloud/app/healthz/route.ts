import { getDb } from "@/lib/db";
import { env } from "@/lib/env";
import { json } from "@/lib/http";
import { keyStatuses, type KeySource } from "@/lib/keys";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * GET /healthz — which driver / vendors / mock mode are active. Vendor keys are reported by
 * *source* only ("database" = the admin console's encrypted store, "env", or "none") — never
 * a mask or any part of a key.
 */
export async function GET() {
  let keys: Record<string, KeySource> = {};
  try {
    for (const k of await keyStatuses(await getDb())) keys[k.provider] = k.source;
  } catch {
    keys = {};
  }
  const has = (provider: string, envValue: string | undefined) => (keys[provider] ? keys[provider] !== "none" : Boolean(envValue));
  return json({
    ok: true,
    db: env.dbDriver,
    mockUpstream: env.mockUpstream,
    devLogin: Boolean(env.devLoginSecret) && !env.isProduction,
    vendors: {
      jev: has("typesafe", env.typesafeApiKey),
      claude: has("anthropic", env.anthropicApiKey),
      gemini: has("gemini", env.geminiApiKey),
    },
    keys,
    stripe: Boolean(env.stripeSecretKey),
  });
}
