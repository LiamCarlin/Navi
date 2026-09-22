"use client";

import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { Glyph } from "./Glyph";
import { u } from "./Panel";

export type Step = { label: string; state: "running" | "done" };

/**
 * The voice island: the black pill that hangs from the notch while you talk.
 * Sized in screen units (`--u`) so it fits the MacBook and can be shown at real pixels elsewhere.
 * The caller animates it in and out; this component only lays out its live contents and lets the
 * pill grow as words and steps arrive.
 */
export function Island({
  text,
  listening,
  steps,
  width = 420,
  status,
  notch = 0,
  className = "",
}: {
  text: string;
  listening: boolean;
  steps: Step[];
  width?: number;
  status?: string;
  /** Height of the notch (in u) the island hangs from; its content starts below it. */
  notch?: number;
  className?: string;
}) {
  const reduce = useReducedMotion();
  const label = status ?? (listening ? "Listening" : steps.every((s) => s.state === "done") && steps.length ? "Done" : "Working");

  return (
    <motion.div
      layout={!reduce}
      transition={{ layout: { duration: 0.28, ease: [0.22, 1, 0.36, 1] } }}
      className={`overflow-hidden bg-black text-white shadow-[0_18px_50px_-12px_rgba(0,0,0,0.9),inset_0_-1px_0_rgba(255,255,255,0.06)] ${className}`}
      style={{ width: u(width), borderRadius: `0 0 ${u(22)} ${u(22)}`, padding: `${u(notch + 12)} ${u(16)} ${u(14)}` }}
      role="img"
      aria-label={`Navi voice island: ${text}`}
    >
      <motion.div layout="position" className="flex items-center" style={{ gap: u(10) }}>
        <span
          className="flex shrink-0 items-center justify-center rounded-full bg-accent-soft text-accent"
          style={{ width: u(24), height: u(24) }}
        >
          <Glyph style={{ width: u(12), height: u(12) }} />
        </span>
        <Waveform active={listening} />
        <span className="ml-auto text-fg-dim" style={{ fontSize: u(11) }}>
          {label}
        </span>
      </motion.div>

      <AnimatePresence initial={false}>
        {text && (
          <motion.p
            key="text"
            layout="position"
            initial={reduce ? false : { opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="leading-snug text-white"
            style={{ fontSize: u(14), marginTop: u(10) }}
          >
            “{text}
            {listening && <span className="caret" />}”
          </motion.p>
        )}
      </AnimatePresence>

      <AnimatePresence initial={false}>
        {steps.length > 0 && (
          <motion.ul
            key="steps"
            layout="position"
            initial={reduce ? false : { opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="border-t border-white/10"
            style={{ marginTop: u(10), paddingTop: u(8), display: "grid", gap: u(5) }}
          >
            {steps.map((s) => (
              <motion.li
                key={s.label}
                layout="position"
                initial={reduce ? false : { opacity: 0, x: -4 }}
                animate={{ opacity: 1, x: 0 }}
                transition={{ duration: 0.2 }}
                className={`flex items-center ${s.state === "done" ? "text-white/85" : "text-white/60"}`}
                style={{ gap: u(8), fontSize: u(12.5) }}
              >
                <StepMark state={s.state} />
                <span className="truncate">{s.label}</span>
              </motion.li>
            ))}
          </motion.ul>
        )}
      </AnimatePresence>
    </motion.div>
  );
}

function StepMark({ state }: { state: Step["state"] }) {
  if (state === "done") {
    return (
      <span
        className="flex shrink-0 items-center justify-center rounded-full bg-accent text-black"
        style={{ width: u(14), height: u(14) }}
      >
        <svg viewBox="0 0 24 24" style={{ width: u(9), height: u(9) }} fill="none" stroke="currentColor" strokeWidth="3.2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M5 12l5 5 9-10" />
        </svg>
      </span>
    );
  }
  return (
    <span
      className="spin shrink-0 rounded-full border-2 border-white/25 border-t-accent"
      style={{ width: u(14), height: u(14) }}
      aria-hidden="true"
    />
  );
}

const BARS = [0.45, 0.8, 1, 0.6, 0.9, 0.5, 0.75, 0.4];

export function Waveform({ active, height = 16 }: { active: boolean; height?: number }) {
  return (
    <span className="flex items-center" style={{ height: u(height), gap: u(2.5) }} aria-hidden="true">
      {BARS.map((h, i) => (
        <span
          key={i}
          className={`rounded-full ${active ? "voice-bar bg-accent" : "voice-bar-idle bg-white/35"}`}
          style={{ width: u(2.5), height: `${h * 100}%`, animationDelay: `${i * 0.09}s` }}
        />
      ))}
    </span>
  );
}
