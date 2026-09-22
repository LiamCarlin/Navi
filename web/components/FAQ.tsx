"use client";

import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { useState } from "react";
import { Reveal } from "./Reveal";

const items = [
  {
    q: "Which Macs does it run on?",
    a: "macOS 26 Tahoe on Apple silicon (M1 or later). The launcher, calculator, and voice transcription run on the Mac itself.",
  },
  {
    q: "Do I need my own API keys?",
    a: "No. One subscription covers answers, tasks, voice, and Recall. Nothing to paste, no models to pick.",
  },
  {
    q: "What does Navi see?",
    a: "Only what you ask it to: the window a task needs, and nothing else. Recall is a separate, opt-in tier that reads your screen locally, skips anything sensitive, and writes notes to a folder you own.",
  },
  {
    q: "Is it safe to let it click things?",
    a: "Tasks run in the background so you keep your cursor, and Navi stops to ask before anything it can’t undo — sending, paying, deleting. Say “stop” or press Escape to halt a task instantly.",
  },
  {
    q: "When can I get it?",
    a: "Join the waitlist; invites go out in order as builds are ready. Everyone gets a 7-day Pro trial.",
  },
];

export function FAQ() {
  const [open, setOpen] = useState<number | null>(0);
  const reduce = useReducedMotion();
  return (
    <section id="faq" className="scroll-mt-16 px-4 py-24 sm:px-6 md:py-32">
      <div className="mx-auto max-w-3xl">
        <Reveal>
          <h2 className="h-section">Questions</h2>
        </Reveal>
        <Reveal delay={0.05}>
          <div className="mt-8 divide-y divide-line border-y border-line">
            {items.map((it, i) => {
              const isOpen = open === i;
              return (
                <div key={it.q}>
                  <button
                    type="button"
                    className="flex w-full items-center justify-between gap-4 py-5 text-left text-[15px] font-medium transition-colors duration-200 hover:text-accent"
                    aria-expanded={isOpen}
                    aria-controls={`faq-${i}`}
                    onClick={() => setOpen(isOpen ? null : i)}
                  >
                    {it.q}
                    <span className={`shrink-0 text-fg-dim transition-transform duration-200 ${isOpen ? "rotate-45" : ""}`} aria-hidden="true">
                      +
                    </span>
                  </button>
                  <AnimatePresence initial={false}>
                    {isOpen && (
                      <motion.div
                        id={`faq-${i}`}
                        key="content"
                        initial={reduce ? false : { height: 0, opacity: 0 }}
                        animate={{ height: "auto", opacity: 1 }}
                        exit={reduce ? undefined : { height: 0, opacity: 0 }}
                        transition={{ duration: 0.24, ease: [0.22, 1, 0.36, 1] }}
                        className="overflow-hidden"
                      >
                        <p className="pb-5 text-sm leading-relaxed text-fg-muted">{it.a}</p>
                      </motion.div>
                    )}
                  </AnimatePresence>
                </div>
              );
            })}
          </div>
        </Reveal>
      </div>
    </section>
  );
}
