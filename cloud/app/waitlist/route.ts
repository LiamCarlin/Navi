import { getDb } from "@/lib/db";
import { badRequest, clientIp, handle, json, rateLimited, readJson } from "@/lib/http";
import { waitlistIpLimiter } from "@/lib/ratelimit";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

/** POST /waitlist { email, source?, note? } → 201 created / 200 already on the list. Also used by web/. */
export const POST = handle(async (req) => {
  const rl = waitlistIpLimiter.hit(clientIp(req));
  if (!rl.ok) throw rateLimited(rl.retryAfterSeconds);

  const body = await readJson<{ email?: unknown; source?: unknown; note?: unknown }>(req);
  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  if (!EMAIL.test(email) || email.length > 254) throw badRequest("Enter a valid email address.");
  const source = typeof body.source === "string" ? body.source.slice(0, 64) : null;
  const note = typeof body.note === "string" ? body.note.slice(0, 500) : null;

  const db = await getDb();
  const { created } = await db.addToWaitlist(email, source, note);
  return json({ ok: true, created }, created ? 201 : 200);
});

export function OPTIONS() {
  return new Response(null, {
    status: 204,
    headers: {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "POST, OPTIONS",
      "access-control-allow-headers": "content-type",
    },
  });
}
