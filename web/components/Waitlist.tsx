"use client";

import { useState, type FormEvent } from "react";
import { Reveal } from "./Reveal";
import { Glyph } from "./Glyph";

type State = { kind: "idle" } | { kind: "busy" } | { kind: "done" } | { kind: "error"; message: string };

export function Waitlist() {
  const [state, setState] = useState<State>({ kind: "idle" });
  const [email, setEmail] = useState("");
  const [note, setNote] = useState("");

  async function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (state.kind === "busy") return;
    setState({ kind: "busy" });
    try {
      const res = await fetch("/api/waitlist", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email, note, source: "site" }),
      });
      const data = (await res.json().catch(() => ({}))) as { error?: string };
      if (res.status === 201 || res.status === 200) {
        setState({ kind: "done" });
      } else {
        setState({ kind: "error", message: data.error ?? "Something went wrong. Try again." });
      }
    } catch {
      setState({ kind: "error", message: "Couldn't reach the server. Try again." });
    }
  }

  return (
    <section id="waitlist" className="scroll-mt-20 px-4 py-20 sm:px-6 md:py-28">
      <Reveal>
        <div className="card gradient-border relative mx-auto max-w-3xl overflow-hidden p-8 text-center sm:p-12">
          <div className="pointer-events-none absolute inset-0 -z-10 bg-[radial-gradient(60%_80%_at_50%_0%,rgba(139,140,248,0.18),transparent_70%)]" />
          <Glyph className="mx-auto mb-5 h-8 w-8 text-accent" />
          <h2 className="text-balance text-3xl font-semibold tracking-tight sm:text-4xl">Get Navi first.</h2>
          <p className="mx-auto mt-3 max-w-md text-fg-muted">
            Invites go out in order. Tell us what you’d use it for and we’ll move you up.
          </p>

          {state.kind === "done" ? (
            <div
              role="status"
              className="mx-auto mt-8 max-w-md rounded-2xl border border-accent/40 bg-accent-soft px-6 py-5 text-fg"
            >
              <div className="text-lg font-medium">You’re on the list.</div>
              <div className="mt-1 text-sm text-fg-muted">We’ll email you in order.</div>
            </div>
          ) : (
            <form onSubmit={submit} className="mx-auto mt-8 flex max-w-md flex-col gap-3 text-left">
              <label className="sr-only" htmlFor="wl-email">
                Email
              </label>
              <input
                id="wl-email"
                name="email"
                type="email"
                required
                autoComplete="email"
                placeholder="you@example.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="w-full rounded-xl border border-line-strong bg-bg/70 px-4 py-3 text-base text-fg outline-none transition-colors placeholder:text-fg-dim focus:border-accent"
              />
              <label className="sr-only" htmlFor="wl-note">
                What would you use it for?
              </label>
              <textarea
                id="wl-note"
                name="note"
                rows={2}
                maxLength={500}
                placeholder="What would you use it for? (optional)"
                value={note}
                onChange={(e) => setNote(e.target.value)}
                className="w-full resize-none rounded-xl border border-line-strong bg-bg/70 px-4 py-3 text-base text-fg outline-none transition-colors placeholder:text-fg-dim focus:border-accent"
              />
              <button
                type="submit"
                disabled={state.kind === "busy"}
                className="mt-1 rounded-full bg-fg px-6 py-3 text-sm font-medium text-bg transition-transform hover:scale-[1.02] active:scale-[0.98] disabled:opacity-60"
              >
                {state.kind === "busy" ? "Adding you…" : "Join the waitlist"}
              </button>
              {state.kind === "error" && (
                <p role="alert" className="text-sm text-rose-400">
                  {state.message}
                </p>
              )}
              <p className="text-center text-xs text-fg-dim">No spam. One email when it’s your turn.</p>
            </form>
          )}
        </div>
      </Reveal>
    </section>
  );
}
