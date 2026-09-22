import { env } from "@/lib/env";
import { SignInForm } from "./sign-in-form";

export const dynamic = "force-dynamic";

/**
 * GET /auth/start?redirect=navi — the hosted sign-in page the app opens in the
 * user's browser. Magic link, plus Google when configured in Supabase. After
 * Supabase redirects back to /auth/callback we hand off to navi://auth/callback.
 */
export default async function AuthStart({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const params = await searchParams;
  const redirect = typeof params.redirect === "string" ? params.redirect : "navi";
  const callbackUrl = `${env.baseUrl}/auth/callback?redirect=${encodeURIComponent(redirect)}`;
  const configured = env.dbDriver === "supabase" && Boolean(env.supabaseUrl && env.supabaseAnonKey);

  return (
    <main style={{ maxWidth: 400, margin: "16vh auto 0", padding: "0 24px" }}>
      <div style={{ fontSize: 13, letterSpacing: 2, textTransform: "uppercase", color: "#7c7c86" }}>✦ Navi</div>
      <h1 style={{ fontSize: 28, fontWeight: 600, letterSpacing: -0.5, margin: "10px 0 6px" }}>Sign in to Navi</h1>
      <p style={{ color: "#9a9aa3", margin: "0 0 28px", lineHeight: 1.5 }}>
        Enter your email and we&apos;ll send a link. Nothing else to remember.
      </p>
      {configured ? (
        <SignInForm supabaseUrl={env.supabaseUrl!} anonKey={env.supabaseAnonKey!} callbackUrl={callbackUrl} googleEnabled={env.googleConfigured} />
      ) : (
        <p style={{ color: "#e0a458", background: "#1a160f", border: "1px solid #3b2f16", padding: "12px 14px", borderRadius: 10, lineHeight: 1.5 }}>
          Sign-in isn&apos;t configured on this instance (no Supabase project). In development use <code>POST /auth/dev-login</code>.
        </p>
      )}
      <p style={{ color: "#5c5c66", fontSize: 12, marginTop: 40 }}>
        You&apos;ll be sent back to the Navi app when you&apos;re done.
      </p>
    </main>
  );
}
