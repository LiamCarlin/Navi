"use client";

import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { useRef } from "react";
import { Section } from "./Section";
import { useLoop } from "./useLoop";
import { Check, Shield, Typed, Win, typed, words } from "./Windows";

/* You keep typing in the doc; behind it Chrome searches, Navi picks, asks, and books. */
const DOC =
  "Q4 is about three things: ship the new panel, cut latency under a second everywhere, and get the first hundred paying customers. The panel is nearly there.";
const URL = "google.com/travel/flights";
const FLIGHTS = [
  { airline: "ANA", code: "NH 7", time: "11:05 → 14:10", price: "$412" },
  { airline: "JAL", code: "JL 1", time: "13:40 → 16:45", price: "$438" },
  { airline: "United", code: "UA 837", time: "10:50 → 14:20", price: "$451" },
];
const URL_AT = 300;
const QUERY_AT = 1300;
const ROWS_AT = 2100;
const PICK_AT = 3400;
const SHEET_AT = 4000;
const PRESS_AT = 5800;
const BOOKED_AT = 6100;
const SHEET_OUT = 8400;
const LOOP = 12_000;

type Frame = { doc: string; url: number; query: boolean; rows: number; picked: boolean; sheet: boolean; pressed: boolean; booked: boolean };

function derive(t: number): Frame {
  return {
    doc: words(DOC, t, 200, 230),
    url: typed(URL, t, URL_AT, 30),
    query: t >= QUERY_AT,
    rows: t < ROWS_AT ? 0 : Math.min(FLIGHTS.length, Math.floor((t - ROWS_AT) / 320) + 1),
    picked: t >= PICK_AT,
    sheet: t >= SHEET_AT && t < SHEET_OUT,
    pressed: t >= PRESS_AT,
    booked: t >= BOOKED_AT,
  };
}
const keyOf = (f: Frame) => `${f.doc.length}|${f.url}|${f.query}|${f.rows}|${f.picked}|${f.sheet}|${f.pressed}|${f.booked}`;

export function Background() {
  const ref = useRef<HTMLDivElement>(null);
  const reduce = useReducedMotion();
  const { frame: f } = useLoop(ref, { duration: LOOP, derive, key: keyOf, staticT: 6600 });

  return (
    <Section
      n="04"
      title="It works while you work."
      flip
      aside={
        <p className="flex flex-wrap items-center gap-x-1.5 gap-y-1">
          <Shield className="mr-0.5 h-4 w-4 text-accent" />
          <span>Asks first for send, pay, and delete.</span>
          <span>
            Press <span className="keycap">esc</span> to stop a task.
          </span>
        </p>
      }
      visual={
        <div ref={ref} className="relative mx-auto aspect-[5/4] w-full max-w-xl sm:aspect-[4/3]" aria-label="Your document stays in front while Navi books a flight in Chrome behind it">
          {/* Chrome, behind */}
          <Win title="Flights · SFO → TYO" tint="#3b82f6" className="absolute left-0 top-0 h-[76%] w-[78%]">
            <div className="p-3 text-[11px]">
              <div className="flex h-6 items-center rounded-[6px] px-2 text-win-muted" style={{ background: "var(--win-skel)" }}>
                <span className="mr-2 h-2.5 w-2.5 rounded-full border border-current opacity-50" />
                <Typed text={URL} n={f.url} ink />
              </div>
              <div className={`mt-2 flex h-7 items-center gap-2 rounded-[6px] border px-2 transition-opacity duration-200 ${f.query ? "opacity-100" : "opacity-0"}`} style={{ borderColor: "var(--win-line)" }}>
                <span className="text-win-fg">SFO</span>
                <span className="text-win-muted">→</span>
                <span className="text-win-fg">TYO</span>
                <span className="ml-auto tnum text-win-muted">Oct 14 · 1 adult</span>
              </div>
              <ul className="mt-2 space-y-1.5">
                {FLIGHTS.map((fl, i) => (
                  <li
                    key={fl.code}
                    className="flex items-center gap-2 rounded-[6px] border px-2 py-1.5 transition-[opacity,border-color] duration-200"
                    style={{
                      opacity: i < f.rows ? 1 : 0,
                      borderColor: f.picked && i === 0 ? "var(--accent)" : "var(--win-line)",
                      background: f.picked && i === 0 ? "var(--accent-soft)" : undefined,
                    }}
                  >
                    <span className="h-4 w-4 rounded-[4px]" style={{ background: "var(--win-skel)" }} />
                    <span className="text-win-fg">{fl.airline}</span>
                    <span className="tnum text-win-muted">{fl.time}</span>
                    <span className="tnum ml-auto font-medium text-win-fg">{fl.price}</span>
                  </li>
                ))}
              </ul>
            </div>
            <div className="glass absolute right-2 top-9 flex items-center gap-2 rounded-full px-2.5 py-1 text-[11px]">
              {f.booked ? (
                <span className="flex h-2.5 w-2.5 items-center justify-center rounded-full bg-accent text-accent-ink">
                  <Check className="h-2 w-2" />
                </span>
              ) : (
                <span className="spin h-2.5 w-2.5 rounded-full border-2 border-current/25 border-t-accent" />
              )}
              Navi · {f.booked ? "booked" : f.picked ? "picked the cheapest" : f.rows > 0 ? "comparing prices" : "searching"}
            </div>
          </Win>

          {/* Your document, in front */}
          <Win title="Q4 plan" tint="#f59e0b" className="absolute bottom-[12%] right-0 h-[66%] w-[70%] sm:bottom-[6%] sm:h-[72%]">
            <div className="p-4 text-[12px] leading-relaxed text-win-fg">
              <div className="mb-2 text-[14px] font-semibold">Q4 plan</div>
              <p className="max-w-[36ch] text-pretty">
                {f.doc}
                <span className="caret caret-ink" />
              </p>
            </div>
          </Win>

          {/* The confirmation sheet */}
          <AnimatePresence initial={false}>
            {f.sheet && (
              <motion.div
                key="sheet"
                className="absolute bottom-0 left-0 z-10 w-[78%] sm:left-[10%] sm:w-[62%]"
                initial={reduce ? false : { y: 16, opacity: 0, scale: 0.98 }}
                animate={{ y: 0, opacity: 1, scale: 1 }}
                exit={reduce ? undefined : { y: 8, opacity: 0, transition: { duration: 0.18 } }}
                transition={{ type: "spring", stiffness: 420, damping: 34 }}
              >
                <div className="card rounded-[12px] p-3.5" style={{ boxShadow: "var(--shadow)" }}>
                  {f.booked ? (
                    <div className="flex items-center gap-3">
                      <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-accent text-accent-ink">
                        <Check className="h-3.5 w-3.5" />
                      </span>
                      <div className="min-w-0">
                        <div className="text-[13px] font-medium">Booked</div>
                        <div className="tnum mt-0.5 text-[11px] text-fg-muted">ANA NH 7 · Oct 14 · $412 · confirmation in Mail</div>
                      </div>
                    </div>
                  ) : (
                    <>
                      <div className="flex items-start gap-3">
                        <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-accent-soft text-accent">
                          <Shield className="h-3.5 w-3.5" />
                        </span>
                        <div className="min-w-0">
                          <div className="text-[13px] font-medium">Book ANA for $412?</div>
                          <div className="mt-0.5 text-[11px] text-fg-muted">This charges your saved card. Navi won’t continue until you say so.</div>
                        </div>
                      </div>
                      <div className="mt-3 flex justify-end gap-2">
                        <span className="rounded-[8px] border border-line px-2.5 py-1 text-[11px] text-fg-muted">Not now</span>
                        <span className={`rounded-[8px] bg-fg px-2.5 py-1 text-[11px] font-medium text-bg transition-opacity duration-100 ${f.pressed ? "opacity-70" : ""}`}>
                          Book it
                        </span>
                      </div>
                    </>
                  )}
                </div>
              </motion.div>
            )}
          </AnimatePresence>
        </div>
      }
    >
      Tasks run in the app they need while your window stays in front — your cursor, your focus. Before anything you
      can’t undo, Navi stops and asks.
    </Section>
  );
}
