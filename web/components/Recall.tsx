import { Reveal } from "./Reveal";
import { Glyph } from "./Glyph";

const points = [
  {
    title: "Read on your Mac",
    body: "Navi reads the screen locally. Frames never leave the machine; only short summaries do.",
  },
  {
    title: "Sensitive screens are dropped",
    body: "Passwords, banking, anything private: never stored, never summarised. Pause for an hour or the day in one click.",
  },
  {
    title: "Notes you own",
    body: "Everything lands in an Obsidian vault on your disk as linked markdown notes. Delete the folder and it's gone.",
  },
];

export function Recall() {
  return (
    <section id="recall" className="scroll-mt-20 px-4 py-20 sm:px-6 md:py-28">
      <div className="mx-auto grid max-w-6xl grid-cols-1 items-center gap-12 md:grid-cols-2">
        <Reveal>
          <div className="mb-3 text-xs font-medium uppercase tracking-wider text-accent">Recall</div>
          <h2 className="text-balance text-3xl font-semibold tracking-tight sm:text-4xl">
            Navi remembers your screen, so you don’t have to.
          </h2>
          <p className="mt-4 text-fg-muted">
            Ask “what was I doing yesterday?” or “where did I see that quote?” and get the answer with a link
            back to the moment.
          </p>
          <ul className="mt-8 space-y-5">
            {points.map((p) => (
              <li key={p.title} className="flex gap-3">
                <span className="mt-1 flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-accent-soft text-accent">
                  <svg viewBox="0 0 24 24" className="h-3 w-3" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round">
                    <path d="M5 12l5 5 9-10" />
                  </svg>
                </span>
                <div>
                  <div className="font-medium">{p.title}</div>
                  <div className="mt-1 text-sm text-fg-muted">{p.body}</div>
                </div>
              </li>
            ))}
          </ul>
        </Reveal>

        <Reveal delay={0.1}>
          <RecallDemo />
        </Reveal>
      </div>
    </section>
  );
}

function RecallDemo() {
  const notes = [
    { t: "09:40", app: "Xcode", text: "PanelController.swift — animating the results list" },
    { t: "11:15", app: "Chrome", text: "Reading about macOS window levels; two tabs open" },
    { t: "14:02", app: "Pages", text: "Pricing doc: Free, Pro, Pro + Recall" },
  ];
  return (
    <div className="card gradient-border overflow-hidden">
      <div className="flex items-center gap-2 border-b border-line px-4 py-3 text-sm">
        <Glyph className="h-4 w-4 text-accent" />
        <span>What was I working on yesterday?</span>
      </div>
      <div className="p-4">
        <p className="text-sm leading-relaxed text-fg-muted">
          Mostly the panel animation in Xcode, a bit of reading on window layering, and the pricing doc after
          lunch.
        </p>
        <ul className="mt-4 space-y-2">
          {notes.map((n) => (
            <li key={n.t} className="flex items-center gap-3 rounded-lg border border-line bg-bg/50 px-3 py-2 text-sm">
              <span className="font-mono text-xs text-fg-dim">{n.t}</span>
              <span className="rounded-md bg-white/5 px-1.5 py-0.5 text-xs text-fg-muted">{n.app}</span>
              <span className="truncate text-fg-muted">{n.text}</span>
            </li>
          ))}
        </ul>
        <div className="mt-4 flex items-center gap-2 text-xs text-fg-dim">
          <span className="h-1.5 w-1.5 rounded-full bg-emerald-400" />
          Written to ~/Notes/Navi/2026-09-21.md
        </div>
      </div>
    </div>
  );
}
