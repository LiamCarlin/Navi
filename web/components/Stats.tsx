"use client";

import { animate, motion, useInView, useReducedMotion } from "framer-motion";
import { useEffect, useRef, useState } from "react";
import { Lines, Reveal } from "./motion/Reveal";
import { EASE } from "@/lib/motion";

const STATS = [
  { n: 0.1, fmt: (v: number) => `~${v.toFixed(1)}`, unit: "s", title: "To decide what you meant", body: "One call to a small model that returns a choice and how sure it is. Not a paragraph." },
  { n: 115, fmt: (v: number) => `${Math.round(v)}+`, unit: "", title: "Apps and sites it knows", body: "Written playbooks for 60+ Mac apps and 55+ websites, plus what worked for you before." },
  { n: 0, fmt: () => "0", unit: "", title: "API keys to paste", body: "One subscription covers answers, tasks, voice and Recall. No model menus." },
];

const DECISION = [
  { k: "kind", v: "do a task", p: 0.96 },
  { k: "app", v: "Messages", p: 0.91 },
  { k: "can’t undo", v: "sends a message", p: 0.94 },
  { k: "needs you", v: "before sending", p: 0.97 },
];

export function Stats() {
  return (
    <section className="px-4 py-24 sm:px-6 md:py-32">
      <div className="mx-auto grid max-w-6xl grid-cols-1 items-center gap-12 lg:grid-cols-2 lg:gap-16">
        <Reveal className="card p-6 sm:p-10">
          <DecisionCard />
        </Reveal>
        <div>
          <Lines className="h-section" lines={["Fast, because it", "decides first"]} />
          <dl className="mt-10 divide-y divide-line">
            {STATS.map((s, i) => (
              <Reveal key={s.title} i={i} className="grid grid-cols-[7.5rem_1fr] gap-6 py-6 sm:grid-cols-[9rem_1fr]">
                <dt className="tnum text-[2.6rem] font-medium leading-none tracking-[-0.04em]">
                  <Count to={s.n} fmt={s.fmt} />
                  <span className="ml-1 text-[1.1rem] tracking-normal text-fg-dim">{s.unit}</span>
                </dt>
                <dd>
                  <div className="text-[1.3rem] font-medium tracking-[-0.02em]">{s.title}</div>
                  <p className="body mt-1.5 text-[14.5px]">{s.body}</p>
                </dd>
              </Reveal>
            ))}
          </dl>
        </div>
      </div>
    </section>
  );
}

function Count({ to, fmt }: { to: number; fmt: (v: number) => string }) {
  const ref = useRef<HTMLSpanElement>(null);
  const inView = useInView(ref, { once: true, amount: 1 });
  const reduce = useReducedMotion();
  const [v, setV] = useState(reduce ? to : 0);
  useEffect(() => {
    if (!inView || reduce) return;
    const c = animate(0, to, { duration: 1.4, ease: EASE, onUpdate: setV });
    return () => c.stop();
  }, [inView, reduce, to]);
  return <span ref={ref}>{fmt(v)}</span>;
}

/** What the decision for “text sam i’m 10 minutes late” looks like: typed fields with probabilities, not prose. */
function DecisionCard() {
  const ref = useRef<HTMLDivElement>(null);
  const inView = useInView(ref, { once: true, amount: 0.5 });
  const reduce = useReducedMotion();
  return (
    <div ref={ref}>
      <div className="glass-dark rounded-full px-4 py-2 text-[14px]">
        <span className="text-white/50">You typed </span>text sam i’m 10 minutes late
      </div>
      <div className="glass-dark mt-4 rounded-[20px] p-5 font-mono text-[13px]">
        <div className="flex items-center justify-between text-white/45">
          <span>decision</span>
          <span>0.09 s</span>
        </div>
        <ul className="mt-4 space-y-3.5">
          {DECISION.map((d, i) => (
            <li key={d.k}>
              <div className="flex items-baseline justify-between gap-3">
                <span className="w-24 shrink-0 text-white/45">{d.k}</span>
                <span className="flex-1 truncate text-white">{d.v}</span>
                <span className="tnum text-white/70">{d.p.toFixed(2)}</span>
              </div>
              <div className="mt-1.5 h-[3px] overflow-hidden rounded-full bg-white/10">
                <motion.div
                  className="h-full rounded-full"
                  style={{ background: "linear-gradient(90deg,#4b8dff,#9db8ff)", originX: 0 }}
                  initial={reduce ? false : { scaleX: 0 }}
                  animate={inView ? { scaleX: d.p } : undefined}
                  transition={{ duration: 0.9, ease: EASE, delay: 0.2 + i * 0.12 }}
                />
              </div>
            </li>
          ))}
        </ul>
      </div>
      <p className="mt-5 text-[13px] leading-relaxed text-fg-muted">
        The decision behind one task. Every step after it is another quick decision like this one, which is how Navi knows to
        stop before it sends.
      </p>
    </div>
  );
}
