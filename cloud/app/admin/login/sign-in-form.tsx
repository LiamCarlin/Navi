"use client";

import { createBrowserClient } from "@supabase/ssr";
import { useMemo, useState, type FormEvent } from "react";
import s from "../admin.module.css";

interface Props {
  supabaseUrl: string;
  anonKey: string;
  callbackUrl: string;
  googleEnabled: boolean;
}

/** Supabase magic link / Google for the console; lands on /admin/auth/callback (PKCE). */
export function AdminSignInForm({ supabaseUrl, anonKey, callbackUrl, googleEnabled }: Props) {
  const supabase = useMemo(() => createBrowserClient(supabaseUrl, anonKey), [supabaseUrl, anonKey]);
  const [email, setEmail] = useState("");
  const [state, setState] = useState<"idle" | "busy" | "sent" | { error: string }>("idle");

  async function sendLink(e: FormEvent) {
    e.preventDefault();
    setState("busy");
    const { error } = await supabase.auth.signInWithOtp({ email: email.trim(), options: { emailRedirectTo: callbackUrl } });
    setState(error ? { error: error.message } : "sent");
  }

  async function google() {
    setState("busy");
    const { error } = await supabase.auth.signInWithOAuth({ provider: "google", options: { redirectTo: callbackUrl } });
    if (error) setState({ error: error.message });
  }

  if (state === "sent") {
    return <div className={s.flashOk}>Check your email — the link signs you in to the console.</div>;
  }

  return (
    <form onSubmit={sendLink} style={{ display: "grid", gap: 10 }}>
      <input className={s.input} type="email" autoComplete="email" required autoFocus placeholder="you@navi.app" value={email} onChange={(e) => setEmail(e.target.value)} disabled={state === "busy"} />
      <button className={s.btnPrimary} type="submit" disabled={state === "busy" || !email}>{state === "busy" ? "Sending…" : "Email me a link"}</button>
      {googleEnabled && (
        <button className={s.btn} type="button" onClick={google} disabled={state === "busy"}>Continue with Google</button>
      )}
      {typeof state === "object" && <div className={s.flashErr}>{state.error}</div>}
    </form>
  );
}
