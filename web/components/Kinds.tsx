"use client";

import { motion, useReducedMotion, useScroll, useSpring } from "framer-motion";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { Bar } from "./bar/Bar";
import { exampleBody } from "./bar/bodies";
import { Head } from "./motion/Reveal";
import { EXAMPLES, KIND_LABEL, KIND_TINT, type Kind } from "@/lib/demo";

type Step = { kind: Kind; title: string; body: ReactNode; facts: string[]; sure: number; runs: string; asks: string };

const STEPS: Step[] = [
  {
    kind: "open",
    sure: 0.98,
    runs: "On your Mac",
    asks: "No",
    title: "Opening things is instant.",
    body: "Apps, files, folders, System Settings panes and toggles like Dark Mode match as you type, from an index on your Mac. Those rows appear before any server has answered, so ⏎ never waits. Every list also offers to ask Navi or search the web instead.",
    facts: ["On-device index", "⏎ open", "⌘⏎ ask Navi instead"],
  },
  {
    kind: "calc",
    sure: 0.99,
    runs: "On your Mac",
    asks: "No",
    title: "Math answers before you finish typing.",
    body: "Arithmetic, percentages and tips are worked out on the Mac and shown as the first result. ⏎ copies it.",
    facts: ["On-device", "18% of $64.50 → $11.61"],
  },
  {
    kind: "answer",
    sure: 0.94,
    runs: "Streams from Navi’s service",
    asks: "No",
    title: "Questions get an answer, not a page of links.",
    body: "When what you typed reads as a question, the answer streams into the bar, short enough to read at a glance. ⌘C copies it. No browser tab, no chat window to close afterwards.",
    facts: ["Streams in the bar", "⌘C copy"],
  },
  {
    kind: "task",
    sure: 0.96,
    runs: "Messages, in the background",
    asks: "Before sending",
    title: "Tasks run in the app, behind your window.",
    body: "Give it a job and Navi works out which app it needs, opens it in the background and goes step by step: find the contact, type the message. Sending is the one step it won’t take alone. That waits for you to press ⌘⏎.",
    facts: ["Asks before send, pay, delete", "esc stops it"],
  },
  {
    kind: "schedule",
    sure: 0.91,
    runs: "Your calendars, through macOS",
    asks: "Before inviting",
    title: "Meetings, without the back-and-forth.",
    body: "Type who and roughly when, and a card drops down with everyone on one timeline and three times you’re all free. ⏎ books it and sends the invites. It uses the Google, Exchange and iCloud calendars already on your Mac. If someone’s calendar isn’t shared with you, it shows the meetings you have in common.",
    facts: ["↑↓ time", "⌘[ ⌘] day", "⏎ book + invite"],
  },
  {
    kind: "remind",
    sure: 0.97,
    runs: "Apple Reminders",
    asks: "No",
    title: "A reminder is one sentence.",
    body: "The task, the time and the alert are filled in from what you typed. “every sunday morning” repeats it, “urgent” flags it. It goes into Apple Reminders, so it’s on your phone too.",
    facts: ["Repeats", "Priority", "Your Reminders lists"],
  },
  {
    kind: "recall",
    sure: 0.93,
    runs: "Your notes, on your disk",
    asks: "No",
    title: "Ask about your own day.",
    body: "With Recall on, Navi keeps notes on what was on your screen, so “what was I working on yesterday afternoon” has a real answer, with the moments it came from.",
    facts: ["Optional", "Notes stay in a folder you own"],
  },
];

const exampleFor = (k: Kind) => EXAMPLES.find((e) => e.kind === k && (k !== "open" || e.q === "maps"))!;

/**
 * "What it does": the steps scroll past on the left while the bar on the right stays put
 * and changes to match. On phones each step carries its own bar instead.
 */
export function Kinds() {
  const reduce = useReducedMotion();
  const [active, setActive] = useState(0);
  const list = useRef<HTMLDivElement>(null);
  const { scrollYProgress } = useScroll({ target: list, offset: ["start center", "end center"] });
  const rail = useSpring(scrollYProgress, { stiffness: 140, damping: 30 });

  useEffect(() => {
    const els = list.current?.querySelectorAll<HTMLElement>("[data-step]");
    if (!els) return;
    const io = new IntersectionObserver(
      (es) => es.forEach((e) => e.isIntersecting && setActive(Number((e.target as HTMLElement).dataset.step))),
      { rootMargin: "-48% 0px -48% 0px" },
    );
    els.forEach((el) => io.observe(el));
    return () => io.disconnect();
  }, []);

  return (
    <section id="what" className="scroll-mt-16 px-4 py-24 sm:px-6 md:py-32">
      <div className="mx-auto max-w-6xl">
        <Head
          title={["One bar,", "seven kinds of answer"]}
          sub="You don’t pick a mode. Navi decides whether you meant something to open, a sum, a question, a job, a meeting, a reminder or a memory."
        />

        <div className="relative mt-16 grid grid-cols-1 gap-8 lg:mt-24 lg:grid-cols-12">
          {/* Steps */}
          <div ref={list} className="relative lg:col-span-5">
            <div className="absolute bottom-0 left-0 top-0 hidden w-px bg-line lg:block" aria-hidden="true">
              <motion.div className="absolute inset-x-0 top-0 h-full origin-top" style={{ scaleY: rail, background: "var(--fg)" }} />
            </div>
            {STEPS.map((s, i) => (
              <div key={s.kind} data-step={i} className="flex min-h-0 flex-col justify-center py-10 lg:min-h-[78vh] lg:py-0 lg:pl-10">
                <motion.div
                  animate={{ opacity: reduce || active === i ? 1 : 0.28 }}
                  transition={{ duration: 0.5 }}
                  className="max-lg:!opacity-100"
                >
                  <div className="flex items-center gap-2.5">
                    <span className="h-2 w-2 rounded-full" style={{ background: KIND_TINT[s.kind] }} />
                    <span className="text-sm font-medium">{KIND_LABEL[s.kind]}</span>
                    <span className="mono ml-1">“{exampleFor(s.kind).q}”</span>
                  </div>
                  <h3 className="mt-4 text-[1.75rem] font-medium leading-[1.12] tracking-[-0.03em] sm:text-[2rem]">{s.title}</h3>
                  <p className="body mt-4 max-w-[46ch] text-[1.03rem]">{s.body}</p>
                  <ul className="mt-5 flex flex-wrap gap-2">
                    {s.facts.map((f) => (
                      <li key={f} className="rounded-full bg-bg-soft px-3 py-1 text-[13px] text-fg-muted ring-1 ring-line">
                        {f}
                      </li>
                    ))}
                  </ul>
                </motion.div>
                <div className="mt-8 lg:hidden">
                  <MiniDesk step={s} live={false} />
                </div>
              </div>
            ))}
          </div>

          {/* The bar that stays */}
          <div className="hidden lg:col-span-7 lg:block">
            <div className="sticky top-[14vh] h-[72vh]">
              <MiniDesk step={STEPS[active]} live index={active} />
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

/** A wallpaper panel with the bar on it, showing one kind. `live` replays typing and streaming on change. */
function MiniDesk({ step, live, index = 0 }: { step: Step; live: boolean; index?: number }) {
  const reduce = useReducedMotion();
  const kind = step.kind;
  const ex = exampleFor(kind);
  const [t, setT] = useState(live && !reduce ? 0 : 1e6);

  useEffect(() => {
    if (!live || reduce) return;
    const start = performance.now();
    let raf = 0;
    const tick = (now: number) => {
      const e = now - start;
      setT(e);
      if (e < 7000) raf = requestAnimationFrame(tick);
    };
    setT(0);
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [kind, live, reduce]);

  const typeMs = 22;
  const typed = Math.min(ex.q.length, Math.floor(t / typeMs));
  const enteredAt = ex.q.length * typeMs + 250;
  const view = t >= enteredAt ? exampleBody(ex, t - enteredAt) : null;

  return (
    <div
      className="relative h-full min-h-[420px] overflow-hidden rounded-[24px] shadow-[0_30px_80px_-40px_rgba(30,40,90,0.5)] sm:rounded-[32px]"
      style={{ background: "var(--wall)" }}
    >
      {live && (
        <div className="mono absolute left-5 top-4 z-10 flex items-center gap-2 !text-white/80">
          <span className="tnum">{String(index + 1).padStart(2, "0")} / {String(STEPS.length).padStart(2, "0")}</span>
        </div>
      )}
      <div className="stage absolute inset-x-4 top-[12%] mx-auto max-w-[620px] sm:inset-x-8">
        <Bar query={ex.q.slice(0, typed)} caret={typed < ex.q.length || !view} body={view?.body} bodyKey={view?.key} hints={view?.hints} />
      </div>
      <div className="absolute inset-x-4 bottom-4 sm:inset-x-8 sm:bottom-8">
        <div className="glass mx-auto grid max-w-[620px] grid-cols-3 divide-x divide-[var(--panel-line)] rounded-[16px] text-[12px] sm:text-[13px]">
          {[
            ["Decided", `${KIND_LABEL[kind]} · ${Math.round(step.sure * 100)}%`],
            ["Runs", step.runs],
            ["Asks first", step.asks],
          ].map(([k, v]) => (
            <div key={k} className="min-w-0 px-3 py-2.5 sm:px-4 sm:py-3">
              <div className="text-panel-dim text-[11px]">{k}</div>
              <motion.div key={v} initial={reduce ? false : { opacity: 0, y: 4 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.35, delay: 0.1 }} className="mt-0.5 truncate font-medium">
                {v}
              </motion.div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
