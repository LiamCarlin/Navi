import { classifyAuthError, getAuthBackend, SignInError, type SignInErrorKind } from "@/lib/auth-backend";
import type { SessionTokens } from "@/lib/db";
import { clientIp } from "@/lib/http";
import { fragmentFinishPage, readFragmentPost } from "@/lib/fragment-signin";
import { HttpError } from "@/lib/http";
import { authIpLimiter } from "@/lib/ratelimit";
import { clearSupabaseCookies, cookieJar, finishSignIn, parseFlow, redirectResponse, startPath, type Flow } from "@/lib/signin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** `redirect` straight on the URL, or inside `next`/`redirect_to` (email templates that wrap {{ .RedirectTo }}). */
function flowFrom(url: URL): Flow {
  const direct = url.searchParams.get("redirect");
  if (direct) return parseFlow(direct);
  for (const k of ["next", "redirect_to"]) {
    const v = url.searchParams.get(k);
    if (!v) continue;
    try { return parseFlow(new URL(v, url).searchParams.get("redirect")); } catch { /* ignore */ }
  }
  return parseFlow(null);
}

/**
 * GET /auth/callback — where the sign-in email's link and the Google/Apple return land.
 *   ?code=…                    PKCE (the browser that started)            → finish
 *   ?token_hash=…&type=email   token-hash email template (any browser)    → finish
 *   ?error=…&error_code=…      the provider or the link said no           → /auth/start with the reason
 *   (nothing)                  default-template link: session in the #fragment (any browser)
 *                              → a page that POSTs it back here (lib/fragment-signin.ts)
 * finish: app flow → 302 navi://auth/callback?code=<single-use, 5 min>; web flow → cookie → /account.
 * Failures go back to /auth/start?error=<kind>, which explains what happened, offers the
 * 6-digit code, and links back to the app (navi://auth/callback?error=sign_in_failed).
 */
export async function GET(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const flow = flowFrom(url);
  const fail = (kind: SignInErrorKind) => redirectResponse(req, startPath(flow, { error: kind }), clearSupabaseCookies(req));

  const rl = await authIpLimiter.hit(clientIp(req));
  if (!rl.ok) return fail("rate_limited");

  const errorCode = url.searchParams.get("error_code");
  const error = url.searchParams.get("error");
  if (errorCode || error) {
    const description = url.searchParams.get("error_description") ?? "";
    return fail(classifyAuthError({ code: errorCode ?? error ?? "", message: description }, errorCode ? "link" : "oauth"));
  }

  const backend = getAuthBackend();
  if (!backend) return fail("unconfigured");

  const code = url.searchParams.get("code");
  const tokenHash = url.searchParams.get("token_hash");
  const type = url.searchParams.get("type") ?? "email";
  const jar = cookieJar(req);

  let tokens: SessionTokens;
  try {
    if (tokenHash) tokens = await backend.verifyTokenHash(tokenHash, type);
    else if (code) tokens = await backend.exchangeCode(code, jar);
    // Nothing in the query: the session (if any) is in the fragment, which only the page sees.
    else return fragmentFinishPage({ postTo: `${url.pathname}${url.search}`, errorTo: startPath(flow, { error: "expired" }) });
  } catch (e) {
    if (e instanceof SignInError) return fail(e.kind);
    console.error("[navi-cloud] /auth/callback failed:", (e as Error).message);
    return fail("failed");
  }

  try {
    const done = await finishSignIn(flow, tokens);
    return redirectResponse(req, done.location, [...clearSupabaseCookies(req), ...jar.setCookies, ...done.setCookies]);
  } catch (e) {
    console.error("[navi-cloud] /auth/callback finish failed:", (e as Error).message);
    return fail("failed");
  }
}

/**
 * POST /auth/callback — the fragment page's form: { access_token, refresh_token }.
 * Same origin only; the tokens are verified with the auth server, then the flow ends exactly
 * like the GET: app → single-use 5-minute code → navi://…, web → cookie → /account.
 */
export async function POST(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const flow = flowFrom(url);
  const fail = (kind: SignInErrorKind) => redirectResponse(req, startPath(flow, { error: kind }), clearSupabaseCookies(req), 303);

  const rl = await authIpLimiter.hit(clientIp(req));
  if (!rl.ok) return fail("rate_limited");

  let posted;
  try {
    posted = await readFragmentPost(req);
  } catch (e) {
    if (e instanceof HttpError) return new Response("Cross-site request refused.", { status: 403 });
    throw e;
  }
  if (!posted) return fail("expired");

  const backend = getAuthBackend();
  if (!backend) return fail("unconfigured");

  let tokens: SessionTokens;
  try {
    tokens = await backend.sessionFromFragment(posted.accessToken, posted.refreshToken);
  } catch (e) {
    if (e instanceof SignInError) return fail(e.kind);
    console.error("[navi-cloud] /auth/callback (fragment) failed:", (e as Error).message);
    return fail("failed");
  }

  try {
    const done = await finishSignIn(flow, tokens);
    return redirectResponse(req, done.location, [...clearSupabaseCookies(req), ...done.setCookies], 303);
  } catch (e) {
    console.error("[navi-cloud] /auth/callback (fragment) finish failed:", (e as Error).message);
    return fail("failed");
  }
}
