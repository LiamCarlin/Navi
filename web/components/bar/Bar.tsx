"use client";

import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import type { ReactNode } from "react";
import { Glyph } from "../Glyph";
import { u } from "@/lib/u";
import { EASE } from "@/lib/motion";

/**
 * The ⌘Space bar, drawn from the app's own PanelStyle: 680 pt wide, 28 pt corners,
 * a 64 pt bar, 52 pt rows with 14 pt corners, a 32 pt footer of key hints.
 * Sized in `u` so it must sit inside a `.stage` (or `.screen`).
 * Purely presentational: callers decide the query and the body.
 */
export function Bar({
  query,
  placeholder = "Ask Navi anything",
  caret = true,
  body,
  bodyKey,
  hints,
  className = "",
  input,
  label,
}: {
  query: string;
  placeholder?: string;
  caret?: boolean;
  body?: ReactNode;
  /** Changes whenever the body is a different thing, so it cross-fades instead of popping. */
  bodyKey?: string;
  hints?: Hint[];
  className?: string;
  /** Replace the drawn query with a real input (the hero). */
  input?: ReactNode;
  label?: string;
}) {
  const reduce = useReducedMotion();
  return (
    <div
      className={`glass overflow-hidden ${className}`}
      style={{ borderRadius: u(28) }}
      role={input ? undefined : "img"}
      aria-label={input ? undefined : label ?? (query ? `Navi: ${query}` : "Navi bar")}
    >
      <div className="flex items-center" style={{ height: u(64), padding: `0 ${u(22)}`, gap: u(14) }}>
        <Glyph className="shrink-0" style={{ width: u(20), height: u(20), color: "#bf5af2" }} />
        {input ?? (
          <div className="min-w-0 flex-1 truncate leading-none" style={{ fontSize: u(21), letterSpacing: "-0.01em" }}>
            {query.length === 0 ? <span className="text-panel-dim">{placeholder}</span> : <span>{query}</span>}
            {caret && <span className="caret" style={{ background: "#5e5ce6" }} />}
          </div>
        )}
        <Mic />
      </div>

      <AnimatePresence initial={false} mode="popLayout">
        {body && (
          <motion.div
            key={bodyKey ?? "body"}
            initial={reduce ? false : { opacity: 0, y: -6 }}
            animate={{ opacity: 1, y: 0 }}
            exit={reduce ? undefined : { opacity: 0, transition: { duration: 0.12 } }}
            transition={{ duration: 0.32, ease: EASE }}
            style={{ borderTop: "1px solid var(--panel-line)" }}
          >
            {body}
          </motion.div>
        )}
      </AnimatePresence>

      {body && hints && hints.length > 0 && <Footer hints={hints} />}
    </div>
  );
}

export type Hint = { keys: string; label?: string };

function Footer({ hints }: { hints: Hint[] }) {
  return (
    <div
      className="flex items-center justify-end"
      style={{ height: u(32), padding: `0 ${u(18)}`, gap: u(14), borderTop: "1px solid var(--panel-line)" }}
    >
      {hints.map((h) => (
        <span key={h.keys + h.label} className="flex items-center" style={{ gap: u(5) }}>
          <Cap>{h.keys}</Cap>
          {h.label && (
            <span className="text-panel-dim" style={{ fontSize: u(11) }}>
              {h.label}
            </span>
          )}
        </span>
      ))}
    </div>
  );
}

export function Cap({ children }: { children: ReactNode }) {
  return (
    <span
      className="inline-flex items-center whitespace-nowrap font-semibold text-panel-muted"
      style={{
        height: u(17),
        padding: `0 ${u(5)}`,
        borderRadius: u(5),
        fontSize: u(10.5),
        background: "var(--panel-row)",
        border: "1px solid var(--panel-line)",
      }}
    >
      {children}
    </span>
  );
}

function Mic() {
  return (
    <span
      className="flex shrink-0 items-center justify-center rounded-full text-panel-muted"
      style={{ width: u(30), height: u(30), background: "var(--panel-row)" }}
      aria-hidden="true"
    >
      <svg viewBox="0 0 24 24" style={{ width: u(14), height: u(14) }} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
        <rect x="9" y="3" width="6" height="11" rx="3" />
        <path d="M5 11a7 7 0 0 0 14 0M12 18v3" />
      </svg>
    </span>
  );
}

/* ---------------------------------------------------------------- rows */

export type Tile =
  | "maps"
  | "messages"
  | "calendar"
  | "notes"
  | "reminders"
  | "music"
  | "mail"
  | "browser"
  | "finder"
  | "settings"
  | "ask"
  | "search"
  | "calc"
  | "task"
  | "memory"
  | "doc"
  | "slack"
  | "app";

export type RowData = { tile: Tile; title: string; sub: string; action?: string };

export function Rows({ rows, selected = 0 }: { rows: RowData[]; selected?: number }) {
  const reduce = useReducedMotion();
  return (
    <ul style={{ padding: u(10), display: "grid", gap: u(2) }}>
      {rows.map((r, i) => (
        <motion.li
          key={r.title + r.sub}
          initial={reduce ? false : { opacity: 0, y: 6 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.03 + i * 0.04, duration: 0.3, ease: EASE }}
          className="flex items-center"
          style={{
            height: u(52),
            gap: u(12),
            padding: `0 ${u(10)}`,
            borderRadius: u(14),
            background: i === selected ? "var(--panel-row)" : undefined,
          }}
        >
          <TileIcon tile={r.tile} />
          <div className="min-w-0 flex-1">
            <div className="truncate font-medium leading-tight" style={{ fontSize: u(15) }}>
              {r.title}
            </div>
            <div className="truncate text-panel-dim" style={{ fontSize: u(12), marginTop: u(2) }}>
              {r.sub}
            </div>
          </div>
          {i === selected && <Cap>⏎ {r.action ?? "open"}</Cap>}
        </motion.li>
      ))}
    </ul>
  );
}

const TILE: Record<Tile, { bg: string; fg?: string }> = {
  maps: { bg: "linear-gradient(160deg,#5fd18b,#1e9e5a)" },
  messages: { bg: "linear-gradient(160deg,#6ee17a,#21b34a)" },
  calendar: { bg: "#ffffff", fg: "#ff3b30" },
  notes: { bg: "linear-gradient(180deg,#ffd84d 0 30%,#fffaf0 30%)", fg: "#9a7b00" },
  reminders: { bg: "#ffffff", fg: "#ff9f0a" },
  music: { bg: "linear-gradient(160deg,#ff6a80,#fa2d48)" },
  mail: { bg: "linear-gradient(160deg,#58b4ff,#1a73e8)" },
  browser: { bg: "linear-gradient(160deg,#6cc6ff,#2b7fff)" },
  finder: { bg: "linear-gradient(90deg,#6fc3ff 50%,#e9f2ff 50%)", fg: "#1d3b64" },
  settings: { bg: "linear-gradient(160deg,#a5a5ad,#6c6c74)" },
  ask: { bg: "linear-gradient(150deg,#bf5af2,#7d4be8)" },
  search: { bg: "linear-gradient(150deg,#40c8e0,#1aa3a3)" },
  calc: { bg: "linear-gradient(160deg,#ffb340,#ff8a00)" },
  task: { bg: "linear-gradient(150deg,#ff5f8a,#e0306a)" },
  memory: { bg: "linear-gradient(150deg,#7d7aff,#5e5ce6)" },
  doc: { bg: "linear-gradient(160deg,#4f9dff,#2563eb)" },
  slack: { bg: "linear-gradient(160deg,#5a2a64,#3b1442)" },
  app: { bg: "linear-gradient(160deg,#8e8e96,#5c5c64)" },
};

export function TileIcon({ tile, size = 32 }: { tile: Tile; size?: number }) {
  const t = TILE[tile];
  return (
    <span
      className="relative flex shrink-0 items-center justify-center overflow-hidden"
      style={{
        width: u(size),
        height: u(size),
        borderRadius: u(size * 0.25),
        background: t.bg,
        color: t.fg ?? "#fff",
        boxShadow: "inset 0 0 0 0.5px rgba(0,0,0,0.12), 0 1px 2px rgba(0,0,0,0.15)",
      }}
      aria-hidden="true"
    >
      <TileGlyph tile={tile} size={size * 0.5} />
    </span>
  );
}

function TileGlyph({ tile, size }: { tile: Tile; size: number }) {
  const s = { width: u(size), height: u(size) };
  const p = { fill: "none", stroke: "currentColor", strokeWidth: 2, strokeLinecap: "round", strokeLinejoin: "round" } as const;
  switch (tile) {
    case "ask":
      return <Glyph style={s} />;
    case "search":
      return (
        <svg viewBox="0 0 24 24" style={s} {...p} strokeWidth={2.6}>
          <circle cx="11" cy="11" r="6" />
          <path d="M20 20l-4.5-4.5" />
        </svg>
      );
    case "maps":
      return (
        <svg viewBox="0 0 24 24" style={s} fill="currentColor">
          <path d="M12 3l6 17-6-3.5L6 20z" />
        </svg>
      );
    case "messages":
      return (
        <svg viewBox="0 0 24 24" style={s} fill="currentColor">
          <path d="M12 4c5 0 9 3.1 9 7s-4 7-9 7c-.9 0-1.8-.1-2.6-.3L5 20l1-3.6C4.2 15.1 3 13.2 3 11c0-3.9 4-7 9-7z" />
        </svg>
      );
    case "calendar":
      return (
        <span className="flex flex-col items-center leading-none" style={{ gap: u(1) }}>
          <span style={{ fontSize: u(size * 0.42), fontWeight: 600 }}>MON</span>
          <span style={{ fontSize: u(size * 0.95), fontWeight: 500, color: "#111" }}>14</span>
        </span>
      );
    case "reminders":
      return (
        <svg viewBox="0 0 24 24" style={s}>
          <circle cx="6" cy="7" r="2" fill="#0a84ff" />
          <circle cx="6" cy="12" r="2" fill="#ff3b30" />
          <circle cx="6" cy="17" r="2" fill="#ff9f0a" />
          <path d="M10 7h10M10 12h10M10 17h10" stroke="#c7c7cc" strokeWidth="1.6" strokeLinecap="round" />
        </svg>
      );
    case "notes":
      return (
        <svg viewBox="0 0 24 24" style={s} {...p} strokeWidth={1.6}>
          <path d="M6 12h12M6 16h12M6 20h8" />
        </svg>
      );
    case "music":
      return (
        <svg viewBox="0 0 24 24" style={s} fill="currentColor">
          <path d="M9 17.5V6l10-2v11.5a2.5 2.5 0 1 1-2-2.45V7.3l-6 1.2v9a2.5 2.5 0 1 1-2-2.45z" />
        </svg>
      );
    case "mail":
      return (
        <svg viewBox="0 0 24 24" style={s} {...p}>
          <rect x="3" y="6" width="18" height="13" rx="2" />
          <path d="M3.5 7l8.5 6 8.5-6" />
        </svg>
      );
    case "browser":
      return (
        <svg viewBox="0 0 24 24" style={s} {...p} strokeWidth={1.7}>
          <circle cx="12" cy="12" r="9" />
          <path d="M3 12h18M12 3c3 3.5 3 14.5 0 18M12 3c-3 3.5-3 14.5 0 18" />
        </svg>
      );
    case "finder":
      return (
        <svg viewBox="0 0 24 24" style={s} {...p} strokeWidth={1.8}>
          <path d="M8 8v2M16 8v2M7 15c3 2 7 2 10 0" />
        </svg>
      );
    case "settings":
      return (
        <svg viewBox="0 0 24 24" style={s} {...p} strokeWidth={1.8}>
          <circle cx="12" cy="12" r="3" />
          <path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M4.9 19.1L7 17M17 7l2.1-2.1" />
        </svg>
      );
    case "calc":
      return (
        <svg viewBox="0 0 24 24" style={s} {...p} strokeWidth={2.2}>
          <path d="M6 8h4M8 6v4M14 8h4M6 16h4M14 15h4M14 18h4" />
        </svg>
      );
    case "task":
      return (
        <svg viewBox="0 0 24 24" style={s} {...p} strokeWidth={2.2}>
          <path d="M5 12l4 4 10-10" />
        </svg>
      );
    case "memory":
      return (
        <svg viewBox="0 0 24 24" style={s} {...p} strokeWidth={2}>
          <circle cx="12" cy="12" r="8" />
          <path d="M12 8v4l3 2" />
        </svg>
      );
    case "doc":
      return (
        <svg viewBox="0 0 24 24" style={s} {...p} strokeWidth={1.8}>
          <path d="M6 3h8l4 4v14H6z" />
          <path d="M9 12h6M9 16h6" />
        </svg>
      );
    case "slack":
      return (
        <svg viewBox="0 0 24 24" style={s} {...p} strokeWidth={2.4}>
          <path d="M9 4v16M15 4v16M4 9h16M4 15h16" />
        </svg>
      );
    default:
      return (
        <svg viewBox="0 0 24 24" style={s} {...p}>
          <rect x="5" y="5" width="14" height="14" rx="4" />
        </svg>
      );
  }
}

/* ---------------------------------------------------------------- bodies */

/** A streamed answer: the text up to `shown` characters, then where it came from. */
export function AnswerBody({ text, shown, source }: { text: string; shown?: number; source?: string }) {
  const n = shown ?? text.length;
  return (
    <div style={{ padding: `${u(16)} ${u(24)} ${u(18)}` }}>
      <p className="leading-relaxed" style={{ fontSize: u(15) }}>
        {text.slice(0, n)}
        {n < text.length && <span className="caret" style={{ background: "#bf5af2" }} />}
      </p>
      {source && n >= text.length && (
        <div className="text-panel-dim" style={{ fontSize: u(11.5), marginTop: u(10) }}>
          {source}
        </div>
      )}
    </div>
  );
}

export function CalcBody({ expr, result, note }: { expr: string; result: string; note?: string }) {
  return (
    <div className="flex items-center" style={{ padding: `${u(18)} ${u(22)}`, gap: u(14) }}>
      <TileIcon tile="calc" size={36} />
      <div className="min-w-0 flex-1">
        <div className="tnum font-medium tracking-tight" style={{ fontSize: u(28), lineHeight: 1.05 }}>
          {result}
        </div>
        <div className="truncate text-panel-dim" style={{ fontSize: u(12), marginTop: u(4) }}>
          {expr}
          {note ? ` · ${note}` : ""}
        </div>
      </div>
      <Cap>⏎ copy</Cap>
    </div>
  );
}

export type StepData = { label: string; state: "done" | "running" | "waiting" | "ask" };

/** A task's steps as they happen, the way the app's agent view lists them. */
export function TaskBody({ title, app, steps, ask }: { title: string; app: Tile; steps: StepData[]; ask?: string }) {
  const reduce = useReducedMotion();
  const done = steps.length > 0 && steps.every((s) => s.state === "done");
  return (
    <div style={{ padding: `${u(14)} ${u(20)} ${u(16)}` }}>
      <div className="flex items-center" style={{ gap: u(10) }}>
        <TileIcon tile={app} size={24} />
        <span className="truncate font-medium" style={{ fontSize: u(14) }}>
          {title}
        </span>
        <span
          className="ml-auto rounded-full font-semibold"
          style={{
            fontSize: u(10),
            padding: `${u(3)} ${u(8)}`,
            background: done ? "rgba(48,209,88,0.16)" : "rgba(255,55,95,0.14)",
            color: done ? "#30d158" : "#ff375f",
          }}
        >
          {done ? "DONE" : "LIVE"}
        </span>
      </div>
      <ol style={{ marginTop: u(12), display: "grid", gap: u(8) }}>
        {steps.map((s, i) => (
          <motion.li
            key={s.label}
            initial={reduce ? false : { opacity: 0, x: -6 }}
            animate={{ opacity: 1, x: 0 }}
            transition={{ duration: 0.3, ease: EASE }}
            className={`flex items-center ${s.state === "waiting" ? "text-panel-dim" : ""}`}
            style={{ gap: u(10), fontSize: u(13) }}
          >
            <StepMark state={s.state} n={i + 1} />
            <span className="truncate">{s.label}</span>
          </motion.li>
        ))}
      </ol>
      {ask && (
        <motion.div
          initial={reduce ? false : { opacity: 0, y: 6 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.3, ease: EASE }}
          className="flex items-center"
          style={{
            marginTop: u(14),
            padding: `${u(10)} ${u(12)}`,
            gap: u(10),
            borderRadius: u(14),
            background: "rgba(255,159,10,0.12)",
            border: "1px solid rgba(255,159,10,0.3)",
          }}
        >
          <span style={{ fontSize: u(13) }} className="min-w-0 flex-1 truncate">
            Navi wants to: <b className="font-semibold">{ask}</b>
          </span>
          <Cap>⌘⏎ approve</Cap>
          <Cap>⌘⌫ deny</Cap>
        </motion.div>
      )}
    </div>
  );
}

function StepMark({ state, n }: { state: StepData["state"]; n: number }) {
  const size = { width: u(18), height: u(18) };
  if (state === "done")
    return (
      <span className="flex shrink-0 items-center justify-center rounded-full text-white" style={{ ...size, background: "#30d158" }}>
        <svg viewBox="0 0 24 24" style={{ width: u(11), height: u(11) }} fill="none" stroke="currentColor" strokeWidth="3.4" strokeLinecap="round" strokeLinejoin="round">
          <path d="M5 12l5 5 9-10" />
        </svg>
      </span>
    );
  if (state === "running")
    return <span className="spin shrink-0 rounded-full" style={{ ...size, border: `${u(2)} solid var(--panel-line)`, borderTopColor: "#ff375f" }} aria-hidden="true" />;
  if (state === "ask")
    return (
      <span className="flex shrink-0 items-center justify-center rounded-full font-bold text-black" style={{ ...size, background: "#ff9f0a", fontSize: u(11) }}>
        !
      </span>
    );
  return (
    <span className="tnum flex shrink-0 items-center justify-center rounded-full text-panel-dim" style={{ ...size, border: "1px solid var(--panel-line)", fontSize: u(10) }}>
      {n}
    </span>
  );
}

/** The scheduler card: you and each guest over a 9–18 timeline, and three times everyone's free. */
export function ScheduleCard({
  people,
  slots,
  picked = 0,
  title,
  when,
  range,
}: {
  people: { name: string; initials: string; tint: string; busy: [number, number][]; unshared?: boolean }[];
  slots: string[];
  picked?: number;
  /** The picked slot, in hours (14.5 = 2:30 pm). */
  range?: [number, number];
  title: string;
  when: string;
}) {
  const reduce = useReducedMotion();
  const H0 = 9;
  const H1 = 18;
  const pct = (h: number) => `${((h - H0) / (H1 - H0)) * 100}%`;
  return (
    <div style={{ padding: `${u(14)} ${u(20)} ${u(16)}` }}>
      <div className="flex items-baseline justify-between" style={{ gap: u(10) }}>
        <span className="truncate font-medium" style={{ fontSize: u(15) }}>
          {title}
        </span>
        <span className="tnum shrink-0 text-panel-muted" style={{ fontSize: u(12) }}>
          {when}
        </span>
      </div>
      <div style={{ marginTop: u(12), display: "grid", gap: u(7) }}>
        {people.map((p, i) => (
          <div key={p.name} className="flex items-center" style={{ gap: u(10) }}>
            <span
              className="flex shrink-0 items-center justify-center rounded-full font-semibold text-white"
              style={{ width: u(22), height: u(22), background: p.tint, fontSize: u(9.5) }}
            >
              {p.initials}
            </span>
            <span className="shrink-0 truncate text-panel-muted" style={{ width: u(64), fontSize: u(12) }}>
              {p.name}
            </span>
            <div className="relative flex-1 overflow-hidden" style={{ height: u(16), borderRadius: u(5), background: "var(--panel-row)" }}>
              {p.unshared ? (
                <span className="absolute inset-0 flex items-center text-panel-dim" style={{ fontSize: u(10), paddingLeft: u(8) }}>
                  Calendar not shared · showing meetings you share
                </span>
              ) : (
                p.busy.map(([a, b], j) => (
                  <motion.span
                    key={j}
                    className="absolute inset-y-0"
                    style={{ left: pct(a), width: `calc(${pct(b)} - ${pct(a)})`, background: "rgba(127,127,140,0.45)", borderRadius: u(4), originX: 0 }}
                    initial={reduce ? false : { scaleX: 0 }}
                    animate={{ scaleX: 1 }}
                    transition={{ delay: 0.1 + i * 0.06 + j * 0.03, duration: 0.45, ease: EASE }}
                  />
                ))
              )}
              {range && (
                <span
                  className="absolute inset-y-0"
                  style={{ left: pct(range[0]), width: `calc(${pct(range[1])} - ${pct(range[0])})`, background: "rgba(94,92,230,0.35)", boxShadow: "inset 0 0 0 1px #5e5ce6", borderRadius: u(4) }}
                />
              )}
            </div>
          </div>
        ))}
        <div className="flex justify-between text-panel-dim tnum" style={{ paddingLeft: u(96), fontSize: u(9.5) }}>
          {[9, 11, 13, 15, 17].map((h) => (
            <span key={h}>{h > 12 ? `${h - 12} pm` : `${h} am`}</span>
          ))}
        </div>
      </div>
      <div className="flex items-center" style={{ marginTop: u(12), gap: u(8) }}>
        <span className="text-panel-dim" style={{ fontSize: u(11.5) }}>
          Everyone’s free at
        </span>
        {slots.map((s, i) => (
          <span
            key={s}
            className="tnum rounded-full font-medium"
            style={{
              fontSize: u(12),
              padding: `${u(4)} ${u(10)}`,
              background: i === picked ? "#5e5ce6" : "var(--panel-row)",
              color: i === picked ? "#fff" : undefined,
            }}
          >
            {s}
          </span>
        ))}
      </div>
    </div>
  );
}

/** The reminder card: the task, when it's due, and the quick-due chips. */
export function ReminderCard({ task, due, repeat, list, chip = 2 }: { task: string; due: string; repeat?: string; list: string; chip?: number }) {
  const chips = ["In 1 hour", "This evening", "Tomorrow", "This weekend", "Next week"];
  return (
    <div style={{ padding: `${u(14)} ${u(20)} ${u(16)}` }}>
      <div className="flex items-center" style={{ gap: u(12) }}>
        <span className="shrink-0 rounded-full" style={{ width: u(18), height: u(18), border: `${u(1.5)} solid #ff9f0a` }} />
        <span className="min-w-0 flex-1 truncate font-medium" style={{ fontSize: u(15) }}>
          {task}
        </span>
        <span className="shrink-0 text-panel-dim" style={{ fontSize: u(11.5) }}>
          {list}
        </span>
      </div>
      <div className="tnum flex items-center text-panel-muted" style={{ marginTop: u(6), marginLeft: u(30), gap: u(8), fontSize: u(12.5) }}>
        <span style={{ color: "#ff9f0a" }}>{due}</span>
        {repeat && <span>· {repeat}</span>}
        <span>· alert at due time</span>
      </div>
      <div className="flex flex-wrap" style={{ marginTop: u(12), marginLeft: u(30), gap: u(6) }}>
        {chips.map((c, i) => (
          <span
            key={c}
            className="rounded-full"
            style={{
              fontSize: u(11.5),
              padding: `${u(4)} ${u(10)}`,
              background: i === chip ? "rgba(255,159,10,0.18)" : "var(--panel-row)",
              color: i === chip ? "#ff9f0a" : undefined,
              boxShadow: i === chip ? "inset 0 0 0 1px rgba(255,159,10,0.45)" : undefined,
            }}
          >
            {c}
          </span>
        ))}
      </div>
    </div>
  );
}

/** A memory answer: what you were doing, with the moments it came from. */
export function RecallBody({ answer, moments }: { answer: string; moments: { time: string; app: Tile; line: string }[] }) {
  const reduce = useReducedMotion();
  return (
    <div style={{ padding: `${u(14)} ${u(20)} ${u(16)}` }}>
      <p className="leading-relaxed" style={{ fontSize: u(14.5) }}>
        {answer}
      </p>
      <ul style={{ marginTop: u(12), display: "grid", gap: u(6) }}>
        {moments.map((m, i) => (
          <motion.li
            key={m.time}
            initial={reduce ? false : { opacity: 0, y: 4 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.15 + i * 0.06, duration: 0.3, ease: EASE }}
            className="flex items-center"
            style={{ gap: u(10), padding: `${u(6)} ${u(8)}`, borderRadius: u(10), background: "var(--panel-row)" }}
          >
            <span className="tnum shrink-0 text-panel-dim" style={{ fontSize: u(11), width: u(36) }}>
              {m.time}
            </span>
            <TileIcon tile={m.app} size={18} />
            <span className="truncate text-panel-muted" style={{ fontSize: u(12.5) }}>
              {m.line}
            </span>
          </motion.li>
        ))}
      </ul>
    </div>
  );
}
