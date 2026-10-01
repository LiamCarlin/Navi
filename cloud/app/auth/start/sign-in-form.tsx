"use client";

import { useEffect, useRef, useState, type FormEvent } from "react";

type Flow = "navi" | "account";
type Provider = "google" | "apple";
interface Notice { kind: string; title: string; message: string }

interface Props {
  flow: Flow;
  /** False when this server has no sign-in configured (no Supabase, not dev). */
  enabled: boolean;
  /** Dev server without a mail service: the code is printed in the server log. */
  memoryMode: boolean;
  providers: Provider[];
  devLogin: boolean;
  initialEmail: string;
  initialError: Notice | null;
  signedOut: boolean;
}

type Step =
  | { name: "email" }
  | { name: "code"; email: string }
  | { name: "done"; redirect: string };

const RESEND_SECONDS = 30;

async function post(path: string, body: unknown): Promise<{ ok: boolean; status: number; data: Record<string, unknown> }> {
  try {
    const res = await fetch(path, {
      method: "POST",
      headers: { "content-type": "application/json" },
      credentials: "same-origin",
      body: JSON.stringify(body),
    });
    const data = (await res.json().catch(() => ({}))) as Record<string, unknown>;
    return { ok: res.ok, status: res.status, data };
  } catch {
    return { ok: false, status: 0, data: { error: "network", message: "You appear to be offline. Check your connection and try again." } };
  }
}

function noticeFrom(data: Record<string, unknown>, fallbackTitle: string): Notice {
  const kind = typeof data.error === "string" ? data.error : "failed";
  const message = typeof data.message === "string" ? data.message : "Something went wrong. Try again.";
  const titles: Record<string, string> = {
    invalid_code: "That code didn’t work",
    invalid_email: "Check your email address",
    rate_limited: "Too many attempts",
    signups_closed: "Sign-ups are closed",
    unconfigured: "Sign-in is unavailable",
    network: "No connection",
  };
  return { kind, title: titles[kind] ?? fallbackTitle, message };
}

export function SignInForm({ flow, enabled, memoryMode, providers, devLogin, initialEmail, initialError, signedOut }: Props) {
  const [step, setStep] = useState<Step>({ name: "email" });
  const [email, setEmail] = useState(initialEmail);
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState<null | "send" | "verify" | "dev">(null);
  const [notice, setNotice] = useState<Notice | null>(initialError);
  const [info, setInfo] = useState<string | null>(signedOut ? "You’re signed out." : null);
  const [resendIn, setResendIn] = useState(0);
  const codeRef = useRef<HTMLInputElement>(null);

  // Links that fail in the implicit flow report the reason in the URL fragment, which the
  // server never sees: turn it into ?error= so the page explains it.
  useEffect(() => {
    const h = new URLSearchParams(window.location.hash.slice(1));
    const code = h.get("error_code") ?? h.get("error");
    if (!code) return;
    const kind = code === "otp_expired" || /expired|invalid/i.test(h.get("error_description") ?? "") ? "expired" : code === "access_denied" ? "cancelled" : "failed";
    const q = new URLSearchParams(window.location.search);
    q.set("error", kind);
    window.location.replace(`${window.location.pathname}?${q.toString()}`);
  }, []);

  useEffect(() => {
    if (resendIn <= 0) return;
    const t = setTimeout(() => setResendIn((s) => s - 1), 1000);
    return () => clearTimeout(t);
  }, [resendIn]);

  useEffect(() => {
    if (step.name === "code") codeRef.current?.focus();
  }, [step.name]);

  async function send(target: string) {
    setBusy("send");
    setNotice(null);
    setInfo(null);
    const r = await post("/auth/otp", { email: target, redirect: flow });
    setBusy(null);
    if (!r.ok) {
      setNotice(noticeFrom(r.data, "Couldn’t send the email"));
      return false;
    }
    setResendIn(RESEND_SECONDS);
    return true;
  }

  async function onEmail(e: FormEvent) {
    e.preventDefault();
    const target = email.trim();
    if (!target) return;
    if (await send(target)) {
      setCode("");
      setStep({ name: "code", email: target });
    }
  }

  function finish(redirect: string) {
    if (flow === "account" || redirect.startsWith("/")) {
      window.location.assign(redirect);
      return;
    }
    setStep({ name: "done", redirect });
    window.location.href = redirect; // hands the one-time code to the app
  }

  async function onCode(e: FormEvent) {
    e.preventDefault();
    if (step.name !== "code") return;
    setBusy("verify");
    setNotice(null);
    const r = await post("/auth/verify", { email: step.email, code, redirect: flow });
    setBusy(null);
    if (!r.ok || typeof r.data.redirect !== "string") {
      setNotice(noticeFrom(r.data, "That code didn’t work"));
      setCode("");
      codeRef.current?.focus();
      return;
    }
    finish(r.data.redirect);
  }

  const appBack = `navi://auth/callback?${new URLSearchParams({ error: "sign_in_failed", message: notice?.title ?? "Sign-in cancelled" }).toString()}`;

  if (!enabled && !devLogin) {
    return (
      <div className="nv-banner nv-banner-warn" role="status">
        <strong>Sign-in is unavailable</strong>
        Sign-in isn’t set up on this server yet. Try again later.
      </div>
    );
  }

  if (step.name === "done") {
    return (
      <div className="nv-stack">
        <div className="nv-banner nv-banner-ok" role="status">
          <strong>You’re signed in</strong>
          Navi should open by itself. If your browser asks, choose “Open Navi”.
        </div>
        <a className="nv-btn nv-btn-primary nv-btn-block" href={step.redirect}>
          Open Navi
        </a>
        <p className="nv-dim" style={{ textAlign: "center", margin: 0 }}>
          You can close this tab.
        </p>
      </div>
    );
  }

  return (
    <div className="nv-stack">
      {notice && (
        <div className="nv-banner nv-banner-bad" role="alert">
          <strong>{notice.title}</strong>
          {notice.message}
          {flow === "navi" && notice.kind !== "rate_limited" && (
            <div style={{ marginTop: 8 }}>
              <a className="nv-link" href={appBack}>
                Back to Navi
              </a>
            </div>
          )}
        </div>
      )}
      {info && !notice && (
        <div className="nv-banner nv-banner-info" role="status">
          {info}
        </div>
      )}

      {enabled && step.name === "email" && (
        <>
          <form onSubmit={onEmail} className="nv-stack" noValidate>
            <div>
              <label className="nv-label" htmlFor="email">
                Email
              </label>
              <input
                id="email"
                className="nv-input"
                type="email"
                name="email"
                autoComplete="email"
                inputMode="email"
                autoFocus
                required
                placeholder="you@example.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                disabled={busy !== null}
              />
            </div>
            <button className="nv-btn nv-btn-primary nv-btn-block" type="submit" disabled={busy !== null || !email.trim()}>
              {busy === "send" ? <span className="nv-spinner" aria-hidden="true" /> : null}
              {busy === "send" ? "Sending…" : "Continue with email"}
            </button>
            <p className="nv-dim" style={{ textAlign: "center", margin: 0 }}>
              <button
                type="button"
                className="nv-link"
                disabled={busy !== null}
                onClick={() => {
                  const target = email.trim();
                  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(target)) {
                    setNotice({ kind: "invalid_email", title: "Enter your email first", message: "Type the address the code was sent to, then choose “I have a code”." });
                    return;
                  }
                  setNotice(null);
                  setInfo(null);
                  setCode("");
                  setStep({ name: "code", email: target });
                }}
              >
                I have a code
              </button>
            </p>
          </form>

          {providers.length > 0 && (
            <>
              <div className="nv-divider">or</div>
              {providers.includes("apple") && (
                <a className="nv-btn nv-btn-secondary nv-btn-block" href={`/auth/oauth?provider=apple&redirect=${flow}`}>
                  <AppleIcon /> Continue with Apple
                </a>
              )}
              {providers.includes("google") && (
                <a className="nv-btn nv-btn-secondary nv-btn-block" href={`/auth/oauth?provider=google&redirect=${flow}`}>
                  <GoogleIcon /> Continue with Google
                </a>
              )}
            </>
          )}
        </>
      )}

      {step.name === "code" && (
        <form onSubmit={onCode} className="nv-stack" noValidate>
          <div className="nv-banner nv-banner-info" role="status" style={{ marginBottom: 0 }}>
            <strong>Check your inbox</strong>
            We sent a sign-in link and a 6-digit code to <span style={{ color: "var(--nv-fg)" }}>{step.email}</span>.
            {flow === "navi" ? " Open the link on this Mac, or type the code here." : " Open the link, or type the code here."}
            {memoryMode && <div className="nv-dim" style={{ marginTop: 6 }}>Dev server: the code is in the server log.</div>}
          </div>
          <div>
            <label className="nv-label" htmlFor="code">
              6-digit code
            </label>
            <input
              id="code"
              ref={codeRef}
              className="nv-input nv-code"
              name="code"
              inputMode="numeric"
              autoComplete="one-time-code"
              pattern="[0-9]*"
              maxLength={10}
              placeholder="000000"
              value={code}
              onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
              disabled={busy !== null}
            />
          </div>
          <button className="nv-btn nv-btn-primary nv-btn-block" type="submit" disabled={busy !== null || code.length < 6}>
            {busy === "verify" ? <span className="nv-spinner" aria-hidden="true" /> : null}
            {busy === "verify" ? "Signing in…" : "Sign in"}
          </button>
          <div className="nv-row" style={{ justifyContent: "space-between" }}>
            <button
              type="button"
              className="nv-link"
              disabled={busy !== null || resendIn > 0}
              onClick={async () => {
                if (await send(step.email)) setInfo("We sent a new email. Use the newest one.");
              }}
            >
              {resendIn > 0 ? `Resend in ${resendIn}s` : "Send a new email"}
            </button>
            <button
              type="button"
              className="nv-link"
              onClick={() => {
                setStep({ name: "email" });
                setNotice(null);
                setInfo(null);
              }}
            >
              Use a different email
            </button>
          </div>
        </form>
      )}

      {devLogin && step.name === "email" && <DevLogin flow={flow} defaultEmail={email} onDone={finish} onError={setNotice} />}
    </div>
  );
}

/** Development only (DEV_LOGIN_SECRET set, never on production): skip email entirely. */
function DevLogin({ flow, defaultEmail, onDone, onError }: { flow: Flow; defaultEmail: string; onDone: (r: string) => void; onError: (n: Notice) => void }) {
  const [open, setOpen] = useState(false);
  const [email, setEmail] = useState(defaultEmail || "dev@navi.local");
  const [secret, setSecret] = useState("");
  const [busy, setBusy] = useState(false);
  if (!open) {
    return (
      <p className="nv-dim" style={{ textAlign: "center", margin: "8px 0 0" }}>
        <button type="button" className="nv-link" onClick={() => setOpen(true)}>
          Developer sign-in
        </button>
      </p>
    );
  }
  return (
    <form
      className="nv-card nv-stack"
      style={{ marginTop: 8 }}
      onSubmit={async (e) => {
        e.preventDefault();
        setBusy(true);
        try {
          const res = await fetch("/auth/dev-login", {
            method: "POST",
            headers: { "content-type": "application/json", "x-dev-login-secret": secret },
            credentials: "same-origin",
            body: JSON.stringify({ email, redirect: flow }),
          });
          const data = (await res.json().catch(() => ({}))) as Record<string, unknown>;
          if (res.ok && typeof data.redirect === "string") onDone(data.redirect);
          else onError({ kind: "failed", title: "Developer sign-in failed", message: String(data.message ?? res.status) });
        } finally {
          setBusy(false);
        }
      }}
    >
      <div className="nv-dim">Development server only — signs in without email.</div>
      <input className="nv-input" aria-label="Email" value={email} onChange={(e) => setEmail(e.target.value)} />
      <input className="nv-input" aria-label="Dev login secret" type="password" placeholder="DEV_LOGIN_SECRET" value={secret} onChange={(e) => setSecret(e.target.value)} />
      <button className="nv-btn nv-btn-secondary nv-btn-block" type="submit" disabled={busy || !secret}>
        {busy ? "Signing in…" : "Sign in (dev)"}
      </button>
    </form>
  );
}

function AppleIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" fill="currentColor">
      <path d="M16.37 12.73c-.02-2.2 1.8-3.26 1.88-3.31-1.03-1.5-2.62-1.71-3.18-1.73-1.35-.14-2.64.8-3.33.8-.69 0-1.74-.78-2.86-.76-1.47.02-2.83.86-3.59 2.17-1.53 2.66-.39 6.59 1.1 8.75.73 1.05 1.6 2.24 2.73 2.2 1.1-.04 1.51-.71 2.84-.71 1.32 0 1.7.71 2.86.69 1.18-.02 1.93-1.07 2.65-2.13.84-1.22 1.18-2.4 1.2-2.46-.03-.01-2.3-.88-2.3-3.51zM14.2 6.27c.6-.73 1.01-1.75.9-2.77-.87.04-1.92.58-2.54 1.31-.56.65-1.05 1.69-.92 2.69.97.08 1.96-.49 2.56-1.23z" />
    </svg>
  );
}

function GoogleIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path fill="#EA4335" d="M12 10.2v3.9h5.5c-.24 1.26-.97 2.33-2.06 3.05l3.33 2.58c1.94-1.79 3.06-4.42 3.06-7.55 0-.72-.06-1.42-.19-2.09H12z" />
      <path fill="#34A853" d="M5.84 14.29l-.75.57-2.66 2.07C4.12 20.27 7.8 22.5 12 22.5c2.84 0 5.22-.94 6.96-2.53l-3.33-2.58c-.92.62-2.1.99-3.63.99-2.79 0-5.15-1.88-6-4.41z" />
      <path fill="#4A90E2" d="M2.43 7.07A10.43 10.43 0 0 0 1.5 12c0 1.77.43 3.45 1.18 4.93l3.41-2.64A6.3 6.3 0 0 1 5.76 12c0-.79.14-1.56.38-2.29z" />
      <path fill="#FBBC05" d="M12 5.29c1.54 0 2.92.53 4.01 1.57l2.98-2.98C17.21 2.21 14.83 1.5 12 1.5 7.8 1.5 4.12 3.73 2.43 7.07l3.71 2.86C6.99 7.17 9.3 5.29 12 5.29z" />
    </svg>
  );
}
