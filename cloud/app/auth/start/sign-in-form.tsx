"use client";

import { createBrowserClient } from "@supabase/ssr";
import { useMemo, useState, type CSSProperties, type FormEvent } from "react";

interface Props {
  supabaseUrl: string;
  anonKey: string;
  callbackUrl: string;
  googleEnabled: boolean;
}

const input: CSSProperties = {
  width: "100%",
  boxSizing: "border-box",
  padding: "12px 14px",
  fontSize: 16,
  borderRadius: 10,
  border: "1px solid #2a2a30",
  background: "#141418",
  color: "#f2f2f4",
  outline: "none",
};

const button: CSSProperties = {
  width: "100%",
  padding: "12px 14px",
  fontSize: 15,
  fontWeight: 600,
  borderRadius: 10,
  border: "1px solid #2a2a30",
  background: "#f2f2f4",
  color: "#0b0b0d",
  cursor: "pointer",
};

export function SignInForm({ supabaseUrl, anonKey, callbackUrl, googleEnabled }: Props) {
  // PKCE: the code verifier is stored in a cookie by @supabase/ssr, so the
  // server-side /auth/callback can finish the exchange.
  const supabase = useMemo(() => createBrowserClient(supabaseUrl, anonKey), [supabaseUrl, anonKey]);
  const [email, setEmail] = useState("");
  const [state, setState] = useState<{ kind: "idle" } | { kind: "busy" } | { kind: "sent" } | { kind: "error"; message: string }>({ kind: "idle" });

  async function sendLink(e: FormEvent) {
    e.preventDefault();
    setState({ kind: "busy" });
    const { error } = await supabase.auth.signInWithOtp({ email: email.trim(), options: { emailRedirectTo: callbackUrl } });
    setState(error ? { kind: "error", message: error.message } : { kind: "sent" });
  }

  async function google() {
    setState({ kind: "busy" });
    const { error } = await supabase.auth.signInWithOAuth({ provider: "google", options: { redirectTo: callbackUrl } });
    if (error) setState({ kind: "error", message: error.message });
  }

  if (state.kind === "sent") {
    return (
      <div style={{ background: "#121a14", border: "1px solid #1f3a27", padding: "14px 16px", borderRadius: 10, lineHeight: 1.5 }}>
        <strong>Check your email.</strong>
        <div style={{ color: "#9a9aa3" }}>We sent a sign-in link to {email}. Open it on this Mac and you&apos;ll land back in Navi.</div>
      </div>
    );
  }

  return (
    <form onSubmit={sendLink} style={{ display: "grid", gap: 12 }}>
      <input
        style={input}
        type="email"
        name="email"
        autoComplete="email"
        autoFocus
        required
        placeholder="you@example.com"
        value={email}
        onChange={(e) => setEmail(e.target.value)}
        disabled={state.kind === "busy"}
      />
      <button style={button} type="submit" disabled={state.kind === "busy" || !email}>
        {state.kind === "busy" ? "Sending…" : "Email me a link"}
      </button>
      {googleEnabled && (
        <button
          type="button"
          onClick={google}
          disabled={state.kind === "busy"}
          style={{ ...button, background: "transparent", color: "#f2f2f4" }}
        >
          Continue with Google
        </button>
      )}
      {state.kind === "error" && (
        <div style={{ color: "#f0868a", fontSize: 14 }}>{state.message}</div>
      )}
    </form>
  );
}
