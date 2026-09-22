"use client";

import { useId, useState, type FormEvent } from "react";
import { getRef, joined, takeSource } from "@/lib/source";

type Done = { position: number | null; ref: string | null; status: "created" | "exists" };
type State = { kind: "idle" } | { kind: "busy" } | { kind: "done"; done: Done } | { kind: "error"; message: string };

const SHARE_TEXT = "I just joined the waitlist for Navi — say it, it’s done.";

/**
 * The one waitlist form, used everywhere: hero, sticky bar, mid-page lines, the waitlist section.
 * `source` says where the signup came from; a pending source from a CTA (pricing) wins when
 * `takePending` is set. After a successful submit it shows the place in line and the share step.
 */
export function WaitlistForm({
  source,
  compact = false,
  note = false,
  takePending = false,
  className = "",
}: {
  source: string;
  compact?: boolean;
  note?: boolean;
  takePending?: boolean;
  className?: string;
}) {
  const id = useId();
  const [state, setState] = useState<State>({ kind: "idle" });
  const [email, setEmail] = useState("");
  const [noteText, setNoteText] = useState("");

  async function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (state.kind === "busy") return;
    setState({ kind: "busy" });
    try {
      const res = await fetch("/api/waitlist", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          email,
          note: noteText,
          source: takePending ? takeSource(source) : source,
          ref: getRef() ?? undefined,
        }),
      });
      const data = (await res.json().catch(() => ({}))) as { error?: string; position?: number | null; ref?: string | null; status?: "created" | "exists" };
      if (res.status === 201 || res.status === 200) {
        joined.set();
        setState({ kind: "done", done: { position: data.position ?? null, ref: data.ref ?? null, status: data.status ?? "created" } });
      } else {
        setState({ kind: "error", message: data.error ?? "Something went wrong. Try again." });
      }
    } catch {
      setState({ kind: "error", message: "Couldn’t reach the server. Try again." });
    }
  }

  if (state.kind === "done") return <Share done={state.done} compact={compact} className={className} />;

  const field =
    "h-11 w-full rounded-[12px] border border-line-strong bg-bg-elev px-4 text-[15px] text-fg outline-none transition-colors duration-150 placeholder:text-fg-dim focus:border-accent focus-visible:outline-none";

  return (
    <form onSubmit={submit} className={`${compact ? "flex flex-col gap-2 sm:flex-row" : "flex flex-col gap-3"} ${className}`} aria-busy={state.kind === "busy"}>
      <label className="sr-only" htmlFor={`${id}-email`}>
        Email
      </label>
      <input
        id={`${id}-email`}
        name="email"
        type="email"
        required
        autoComplete="email"
        placeholder="you@example.com"
        value={email}
        onChange={(e) => setEmail(e.target.value)}
        className={`${field} ${compact ? "sm:min-w-0 sm:flex-1" : ""}`}
      />
      {note && (
        <>
          <label className="sr-only" htmlFor={`${id}-note`}>
            What would you use it for?
          </label>
          <textarea
            id={`${id}-note`}
            name="note"
            rows={2}
            maxLength={500}
            placeholder="What would you use it for? (optional)"
            value={noteText}
            onChange={(e) => setNoteText(e.target.value)}
            className={`${field} h-auto resize-none py-3`}
          />
        </>
      )}
      <button type="submit" disabled={state.kind === "busy"} className={`btn-primary shrink-0 ${compact ? "" : "sm:self-start"}`}>
        {state.kind === "busy" ? "Adding you…" : "Join the waitlist"}
      </button>
      {state.kind === "error" && (
        <p role="alert" className="text-sm text-[#e5484d] sm:basis-full">
          {state.message}
        </p>
      )}
    </form>
  );
}

function Share({ done, compact, className }: { done: Done; compact: boolean; className: string }) {
  const [copied, setCopied] = useState(false);
  const origin = typeof window === "undefined" ? "" : window.location.origin;
  const url = done.ref ? `${origin}/?ref=${done.ref}` : origin;
  const x = `https://x.com/intent/post?text=${encodeURIComponent(SHARE_TEXT)}&url=${encodeURIComponent(url)}`;
  const mail = `mailto:?subject=${encodeURIComponent("Navi — say it, it’s done")}&body=${encodeURIComponent(`${SHARE_TEXT}\n${url}`)}`;

  async function copy() {
    try {
      await navigator.clipboard.writeText(url);
      setCopied(true);
      setTimeout(() => setCopied(false), 1800);
    } catch {}
  }

  return (
    <div role="status" className={`rounded-[12px] border border-line bg-bg-elev p-4 ${compact ? "" : "sm:p-5"} ${className}`}>
      <div className="text-[17px] font-medium text-fg">
        {done.status === "exists" ? "You’re already on the list." : done.position ? `You’re #${done.position} in line.` : "You’re on the list."}
      </div>
      <div className="mt-1 text-sm text-fg-muted">Share to move up. Each signup from your link counts.</div>
      <div className="mt-3 flex flex-wrap gap-2">
        <a href={x} target="_blank" rel="noopener noreferrer" className="btn-secondary !h-9 !text-sm">
          Post on X
        </a>
        <button type="button" onClick={copy} className="btn-secondary !h-9 !text-sm">
          {copied ? "Copied" : "Copy link"}
        </button>
        <a href={mail} className="btn-secondary !h-9 !text-sm">
          Email
        </a>
      </div>
    </div>
  );
}
