import { timingSafeEqual } from "node:crypto";
import { bearerToken } from "@/lib/auth";
import { getDb } from "@/lib/db";
import { env } from "@/lib/env";
import { json } from "@/lib/http";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function matches(given: string | null, expected: string): boolean {
  if (!given) return false;
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

/**
 * GET /auth/purge — daily housekeeping, called by Vercel Cron (vercel.json) with
 * `Authorization: Bearer $CRON_SECRET`. Deletes expired sign-in codes and rate-limit windows
 * that ended more than a day ago. 404 while CRON_SECRET is not set.
 */
export async function GET(req: Request): Promise<Response> {
  const secret = env.cronSecret;
  if (!secret) return new Response("Not found", { status: 404 });
  if (!matches(bearerToken(req), secret)) return json({ error: "unauthenticated" }, 401);
  const purged = await (await getDb()).purgeExpired(new Date());
  console.info(`[navi-cloud] purge: ${purged.authCodes} auth codes, ${purged.rateLimits} rate-limit rows`);
  return json({ ok: true, purged });
}
