import { getAuthBackend, OAUTH_PROVIDERS, SignInError, type OAuthProvider } from "@/lib/auth-backend";
import { clientIp } from "@/lib/http";
import { authIpLimiter } from "@/lib/ratelimit";
import { callbackUrl, cookieJar, parseFlow, redirectResponse, startPath } from "@/lib/signin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * GET /auth/oauth?provider=google|github|apple&redirect=navi|account
 * → 302 to the provider's consent page (PKCE verifier cookie set here) → … → /auth/callback.
 * Providers are switched on in the Supabase dashboard (see DEPLOY.md).
 */
export async function GET(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const flow = parseFlow(url.searchParams.get("redirect"));
  try {
    const rl = await authIpLimiter.hit(clientIp(req));
    if (!rl.ok) throw new SignInError("rate_limited");
    const provider = url.searchParams.get("provider") as OAuthProvider;
    if (!OAUTH_PROVIDERS.includes(provider)) throw new SignInError("provider");
    const backend = getAuthBackend();
    if (!backend) throw new SignInError("unconfigured");
    if (!(await backend.providers()).includes(provider)) throw new SignInError("provider");
    const jar = cookieJar(req);
    const target = await backend.oauthUrl(provider, callbackUrl(flow), jar);
    return redirectResponse(req, target, jar.setCookies);
  } catch (e) {
    const kind = e instanceof SignInError ? e.kind : "failed";
    if (!(e instanceof SignInError)) console.error("[navi-cloud] /auth/oauth failed:", (e as Error).message);
    return redirectResponse(req, startPath(flow, { error: kind }));
  }
}
