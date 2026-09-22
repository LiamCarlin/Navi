"use client";

import { useState, type FormEvent } from "react";
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
    <section id="waitlist" className="scroll-mt-16 px-6 py-24 md:py-32">
      <div className="mx-auto grid max-w-6xl grid-cols-1 gap-8 border-t border-line pt-12 lg:grid-cols-12">
        <div className="lg:col-span-5">
          <Glyph className="mb-5 h-6 w-6 text-accent" />
          <h2 className="h-section">Get Navi first.</h2>
          <p className="lede mt-5">Invites go out in order. Tell us what you’d use it for and we’ll move you up.</p>
        </div>
        <div className="lg:col-span-6 lg:col-start-7">

          {state.kind === "done" ? (
            <div
              role="status"
              className="rounded-[12px] border border-line bg-bg-elev px-6 py-5 text-fg"
            >
              <div className="text-lg font-medium">You’re on the list.</div>
              <div className="mt-1 text-sm text-fg-muted">We’ll email you in order.</div>
            </div>
          ) : (
            <form onSubmit={submit} className="flex flex-col gap-3">
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
                className="w-full rounded-[12px] border border-line-strong bg-bg-elev px-4 py-3 text-base text-fg outline-none transition-colors duration-150 placeholder:text-fg-dim focus:border-accent focus-visible:outline-none"
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
                className="w-full resize-none rounded-[12px] border border-line-strong bg-bg-elev px-4 py-3 text-base text-fg outline-none transition-colors duration-150 placeholder:text-fg-dim focus:border-accent focus-visible:outline-none"
              />
              <button
                type="submit"
                disabled={state.kind === "busy"}
                className="btn-primary mt-1 sm:self-start"
              >
                {state.kind === "busy" ? "Adding you…" : "Join the waitlist"}
              </button>
              {state.kind === "error" && (
                <p role="alert" className="text-sm text-[#e5484d]">
                  {state.message}
                </p>
              )}
              <p className="text-xs text-fg-dim">No spam. One email when it’s your turn.</p>
            </form>
          )}
        </div>
      </div>
    </section>
  );
}
