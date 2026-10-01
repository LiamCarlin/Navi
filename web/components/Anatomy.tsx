"use client";

import { motion, type MotionValue, useMotionValueEvent, useReducedMotion, useScroll, useTransform } from "framer-motion";
import { useRef, useState } from "react";
import { Head, Reveal } from "./motion/Reveal";
import { EASE } from "@/lib/motion";

type Lane = "mac" | "decide" | "write";
type Ev = { t: number; lane: Lane; short: string; long: string; flag?: "ask" };

const T = 3.2; // seconds on the axis

const LANES: { id: Lane; name: string; sub: string; tint: string }[] = [
  { id: "mac", name: "Your Mac", sub: "Reads windows, clicks, types. Local.", tint: "#0a84ff" },
  { id: "decide", name: "Decides", sub: "A small model that only makes choices, about 0.1 s each.", tint: "#bf5af2" },
  { id: "write", name: "Writes", sub: "A larger model, only when words need writing.", tint: "#ff9f0a" },
];

const EVENTS: Ev[] = [
  { t: 0, lane: "mac", short: "⏎", long: "You press ⏎. The local rows have been updating on every keystroke already." },
  { t: 0.1, lane: "decide", short: "Do a task · 0.96", long: "What is this? A task, 96% sure. It sends a message, so it will stop and ask before that part." },
  { t: 0.24, lane: "decide", short: "Messages", long: "Which app? Messages, not WhatsApp: it’s where you usually talk to Sam." },
  { t: 0.45, lane: "mac", short: "Open", long: "Messages opens behind the window you’re in. Your cursor and focus don’t move." },
  { t: 0.72, lane: "mac", short: "Read", long: "Reads the window as a list of controls and text, the way a screen reader would. No screenshot needed." },
  { t: 0.88, lane: "decide", short: "New message · 0.93", long: "Next move: start a new message." },
  { t: 1.08, lane: "mac", short: "To: sam", long: "Types “sam” into the To: field, so Messages starts looking up contacts." },
  { t: 1.62, lane: "mac", short: "Pick contact", long: "Waits for the suggestions and picks the person, Sam Rivera, over the group chat that starts with the same name." },
  { t: 1.86, lane: "decide", short: "Type it · 0.95", long: "Next move: type the message into the body." },
  { t: 2.36, lane: "mac", short: "Type", long: "Types “I’m 10 minutes late”." },
  { t: 2.62, lane: "decide", short: "Send · can’t undo", long: "Next move would be Return, which sends. That can’t be undone." },
  { t: 2.74, lane: "mac", short: "Ask you", long: "So it stops and asks: send this to Sam Rivera? ⌘⏎ sends it, ⌘⌫ doesn’t.", flag: "ask" },
];

/**
 * "How it works": one run, slowed down and scrubbed by the scroll. Three lanes show who
 * did what; the log underneath says it in words. On phones it's a plain vertical list.
 */
export function Anatomy() {
  return (
    <section id="how" className="scroll-mt-16">
      <div className="px-4 pt-24 sm:px-6 md:pt-32">
        <Head
          title={["What happens", "after you press ⏎"]}
          sub="A fast model only makes choices and says how sure it is. A slower one only writes, and only when something needs writing. Everything else happens on your Mac."
        />
      </div>
      <Scrubbed />
      <Stacked />
    </section>
  );
}

function Scrubbed() {
  const reduce = useReducedMotion();
  const outer = useRef<HTMLDivElement>(null);
  const { scrollYProgress } = useScroll({ target: outer, offset: ["start start", "end end"] });
  const clock = useTransform(scrollYProgress, [0.04, 0.92], [0, T], { clamp: true });
  const [t, setT] = useState(reduce ? T : 0);
  useMotionValueEvent(clock, "change", (v) => !reduce && setT(Math.round(v * 100) / 100));
  const left = useTransform(clock, (v) => `${(v / T) * 100}%`);

  const seen = EVENTS.filter((e) => e.t <= t);
  const current = seen[seen.length - 1];

  return (
    <div ref={outer} className="relative hidden h-[320vh] lg:block">
      <div className="sticky top-0 flex h-screen items-center px-6">
        <div className="mx-auto w-full max-w-6xl">
          <div className="mb-6 flex items-baseline justify-between">
            <div className="flex items-baseline gap-3">
              <span className="text-sm text-fg-muted">You typed</span>
              <span className="glass-dark rounded-full px-3.5 py-1.5 text-[14px]">text sam i’m 10 minutes late</span>
            </div>
            <div className="tnum font-mono text-[2.4rem] leading-none tracking-tight">
              {t.toFixed(2)}
              <span className="ml-1 text-base text-fg-dim">s</span>
            </div>
          </div>

          <div className="card relative overflow-hidden bg-white">
            {/* time axis */}
            <div className="relative ml-[220px] mr-8 flex h-10 items-end justify-between border-b border-line pb-2">
              {Array.from({ length: Math.round(T / 0.5) + 1 }, (_, i) => i * 0.5).map((s) => (
                <span key={s} className="mono -translate-x-1/2 first:translate-x-0">
                  {s.toFixed(1)}
                </span>
              ))}
            </div>
            {LANES.map((lane) => (
              <div key={lane.id} className="relative flex h-[104px] items-center border-b border-line last:border-b-0">
                <div className="w-[220px] shrink-0 px-6">
                  <div className="flex items-center gap-2 text-[15px] font-medium">
                    <span className="h-2 w-2 rounded-full" style={{ background: lane.tint }} />
                    {lane.name}
                  </div>
                  <div className="mt-1 text-[12.5px] leading-snug text-fg-dim">{lane.sub}</div>
                </div>
                <div className="relative mr-8 h-full flex-1">
                  {EVENTS.filter((e) => e.lane === lane.id).map((e, i) => {
                    const on = e.t <= t;
                    const up = i % 2 === 0;
                    return (
                      <motion.div
                        key={e.t}
                        className="absolute top-1/2"
                        style={{ left: `${(e.t / T) * 100}%` }}
                        initial={false}
                        animate={{ opacity: on ? 1 : 0, scale: on ? 1 : 0.6 }}
                        transition={{ duration: 0.35, ease: EASE }}
                      >
                        <span
                          className="absolute -translate-x-1/2 -translate-y-1/2 rounded-full"
                          style={{ width: 10, height: 10, background: e.flag ? "#ff9f0a" : lane.tint, boxShadow: `0 0 0 4px #fff` }}
                        />
                        <span
                          className={`absolute -translate-x-1/2 whitespace-nowrap text-[12px] font-medium ${up ? "-top-8" : "top-4"} ${current === e ? "text-fg" : "text-fg-muted"}`}
                        >
                          {e.short}
                        </span>
                      </motion.div>
                    );
                  })}
                  {lane.id === "write" && (
                    <div className="absolute inset-x-0 top-1/2 flex -translate-y-1/2 items-center gap-4">
                      <span className="h-px flex-1 border-t border-dashed border-line-strong" />
                      <span className="shrink-0 rounded-full bg-bg-soft px-3 py-1 text-[12.5px] text-fg-muted ring-1 ring-line">
                        Idle: nothing here needed writing. It would run for “tell Sam why I’m late, nicely”.
                      </span>
                      <span className="h-px w-10 border-t border-dashed border-line-strong" />
                    </div>
                  )}
                </div>
              </div>
            ))}
            <Playhead left={left} />
          </div>

          {/* log */}
          <div className="mt-8 grid grid-cols-12 gap-8">
            <div className="col-span-7 min-h-[96px]">
              <motion.p
                key={current?.t ?? -1}
                initial={reduce ? false : { opacity: 0, y: 10 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ duration: 0.4, ease: EASE }}
                className="text-[1.5rem] font-medium leading-[1.3] tracking-[-0.025em]"
              >
                {current?.long}
              </motion.p>
            </div>
            <p className="col-span-4 col-start-9 text-[13px] leading-relaxed text-fg-dim">
              Scroll moves the clock. Timings are typical for this kind of task, not a benchmark; your network and your Mac
              change them. The pause before picking the contact is Messages filling in its suggestion list.
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}

function Playhead({ left }: { left: MotionValue<string> }) {
  return (
    <div className="pointer-events-none absolute bottom-0 left-[220px] right-8 top-10">
      <motion.div className="absolute bottom-0 top-0 w-px bg-fg" style={{ left }}>
        <span className="absolute -left-[3px] -top-[3px] h-[7px] w-[7px] rounded-full bg-fg" />
      </motion.div>
    </div>
  );
}

function Stacked() {
  return (
    <div className="px-4 pb-24 pt-12 sm:px-6 lg:hidden">
      <div className="mb-6 flex flex-wrap items-baseline gap-2">
        <span className="text-sm text-fg-muted">You typed</span>
        <span className="glass-dark rounded-full px-3.5 py-1.5 text-[14px]">text sam i’m 10 minutes late</span>
      </div>
      <ol className="relative border-l border-line">
        {EVENTS.map((e, i) => {
          const lane = LANES.find((l) => l.id === e.lane)!;
          return (
            <Reveal as="li" key={e.t} i={0} className="relative pb-7 pl-6 last:pb-0">
              <span className="absolute -left-[5px] top-1.5 h-[9px] w-[9px] rounded-full" style={{ background: e.flag ? "#ff9f0a" : lane.tint }} />
              <div className="flex items-baseline gap-3">
                <span className="mono">{e.t.toFixed(2)} s</span>
                <span className="text-[13px] font-medium" style={{ color: lane.tint }}>
                  {lane.name}
                </span>
              </div>
              <p className="body mt-1 text-fg">{e.long}</p>
              {i === EVENTS.length - 1 && <p className="mt-4 text-[13px] text-fg-dim">Timings are typical, not a benchmark.</p>}
            </Reveal>
          );
        })}
      </ol>
    </div>
  );
}
