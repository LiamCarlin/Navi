"use client";

import { AnimatePresence, motion, useInView, useReducedMotion } from "framer-motion";
import { useEffect, useRef, useState } from "react";
import { LiveBar } from "./bar/LiveBar";
import { Head, Reveal } from "./motion/Reveal";
import { EASE } from "@/lib/motion";

const SAID = [
  { words: "open spotify and play something calm", did: ["Spotify is open", "Playing a calm playlist"] },
  { words: "remind me to stretch at four", did: ["Reminder: “Stretch”, 4:00 PM"] },
  { words: "how far away is the moon", did: ["Answer: about 384,400 km on average"] },
];

export function TypeTalk() {
  return (
    <section id="what-it-is" className="scroll-mt-16 px-4 py-24 sm:px-6 md:py-32">
      <Head title={["How Navi helps,", "the moment you ask"]} sub="Two shortcuts, from any app. Navi works out what you meant and does it." />
      <div className="mx-auto mt-14 grid max-w-6xl grid-cols-1 gap-5 lg:mt-16 lg:grid-cols-2">
        <Reveal className="card-blue flex flex-col p-6 sm:p-8">
          <div className="flex items-center gap-2 text-white/85">
            <Cap light>⌘</Cap>
            <Cap light>Space</Cap>
          </div>
          <h3 className="h-card mt-4 text-white">
            Type what you want. <span className="text-white/70">Navi decides what it is.</span>
          </h3>
          <div className="mt-7 flex-1">
            <LiveBar />
          </div>
        </Reveal>

        <Reveal i={1} className="card flex flex-col p-6 sm:p-8">
          <div className="flex items-center gap-2 text-fg-muted">
            <Cap>⌥</Cap>
            <Cap>Space</Cap>
          </div>
          <h3 className="h-card mt-4">
            Or say it. <span className="text-fg-dim">Three things in one breath is fine.</span>
          </h3>
          <div className="mt-7 flex-1">
            <IslandLoop />
          </div>
        </Reveal>
      </div>
    </section>
  );
}

function Cap({ children, light = false }: { children: React.ReactNode; light?: boolean }) {
  return (
    <span
      className={`inline-flex h-7 min-w-7 items-center justify-center rounded-[8px] px-2 text-[13px] font-medium ${
        light ? "bg-white/20 text-white shadow-[inset_0_1px_0_rgba(255,255,255,0.4),0_0_0_1px_rgba(255,255,255,0.3)]" : "keycap !h-7 !text-[13px]"
      }`}
    >
      {children}
    </span>
  );
}

/** The notch island on a sunset screen, hearing one instruction after another on a loop. */
function IslandLoop() {
  const reduce = useReducedMotion();
  const ref = useRef<HTMLDivElement>(null);
  const inView = useInView(ref, { amount: 0.4 });
  const [i, setI] = useState(0);
  const [t, setT] = useState(reduce ? 1e5 : 0);

  useEffect(() => {
    if (reduce || !inView) return;
    const start = performance.now() - t;
    const id = setInterval(() => {
      const e = performance.now() - start;
      if (e > 6200) {
        setI((v) => (v + 1) % SAID.length);
        setT(0);
      } else setT(e);
    }, 60);
    return () => clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [i, inView, reduce]);

  const s = SAID[i];
  const words = s.words.split(" ");
  const heard = Math.min(words.length, Math.floor(t / 230));
  const listening = heard < words.length;
  const doneAt = (k: number) => words.length * 230 + 500 + k * 700;

  return (
    <div ref={ref} className="relative h-full min-h-[380px] overflow-hidden rounded-[24px] sm:min-h-[430px]" style={{ background: "var(--wall)" }}>
      <div className="absolute inset-x-0 top-0 flex h-7 items-center justify-between px-4 text-[11px]" style={{ background: "var(--menubar)", color: "var(--menubar-fg)" }}>
        <span className="font-semibold">Finder</span>
        <span className="tnum">Tue 3:12</span>
      </div>
      <div className="absolute left-1/2 top-0 w-[min(400px,78%)] -translate-x-1/2">
        <div className="rounded-b-[24px] bg-black px-5 pb-5 pt-9 text-white shadow-[0_24px_50px_-16px_rgba(0,0,0,0.6)]">
          <div className="flex items-center gap-3">
            <span className="flex h-5 items-center gap-[3px]" aria-hidden="true">
              {[0.4, 0.75, 1, 0.55, 0.9, 0.45, 0.7].map((h, k) => (
                <span key={k} className={`w-[3px] rounded-full bg-white ${listening ? "voice-bar" : "voice-bar-idle opacity-40"}`} style={{ height: `${h * 100}%`, animationDelay: `${k * 0.08}s` }} />
              ))}
            </span>
            <span className="text-[12px] text-white/60">{listening ? "Listening" : "Done"}</span>
          </div>
          <p className="mt-3 min-h-[2.9em] text-[17px] leading-snug">
            “
            {words.slice(0, heard).map((w, k) => (
              <motion.span key={`${i}-${k}`} initial={reduce ? false : { opacity: 0, filter: "blur(4px)" }} animate={{ opacity: 1, filter: "blur(0px)" }} transition={{ duration: 0.25 }}>
                {k > 0 ? " " : ""}
                {w}
              </motion.span>
            ))}
            {listening && <span className="caret" style={{ background: "#bf5af2" }} />}”
          </p>
          <ul className="mt-3 grid gap-1.5 border-t border-white/10 pt-3">
            <AnimatePresence initial={false}>
              {s.did.map((d, k) =>
                t > doneAt(k) ? (
                  <motion.li
                    key={`${i}-${d}`}
                    initial={reduce ? false : { opacity: 0, x: -6 }}
                    animate={{ opacity: 1, x: 0 }}
                    transition={{ duration: 0.35, ease: EASE }}
                    className="flex items-center gap-2.5 text-[13px] text-white/85"
                  >
                    <span className="flex h-4 w-4 shrink-0 items-center justify-center rounded-full bg-[#30d158] text-black">
                      <svg viewBox="0 0 24 24" className="h-2.5 w-2.5" fill="none" stroke="currentColor" strokeWidth="3.4" strokeLinecap="round" strokeLinejoin="round">
                        <path d="M5 12l5 5 9-10" />
                      </svg>
                    </span>
                    {d}
                  </motion.li>
                ) : null,
              )}
            </AnimatePresence>
            {t <= doneAt(0) && <li className="text-[13px] text-white/35">…</li>}
          </ul>
        </div>
      </div>
      <div className="absolute inset-x-0 bottom-5 flex justify-center gap-1.5">
        {SAID.map((_, k) => (
          <span key={k} className={`h-1.5 rounded-full bg-white transition-all duration-500 ${k === i ? "w-5 opacity-90" : "w-1.5 opacity-50"}`} />
        ))}
      </div>
    </div>
  );
}
