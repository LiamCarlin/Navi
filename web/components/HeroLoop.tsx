"use client";

import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { useRef } from "react";
import { Island, type Step } from "./Island";
import { Panel, u, type Row } from "./Panel";
import { useLoop } from "./useLoop";

/* ------------------------------------------------------------------ */
/* Timeline. Everything is a pure function of elapsed ms, so the loop   */
/* restarts cleanly, pauses when scrolled away, and reduced-motion can  */
/* simply render one late frame.                                        */
/* ------------------------------------------------------------------ */

export const LOOP_MS = 12_200;

const SPOKEN = "open chrome, search flights to tokyo, and pick the cheapest";
const WORDS = SPOKEN.split(" ");
const WORD_MS = 230;
const WORDS_AT = 900;

const STEPS: { label: string; at: number; done: number }[] = [
  { label: "Opening Chrome", at: 3300, done: 3750 },
  { label: "Searching flights to Tokyo", at: 3800, done: 4500 },
  { label: "Comparing prices", at: 4550, done: 5300 },
  { label: "Picked $412 · ANA, Oct 14", at: 5350, done: 5750 },
];

const ISLAND_IN = 450;
const ISLAND_OUT = 6500;
const BAR_IN = 7100;
const BAR_OUT = 11_900;

type Scene = { query: string; from: number; charMs: number; rows: Row[]; clearAt: number };

const SCENES: Scene[] = [
  {
    query: "search flights to tokyo, pick the cheapest",
    from: 7400,
    charMs: 28,
    clearAt: 9350,
    rows: [
      { icon: "browser", title: "Do it: search flights to Tokyo, pick the cheapest", kind: "Task · runs in Chrome", hint: "Run" },
      { icon: "app", title: "Google Chrome", kind: "App", hint: "Open" },
      { icon: "spark", title: "Ask Navi", kind: "Answer", hint: "Ask" },
    ],
  },
  {
    query: "12% of 340",
    from: 9450,
    charMs: 45,
    clearAt: 10_650,
    rows: [
      { icon: "calc", title: "40.8", kind: "Calculator", hint: "Copy" },
      { icon: "app", title: "Calculator", kind: "App", hint: "Open" },
    ],
  },
  {
    query: "maps",
    from: 10_750,
    charMs: 60,
    clearAt: BAR_OUT,
    rows: [
      { icon: "map", title: "Maps", kind: "App", hint: "Open" },
      { icon: "app", title: "Directions home", kind: "Maps", hint: "Open" },
    ],
  },
];
const ROWS_DELAY = 180;

type Frame = {
  hint: string | null;
  island: boolean;
  text: string;
  listening: boolean;
  steps: Step[];
  status?: string;
  bar: boolean;
  query: string;
  typed: number;
  rows: Row[] | null;
};

function derive(t: number): Frame {
  // Keycap hints just before each surface appears.
  let hint: string | null = null;
  if (t >= ISLAND_IN - 320 && t < ISLAND_IN) hint = "⌥ Space";
  if (t >= BAR_IN - 320 && t < BAR_IN) hint = "⌘ Space";

  const island = t >= ISLAND_IN && t < ISLAND_OUT;
  const wordsShown = Math.max(0, Math.min(WORDS.length, Math.floor((t - WORDS_AT) / WORD_MS) + 1));
  const text = t >= WORDS_AT ? WORDS.slice(0, wordsShown).join(" ") : "";
  const listening = t < WORDS_AT + WORDS.length * WORD_MS + 200;
  const steps: Step[] = STEPS.filter((s) => t >= s.at).map((s) => ({ label: s.label, state: t >= s.done ? "done" : "running" }));
  const status = steps.length === STEPS.length && steps.every((s) => s.state === "done") ? "Done" : undefined;

  const bar = t >= BAR_IN && t < BAR_OUT;
  let query = "";
  let typed = 0;
  let rows: Row[] | null = null;
  for (const s of SCENES) {
    if (t >= s.from && t < s.clearAt) {
      query = s.query;
      typed = Math.min(s.query.length, Math.floor((t - s.from) / s.charMs));
      const typedAt = s.from + s.query.length * s.charMs;
      rows = t >= typedAt + ROWS_DELAY ? s.rows : null;
    }
  }

  return { hint, island, text, listening, steps, status, bar, query, typed, rows };
}

/** One composed frame for reduced-motion: island down, everything spoken, all steps done. */
const STATIC_T = 5900;

function keyOf(f: Frame) {
  return `${f.hint}|${f.island}|${f.text}|${f.listening}|${f.steps.map((s) => s.state[0]).join("")}|${f.bar}|${f.query}|${f.typed}|${f.rows ? 1 : 0}`;
}

/* ------------------------------------------------------------------ */

/** The live content on the MacBook screen: voice island, then the ⌘Space bar in its three modes. */
export function HeroLoop() {
  const reduce = useReducedMotion();
  const ref = useRef<HTMLDivElement>(null);
  const { frame } = useLoop(ref, { duration: LOOP_MS, derive, key: keyOf, staticT: STATIC_T });

  const spring = { type: "spring", stiffness: 420, damping: 34, mass: 0.9 } as const;

  return (
    <div ref={ref} className="absolute inset-0">
      {/* Voice island, dropping out of the notch */}
      <AnimatePresence initial={false}>
        {frame.island && (
          <div key="island" className="pointer-events-none absolute inset-x-0 top-0 z-20 flex justify-center">
            <motion.div
              initial={reduce ? false : { y: "-100%" }}
              animate={{ y: 0 }}
              exit={reduce ? undefined : { y: "-100%", transition: { duration: 0.28, ease: [0.4, 0, 1, 1] } }}
              transition={spring}
            >
              <Island text={frame.text} listening={frame.listening} steps={frame.steps} status={frame.status} width={400} notch={30} />
            </motion.div>
          </div>
        )}
      </AnimatePresence>

      {/* ⌘Space bar, dropping from the top of the screen */}
      <AnimatePresence initial={false}>
        {frame.bar && (
          <div key="bar" className="pointer-events-none absolute inset-x-0 z-20 flex justify-center" style={{ top: "20%" }}>
            <motion.div
              style={{ width: u(620) }}
              initial={reduce ? false : { y: -40, opacity: 0, scale: 0.98 }}
              animate={{ y: 0, opacity: 1, scale: 1 }}
              exit={reduce ? undefined : { y: -24, opacity: 0, transition: { duration: 0.22 } }}
              transition={spring}
            >
              <Panel query={frame.query} typed={frame.typed} rows={frame.rows} showCaret />
            </motion.div>
          </div>
        )}
      </AnimatePresence>

      {/* Keycap hint above the dock */}
      <AnimatePresence>
        {frame.hint && (
          <div key={frame.hint} className="pointer-events-none absolute inset-x-0 z-20 flex justify-center" style={{ bottom: u(52) }}>
            <motion.div
              className="glass flex items-center whitespace-nowrap"
              style={{ height: u(26), padding: `0 ${u(10)}`, borderRadius: u(7), fontSize: u(12), gap: u(6) }}
              initial={{ opacity: 0, scale: 0.92, y: 4 }}
              animate={{ opacity: 1, scale: 1, y: 0 }}
              exit={{ opacity: 0, scale: 0.96, transition: { duration: 0.15 } }}
              transition={{ duration: 0.18 }}
            >
              <span className="inline-block rounded-full bg-accent" style={{ width: u(5), height: u(5) }} />
              {frame.hint}
            </motion.div>
          </div>
        )}
      </AnimatePresence>
    </div>
  );
}
