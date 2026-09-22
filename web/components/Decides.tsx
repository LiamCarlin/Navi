"use client";

import { motion, useReducedMotion } from "framer-motion";
import { useRef } from "react";
import { Reveal } from "./Reveal";
import { useLoop } from "./useLoop";

/* A 6 s loop on a 1-second ruler: Navi decides at ~100 ms and is done by ~0.9 s; the chatbot is still spinning. */
const LOOP = 6000;
const KEY_AT = 300;
const DECIDE_AT = KEY_AT + 100;
const ACT_UNTIL = KEY_AT + 900;

type Frame = { pressed: boolean; decided: boolean; done: boolean; botLabel: string; t: number };

function derive(t: number): Frame {
  const pressed = t >= KEY_AT;
  const decided = t >= DECIDE_AT;
  const done = t >= ACT_UNTIL;
  let botLabel = "";
  if (t >= KEY_AT) botLabel = "Thinking…";
  if (t >= KEY_AT + 1800) botLabel = "Still thinking…";
  if (t >= KEY_AT + 3600) botLabel = "Typing a reply…";
  // Quantise so the frame key only changes ~10×/s while the ruler fills.
  return { pressed, decided, done, botLabel, t: Math.floor(t / 100) };
}
const keyOf = (f: Frame) => `${f.pressed}${f.decided}${f.done}${f.botLabel}${f.t}`;

export function Decides() {
  const ref = useRef<HTMLDivElement>(null);
  const reduce = useReducedMotion();
  const f = useLoop(ref, { duration: LOOP, derive, key: keyOf, staticT: KEY_AT + 2500 });
  const ms = Math.max(0, f.t * 100 - KEY_AT);

  return (
    <section className="px-4 py-24 sm:px-6 md:py-32">
      <div className="mx-auto grid max-w-6xl grid-cols-1 items-center gap-10 md:grid-cols-[minmax(0,5fr)_minmax(0,7fr)] md:gap-16">
        <Reveal>
          <div className="eyebrow mb-3">Why it feels instant</div>
          <h2 className="h-section">Fast because it decides, not chats.</h2>
          <p className="lede mt-4">
            Navi doesn’t wait on a chatbot. A small decision model returns a typed decision — open, answer, do,
            which app, risky? — in about 100 ms. The heavier model only runs when text or vision is needed.
          </p>
        </Reveal>

        <Reveal delay={0.08}>
          <div ref={ref} className="card p-5 sm:p-6" aria-label="Timeline: Navi decides in about 100 ms; a chatbot is still thinking after seconds">
            <div className="mb-5 flex items-center justify-between text-xs text-fg-dim">
              <span className="flex items-center gap-2">
                <span className={`keycap transition-transform duration-150 ${f.pressed ? "translate-y-px opacity-80" : ""}`}>⏎</span>
                keystroke
              </span>
              <span className="font-mono tabular-nums">{ms < 4000 ? `${ms} ms` : ">4 s"}</span>
            </div>

            <Track label="Navi" tone="accent">
              <Ruler />
              <Segment from={0} to={10} active={f.pressed} label="decide" className="bg-accent" />
              <Segment from={10} to={90} active={f.decided} label="act" className="bg-accent/40" />
              <motion.span
                className="absolute -top-1 flex h-6 w-6 items-center justify-center rounded-full bg-accent text-black shadow-[0_0_0_3px_var(--bg-elev)]"
                style={{ left: "calc(90% - 12px)" }}
                initial={false}
                animate={{ scale: f.done ? 1 : 0, opacity: f.done ? 1 : 0 }}
                transition={reduce ? { duration: 0 } : { type: "spring", stiffness: 500, damping: 26 }}
              >
                <svg viewBox="0 0 24 24" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="3.2" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M5 12l5 5 9-10" />
                </svg>
              </motion.span>
              <span className="absolute left-[10%] top-6 -translate-x-1/2 whitespace-nowrap font-mono text-[10px] text-fg-dim">≈100 ms</span>
              <span className="absolute left-[90%] top-6 -translate-x-1/2 whitespace-nowrap font-mono text-[10px] text-fg-dim">done · under 1 s</span>
            </Track>

            <Track label="A chatbot" tone="dim" className="mt-12">
              <Ruler />
              <div
                className="absolute inset-y-0 left-0 rounded-full bg-[repeating-linear-gradient(90deg,rgba(255,255,255,0.14)_0_6px,transparent_6px_12px)] transition-[width] duration-300 ease-linear"
                style={{ width: f.pressed ? "100%" : "0%" }}
              />
              <span className="absolute left-2 top-6 flex items-center gap-2 whitespace-nowrap text-[11px] text-fg-dim">
                <span className={`h-3 w-3 rounded-full border-2 border-white/20 border-t-white/70 ${f.pressed ? "spin" : ""}`} />
                {f.botLabel || "waiting for you to type"}
              </span>
              <span className="absolute right-0 top-6 font-mono text-[10px] text-fg-dim">…</span>
            </Track>
          </div>
        </Reveal>
      </div>
    </section>
  );
}

function Track({ label, tone, className = "", children }: { label: string; tone: "accent" | "dim"; className?: string; children: React.ReactNode }) {
  return (
    <div className={`grid grid-cols-[72px_1fr] items-center gap-3 sm:grid-cols-[88px_1fr] ${className}`}>
      <span className={`text-sm font-medium ${tone === "accent" ? "text-fg" : "text-fg-muted"}`}>{label}</span>
      <div className="relative h-4">{children}</div>
    </div>
  );
}

function Ruler() {
  return <div className="absolute inset-x-0 top-1/2 h-px -translate-y-1/2 bg-line-strong" aria-hidden="true" />;
}

function Segment({ from, to, active, label, className }: { from: number; to: number; active: boolean; label: string; className: string }) {
  return (
    <motion.div
      className={`absolute inset-y-0 rounded-full ${className}`}
      style={{ left: `${from}%`, originX: 0 }}
      initial={false}
      animate={{ width: active ? `${to - from}%` : "0%" }}
      transition={{ duration: active ? (to - from) / 100 : 0, ease: "linear" }}
      title={label}
    />
  );
}
