import { billingCanceller, exportAccount } from "@/lib/account";
import { requireAccountUser } from "@/lib/auth";
import { getDb } from "@/lib/db";
import { handle, json, rateLimited, unauthenticated } from "@/lib/http";
import { perUserLimiter } from "@/lib/ratelimit";
import { getSessionProvider } from "@/lib/sessions";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * GET /v1/account/export  (Bearer, or the /account cookie session) → 200 JSON
 * Everything Navi Cloud holds about the signed-in user: profile, plan + usage this period,
 * entitlement grants, every usage row, the waitlist row if any, signed-in devices.
 * `?download=1` adds Content-Disposition so a browser saves it as a file.
 * 401 once the account has been deleted (a still-unexpired token must not resurrect it).
 */
export const GET = handle(async (req) => {
  const caller = await requireAccountUser(req);
  const rl = await perUserLimiter.hit(caller.user.id);
  if (!rl.ok) throw rateLimited(rl.retryAfterSeconds);

  const sessions = getSessionProvider();
  if (!(await sessions.userExists(caller.user.id))) throw unauthenticated("This Navi account no longer exists.");

  const body = await exportAccount({ db: await getDb(), sessions, billing: billingCanceller() }, caller.user);
  const headers: Record<string, string> = {};
  if (new URL(req.url).searchParams.get("download") === "1") {
    headers["content-disposition"] = `attachment; filename="navi-account-${body.exportedAt.slice(0, 10)}.json"`;
  }
  return json(body, { status: 200, headers });
});
