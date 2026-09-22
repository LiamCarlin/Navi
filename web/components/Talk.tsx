"use client";

import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { useRef } from "react";
import { Glyph } from "./Glyph";
import { Island, type Step } from "./Island";
import { Section } from "./Section";
import { useLoop } from "./useLoop";
import { Notice, Win } from "./Windows";

/* Three clauses in one breath, at speech pace; Navi acts on each as it lands. */
const CLAUSES: { words: string; done: string; at: number; act: number }[] = [
  { words: "text Sam I’m five minutes out", done: "Sent to Sam · Messages", at: 900, act: 2500 },
  { words: "and open the calendar", done: "Calendar · this week", at: 3600, act: 4800 },
  { words: "and play my focus playlist", done: "Playing Focus · Music", at: 5700, act: 7200 },
];
const WORD_MS = 210;
const ISLAND_IN = 400;
const ISLAND_OUT = 10_200;
const LOOP = 13_500;

type Frame = { island: boolean; text: string; listening: boolean; steps: Step[]; acted: number };

function derive(t: number): Frame {
  const parts: string[] = [];
  const steps: Step[] = [];
  let listening = false;
  let acted = 0;
  CLAUSES.forEach((c, i) => {
    const w = c.words.split(" ");
    if (t < c.at) return;
    const n = Math.min(w.length, Math.floor((t - c.at) / WORD_MS) + 1);
    parts.push(w.slice(0, n).join(" "));
    const spokenAt = c.at + w.length * WORD_MS;
    if (t < spokenAt + 250) listening = true;
    if (t >= spokenAt + 300) steps.push({ label: c.done, state: t >= c.act ? "done" : "running" });
    if (t >= c.act && t < ISLAND_OUT + 600) acted = i + 1;
  });
  return { island: t >= ISLAND_IN && t < ISLAND_OUT, text: parts.join(" "), listening, steps, acted };
}
const keyOf = (f: Frame) => `${f.island}|${f.text}|${f.listening}|${f.steps.map((s) => s.state[0]).join("")}|${f.acted}`;

export function Talk() {
  const ref = useRef<HTMLDivElement>(null);
  const reduce = useReducedMotion();
  const { frame: f } = useLoop(ref, { duration: LOOP, derive, key: keyOf, staticT: 8400 });
  const spring = { type: "spring", stiffness: 420, damping: 34 } as const;

  return (
    <Section
      id="voice"
      n="03"
      title="Talk to it."
      aside="Speech is transcribed on your Mac. “Stop” and “undo” work mid-task."
      visual={
        <div ref={ref} className="w-full" style={{ "--u": "1px" } as React.CSSProperties}>
          {/* The top of the screen: menu bar, notch, wallpaper. */}
          <div className="relative h-[360px] overflow-hidden rounded-[16px] border border-line" style={{ background: "var(--wall)" }}>
            <div
              className="absolute inset-x-0 top-0 flex h-6 items-center px-3 text-[11px] backdrop-blur-md"
              style={{ background: "var(--menubar)", color: "var(--menubar-fg)" }}
            >
              <span className="font-semibold">Finder</span>
              <span className="ml-auto flex items-center gap-1">
                <Glyph className="h-[11px] w-[11px] text-accent" />
                <span>Navi</span>
              </span>
            </div>
            <div className="pointer-events-none absolute inset-x-0 top-0 z-20 flex justify-center">
              <Island open={f.island} text={f.text} listening={f.listening} steps={f.steps} width={330} notchWidth={96} notchHeight={24} />
            </div>

            {/* What each clause did: a notification, a window, a notification. */}
            <div className="absolute bottom-3 right-3 z-10 flex flex-col items-end gap-2">
              <AnimatePresence>
                {f.acted >= 1 && (
                  <motion.div key="msg" initial={reduce ? false : { x: 24, opacity: 0 }} animate={{ x: 0, opacity: 1 }} exit={{ opacity: 0 }} transition={spring}>
                    <Notice app="Messages" tint="#34c759" title="Sam" line="You: I’m five minutes out" icon={<MessageIcon />} />
                  </motion.div>
                )}
                {f.acted >= 3 && (
                  <motion.div key="music" initial={reduce ? false : { x: 24, opacity: 0 }} animate={{ x: 0, opacity: 1 }} exit={{ opacity: 0 }} transition={spring}>
                    <Notice app="Music" tint="#fc3c44" title="Focus" line="Playing · 42 songs" icon={<PlayIcon />} />
                  </motion.div>
                )}
              </AnimatePresence>
            </div>
            <div className="absolute bottom-3 left-3 z-10">
              <AnimatePresence>
                {f.acted >= 2 && (
                  <motion.div key="cal" initial={reduce ? false : { y: 16, opacity: 0, scale: 0.98 }} animate={{ y: 0, opacity: 1, scale: 1 }} exit={{ opacity: 0 }} transition={spring}>
                    <CalendarWindow />
                  </motion.div>
                )}
              </AnimatePresence>
            </div>
          </div>
        </div>
      }
    >
      Press <span className="keycap">⌥ Space</span> and the island drops out of the notch. Say three things in one
      breath; Navi acts on each as you say it, in any app or browser.
    </Section>
  );
}

function CalendarWindow() {
  const days = ["Mon", "Tue", "Wed", "Thu", "Fri"];
  return (
    <Win title="Calendar" tint="#ff3b30" className="w-[240px]">
      <div className="grid grid-cols-5 gap-1 p-2 text-[9px]">
        {days.map((d, i) => (
          <div key={d} className="min-h-[54px] rounded-[4px] p-1" style={{ background: "var(--win-skel)" }}>
            <div className="mb-1 text-win-muted">{d}</div>
            {i === 1 && <div className="mb-0.5 truncate rounded-[3px] bg-[#0a84ff] px-1 py-0.5 text-white">Standup</div>}
            {i === 2 && <div className="truncate rounded-[3px] px-1 py-0.5 text-accent-ink" style={{ background: "var(--accent)" }}>Sam</div>}
            {i === 4 && <div className="truncate rounded-[3px] bg-[#34c759] px-1 py-0.5 text-white">Review</div>}
          </div>
        ))}
      </div>
    </Win>
  );
}

function MessageIcon() {
  return (
    <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="2" strokeLinejoin="round">
      <path d="M21 12a8 8 0 0 1-11.6 7.1L4 21l1.6-4.3A8 8 0 1 1 21 12z" />
    </svg>
  );
}

function PlayIcon() {
  return (
    <svg viewBox="0 0 24 24" className="h-4 w-4" fill="currentColor">
      <path d="M8 5v14l11-7z" />
    </svg>
  );
}
