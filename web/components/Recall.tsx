"use client";

import { useRef } from "react";
import { Glyph } from "./Glyph";
import { Section } from "./Section";
import { useLoop } from "./useLoop";
import { Typed, typed, words } from "./Windows";

/* A day of screen memory: the strip scrubs, the question types, the answer streams. */
const DAY: { t: string; app: string; tint: string; w: number }[] = [
  { t: "09:00", app: "Mail", tint: "#3b82f6", w: 1 },
  { t: "09:40", app: "Xcode", tint: "#6366f1", w: 3 },
  { t: "11:15", app: "Chrome", tint: "#f59e0b", w: 2 },
  { t: "12:30", app: "Messages", tint: "#22c55e", w: 1 },
  { t: "13:10", app: "Xcode", tint: "#6366f1", w: 2 },
  { t: "14:02", app: "Pages", tint: "#f97316", w: 2 },
  { t: "15:30", app: "Chrome", tint: "#f59e0b", w: 1 },
  { t: "16:20", app: "Terminal", tint: "#64748b", w: 1 },
];
const QUESTION = "What was I working on yesterday?";
const ANSWER =
  "Mostly the panel animation in Xcode — PanelController.swift from 09:40 — then some reading on window layering in Chrome, and the pricing doc in Pages after lunch.";
const NOTES = [
  { t: "09:40", app: "Xcode", text: "PanelController.swift — the results list animation" },
  { t: "11:15", app: "Chrome", text: "Reading about window levels; two tabs open" },
  { t: "14:02", app: "Pages", text: "Pricing doc: Free, Pro, Pro + Recall" },
];
const SCRUB_AT = 300;
const SCRUB_MS = 3200;
const Q_AT = 800;
const A_AT = 3900;
const LOOP = 12_500;

type Frame = { scrub: number; q: number; answer: string; notes: number };

function derive(t: number): Frame {
  const scrub = Math.max(0, Math.min(1, (t - SCRUB_AT) / SCRUB_MS));
  const answer = words(ANSWER, t, A_AT, 90);
  const notes = t < A_AT + 1200 ? 0 : Math.min(NOTES.length, Math.floor((t - A_AT - 1200) / 500) + 1);
  return { scrub: Math.round(scrub * 100) / 100, q: typed(QUESTION, t, Q_AT, 55), answer, notes };
}
const keyOf = (f: Frame) => `${f.scrub}|${f.q}|${f.answer.length}|${f.notes}`;

export function Recall() {
  const ref = useRef<HTMLDivElement>(null);
  const { frame: f } = useLoop(ref, { duration: LOOP, derive, key: keyOf, staticT: 8000 });
  const total = DAY.reduce((a, d) => a + d.w, 0);

  return (
    <Section
      id="recall"
      n="05"
      title="Recall. What was I working on yesterday?"
      aside="Optional tier. Frames never leave your Mac. Pause it for an hour or the day in one click."
      visual={
        <div ref={ref} className="card overflow-hidden" style={{ "--u": "1px" } as React.CSSProperties}>
          {/* The day, as a strip of app-colored blocks, scrubbed by a playhead. */}
          <div className="border-b border-line p-4">
            <div className="tnum mb-2 flex justify-between text-[11px] text-fg-dim">
              <span>Yesterday</span>
              <span>09:00 – 17:00</span>
            </div>
            <div className="relative">
              <div className="flex h-10 gap-[3px]" style={{ containerType: "inline-size" }}>
                {DAY.map((d, i) => {
                  const start = DAY.slice(0, i).reduce((a, x) => a + x.w, 0) / total;
                  const passed = f.scrub >= start;
                  return (
                    <div
                      key={d.t}
                      className="rounded-[4px] transition-opacity duration-200"
                      style={{ flex: d.w, background: d.tint, opacity: passed ? 0.9 : 0.25 }}
                      title={`${d.t} ${d.app}`}
                    />
                  );
                })}
                <div
                  className="absolute top-[-4px] bottom-[-4px] w-[2px] rounded-full bg-fg"
                  style={{ left: 0, transform: `translateX(calc(${f.scrub * 100}cqw - 1px))`, boxShadow: "0 0 0 2px var(--bg-elev)" }}
                  aria-hidden="true"
                />
              </div>
              <div className="tnum mt-1.5 hidden text-[10px] text-fg-dim sm:flex">
                {DAY.map((d) => (
                  <span key={d.t} className="truncate" style={{ flex: d.w }}>
                    {d.t}
                  </span>
                ))}
              </div>
            </div>
          </div>

          <div className="flex items-center gap-2 border-b border-line px-4 py-3 text-sm">
            <Glyph className="h-4 w-4 text-accent" />
            <span>
              {f.q === 0 ? <span className="text-fg-dim">Ask Navi anything</span> : <Typed text={QUESTION} n={f.q} />}
            </span>
          </div>
          <div className="p-4">
            <p className="min-h-[66px] max-w-[52ch] text-sm leading-relaxed text-fg-muted">
              {f.answer}
              {f.answer && f.answer.length < ANSWER.length && <span className="caret" />}
            </p>
            <ul className="mt-4 space-y-2">
              {NOTES.map((n, i) => (
                <li
                  key={n.t}
                  className="flex items-center gap-3 rounded-[8px] border border-line px-3 py-2 text-sm transition-opacity duration-200"
                  style={{ opacity: i < f.notes ? 1 : 0 }}
                >
                  <span className="tnum text-xs text-fg-dim">{n.t}</span>
                  <span className="rounded-[6px] px-1.5 py-0.5 text-xs text-fg-muted" style={{ background: "var(--glass-strong)" }}>
                    {n.app}
                  </span>
                  <span className="truncate text-fg-muted">{n.text}</span>
                </li>
              ))}
            </ul>
          </div>
        </div>
      }
    >
      Navi reads your screen locally and keeps plain-text notes on your disk, so you can ask. Passwords, banking,
      anything sensitive: never stored.
    </Section>
  );
}
