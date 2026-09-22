"use client";

import { AnimatePresence, motion } from "framer-motion";
import { useState } from "react";
import { Reveal } from "./Reveal";

const items = [
  {
    q: "Which Macs does it run on?",
    a: "Navi needs macOS 26 Tahoe on an Apple silicon Mac (M1 or later). The panel, the launcher, the calculator and screen reading all run natively.",
  },
  {
    q: "Do I need my own API keys?",
    a: "No. One subscription covers everything: answers, tasks, voice, and Recall. There are no keys to paste, no models to pick, and no separate bills.",
  },
  {
    q: "What does Navi see?",
    a: "Only what you ask it to. When you type a question or a task, Navi looks at the window it needs to work in and nothing else. Recall is a separate, opt-in tier: it reads your screen locally, skips anything sensitive, and writes plain-text notes into a vault on your own disk.",
  },
  {
    q: "Is it safe to let it click things?",
    a: "Navi works in the background so you keep your cursor, and it stops to ask before anything it can't undo: sending a message, paying for something, deleting a file. Say “stop” or press Escape to halt a task instantly.",
  },
  {
    q: "When can I get it?",
    a: "Join the waitlist and you'll get an invite in order. Early invites go out to the first people on the list as builds are ready; everyone gets a 7-day Pro trial when they join.",
  },
];

export function FAQ() {
  const [open, setOpen] = useState<number | null>(0);
  return (
    <section id="faq" className="scroll-mt-20 px-4 py-20 sm:px-6 md:py-28">
      <div className="mx-auto max-w-3xl">
        <Reveal>
          <h2 className="text-balance text-3xl font-semibold tracking-tight sm:text-4xl">Questions</h2>
        </Reveal>
        <Reveal delay={0.05}>
          <div className="mt-10 divide-y divide-line border-y border-line">
            {items.map((it, i) => {
              const isOpen = open === i;
              return (
                <div key={it.q}>
                  <button
                    type="button"
                    className="flex w-full items-center justify-between gap-4 py-5 text-left text-base font-medium transition-colors hover:text-accent"
                    aria-expanded={isOpen}
                    aria-controls={`faq-${i}`}
                    onClick={() => setOpen(isOpen ? null : i)}
                  >
                    {it.q}
                    <span
                      className={`shrink-0 text-fg-dim transition-transform duration-300 ${isOpen ? "rotate-45" : ""}`}
                      aria-hidden="true"
                    >
                      +
                    </span>
                  </button>
                  <AnimatePresence initial={false}>
                    {isOpen && (
                      <motion.div
                        id={`faq-${i}`}
                        key="content"
                        initial={{ height: 0, opacity: 0 }}
                        animate={{ height: "auto", opacity: 1 }}
                        exit={{ height: 0, opacity: 0 }}
                        transition={{ duration: 0.3, ease: [0.22, 1, 0.36, 1] }}
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
