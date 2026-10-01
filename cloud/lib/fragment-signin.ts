/**
 * Sign-in links that work in any browser, with Supabase's default email template.
 *
 * Without custom SMTP the dashboard locks the templates, so the email carries
 * `{{ .ConfirmationURL }}` only. When the OTP was requested without a PKCE challenge, that
 * link verifies at Supabase and lands on our callback with the session in the URL
 * *fragment* (`#access_token=…&refresh_token=…`), which never reaches the server. The
 * callback answers such a bare GET with this tiny page: it strips the fragment from the
 * address bar and history first, then POSTs the two tokens (body, same origin) back to the
 * callback, which verifies them with Supabase before doing anything with them.
 *
 * The token_hash template (DEPLOY.md §3) and PKCE `?code=` keep working alongside; this
 * is only the fallback for a callback that arrives with neither.
 */

import { assertSameOrigin } from "./auth";

/** JSON for an inline <script>, safe against `</script>` and U+2028/2029. */
function inlineJson(v: unknown): string {
  return JSON.stringify(v).replace(/</g, "\\u003c").replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029");
}

/**
 * The page a bare callback GET returns.
 * - `postTo`: same-origin path the tokens are POSTed to (form submit, so the server's
 *   redirect + Set-Cookie behave like any navigation).
 * - `errorTo`: where to go when there is no fragment at all (a mangled or reused link).
 * A fragment carrying `error`/`error_code` is replayed as query parameters on this same
 * path, so the callback's existing error handling explains it.
 */
export function fragmentFinishPage(opts: { postTo: string; errorTo: string }): Response {
  const script = `(function(){
var h=location.hash.replace(/^#/,"");
history.replaceState(null,"",location.pathname+location.search);
var p=new URLSearchParams(h);
if(p.get("error")||p.get("error_code")){var q=new URLSearchParams(location.search);["error","error_code","error_description"].forEach(function(k){var v=p.get(k);if(v)q.set(k,v)});location.replace(location.pathname+"?"+q.toString());return}
var a=p.get("access_token"),r=p.get("refresh_token");
if(!a||!r){location.replace(${inlineJson(opts.errorTo)});return}
var f=document.createElement("form");f.method="POST";f.action=${inlineJson(opts.postTo)};
[["access_token",a],["refresh_token",r]].forEach(function(kv){var i=document.createElement("input");i.type="hidden";i.name=kv[0];i.value=kv[1];f.appendChild(i)});
document.body.appendChild(f);f.submit();
})();`;
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><title>Signing in · Navi</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#0b0b0d;color:#e8e8ea}p{opacity:.7}</style></head>
<body><p>Signing you in…</p><noscript><p>Turn on JavaScript to finish signing in, or use the 6-digit code instead.</p></noscript><script>${script}</script></body></html>`;
  return new Response(html, {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "referrer-policy": "no-referrer",
    },
  });
}

export interface FragmentTokens {
  accessToken: string;
  refreshToken: string;
}

/**
 * The tokens the finish page POSTed. Same-origin only (a cross-site form can't sign a
 * visitor in to someone else's account); null when the body isn't the page's form.
 */
export async function readFragmentPost(req: Request): Promise<FragmentTokens | null> {
  assertSameOrigin(req);
  const type = req.headers.get("content-type") ?? "";
  if (!type.includes("application/x-www-form-urlencoded") && !type.includes("multipart/form-data")) return null;
  const form = await req.formData().catch(() => null);
  const accessToken = form?.get("access_token");
  const refreshToken = form?.get("refresh_token");
  if (typeof accessToken !== "string" || typeof refreshToken !== "string") return null;
  if (accessToken.length < 20 || accessToken.length > 8192 || refreshToken.length < 8 || refreshToken.length > 4096) return null;
  return { accessToken, refreshToken };
}
