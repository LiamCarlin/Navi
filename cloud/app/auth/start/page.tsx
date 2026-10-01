import { getAuthBackend, isSignInErrorKind, SIGN_IN_ERRORS, type OAuthProvider } from "@/lib/auth-backend";
import { env } from "@/lib/env";
import { normalizeEmail, parseFlow } from "@/lib/signin";
import { Foot, Shell } from "../ui";
import { SignInForm } from "./sign-in-form";

export const dynamic = "force-dynamic";

type Search = Record<string, string | string[] | undefined>;
const one = (v: string | string[] | undefined) => (typeof v === "string" ? v : undefined);

/**
 * GET /auth/start?redirect=navi|account[&error=<kind>][&email=]
 * The hosted sign-in page. Email (one message with a magic link and a 6-digit code), plus
 * "Continue with Google / GitHub / Apple" when those providers are switched on. `redirect=navi` (the
 * default, §3.1) ends in navi://auth/callback?code=…; `redirect=account` ends on /account.
 */
export default async function AuthStart({ searchParams }: { searchParams: Promise<Search> }) {
  const params = await searchParams;
  const flow = parseFlow(one(params.redirect));
  const errorKind = one(params.error);
  const error = isSignInErrorKind(errorKind) ? { kind: errorKind, ...SIGN_IN_ERRORS[errorKind] } : null;

  const backend = getAuthBackend();
  let providers: OAuthProvider[] = [];
  try {
    providers = backend ? await backend.providers() : [];
  } catch {
    providers = [];
  }
  const devLogin = Boolean(env.devLoginSecret) && !env.isProduction;

  const title = flow === "account" ? "Sign in to your account" : "Sign in to Navi";
  const lede =
    flow === "account"
      ? "Manage your plan, download Navi, export or delete your data."
      : "Enter your email. We’ll send a link and a code — no password to remember.";

  return (
    <Shell>
      <main className="nv-narrow">
        <h1 className="nv-h1">{title}</h1>
        <p className="nv-lede">{lede}</p>
        <SignInForm
          flow={flow}
          enabled={backend !== null}
          memoryMode={backend?.kind === "memory"}
          providers={providers}
          devLogin={devLogin}
          initialEmail={normalizeEmail(one(params.email)) ?? ""}
          initialError={error ? { kind: error.kind, title: error.title, message: error.message } : null}
          signedOut={one(params.signed_out) === "1"}
        />
        <Foot />
      </main>
    </Shell>
  );
}
