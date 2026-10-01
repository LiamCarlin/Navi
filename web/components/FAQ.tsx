"use client";

import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { useState } from "react";
import { Head, Reveal } from "./motion/Reveal";
import { EASE } from "@/lib/motion";

const items = [
  {
    q: "Which Macs does it run on?",
    a: "macOS 26 Tahoe on Apple silicon (M1 or later). It lives in the menu bar; there’s no window to keep open.",
  },
  {
    q: "Does it replace Spotlight?",
    a: "It takes over ⌘Space, and offers to turn off Spotlight’s shortcut so the two don’t collide. You can switch it back in System Settings whenever you like.",
  },
  {
    q: "Do I need my own API keys?",
    a: "No. One subscription covers answers, tasks, voice and Recall. Nothing to paste, no models to pick.",
  },
  {
    q: "Is it safe to let it click things?",
    a: "Tasks run behind your window, so your cursor and keyboard stay yours. Before anything it can’t undo (sending, paying, deleting) it stops and asks. Press esc or say “stop” to end a task at once.",
  },
  {
    q: "What happens when it gets stuck?",
    a: "When the fast model isn’t sure, or the same move isn’t working, it stops rather than guessing. A second, slower look at the screen either finishes the answer or suggests one next move; if that doesn’t help either, the task ends and tells you where it got to.",
  },
  {
    q: "Which apps can it use?",
    a: "Most Mac apps, since it works through the same accessibility interface screen readers use. It has written playbooks for 60+ apps and 55+ websites, and web tasks run in whichever browser you use: Safari, Arc, Firefox or Chrome.",
  },
  {
    q: "Does it work offline?",
    a: "Opening apps, files and settings, the calculator, and speech-to-text all work offline. Answers, tasks and Recall summaries need a connection.",
  },
  {
    q: "When can I get it?",
    a: "Join the waitlist; invites go out in order as builds are ready. Everyone starts with a 7-day Pro trial.",
  },
];

export function FAQ() {
  const [open, setOpen] = useState<number | null>(0);
  const reduce = useReducedMotion();
  return (
    <section id="faq" className="scroll-mt-16 px-4 py-24 sm:px-6 md:py-32">
      <div className="mx-auto max-w-3xl">
        <Head title={["Frequently asked questions"]} />
        <div className="mt-12 divide-y divide-line border-y border-line">
          {items.map((it, i) => {
            const isOpen = open === i;
            return (
              <div key={it.q}>
                <button
                  type="button"
                  className="flex w-full items-center justify-between gap-4 py-5 text-left text-[16px] font-medium text-fg transition-colors duration-150 hover:text-fg-muted sm:text-[17px]"
                  aria-expanded={isOpen}
                  aria-controls={`faq-${i}`}
                  onClick={() => setOpen(isOpen ? null : i)}
                >
                  {it.q}
                  <svg
                    viewBox="0 0 24 24"
                    className={`h-4 w-4 shrink-0 text-fg-dim transition-transform duration-200 ${isOpen ? "rotate-45" : ""}`}
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="1.8"
                    strokeLinecap="round"
                    aria-hidden="true"
                  >
                    <path d="M12 5v14M5 12h14" />
                  </svg>
                </button>
                <AnimatePresence initial={false}>
                  {isOpen && (
                    <motion.div
                      id={`faq-${i}`}
                      key="content"
                      initial={reduce ? false : { height: 0, opacity: 0 }}
                      animate={{ height: "auto", opacity: 1 }}
                      exit={reduce ? undefined : { height: 0, opacity: 0 }}
                      transition={{ duration: 0.4, ease: EASE }}
                      className="overflow-hidden"
                    >
                      <p className="body max-w-[62ch] pb-6">{it.a}</p>
                    </motion.div>
                  )}
                </AnimatePresence>
              </div>
            );
          })}
        </div>
        <Reveal>
          <p className="mt-8 text-center text-[14.5px] text-fg-muted">
            Something else?{" "}
            <a className="font-medium text-accent hover:underline" href="mailto:hello@navi.app">
              hello@navi.app
            </a>
          </p>
        </Reveal>
      </div>
    </section>
  );
}
