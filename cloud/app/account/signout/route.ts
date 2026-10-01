import { requireAccountUser } from "@/lib/auth";
import { env } from "@/lib/env";
import { handle, HttpError, readJson } from "@/lib/http";
import { getSessionProvider } from "@/lib/sessions";
import { jsonWithCookies, startPath } from "@/lib/signin";
import { sessionClearCookie } from "@/lib/web-session";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * POST /account/signout { scope: "this" | "everywhere" } → { ok, redirect }
 * "this" ends the browser's session. "everywhere" ends every session of the account — every
 * Mac running Navi and every browser — at the next token refresh (access tokens live ≤ 1 h).
 */
export const POST = handle(async (req) => {
  const body = await readJson<{ scope?: unknown }>(req).catch(() => ({}) as { scope?: unknown });
  const scope = body.scope === "everywhere" ? "everywhere" : "this";
  const clear = sessionClearCookie(env.secureCookies);

  let caller;
  try {
    caller = await requireAccountUser(req);
  } catch (e) {
    // Already signed out (or the token expired): still clear the cookie for "this".
    if (scope === "this" && e instanceof HttpError && e.status === 401) {
      return jsonWithCookies({ ok: true, redirect: startPath("account") }, 200, [clear]);
    }
    throw e;
  }

  const sessions = getSessionProvider();
  if (scope === "everywhere") await sessions.revokeAll(caller.user, caller.accessToken);
  else await sessions.revokeSession(caller.user, caller.accessToken);
  return jsonWithCookies({ ok: true, redirect: startPath("account") }, 200, caller.via === "cookie" ? [clear] : []);
});
