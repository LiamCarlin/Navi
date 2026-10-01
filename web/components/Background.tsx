"use client";

import { motion, useMotionValueEvent, useReducedMotion, useScroll, useTransform } from "framer-motion";
import { useRef, useState } from "react";
import { Glyph } from "./Glyph";
import { Head, Reveal } from "./motion/Reveal";
import { Win } from "./Windows";
import { EASE, progress } from "@/lib/motion";

const MINE = "Tokyo, Oct 14–21. Want: one day trip to Nikko, the ramen place Kenji mentioned, and a morning at Tsukiji before it gets busy.";

const FLIGHTS = [
  { air: "ANA", dep: "11:05", arr: "14:10 +1", price: "$412", best: true },
  { air: "JAL", dep: "13:40", arr: "16:45 +1", price: "$438" },
  { air: "United", dep: "10:50", arr: "14:20 +1", price: "$451" },
  { air: "Zipair", dep: "16:15", arr: "19:30 +1", price: "$468" },
];

const ASKS = [["Safari"], ["Arc"], ["Firefox"], ["Chrome"]];

/**
 * Background mode: your window stays in front and keeps your typing; the task fills in
 * the window behind it. Scroll drives both. At the end the window it worked in comes forward.
 */
export function Background() {
  const reduce = useReducedMotion();
  const ref = useRef<HTMLDivElement>(null);
  const { scrollYProgress } = useScroll({ target: ref, offset: ["start 80%", "end 70%"] });
  const [p, setP] = useState(reduce ? 1 : 0);
  useMotionValueEvent(scrollYProgress, "change", (v) => !reduce && setP(Math.round(v * 300) / 300));
  const backY = useTransform(scrollYProgress, [0, 1], [40, -20]);
  const frontY = useTransform(scrollYProgress, [0, 1], [90, -40]);

  const mine = Math.floor(progress(p, 0.05, 0.75) * MINE.length);
  const rows = Math.floor(progress(p, 0.25, 0.7) * (FLIGHTS.length + 0.01));
  const step = Math.min(5, 1 + Math.floor(progress(p, 0.1, 0.78) * 5));
  const done = p > 0.8;

  return (
    <section id="background" className="scroll-mt-16 px-4 py-24 sm:px-6 md:py-32">
      <Head
        title={["It works while you work"]}
        sub="Tasks run in the app they need, behind the window you’re in. Your cursor stays put, your typing lands where you’re typing, and the window it worked in comes forward when it’s done."
      />

      <div ref={ref} className="mx-auto mt-14 max-w-6xl lg:mt-16">
        <div className="relative aspect-[4/3.6] overflow-hidden rounded-[24px] shadow-[0_40px_100px_-40px_rgba(30,40,90,0.55)] sm:aspect-[16/9] sm:rounded-[32px]" style={{ background: "var(--wall)" }}>
          {/* status pill */}
          <div className="absolute left-1/2 top-5 z-30 -translate-x-1/2">
            <motion.div layout className="glass-dark flex items-center gap-2.5 whitespace-nowrap rounded-full py-2 pl-3 pr-4 text-[13px]" transition={{ duration: 0.4, ease: EASE }}>
              <Glyph gradient className="h-3.5 w-3.5" />
              {done ? (
                <span>
                  Done · cheapest is <b className="font-semibold">ANA, $412</b>
                </span>
              ) : (
                <span className="flex items-center gap-2">
                  Finding flights to Tokyo
                  <span className="tnum text-white/50">{step}/5</span>
                </span>
              )}
            </motion.div>
          </div>

          {/* the window Navi works in */}
          <motion.div
            className="absolute left-[5%] top-[17%] w-[70%] sm:w-[56%]"
            style={reduce ? undefined : { y: backY }}
            animate={{ zIndex: done ? 20 : 10, scale: done ? 1.02 : 0.97, opacity: done ? 1 : 0.92 }}
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
            className="absolute bottom-[7%] right-[5%] w-[62%] sm:w-[44%]"
            style={reduce ? undefined : { y: frontY }}
            animate={{ zIndex: done ? 10 : 20, scale: done ? 0.97 : 1, opacity: done ? 0.88 : 1 }}
            transition={{ duration: 0.6, ease: EASE }}
          >
            <Win title="Notes · Trip" tint="#ffd84d">
              <div className="min-h-[140px] p-4 text-[13px] leading-relaxed sm:min-h-[170px]">
                <div className="mb-1 font-semibold">Japan</div>
                {MINE.slice(0, mine)}
                {!done && <span className="caret caret-ink" />}
              </div>
            </Win>
            <div className="mt-2 text-right text-[11px] font-medium text-white/90">You, typing the whole time</div>
          </motion.div>
        </div>

        <div className="mt-5 grid grid-cols-1 gap-5 md:grid-cols-3">
          <Reveal className="card flex flex-col p-6">
            <div className="glass rounded-[16px] p-3.5 text-[13px]">
              <div>
                Navi wants to: <b className="font-semibold">send this to Sam Rivera</b>
              </div>
              <div className="mt-2.5 flex gap-2">
                <span className="keycap">⌘⏎ approve</span>
                <span className="keycap">⌘⌫ deny</span>
              </div>
            </div>
            <h3 className="mt-6 text-[17px] font-medium tracking-[-0.01em]">Asks before anything it can’t take back</h3>
            <p className="body mt-2 text-[14.5px]">
              Sending, paying, deleting. Everything else just happens. Turn off Auto mode and it asks before every step.
            </p>
          </Reveal>
          <Reveal i={1} className="card flex flex-col p-6">
            <div className="flex h-[86px] items-center justify-center gap-3">
              <span className="keycap !h-12 !min-w-16 !rounded-[12px] !text-[15px]">esc</span>
              <span className="text-[13px] text-fg-dim">or say</span>
              <span className="glass-dark rounded-full px-3 py-1.5 text-[13px]">“stop”</span>
            </div>
            <h3 className="mt-6 text-[17px] font-medium tracking-[-0.01em]">Stops the moment you say so</h3>
            <p className="body mt-2 text-[14.5px]">A task ends on the spot, wherever it got to. “Undo” and “pause” work mid-task too.</p>
          </Reveal>
          <Reveal i={2} className="card flex flex-col p-6">
            <div className="flex h-[86px] flex-wrap items-center justify-center gap-2">
              {ASKS.map(([k]) => (
                <span key={k} className="rounded-full bg-white px-3 py-1.5 text-[13px] text-fg-muted ring-1 ring-line">
                  {k}
                </span>
              ))}
            </div>
            <h3 className="mt-6 text-[17px] font-medium tracking-[-0.01em]">Your browser, a tab behind yours</h3>
            <p className="body mt-2 text-[14.5px]">Web steps run in the browser you already use, with your logins. The tab is never closed out from under you.</p>
          </Reveal>
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
