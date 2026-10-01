import { redirect } from "next/navigation";
import { currentAdmin } from "@/lib/admin/guard";
import { getAuthBackend, type OAuthProvider } from "@/lib/auth-backend";
import { env } from "@/lib/env";
import s from "../admin.module.css";
import { AdminSignInForm } from "./sign-in-form";

export const dynamic = "force-dynamic";

/**
 * /admin/login — the only /admin URL that renders for a visitor who isn't a signed-in
 * admin. Supabase magic link / Google when configured; the DEV_LOGIN_SECRET dev login
 * when that is set (development only).
 */
export default async function AdminLogin({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  if (await currentAdmin()) redirect("/admin");
  const params = await searchParams;
  const error = typeof params.error === "string" ? params.error : null;
  const supabase = env.dbDriver === "supabase" && Boolean(env.supabaseUrl && env.supabaseAnonKey);
  const dev = Boolean(env.devLoginSecret);
  // Same switch as /auth/start: whichever providers are on in Supabase (Apple stays app-only here).
  let providers: Exclude<OAuthProvider, "apple">[] = [];
  try {
    providers = supabase ? ((await getAuthBackend()?.providers()) ?? []).filter((p): p is Exclude<OAuthProvider, "apple"> => p !== "apple") : [];
  } catch {
    providers = [];
  }

  return (
    <main className={s.login}>
      <div className={s.muted} style={{ fontSize: 12, letterSpacing: 2, textTransform: "uppercase" }}>✦ Navi</div>
      <h1 className={s.h1} style={{ fontSize: 24, margin: "8px 0 6px" }}>Admin console</h1>
      <p className={s.sub}>Sign in with an admin account.</p>
      {error && <div className={s.flashErr}>{error}</div>}
      {supabase && (
        <AdminSignInForm
          supabaseUrl={env.supabaseUrl!}
          anonKey={env.supabaseAnonKey!}
          callbackUrl={`${env.baseUrl}/admin/auth/callback`}
          providers={providers}
        />
      )}
      {dev && (
        <form method="post" action="/admin/auth/dev" className={s.card} style={{ marginTop: 16, display: "grid", gap: 10 }}>
          <div className={s.h2} style={{ margin: 0 }}>Dev login <span className={s.badgeWarn}>DEV_LOGIN_SECRET</span></div>
          <input className={s.input} type="email" name="email" placeholder="admin email" required autoComplete="email" />
          <input className={s.input} type="password" name="secret" placeholder="dev login secret" required autoComplete="off" />
          <button className={s.btnPrimary} type="submit">Sign in</button>
        </form>
      )}
      {!supabase && !dev && (
        <div className={s.banner}>No sign-in method is configured on this instance (no Supabase project, no DEV_LOGIN_SECRET).</div>
      )}
    </main>
  );
}
