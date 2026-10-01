"use client";

import { motion, useMotionValueEvent, useReducedMotion, useScroll } from "framer-motion";
import { useRef, useState } from "react";
import { Lines, Reveal } from "./motion/Reveal";
import { EASE, progress } from "@/lib/motion";

type Node = { id: string; x: number; y: number; label: string; day?: boolean };
const NODES: Node[] = [
  { id: "d", x: 300, y: 210, label: "Tue, Sep 30", day: true },
  { id: "pricing", x: 150, y: 110, label: "Pricing doc" },
  { id: "annual", x: 70, y: 220, label: "Annual billing" },
  { id: "xcode", x: 470, y: 120, label: "ResultsListView.swift" },
  { id: "anim", x: 520, y: 250, label: "List animation" },
  { id: "maya", x: 190, y: 330, label: "Maya Patel" },
  { id: "launch", x: 400, y: 340, label: "Navi launch" },
  { id: "m", x: 300, y: 50, label: "Mon, Sep 29", day: true },
  { id: "w", x: 560, y: 380, label: "Wed, Oct 1", day: true },
];
const EDGES: [string, string][] = [
  ["d", "pricing"],
  ["pricing", "annual"],
  ["d", "xcode"],
  ["xcode", "anim"],
  ["d", "maya"],
  ["d", "launch"],
  ["maya", "launch"],
  ["m", "pricing"],
  ["m", "xcode"],
  ["launch", "w"],
  ["anim", "w"],
  ["pricing", "maya"],
];

const PIPE = [
  ["Capture", "A frame now and then, from the apps you haven’t excluded. Paused for an hour or a day in one click."],
  ["Read", "Text is read off the frame on your Mac. Passwords, and anything you’ve told it not to keep, like card numbers or IDs: the frame is dropped right here."],
  ["Triage", "A quick check: is this new, is it important, is it sensitive? Most frames stop here."],
  ["Summarize", "Only the moments that matter are summarized, with personal details redacted before and after."],
  ["Write", "Plain Markdown notes in a folder you own, linked by people, projects and days. Open it in Obsidian and it’s a graph."],
];

const DATA = [
  ["Phone numbers", true],
  ["Addresses", true],
  ["Dates of birth", false],
  ["Card numbers", false],
  ["SSNs and ID numbers", false],
  ["Account numbers", false],
  ["Health information", false],
] as const;

export function Recall() {
  const reduce = useReducedMotion();
  const ref = useRef<HTMLDivElement>(null);
  const { scrollYProgress } = useScroll({ target: ref, offset: ["start 80%", "end 45%"] });
  const [p, setP] = useState(reduce ? 1 : 0);
  useMotionValueEvent(scrollYProgress, "change", (v) => !reduce && setP(Math.round(v * 300) / 300));

  const edgeP = (i: number) => progress(p, 0.05 + i * 0.06, 0.17 + i * 0.06);
  const nodeOn = (id: string) => id === "d" ? p > 0.02 : EDGES.some(([a, b], i) => (a === id || b === id) && edgeP(i) > 0.6);
  const at = (id: string) => NODES.find((n) => n.id === id)!;

  return (
    <section id="recall" className="scroll-mt-16 px-4 py-24 sm:px-6 md:py-36">
      <div className="mx-auto max-w-7xl">
        <div className="grid grid-cols-1 gap-6 lg:grid-cols-12 lg:gap-8">
          <Lines className="h-section lg:col-span-7" lines={["Recall: ask what", "you were doing."]} />
          <Reveal className="lg:col-span-5 lg:pt-3">
            <p className="lede">
              An optional part of Navi. It keeps a diary of your screen as plain notes, so “what was I working on yesterday
              afternoon” or “that article about annual billing I read last week” has an answer.
            </p>
          </Reveal>
        </div>

        <div ref={ref} className="mt-16 grid grid-cols-1 items-center gap-10 lg:mt-20 lg:grid-cols-12 lg:gap-8">
          <div className="relative lg:col-span-7">
            <div className="card relative overflow-hidden p-2 sm:p-4">
              <svg viewBox="0 0 620 420" className="h-auto w-full" role="img" aria-label="A graph of linked notes: days, documents, people and projects">
                {EDGES.map(([a, b], i) => {
                  const A = at(a);
                  const B = at(b);
                  return (
                    <motion.line
                      key={a + b}
                      x1={A.x}
                      y1={A.y}
                      x2={B.x}
                      y2={B.y}
                      stroke="var(--fg-dim)"
                      strokeOpacity={0.5}
                      strokeWidth={1}
                      initial={false}
                      animate={{ pathLength: edgeP(i) }}
                      transition={{ duration: 0.2 }}
                    />
                  );
                })}
                {NODES.map((n) => {
                  const on = nodeOn(n.id);
                  return (
                    <motion.g
                      key={n.id}
                      initial={false}
                      animate={{ opacity: on ? 1 : 0, scale: on ? 1 : 0.5 }}
                      transition={{ duration: 0.45, ease: EASE }}
                      style={{ transformOrigin: `${n.x}px ${n.y}px` }}
                    >
                      <circle cx={n.x} cy={n.y} r={n.day ? 9 : 6} fill={n.day ? "#5e5ce6" : "var(--fg)"} />
                      {n.day && <circle cx={n.x} cy={n.y} r={15} fill="none" stroke="#5e5ce6" strokeOpacity={0.3} />}
                      <text x={n.x} y={n.y + (n.day ? 32 : 22)} textAnchor="middle" fontSize="14" fill="var(--fg-muted)" fontFamily="var(--font-geist-sans)" stroke="var(--bg-elev)" strokeWidth={5} paintOrder="stroke" strokeLinejoin="round">
                        {n.label}
                      </text>
                    </motion.g>
                  );
                })}
              </svg>
            </div>
          </div>

          <div className="lg:col-span-5">
            <motion.div
              className="card overflow-hidden"
              initial={false}
              animate={{ opacity: p > 0.35 ? 1 : 0.0, y: p > 0.35 ? 0 : 20 }}
              transition={{ duration: 0.6, ease: EASE }}
            >
              <div className="flex items-center justify-between border-b border-line px-5 py-3">
                <span className="label">Navi/2026-09-30.md</span>
                <span className="label">Markdown</span>
              </div>
              <div className="space-y-3 px-5 py-4 font-mono text-[12.5px] leading-relaxed text-fg-muted">
                <p className="text-fg"># Tuesday, September 30</p>
                <p>
                  <span className="text-fg">13:10–14:40</span> · Pages · Worked on the <L>Pricing doc</L>: Free, Pro, Pro + Recall.
                  Read two pieces on <L>Annual billing</L>.
                </p>
                <p>
                  <span className="text-fg">14:45</span> · Messages · <L>Maya Patel</L> about the <L>Navi launch</L> date.
                </p>
                <p>
                  <span className="text-fg">16:05–17:10</span> · Xcode · <L>ResultsListView.swift</L>, the <L>List animation</L>.
                </p>
                <p className="text-fg-dim">activity: writing, coding · sensitive frames: 3 dropped</p>
              </div>
            </motion.div>
          </div>
        </div>

        {/* pipeline */}
        <div className="mt-24 md:mt-32">
          <Reveal>
            <h3 className="font-serif text-[2rem] leading-tight tracking-[-0.02em]">From a frame on your screen to a note on your disk.</h3>
          </Reveal>
          <ol className="relative mt-10 grid grid-cols-1 gap-8 sm:grid-cols-2 lg:grid-cols-5 lg:gap-6">
            {PIPE.map(([k, v], i) => (
              <Reveal as="li" key={k} i={i} className="relative border-t border-line pt-5">
                <span className="absolute -top-px left-0 h-px w-10" style={{ background: "var(--grad)" }} />
                <div className="flex items-baseline gap-3">
                  <span className="label tnum">{i + 1}</span>
                  <span className="font-medium">{k}</span>
                </div>
                <p className="body mt-2 text-[14.5px]">{v}</p>
              </Reveal>
            ))}
          </ol>
        </div>

        {/* personal data */}
        <div className="mt-24 grid grid-cols-1 gap-10 md:mt-32 lg:grid-cols-12 lg:gap-8">
          <Reveal className="lg:col-span-5">
            <h3 className="font-serif text-[2rem] leading-tight tracking-[-0.02em]">You decide what it may remember.</h3>
            <p className="body mt-4 max-w-[46ch]">
              Settings → Recall has a switch for each kind of personal detail. These are the defaults. For anything switched off, a
              check on your Mac runs before anything is sent anywhere, and the frame is dropped if it matches. A cleanup can also
              remove details that were saved before you changed your mind.
            </p>
          </Reveal>
          <div className="lg:col-span-6 lg:col-start-7">
            <ul className="divide-y divide-line border-y border-line">
              {DATA.map(([k, on], i) => (
                <Reveal as="li" key={k} i={i} className="flex items-center justify-between py-3.5">
                  <span>{k}</span>
                  <Switch on={on} delay={0.3 + i * 0.05} />
                </Reveal>
              ))}
              <Reveal as="li" i={DATA.length} className="flex items-center justify-between py-3.5">
                <span>
                  Passwords and one-time codes <span className="text-fg-dim">· always blocked</span>
                </span>
                <span className="label">locked</span>
              </Reveal>
            </ul>
          </div>
        </div>
      </div>
    </section>
  );
}

function L({ children }: { children: React.ReactNode }) {
  return (
    <span className="text-accent">
      [[<span className="underline decoration-accent/40 underline-offset-2">{children}</span>]]
    </span>
  );
}

function Switch({ on, delay }: { on: boolean; delay: number }) {
  const reduce = useReducedMotion();
  return (
    <motion.span
      className="relative inline-flex h-[22px] w-[38px] shrink-0 rounded-full"
      initial={reduce ? false : { backgroundColor: "rgba(127,127,127,0.25)" }}
      whileInView={{ backgroundColor: on ? "#30d158" : "rgba(127,127,127,0.25)" }}
      viewport={{ once: true }}
      transition={{ delay, duration: 0.3 }}
      role="img"
      aria-label={on ? "on" : "off"}
    >
      <motion.span
        className="absolute top-[2px] h-[18px] w-[18px] rounded-full bg-white shadow"
        initial={reduce ? false : { left: 2 }}
        whileInView={{ left: on ? 18 : 2 }}
        viewport={{ once: true }}
        transition={{ delay, duration: 0.35, ease: EASE }}
      />
    </motion.span>
  );
}
