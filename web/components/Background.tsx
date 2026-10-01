"use client";

import { motion, useMotionValueEvent, useReducedMotion, useScroll, useTransform } from "framer-motion";
import { useRef, useState } from "react";
import { Glyph } from "./Glyph";
import { Lines, Reveal } from "./motion/Reveal";
import { Win } from "./Windows";
import { EASE, progress } from "@/lib/motion";

const MINE = "Tokyo, Oct 14–21. Want: one day trip to Nikko, the ramen place Kenji mentioned, and a morning at Tsukiji before it gets busy.";

const FLIGHTS = [
  { air: "ANA", dep: "11:05", arr: "14:10 +1", price: "$412", best: true },
  { air: "JAL", dep: "13:40", arr: "16:45 +1", price: "$438" },
  { air: "United", dep: "10:50", arr: "14:20 +1", price: "$451" },
  { air: "Zipair", dep: "16:15", arr: "19:30 +1", price: "$468" },
];

const ASKS = [
  ["Sending", "a message, an email, an invite"],
  ["Paying", "checkout, booking, anything with a card"],
  ["Deleting", "files, emails, events"],
];

/**
 * Background mode: your window stays in front and keeps your typing; the task fills in
 * the window behind it. Scroll drives both. At the end the window it worked in comes forward.
 */
export function Background() {
  const reduce = useReducedMotion();
  const ref = useRef<HTMLDivElement>(null);
  const { scrollYProgress } = useScroll({ target: ref, offset: ["start 85%", "end 35%"] });
  const [p, setP] = useState(reduce ? 1 : 0);
  useMotionValueEvent(scrollYProgress, "change", (v) => !reduce && setP(Math.round(v * 300) / 300));
  const backY = useTransform(scrollYProgress, [0, 1], [40, -20]);
  const frontY = useTransform(scrollYProgress, [0, 1], [90, -40]);

  const mine = Math.floor(progress(p, 0.05, 0.75) * MINE.length);
  const rows = Math.floor(progress(p, 0.25, 0.7) * (FLIGHTS.length + 0.01));
  const step = Math.min(5, 1 + Math.floor(progress(p, 0.1, 0.78) * 5));
  const done = p > 0.8;

  return (
    <section id="background" className="scroll-mt-16 px-4 py-24 sm:px-6 md:py-36">
      <div className="mx-auto grid max-w-7xl grid-cols-1 gap-12 lg:grid-cols-12 lg:gap-8">
        <div className="lg:col-span-5">
          <Lines className="h-section" lines={["It works", "while you work."]} />
          <Reveal>
            <p className="lede mt-6">
              A task runs in the app it needs, but behind the window you’re in. Navi sends its clicks and keystrokes straight to
              that app, so your cursor stays put and your typing lands where you’re typing. When it’s finished, the window it
              worked in comes forward.
            </p>
          </Reveal>

          <Reveal className="mt-12">
            <h3 className="h-card">Before anything it can’t take back, it asks.</h3>
            <ul className="mt-4 divide-y divide-line border-y border-line">
              {ASKS.map(([k, v]) => (
                <li key={k} className="flex items-baseline gap-4 py-3">
                  <span className="w-20 shrink-0 font-medium">{k}</span>
                  <span className="body">{v}</span>
                </li>
              ))}
            </ul>
            <p className="body mt-4">
              Everything else just happens. Turn off Auto mode and it asks before every step instead. <span className="keycap">esc</span>{" "}
              or saying “stop” ends a task on the spot, and every run is logged step by step on your Mac.
            </p>
          </Reveal>
        </div>

        <div ref={ref} className="lg:col-span-7">
          <div className="relative aspect-[4/3.4] overflow-hidden rounded-[22px] border border-line sm:aspect-[4/3] sm:rounded-[28px]" style={{ background: "var(--wall)" }}>
            {/* status pill */}
            <div className="absolute left-1/2 top-4 z-30 -translate-x-1/2">
              <motion.div layout className="glass flex items-center gap-2.5 rounded-full py-2 pl-3 pr-4 text-[13px]" transition={{ duration: 0.4, ease: EASE }}>
                <Glyph gradient className="h-3.5 w-3.5" />
                {done ? (
                  <span>
                    Done · cheapest is <b className="font-semibold">ANA, $412</b>
                  </span>
                ) : (
                  <span className="flex items-center gap-2">
                    Finding flights to Tokyo
                    <span className="tnum text-panel-dim">{step}/5</span>
                  </span>
                )}
              </motion.div>
            </div>

            {/* the window Navi works in */}
            <motion.div
              className="absolute left-[4%] top-[16%] w-[74%]"
              style={reduce ? undefined : { y: backY }}
              animate={{ zIndex: done ? 20 : 10, scale: done ? 1.02 : 0.97, opacity: done ? 1 : 0.9 }}
              transition={{ duration: 0.6, ease: EASE }}
            >
              <Win title="Google Flights · Boston → Tokyo" tint="#2b7fff">
                <div className="p-4 text-[12px]">
                  <div className="flex gap-2">
                    {["Round trip", "1 adult", "Economy"].map((c) => (
                      <span key={c} className="rounded-full px-2.5 py-1" style={{ background: "var(--win-skel)" }}>
                        {c}
                      </span>
                    ))}
                  </div>
                  <div className="mt-3 grid grid-cols-2 gap-2">
                    <Field label="From" value={step >= 2 ? "Boston (BOS)" : ""} />
                    <Field label="To" value={step >= 2 ? "Tokyo (TYO)" : ""} />
                    <Field label="Depart" value={step >= 3 ? "Tue, Oct 14" : ""} />
                    <Field label="Return" value={step >= 3 ? "Tue, Oct 21" : ""} />
                  </div>
                  <ul className="mt-3 space-y-1.5">
                    {FLIGHTS.map((f, i) => (
                      <motion.li
                        key={f.air}
                        initial={false}
                        animate={{ opacity: i < rows ? 1 : 0, y: i < rows ? 0 : 6 }}
                        transition={{ duration: 0.35, ease: EASE }}
                        className="flex items-center justify-between rounded-lg px-3 py-2"
                        style={{ background: f.best && done ? "rgba(48,209,88,0.14)" : "var(--win-bar)" }}
                      >
                        <span className="w-14 font-medium">{f.air}</span>
                        <span className="tnum text-win-muted">
                          {f.dep} → {f.arr}
                        </span>
                        <span className="tnum font-medium">{f.price}</span>
                      </motion.li>
                    ))}
                  </ul>
                </div>
              </Win>
            </motion.div>

            {/* your window */}
            <motion.div
              className="absolute bottom-[6%] right-[4%] w-[58%]"
              style={reduce ? undefined : { y: frontY }}
              animate={{ zIndex: done ? 10 : 20, scale: done ? 0.97 : 1, opacity: done ? 0.85 : 1 }}
              transition={{ duration: 0.6, ease: EASE }}
            >
              <Win title="Notes · Trip" tint="#ffd84d">
                <div className="min-h-[150px] p-4 text-[13px] leading-relaxed sm:min-h-[170px]">
                  <div className="mb-1 font-semibold">Japan</div>
                  {MINE.slice(0, mine)}
                  {!done && <span className="caret caret-ink" />}
                </div>
              </Win>
              <div className="mt-2 text-right text-[11px] text-[var(--menubar-fg)] opacity-70">You, typing the whole time</div>
            </motion.div>
          </div>
        </div>
      </div>
    </section>
  );
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg border px-2.5 py-1.5" style={{ borderColor: "var(--win-line)" }}>
      <div className="text-[10px] text-win-muted">{label}</div>
      <div className="h-4 truncate">{value || <span className="inline-block h-2 w-16 rounded" style={{ background: "var(--win-skel)" }} />}</div>
    </div>
  );
}
