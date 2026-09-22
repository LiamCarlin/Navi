"use client";

import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { useEffect, useState } from "react";
import { Glyph } from "./Glyph";

type Icon = "app" | "map" | "calendar" | "browser" | "clock" | "calc" | "moon" | "spark" | "note";

type Row = { icon: Icon; title: string; kind: string; hint: string };
type Scene = { query: string; rows: Row[] };

const SCENES: Scene[] = [
  {
    query: "Open Maps",
    rows: [
      { icon: "map", title: "Maps", kind: "App", hint: "Open" },
      { icon: "app", title: "Directions home", kind: "Maps", hint: "Open" },
      { icon: "spark", title: "Ask Navi", kind: "Answer", hint: "Ask" },
    ],
  },
  {
    query: "What's on my calendar?",
    rows: [
      { icon: "spark", title: "Standup at 10:00, lunch with Sam at 12:30, review at 15:00", kind: "Answer", hint: "Copy" },
      { icon: "calendar", title: "Calendar", kind: "App", hint: "Open" },
      { icon: "app", title: "Today's events", kind: "Calendar", hint: "Open" },
    ],
  },
  {
    query: "Open Chrome and search for flights to Lisbon…",
    rows: [
      { icon: "browser", title: "Do it: open Chrome, search flights to Lisbon", kind: "Task", hint: "Run" },
      { icon: "app", title: "Google Chrome", kind: "App", hint: "Open" },
      { icon: "spark", title: "Ask Navi", kind: "Answer", hint: "Ask" },
    ],
  },
  {
    query: "What was I working on yesterday?",
    rows: [
      { icon: "clock", title: "Yesterday: PanelController.swift, then the pricing doc", kind: "Recall", hint: "Open" },
      { icon: "note", title: "Daily note · Yesterday", kind: "Vault", hint: "Open" },
      { icon: "spark", title: "Ask Navi", kind: "Answer", hint: "Ask" },
    ],
  },
  {
    query: "12% of 340",
    rows: [
      { icon: "calc", title: "40.8", kind: "Calculator", hint: "Copy" },
      { icon: "app", title: "Calculator", kind: "App", hint: "Open" },
      { icon: "spark", title: "Ask Navi", kind: "Answer", hint: "Ask" },
    ],
  },
  {
    query: "Toggle dark mode",
    rows: [
      { icon: "moon", title: "Dark Mode", kind: "System", hint: "Toggle" },
      { icon: "app", title: "Appearance", kind: "System Settings", hint: "Open" },
      { icon: "spark", title: "Ask Navi", kind: "Answer", hint: "Ask" },
    ],
  },
];

const TYPE_MS = 42;
const ERASE_MS = 14;
const HOLD_MS = 2300;
const RESULT_DELAY_MS = 260;

type Phase = "typing" | "hold" | "erasing";

export function PanelDemo() {
  const reduce = useReducedMotion();
  const [scene, setScene] = useState(0);
  const [typed, setTyped] = useState(reduce ? SCENES[0].query.length : 0);
  const [phase, setPhase] = useState<Phase>(reduce ? "hold" : "typing");

  const query = SCENES[scene].query;
  const showResults = phase === "hold" || (phase === "typing" && typed === query.length);

  useEffect(() => {
    if (reduce) return;
    let t: ReturnType<typeof setTimeout>;
    if (phase === "typing") {
      if (typed < query.length) {
        t = setTimeout(() => setTyped((n) => n + 1), TYPE_MS);
      } else {
        t = setTimeout(() => setPhase("hold"), RESULT_DELAY_MS);
      }
    } else if (phase === "hold") {
      t = setTimeout(() => setPhase("erasing"), HOLD_MS);
    } else {
      if (typed > 0) {
        t = setTimeout(() => setTyped((n) => n - 1), ERASE_MS);
      } else {
        t = setTimeout(() => {
          setScene((s) => (s + 1) % SCENES.length);
          setPhase("typing");
        }, 220);
      }
    }
    return () => clearTimeout(t);
  }, [phase, typed, query.length, reduce]);

  return (
    <div className="relative mx-auto w-full max-w-[680px]" aria-label="Navi panel demo" role="img">
      {/* Glow under the panel */}
      <div className="pointer-events-none absolute -inset-x-10 -top-10 bottom-0 -z-10 rounded-[40px] bg-[radial-gradient(60%_60%_at_50%_30%,rgba(139,140,248,0.28),transparent_70%)] blur-2xl" />

      <div className="gradient-border overflow-hidden rounded-2xl bg-[rgba(22,22,32,0.72)] shadow-[0_30px_80px_-20px_rgba(0,0,0,0.8),inset_0_1px_0_rgba(255,255,255,0.08)] backdrop-blur-2xl">
        {/* Input row */}
        <div className="flex h-[60px] items-center gap-3 px-4 sm:px-5">
          <Glyph className="h-5 w-5 shrink-0 text-accent" />
          <div className="min-w-0 flex-1 truncate text-[17px] leading-none text-fg sm:text-[19px]">
            {typed === 0 && phase !== "typing" ? (
              <span className="text-fg-dim">Ask Navi anything</span>
            ) : (
              <span>{query.slice(0, typed)}</span>
            )}
            <span className="caret" />
          </div>
          <span className="keycap hidden sm:inline-flex">⌘ Space</span>
          <span
            className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-accent-soft text-accent"
            title="Voice"
          >
            <MicIcon />
          </span>
        </div>

        {/* Results */}
        <AnimatePresence initial={false}>
          {showResults && (
            <motion.ul
              key={scene}
              className="border-t border-line px-2 pb-2 pt-2"
              initial={{ opacity: 0, height: 0 }}
              animate={{ opacity: 1, height: "auto" }}
              exit={{ opacity: 0, height: 0 }}
              transition={{ duration: 0.28, ease: [0.22, 1, 0.36, 1] }}
            >
              {SCENES[scene].rows.map((row, i) => (
                <motion.li
                  key={row.title}
                  initial={reduce ? false : { opacity: 0, y: 6 }}
                  animate={{ opacity: 1, y: 0 }}
                  transition={{ delay: 0.06 + i * 0.07, duration: 0.3 }}
                  className={`flex items-center gap-3 rounded-xl px-3 py-2.5 ${
                    i === 0 ? "bg-accent-soft/80 text-fg" : "text-fg-muted"
                  }`}
                >
                  <RowIcon icon={row.icon} />
                  <div className="min-w-0 flex-1">
                    <div className="truncate text-[15px] leading-tight">{row.title}</div>
                    <div className="mt-0.5 text-xs text-fg-dim">{row.kind}</div>
                  </div>
                  <span className={`keycap ${i === 0 ? "opacity-100" : "opacity-50"}`}>⏎ {row.hint}</span>
                </motion.li>
              ))}
            </motion.ul>
          )}
        </AnimatePresence>
      </div>
    </div>
  );
}

const ICON_BG: Record<Icon, string> = {
  app: "from-zinc-500 to-zinc-700",
  map: "from-emerald-400 to-teal-600",
  calendar: "from-rose-400 to-red-600",
  browser: "from-sky-400 to-blue-600",
  clock: "from-amber-300 to-orange-500",
  calc: "from-slate-400 to-slate-700",
  moon: "from-indigo-400 to-violet-600",
  spark: "from-[#8b8cf8] to-[#6f9cff]",
  note: "from-fuchsia-400 to-purple-600",
};

function RowIcon({ icon }: { icon: Icon }) {
  return (
    <span
      className={`flex h-8 w-8 shrink-0 items-center justify-center rounded-[9px] bg-gradient-to-br text-white shadow-[inset_0_1px_0_rgba(255,255,255,0.35)] ${ICON_BG[icon]}`}
      aria-hidden="true"
    >
      <IconGlyph icon={icon} />
    </span>
  );
}

function IconGlyph({ icon }: { icon: Icon }) {
  const p = { fill: "none", stroke: "currentColor", strokeWidth: 1.8, strokeLinecap: "round", strokeLinejoin: "round" } as const;
  switch (icon) {
    case "map":
      return (
        <svg viewBox="0 0 24 24" className="h-4 w-4" {...p}>
          <path d="M12 21s-6-5.2-6-10a6 6 0 1 1 12 0c0 4.8-6 10-6 10z" />
          <circle cx="12" cy="11" r="2" />
        </svg>
      );
    case "calendar":
      return (
        <svg viewBox="0 0 24 24" className="h-4 w-4" {...p}>
          <rect x="3" y="5" width="18" height="16" rx="2" />
          <path d="M3 10h18M8 3v4M16 3v4" />
        </svg>
      );
    case "browser":
      return (
        <svg viewBox="0 0 24 24" className="h-4 w-4" {...p}>
          <circle cx="12" cy="12" r="9" />
          <path d="M3 12h18M12 3c3 3.5 3 14.5 0 18M12 3c-3 3.5-3 14.5 0 18" />
        </svg>
      );
    case "clock":
      return (
        <svg viewBox="0 0 24 24" className="h-4 w-4" {...p}>
          <circle cx="12" cy="12" r="9" />
          <path d="M12 7v5l3 2" />
        </svg>
      );
    case "calc":
      return (
        <svg viewBox="0 0 24 24" className="h-4 w-4" {...p}>
          <rect x="5" y="3" width="14" height="18" rx="2" />
          <path d="M8 7h8M8 12h2M12 12h2M16 12h0M8 16h2M12 16h2M16 16h0" />
        </svg>
      );
    case "moon":
      return (
        <svg viewBox="0 0 24 24" className="h-4 w-4" {...p}>
          <path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z" />
        </svg>
      );
    case "note":
      return (
        <svg viewBox="0 0 24 24" className="h-4 w-4" {...p}>
          <path d="M6 3h9l5 5v13H6z" />
          <path d="M14 3v6h6M9 13h6M9 17h6" />
        </svg>
      );
    case "spark":
      return <Glyph className="h-4 w-4" />;
    default:
      return (
        <svg viewBox="0 0 24 24" className="h-4 w-4" {...p}>
          <rect x="4" y="4" width="16" height="16" rx="4" />
        </svg>
      );
  }
}

function MicIcon() {
  return (
    <svg viewBox="0 0 24 24" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <rect x="9" y="3" width="6" height="11" rx="3" />
      <path d="M5 11a7 7 0 0 0 14 0M12 18v3" />
    </svg>
  );
}
