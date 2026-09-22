import { Reveal } from "./Reveal";
import { Glyph } from "./Glyph";

export function Recall() {
  return (
    <section id="recall" className="scroll-mt-16 px-4 py-24 sm:px-6 md:py-32">
      <div className="mx-auto grid max-w-6xl grid-cols-1 items-center gap-10 md:grid-cols-2 md:gap-16">
        <Reveal className="md:order-2">
          <div className="eyebrow mb-3">Recall · optional</div>
          <h2 className="h-section">“What was I working on yesterday?”</h2>
          <p className="lede mt-4">
            Navi reads your screen locally and keeps plain-text notes on your disk, so you can ask. Passwords,
            banking, anything sensitive: never stored.
          </p>
          <p className="mt-4 text-sm text-fg-dim">Frames never leave your Mac. Pause it for an hour or the day in one click.</p>
        </Reveal>

        <Reveal delay={0.08} className="md:order-1">
          <RecallDemo />
        </Reveal>
      </div>
    </section>
  );
}

function RecallDemo() {
  const notes = [
    { t: "09:40", app: "Xcode", text: "PanelController.swift — the results list animation" },
    { t: "11:15", app: "Chrome", text: "Reading about window levels; two tabs open" },
    { t: "14:02", app: "Pages", text: "Pricing doc: Free, Pro, Pro + Recall" },
  ];
  return (
    <div className="card mx-auto max-w-md overflow-hidden">
      <div className="flex items-center gap-2 border-b border-line px-4 py-3 text-sm">
        <Glyph className="h-4 w-4 text-accent" />
        <span>What was I working on yesterday?</span>
      </div>
      <div className="p-4">
        <p className="text-sm leading-relaxed text-fg-muted">
          Mostly the panel animation in Xcode, some reading on window layering, and the pricing doc after lunch.
        </p>
        <ul className="mt-4 space-y-2">
          {notes.map((n) => (
            <li key={n.t} className="flex items-center gap-3 rounded-[8px] border border-line bg-bg/60 px-3 py-2 text-sm">
              <span className="font-mono text-xs text-fg-dim">{n.t}</span>
              <span className="rounded-[6px] bg-white/6 px-1.5 py-0.5 text-xs text-fg-muted">{n.app}</span>
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
