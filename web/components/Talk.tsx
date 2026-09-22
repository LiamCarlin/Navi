"use client";

import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { useRef } from "react";
import { Glyph } from "./Glyph";
import { Island, type Step } from "./Island";
import { Reveal } from "./Reveal";
import { useLoop } from "./useLoop";

/* Three instructions in one breath; Navi acts on each as it is said. */
const CLAUSES: { words: string; done: string; at: number }[] = [
  { words: "text Sam I'm five minutes late", done: "Sent to Sam · Messages", at: 900 },
  { words: "and then play some jazz on YouTube", done: "Playing “Late Night Jazz” · Chrome", at: 3200 },
  { words: "and turn on Do Not Disturb", done: "Do Not Disturb on", at: 5600 },
];
const WORD_MS = 210;
const ISLAND_IN = 400;
const ISLAND_OUT = 9000;
const LOOP = 9700;

type Frame = { island: boolean; text: string; listening: boolean; steps: Step[] };

function derive(t: number): Frame {
  const parts: string[] = [];
  const steps: Step[] = [];
  let listening = false;
  for (const c of CLAUSES) {
    const words = c.words.split(" ");
    if (t < c.at) break;
    const n = Math.min(words.length, Math.floor((t - c.at) / WORD_MS) + 1);
    parts.push(words.slice(0, n).join(" "));
    const spokenAt = c.at + words.length * WORD_MS;
    if (t < spokenAt + 250) listening = true;
    if (t >= spokenAt + 350) steps.push({ label: c.done, state: t >= spokenAt + 1100 ? "done" : "running" });
  }
  return { island: t >= ISLAND_IN && t < ISLAND_OUT, text: parts.join(" "), listening, steps };
}
const keyOf = (f: Frame) => `${f.island}|${f.text}|${f.listening}|${f.steps.map((s) => s.state[0]).join("")}`;

export function Talk() {
  const ref = useRef<HTMLDivElement>(null);
  const reduce = useReducedMotion();
  const f = useLoop(ref, { duration: LOOP, derive, key: keyOf, staticT: 8000 });

  return (
    <section id="voice" className="scroll-mt-16 px-4 py-24 sm:px-6 md:py-32">
      <div className="mx-auto grid max-w-6xl grid-cols-1 items-center gap-10 md:grid-cols-2 md:gap-16">
        <Reveal className="md:order-2">
          <div className="eyebrow mb-3">Voice</div>
          <h2 className="h-section">Talk to it.</h2>
          <p className="lede mt-4">
            Press <span className="keycap">⌥ Space</span> and the island drops out of the notch. Say three things in one
            breath; Navi acts on each as you say it, in any app or browser.
          </p>
          <p className="mt-4 text-sm text-fg-dim">Speech is transcribed on your Mac. “Stop” and “undo” work mid-task.</p>
        </Reveal>

        <Reveal delay={0.08} className="md:order-1">
          <div ref={ref} className="relative mx-auto w-full max-w-md" style={{ "--u": "1px" } as React.CSSProperties}>
            {/* A slice of the top of the screen: menu bar, notch, wallpaper. */}
            <div className="relative h-[300px] overflow-hidden rounded-[16px] border border-line bg-[linear-gradient(180deg,#15151f,#0e0e14)]">
              <div className="absolute inset-x-0 top-0 flex h-6 items-center bg-black/25 px-3 text-[11px] text-white/80 backdrop-blur-md">
                <span className="font-semibold">Finder</span>
                <span className="ml-auto flex items-center gap-1 text-accent">
                  <Glyph className="h-[11px] w-[11px]" />
                  <span className="text-white/85">Navi</span>
                </span>
              </div>
              <div className="absolute left-1/2 top-0 z-30 h-[26px] w-[104px] -translate-x-1/2 rounded-b-[10px] bg-black" aria-hidden="true" />

              <div className="pointer-events-none absolute inset-x-0 top-0 z-20 flex justify-center">
                <AnimatePresence initial={false}>
                  {f.island && (
                    <motion.div
                      key="island"
                      initial={reduce ? false : { y: "-100%" }}
                      animate={{ y: 0 }}
                      exit={reduce ? undefined : { y: "-100%", transition: { duration: 0.26, ease: [0.4, 0, 1, 1] } }}
                      transition={{ type: "spring", stiffness: 420, damping: 34 }}
                    >
                      <Island text={f.text} listening={f.listening} steps={f.steps} width={340} notch={26} />
                    </motion.div>
                  )}
                </AnimatePresence>
              </div>
            </div>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
