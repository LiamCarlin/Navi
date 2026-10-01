"use client";

import { motion, useReducedMotion } from "framer-motion";
import { Head, Reveal } from "./motion/Reveal";
import { DUR, EASE } from "@/lib/motion";

// Straight from the app's playbook library (Agent/AppSkillLibrary).
const APPS = ["Messages", "Mail", "Calendar", "Notes", "Reminders", "Finder", "Slack", "Notion", "Spotify", "Gmail", "Google Docs", "Outlook", "WhatsApp", "Xcode", "VS Code", "Figma", "Zoom", "Canvas", "GitHub", "Linear", "YouTube", "Google Flights", "Microsoft Teams", "Discord", "Obsidian", "Things", "Safari", "Arc", "Chrome", "Firefox"];

/** Under the hero: the apps Navi already knows, drifting by. */
export function AppStrip() {
  return (
    <section aria-label="Apps Navi has playbooks for" className="px-4 pb-8 sm:px-6">
      <p className="label text-center">Knows its way around 60+ Mac apps and 55+ websites</p>
      <div className="marquee-wrap fade-x mx-auto mt-5 max-w-5xl overflow-hidden">
        <div className="marquee" style={{ "--marquee-dur": "70s" } as React.CSSProperties}>
          {[0, 1].map((copy) => (
            <ul key={copy} className="flex shrink-0 items-center gap-8 pr-8" aria-hidden={copy === 1}>
              {APPS.map((a) => (
                <li key={a} className="shrink-0 text-[15px] font-medium text-fg-dim">
                  {a}
                </li>
              ))}
            </ul>
          ))}
        </div>
      </div>
    </section>
  );
}

const CARDS = [
  {
    title: "A playbook for every app",
    body: "Where things are, the keyboard shortcuts, what “done” looks like, what to avoid. And the steps that worked last time get tried first.",
    from: "make a new note called groceries",
    to: "Notes · ⌘N, then type the title",
  },
  {
    title: "It follows your habits",
    body: "With Recall on, tasks go where you actually work: the Outlook app if that’s how you email, your school’s Canvas instead of the generic one.",
    from: "email the TA about the extension",
    to: "Outlook app, not the website",
  },
  {
    title: "It knows who you mean",
    body: "Names resolve to people and where you talk to them. “Text Priya” goes to WhatsApp if that’s your thread with her.",
    from: "text priya i’m outside",
    to: "WhatsApp · Priya Shah",
  },
  {
    title: "Any browser",
    body: "Safari, Arc, Firefox or Chrome. Web steps run in a background tab of the browser you use, with your logins.",
    from: "find flights to tokyo on the 14th",
    to: "Your browser · a tab behind yours",
  },
];

export function Habits() {
  return (
    <section id="apps" className="scroll-mt-16 px-4 py-24 sm:px-6 md:py-32">
      <Head
        title={["It already knows", "how you work"]}
        sub="A general-purpose model doesn’t know where Notes keeps its new-note button. Navi reads a playbook for the app before every step."
      />
      <div className="mx-auto mt-14 grid max-w-6xl grid-cols-1 gap-5 sm:grid-cols-2 lg:mt-16 lg:grid-cols-4">
        {CARDS.map((c, i) => (
          <Reveal key={c.title} i={i} className="card flex flex-col p-6">
            <Route from={c.from} to={c.to} />
            <h3 className="mt-6 text-[17px] font-medium tracking-[-0.01em]">{c.title}</h3>
            <p className="body mt-2 text-[14.5px]">{c.body}</p>
          </Reveal>
        ))}
      </div>
    </section>
  );
}

/** “what you said” → where it went, with the arrow drawing in. */
function Route({ from, to }: { from: string; to: string }) {
  const reduce = useReducedMotion();
  return (
    <div className="glass-dark rounded-[16px] p-3.5 text-[13px]">
      <div className="truncate">“{from}”</div>
      <div className="mt-2 flex items-center gap-2 text-white/60">
        <svg viewBox="0 0 40 12" className="h-3 w-8 shrink-0" fill="none" stroke="#7fb0ff" strokeWidth="1.6" strokeLinecap="round" aria-hidden="true">
          <motion.path
            d="M1 6h36M32 1.5L37 6l-5 4.5"
            initial={reduce ? false : { pathLength: 0 }}
            whileInView={{ pathLength: 1 }}
            viewport={{ once: true, amount: 1 }}
            transition={{ duration: DUR.slow, ease: EASE, delay: 0.3 }}
          />
        </svg>
        <span className="truncate">{to}</span>
      </div>
    </div>
  );
}
