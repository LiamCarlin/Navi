import { env } from "@/lib/env";
import { json } from "@/lib/http";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export function GET() {
  return json({
    ok: true,
    db: env.dbDriver,
    mockUpstream: env.mockUpstream,
    devLogin: Boolean(env.devLoginSecret),
    vendors: { jev: Boolean(env.typesafeApiKey), claude: Boolean(env.anthropicApiKey), gemini: Boolean(env.geminiApiKey) },
    stripe: Boolean(env.stripeSecretKey),
  });
}
