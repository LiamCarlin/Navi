"use client";

import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { Glyph } from "./Glyph";

export type Icon = "app" | "map" | "calendar" | "browser" | "clock" | "calc" | "moon" | "spark" | "note" | "message" | "doc" | "check";

export type Row = { icon: Icon; title: string; kind: string; hint: string };

import { u } from "@/lib/u";
export { u };

/**
 * The ⌘Space bar. Purely presentational: the caller decides what is typed and which rows show,
 * so the hero loop and the story sections can drive the same component.
 */
export function Panel({
  query,
  typed,
  rows,
  placeholder = "Ask Navi anything",
  showCaret = true,
  pressed = false,
  className = "",
}: {
  query: string;
  typed: number;
  rows: Row[] | null;
  placeholder?: string;
  showCaret?: boolean;
  /** Return was pressed on the first row: it reads as selected and its keycap sits down. */
  pressed?: boolean;
  className?: string;
}) {
  const reduce = useReducedMotion();
  const text = query.slice(0, typed);
  const rowKey = rows ? rows.map((r) => r.title).join("|") : "none";

  return (
    <div
      className={`glass overflow-hidden ${className}`}
      style={{ borderRadius: u(16) }}
      role="img"
      aria-label={rows ? `Navi: ${query}` : "Navi bar"}
    >
      <div className="flex items-center" style={{ height: u(56), padding: `0 ${u(18)}`, gap: u(12) }}>
        <Glyph className="shrink-0 text-accent" style={{ width: u(18), height: u(18) }} />
        <div className="min-w-0 flex-1 truncate leading-none" style={{ fontSize: u(17) }}>
          {text.length === 0 ? <span className="text-panel-dim">{placeholder}</span> : <span>{text}</span>}
          {showCaret && <span className="caret" />}
        </div>
        <Keycap>⌘ Space</Keycap>
        <span
          className="flex shrink-0 items-center justify-center rounded-full bg-accent-soft text-accent"
          style={{ width: u(26), height: u(26) }}
          title="Voice"
        >
          <MicIcon />
        </span>
      </div>

      <AnimatePresence initial={false} mode="wait">
        {rows && (
          <motion.ul
            key={rowKey}
            style={{ padding: u(6), borderTop: "1px solid var(--panel-line)" }}
            initial={reduce ? false : { opacity: 0, height: 0 }}
            animate={{ opacity: 1, height: "auto" }}
            exit={reduce ? undefined : { opacity: 0, height: 0 }}
            transition={{ duration: 0.24, ease: [0.22, 1, 0.36, 1] }}
          >
            {rows.map((row, i) => (
              <motion.li
                key={row.title}
                initial={reduce ? false : { opacity: 0, y: 4 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ delay: 0.04 + i * 0.05, duration: 0.22 }}
                className={`flex items-center ${i === 0 ? "text-panel-fg" : "text-panel-muted"}`}
                style={{ gap: u(12), padding: `${u(8)} ${u(10)}`, borderRadius: u(10), background: i === 0 ? "var(--accent-soft)" : undefined }}
              >
                <RowIcon icon={row.icon} />
                <div className="min-w-0 flex-1">
                  <div className="truncate leading-tight" style={{ fontSize: u(14) }}>
                    {row.title}
                  </div>
                  <div className="text-panel-dim" style={{ fontSize: u(11), marginTop: u(2) }}>
                    {row.kind}
                  </div>
                </div>
                <Keycap dim={i !== 0} down={pressed && i === 0}>
                  ⏎ {row.hint}
                </Keycap>
              </motion.li>
            ))}
          </motion.ul>
        )}
      </AnimatePresence>
    </div>
  );
}

function Keycap({ children, dim = false, down = false }: { children: React.ReactNode; dim?: boolean; down?: boolean }) {
  return (
    <span
      className={`inline-flex shrink-0 items-center whitespace-nowrap text-panel-muted transition-transform duration-100 ${dim ? "opacity-50" : ""} ${down ? "translate-y-px" : ""}`}
      style={{
        height: u(20),
        padding: `0 ${u(6)}`,
        borderRadius: u(5),
        fontSize: u(11),
        border: "1px solid var(--panel-line)",
        background: "var(--panel-row)",
        boxShadow: "inset 0 1px 0 rgba(255,255,255,0.08)",
      }}
    >
      {children}
    </span>
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
  message: "from-green-400 to-emerald-600",
  doc: "from-blue-400 to-indigo-600",
  check: "from-[#8b8cf8] to-[#6f9cff]",
};

export function RowIcon({ icon }: { icon: Icon }) {
  return (
    <span
      className={`flex shrink-0 items-center justify-center bg-gradient-to-br text-white shadow-[inset_0_1px_0_rgba(255,255,255,0.35)] ${ICON_BG[icon]}`}
      style={{ width: u(28), height: u(28), borderRadius: u(8) }}
      aria-hidden="true"
    >
      <IconGlyph icon={icon} />
    </span>
  );
}

function IconGlyph({ icon }: { icon: Icon }) {
  const p = { fill: "none", stroke: "currentColor", strokeWidth: 1.8, strokeLinecap: "round", strokeLinejoin: "round" } as const;
  const size = { width: u(14), height: u(14) };
  switch (icon) {
    case "map":
      return (
        <svg viewBox="0 0 24 24" style={size} {...p}>
          <path d="M12 21s-6-5.2-6-10a6 6 0 1 1 12 0c0 4.8-6 10-6 10z" />
          <circle cx="12" cy="11" r="2" />
        </svg>
      );
    case "calendar":
      return (
        <svg viewBox="0 0 24 24" style={size} {...p}>
          <rect x="3" y="5" width="18" height="16" rx="2" />
          <path d="M3 10h18M8 3v4M16 3v4" />
        </svg>
      );
    case "browser":
      return (
        <svg viewBox="0 0 24 24" style={size} {...p}>
          <circle cx="12" cy="12" r="9" />
          <path d="M3 12h18M12 3c3 3.5 3 14.5 0 18M12 3c-3 3.5-3 14.5 0 18" />
        </svg>
      );
    case "clock":
      return (
        <svg viewBox="0 0 24 24" style={size} {...p}>
          <circle cx="12" cy="12" r="9" />
          <path d="M12 7v5l3 2" />
        </svg>
      );
    case "calc":
      return (
        <svg viewBox="0 0 24 24" style={size} {...p}>
          <rect x="5" y="3" width="14" height="18" rx="2" />
          <path d="M8 7h8M8 12h2M12 12h2M16 12h0M8 16h2M12 16h2M16 16h0" />
        </svg>
      );
    case "moon":
      return (
        <svg viewBox="0 0 24 24" style={size} {...p}>
          <path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z" />
        </svg>
      );
    case "note":
    case "doc":
      return (
        <svg viewBox="0 0 24 24" style={size} {...p}>
          <path d="M6 3h9l5 5v13H6z" />
          <path d="M14 3v6h6M9 13h6M9 17h6" />
        </svg>
      );
    case "message":
      return (
        <svg viewBox="0 0 24 24" style={size} {...p}>
          <path d="M21 12a8 8 0 0 1-11.6 7.1L4 21l1.6-4.3A8 8 0 1 1 21 12z" />
        </svg>
      );
    case "check":
      return (
        <svg viewBox="0 0 24 24" style={size} {...p} strokeWidth={2.4}>
          <path d="M5 12l5 5 9-10" />
        </svg>
      );
    case "spark":
      return <Glyph style={size} />;
    default:
      return (
        <svg viewBox="0 0 24 24" style={size} {...p}>
          <rect x="4" y="4" width="16" height="16" rx="4" />
        </svg>
      );
  }
}

function MicIcon() {
  return (
    <svg viewBox="0 0 24 24" style={{ width: u(12), height: u(12) }} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <rect x="9" y="3" width="6" height="11" rx="3" />
      <path d="M5 11a7 7 0 0 0 14 0M12 18v3" />
    </svg>
  );
}
