"use client";

import { motion, useReducedMotion } from "framer-motion";
import { Lines, Reveal } from "./motion/Reveal";
import { DUR, EASE } from "@/lib/motion";

// Straight from the app's playbook library (Agent/AppSkillLibrary).
const MAC = ["Messages", "Mail", "Calendar", "Notes", "Reminders", "Finder", "Pages", "Numbers", "Keynote", "Music", "Spotify", "Slack", "Notion", "Obsidian", "Things", "Todoist", "Xcode", "Visual Studio Code", "Zed", "Terminal", "Figma", "Zoom", "Microsoft Teams", "Outlook", "Microsoft Word", "Microsoft Excel", "WhatsApp", "Telegram", "Signal", "Discord", "FaceTime", "Photos", "Preview", "System Settings", "Shortcuts", "Voice Memos", "Podcasts", "Freeform"];
const WEB = ["Gmail", "Google Docs", "Google Sheets", "Google Slides", "Google Drive", "Google Calendar", "Google Flights", "Google Maps", "YouTube", "Canvas", "Gradescope", "Piazza", "GitHub", "Linear", "Jira", "Asana", "Trello", "Notion", "Outlook Web", "Slack Web", "LinkedIn", "Reddit", "Wikipedia", "Amazon", "Uber", "Zillow", "IMDb", "Netflix", "Stack Overflow", "Google Classroom", "Google Forms"];

const CARDS = [
  {
    title: "A playbook for every app",
    body: "Navi carries notes on how 60+ Mac apps and 55+ websites work: where things are, their keyboard shortcuts, what “done” looks like, what to avoid. It also remembers which steps finished a job in an app before, and tries those first.",
    from: "make a new note called groceries",
    to: "Notes · ⌘N, then type the title",
  },
  {
    title: "It follows your habits",
    body: "With Recall on, tasks go where you actually work. You email from the Outlook app and never the website, so that’s where an email goes. Links point at your school’s Canvas, not the generic one.",
    from: "email the TA about the extension",
    to: "Outlook app, not Outlook on the web",
  },
  {
    title: "It knows who you mean",
    body: "Names resolve to the people in your life and where you talk to them. “Text Priya” goes to WhatsApp if that’s your thread with her. “The HCI notes” opens the document you keep coming back to.",
    from: "text priya i’m outside",
    to: "WhatsApp · Priya Shah",
  },
  {
    title: "Any browser",
    body: "Safari, Arc, Firefox or Chrome. Web steps run in the browser you already use, in a background tab, with your logins. The tab is never closed out from under you.",
    from: "find flights to tokyo on the 14th",
    to: "Your browser · a new tab behind yours",
  },
];

export function Apps() {
  return (
    <section id="apps" className="scroll-mt-16 py-24 md:py-36">
      <div className="px-4 sm:px-6">
        <div className="mx-auto grid max-w-7xl grid-cols-1 gap-6 lg:grid-cols-12 lg:gap-8">
          <Lines className="h-section lg:col-span-7" lines={["It already knows", "how your apps work."]} />
          <Reveal className="lg:col-span-5 lg:pt-3">
            <p className="lede">
              A general-purpose model doesn’t know where Notes keeps its new-note button. Navi does, because it reads a playbook
              for the app before every step, plus what it’s learned about how you work.
            </p>
          </Reveal>
        </div>
      </div>

      <div className="marquee-wrap fade-x mt-16 space-y-3 overflow-hidden md:mt-20" aria-label="Apps and sites Navi has playbooks for">
        <Track items={MAC} dur="80s" />
        <Track items={WEB} dur="95s" reverse web />
      </div>

      <div className="mt-16 px-4 sm:px-6 md:mt-20">
        <div className="mx-auto grid max-w-7xl grid-cols-1 gap-px overflow-hidden rounded-[22px] border border-line bg-line sm:grid-cols-2 lg:grid-cols-4">
          {CARDS.map((c, i) => (
            <Reveal key={c.title} i={i} className="flex flex-col bg-bg p-6 sm:p-7">
              <h3 className="h-card">{c.title}</h3>
              <p className="body mt-3 flex-1">{c.body}</p>
              <Route from={c.from} to={c.to} />
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}

function Track({ items, dur, reverse = false, web = false }: { items: string[]; dur: string; reverse?: boolean; web?: boolean }) {
  const row = (aria: boolean) => (
    <ul className="flex shrink-0 gap-3 pr-3" aria-hidden={!aria}>
      {items.map((a) => (
        <li key={a} className="flex shrink-0 items-center gap-2 rounded-full border border-line bg-bg-elev px-4 py-2 text-[15px] text-fg-muted">
          <span className="h-1.5 w-1.5 rounded-full" style={{ background: web ? "#40c8e0" : "#0a84ff" }} />
          {a}
        </li>
      ))}
    </ul>
  );
  return (
    <div className={`marquee ${reverse ? "marquee-rev" : ""}`} style={{ "--marquee-dur": dur } as React.CSSProperties}>
      {row(true)}
      {row(false)}
    </div>
  );
}

/** “what you said” → where it went, with the arrow drawing in. */
function Route({ from, to }: { from: string; to: string }) {
  const reduce = useReducedMotion();
  return (
    <div className="mt-6 rounded-[14px] border border-line bg-bg-elev p-3.5 text-[13px]">
      <div className="truncate text-fg">“{from}”</div>
      <div className="mt-2 flex items-center gap-2 text-fg-muted">
        <svg viewBox="0 0 40 12" className="h-3 w-8 shrink-0" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" aria-hidden="true">
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
