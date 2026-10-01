"use client";

import { createBrowserClient } from "@supabase/ssr";
import { useMemo, useState, type FormEvent } from "react";
import s from "../admin.module.css";

interface Props {
  supabaseUrl: string;
  anonKey: string;
  callbackUrl: string;
  /** "Continue with …" buttons: the providers switched on in Supabase. */
  providers: ("google" | "github")[];
}

/** Magic link (sent by the server, any browser) or Google (PKCE, same browser) for the console; both land on /admin/auth/callback. */
export function AdminSignInForm({ supabaseUrl, anonKey, callbackUrl, providers }: Props) {
  const supabase = useMemo(() => createBrowserClient(supabaseUrl, anonKey), [supabaseUrl, anonKey]);
  const [email, setEmail] = useState("");
  const [state, setState] = useState<"idle" | "busy" | "sent" | { error: string }>("idle");

  /** Sent by the server without PKCE, so the link works in whichever browser opens the email. */
  async function sendLink(e: FormEvent) {
    e.preventDefault();
    setState("busy");
    try {
      const res = await fetch("/admin/auth/email", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ email: email.trim() }),
      });
      if (res.ok) return setState("sent");
      const body = (await res.json().catch(() => ({}))) as { message?: string };
      setState({ error: body.message ?? "Couldn’t send the email. Try again." });
    } catch {
      setState({ error: "Couldn’t reach the server. Try again." });
    }
  }

  /** OAuth (PKCE) starts and finishes in this browser, so the verifier cookie is always there. */
  async function oauth(provider: "google" | "github") {
    setState("busy");
    const { error } = await supabase.auth.signInWithOAuth({ provider, options: { redirectTo: callbackUrl } });
    if (error) setState({ error: error.message });
  }

  if (state === "sent") {
    return <div className={s.flashOk}>If that address is an admin, a sign-in link is on its way. It works in any browser.</div>;
  }

  return (
    <form onSubmit={sendLink} style={{ display: "grid", gap: 10 }}>
      <input className={s.input} type="email" autoComplete="email" required autoFocus placeholder="you@buildnavi.com" value={email} onChange={(e) => setEmail(e.target.value)} disabled={state === "busy"} />
      <button className={s.btnPrimary} type="submit" disabled={state === "busy" || !email}>{state === "busy" ? "Sending…" : "Email me a link"}</button>
      {providers.includes("google") && (
        <button className={s.btn} type="button" onClick={() => oauth("google")} disabled={state === "busy"}>Continue with Google</button>
      )}
      {providers.includes("github") && (
        <button className={s.btn} type="button" onClick={() => oauth("github")} disabled={state === "busy"}>Continue with GitHub</button>
      )}
      {typeof state === "object" && <div className={s.flashErr}>{state.error}</div>}
    </form>
  );
}
