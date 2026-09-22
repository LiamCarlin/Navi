"use client";

import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { useState } from "react";
import { Panel, RowIcon, type Row } from "./Panel";
import { Reveal } from "./Reveal";

type Example = {
  chip: string;
  spotlight: { title: string; kind: string }[];
  navi: Row[];
  outcome: string;
  where: string;
};

const EXAMPLES: Example[] = [
  {
    chip: "text mom I'm running late",
    spotlight: [
      { title: "Messages", kind: "Application" },
      { title: "Mom", kind: "Contacts" },
      { title: "text mom I'm running late", kind: "Search the web" },
      { title: "late-fees.pdf", kind: "Documents" },
    ],
    navi: [
      { icon: "message", title: "Text Mom: “I’m running late”", kind: "Task · Messages", hint: "Run" },
      { icon: "app", title: "Messages", kind: "App", hint: "Open" },
    ],
    outcome: "Sent to Mom",
    where: "Messages · 0.8 s",
  },
  {
    chip: "make a doc called Q4 plan and share it with Sam",
    spotlight: [
      { title: "Pages", kind: "Application" },
      { title: "Q3 plan.pages", kind: "Documents" },
      { title: "Sam Ortiz", kind: "Contacts" },
      { title: "make a doc called Q4 plan…", kind: "Search the web" },
    ],
    navi: [
      { icon: "doc", title: "Create “Q4 plan”, share with Sam", kind: "Task · Google Docs", hint: "Run" },
      { icon: "app", title: "Google Docs", kind: "Web app", hint: "Open" },
    ],
    outcome: "Q4 plan shared with Sam",
    where: "Docs · editing",
  },
  {
    chip: "toggle dark mode",
    spotlight: [
      { title: "Displays", kind: "System Settings" },
      { title: "Appearance", kind: "System Settings" },
      { title: "toggle dark mode", kind: "Search the web" },
    ],
    navi: [
      { icon: "moon", title: "Dark Mode", kind: "System · Toggle", hint: "Toggle" },
      { icon: "app", title: "Appearance", kind: "System Settings", hint: "Open" },
    ],
    outcome: "Dark Mode on",
    where: "System · 0.1 s",
  },
];

export function Does() {
  const [i, setI] = useState(0);
  const reduce = useReducedMotion();
  const ex = EXAMPLES[i];

  return (
    <section id="does" className="scroll-mt-16 px-4 py-24 sm:px-6 md:py-32">
      <div className="mx-auto max-w-6xl">
        <Reveal>
          <div className="max-w-2xl">
            <div className="eyebrow mb-3">The difference</div>
            <h2 className="h-section">Spotlight finds. Navi does.</h2>
            <p className="lede mt-4">
              Spotlight hands you a list. Navi runs the command in the app it needs, then tells you it’s done.
            </p>
          </div>
        </Reveal>

        <Reveal delay={0.05}>
          <div className="mt-8 flex flex-wrap gap-2" role="tablist" aria-label="Example commands">
            {EXAMPLES.map((e, n) => (
              <button
                key={e.chip}
                type="button"
                role="tab"
                aria-selected={n === i}
                onClick={() => setI(n)}
                className={`rounded-full border px-3.5 py-1.5 text-sm transition-colors duration-200 ${
                  n === i
                    ? "border-accent/60 bg-accent-soft text-fg"
                    : "border-line bg-glass text-fg-muted hover:border-line-strong hover:text-fg"
                }`}
              >
                “{e.chip}”
              </button>
            ))}
          </div>
        </Reveal>

        <div className="mt-8 grid grid-cols-1 gap-4 md:grid-cols-2 md:gap-6">
          <Reveal delay={0.08}>
            <Compare label="Spotlight" tone="dim">
              <SpotlightMock query={ex.chip} results={ex.spotlight} />
              <p className="mt-4 text-sm text-fg-dim">…and now you do it yourself.</p>
            </Compare>
          </Reveal>
          <Reveal delay={0.12}>
            <Compare label="Navi" tone="accent">
              <div style={{ "--u": "1px" } as React.CSSProperties}>
                <Panel query={ex.chip} typed={ex.chip.length} rows={ex.navi} showCaret={false} />
              </div>
              <AnimatePresence mode="wait" initial={false}>
                <motion.div
                  key={ex.outcome}
                  initial={reduce ? false : { opacity: 0, y: 6 }}
                  animate={{ opacity: 1, y: 0 }}
                  exit={reduce ? undefined : { opacity: 0, y: -4 }}
                  transition={{ duration: 0.22 }}
                  className="mt-4 flex items-center gap-3 rounded-[12px] border border-line bg-bg/60 px-3 py-2.5 text-sm"
                >
                  <RowIcon icon="check" />
                  <div className="min-w-0">
                    <div className="truncate text-fg">{ex.outcome}</div>
                    <div className="text-xs text-fg-dim">{ex.where}</div>
                  </div>
                </motion.div>
              </AnimatePresence>
            </Compare>
          </Reveal>
        </div>
      </div>
    </section>
  );
}

function Compare({ label, tone, children }: { label: string; tone: "dim" | "accent"; children: React.ReactNode }) {
  return (
    <div className="card relative h-full p-4 sm:p-6" style={{ "--u": "1px" } as React.CSSProperties}>
      <div className={`mb-4 text-xs font-medium uppercase tracking-[0.08em] ${tone === "accent" ? "text-accent" : "text-fg-dim"}`}>
        {label}
      </div>
      {children}
    </div>
  );
}

function SpotlightMock({ query, results }: { query: string; results: { title: string; kind: string }[] }) {
  return (
    <div className="overflow-hidden rounded-[16px] border border-white/10 bg-[#2a2a2e]/90 text-[#e5e5ea] shadow-[0_24px_60px_-16px_rgba(0,0,0,0.7)] backdrop-blur-2xl">
      <div className="flex h-[56px] items-center gap-3 px-[18px]">
        <svg viewBox="0 0 24 24" className="h-[18px] w-[18px] text-white/60" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round">
          <circle cx="11" cy="11" r="7" />
          <path d="M20 20l-3.5-3.5" />
        </svg>
        <span className="min-w-0 flex-1 truncate text-[17px]">{query}</span>
      </div>
      <ul className="border-t border-white/10 p-[6px]">
        {results.map((r, i) => (
          <li
            key={r.title}
            className={`flex items-center gap-3 rounded-[10px] px-[10px] py-[8px] ${i === 0 ? "bg-white/10" : ""}`}
          >
            <span className="h-[28px] w-[28px] shrink-0 rounded-[8px] bg-white/10" />
            <div className="min-w-0 flex-1">
              <div className="truncate text-[14px]">{r.title}</div>
              <div className="mt-[2px] text-[11px] text-white/45">{r.kind}</div>
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}
