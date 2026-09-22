"use client";

import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { useRef } from "react";
import { Panel, RowIcon, type Row } from "./Panel";
import { Section } from "./Section";
import { useLoop } from "./useLoop";
import { Check, Typed, Win } from "./Windows";

type Example = {
  chip: string;
  spotlight: { title: string; kind: string }[];
  navi: Row[];
  window: "messages" | "docs" | "settings";
  outcome: string;
  where: string;
};

const EXAMPLES: Example[] = [
  {
    chip: "text mom I’m running late",
    spotlight: [
      { title: "Messages", kind: "Application" },
      { title: "Mom", kind: "Contacts" },
      { title: "text mom I’m running late", kind: "Search the web" },
      { title: "late-fees.pdf", kind: "Documents" },
    ],
    navi: [
      { icon: "message", title: "Text Mom: “I’m running late”", kind: "Task · Messages", hint: "Run" },
      { icon: "app", title: "Messages", kind: "App", hint: "Open" },
    ],
    window: "messages",
    outcome: "Sent to Mom",
    where: "Messages · 0.8 s",
  },
  {
    chip: "make a doc called Q4 plan and share it with Sam",
    spotlight: [
      { title: "Pages", kind: "Application" },
      { title: "Q3 plan.pages", kind: "Documents" },
      { title: "Sam Ortiz", kind: "Contacts" },
      { title: "make a doc called Q4 plan…", kind: "Search the web" },
    ],
    navi: [
      { icon: "doc", title: "Create “Q4 plan”, share with Sam", kind: "Task · Google Docs", hint: "Run" },
      { icon: "app", title: "Google Docs", kind: "Web app", hint: "Open" },
    ],
    window: "docs",
    outcome: "Q4 plan shared with Sam",
    where: "Docs · can edit",
  },
  {
    chip: "toggle dark mode",
    spotlight: [
      { title: "Displays", kind: "System Settings" },
      { title: "Appearance", kind: "System Settings" },
      { title: "toggle dark mode", kind: "Search the web" },
    ],
    navi: [
      { icon: "moon", title: "Dark Mode", kind: "System · Toggle", hint: "Toggle" },
      { icon: "app", title: "Appearance", kind: "System Settings", hint: "Open" },
    ],
    window: "settings",
    outcome: "Dark Mode on",
    where: "System · 0.1 s",
  },
];

/* Per example: type (~35 ms/char), Spotlight lists, Navi runs, the app does the thing, outcome; then the next. */
const PER = 5600;
const REST = 2400;
const LOOP = PER * EXAMPLES.length + REST;
const CHAR_MS = 34;

type Frame = {
  i: number;
  typedN: number;
  spotRows: number;
  naviRows: boolean;
  pressed: boolean;
  window: boolean;
  p: number; // 0–1 progress of the app doing its thing
  done: boolean;
};

function derive(t: number): Frame {
  const i = Math.min(EXAMPLES.length - 1, Math.floor(t / PER));
  const ex = EXAMPLES[i];
  const lt = t - i * PER;
  const typedN = Math.min(ex.chip.length, Math.floor(lt / CHAR_MS));
  const T = ex.chip.length * CHAR_MS;
  const spotRows = lt < T + 150 ? 0 : Math.min(ex.spotlight.length, Math.floor((lt - T - 150) / 90) + 1);
  const naviRows = lt >= T + 120;
  const pressed = lt >= T + 600;
  const window = lt >= T + 850;
  const p = Math.max(0, Math.min(1, (lt - (T + 950)) / 1600));
  const done = lt >= T + 2650;
  return { i, typedN, spotRows, naviRows, pressed, window, p: Math.round(p * 40) / 40, done };
}
const keyOf = (f: Frame) => `${f.i}|${f.typedN}|${f.spotRows}|${f.naviRows}|${f.pressed}|${f.window}|${f.p}|${f.done}`;

export function Does() {
  const ref = useRef<HTMLDivElement>(null);
  const reduce = useReducedMotion();
  const { frame: f, seek } = useLoop(ref, { duration: LOOP, derive, key: keyOf, staticT: 4200 });
  const ex = EXAMPLES[f.i];

  return (
    <Section
      id="does"
      n="01"
      title="Spotlight finds. Navi does."
      visual={
        <div ref={ref}>
          <div className="flex flex-wrap gap-2" role="tablist" aria-label="Example commands">
            {EXAMPLES.map((e, n) => (
              <button
                key={e.chip}
                type="button"
                role="tab"
                aria-selected={n === f.i}
                onClick={() => seek(n * PER)}
                className={`rounded-full border px-3 py-1 text-[13px] transition-colors duration-150 ${
                  n === f.i ? "border-fg text-fg" : "border-line text-fg-muted hover:border-line-strong"
                }`}
              >
                “{e.chip}”
              </button>
            ))}
          </div>

          <div className="mt-6 grid grid-cols-1 gap-4 md:grid-cols-2" style={{ "--u": "1px" } as React.CSSProperties}>
            <Pane label="Spotlight">
              <SpotlightMock query={ex.chip} typedN={f.typedN} results={ex.spotlight} shown={f.spotRows} />
              <div className="mt-4 flex h-[200px] items-end text-[13px] text-fg-dim">
                {f.spotRows >= ex.spotlight.length && <span>…and now you do it yourself.</span>}
              </div>
            </Pane>
            <Pane label="Navi">
              <Panel query={ex.chip} typed={f.typedN} rows={f.naviRows ? ex.navi : null} showCaret={f.typedN < ex.chip.length} pressed={f.pressed} />
              <div className="relative mt-4 h-[200px]">
                <AnimatePresence initial={false}>
                  {f.window && (
                    <motion.div
                      key={`${f.i}-win`}
                      className="absolute inset-x-0 top-0"
                      initial={reduce ? false : { opacity: 0, y: 8, scale: 0.98 }}
                      animate={{ opacity: 1, y: 0, scale: 1 }}
                      exit={reduce ? undefined : { opacity: 0, transition: { duration: 0.15 } }}
                      transition={{ type: "spring", stiffness: 420, damping: 32 }}
                    >
                      <AppWindow kind={ex.window} p={f.p} done={f.done} />
                    </motion.div>
                  )}
                </AnimatePresence>
                <AnimatePresence initial={false}>
                  {f.done && (
                    <motion.div
                      key={`${f.i}-out`}
                      className="absolute inset-x-0 bottom-0 flex items-center gap-3 rounded-[10px] border border-line bg-bg-elev px-3 py-2 text-[13px]"
                      initial={reduce ? false : { opacity: 0, y: 6 }}
                      animate={{ opacity: 1, y: 0 }}
                      exit={reduce ? undefined : { opacity: 0, transition: { duration: 0.15 } }}
                      transition={{ duration: 0.2 }}
                    >
                      <RowIcon icon="check" />
                      <div className="min-w-0">
                        <div className="truncate text-fg">{ex.outcome}</div>
                        <div className="tnum text-xs text-fg-dim">{ex.where}</div>
                      </div>
                    </motion.div>
                  )}
                </AnimatePresence>
              </div>
            </Pane>
          </div>
        </div>
      }
    >
      Spotlight hands you a list. Navi runs the command in the app it needs, then tells you it’s done.
    </Section>
  );
}

function Pane({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="border-t border-line pt-3">
      <div className="mb-3 text-[13px] text-fg-dim">{label}</div>
      {children}
    </div>
  );
}

function SpotlightMock({ query, typedN, results, shown }: { query: string; typedN: number; results: { title: string; kind: string }[]; shown: number }) {
  return (
    <div className="glass overflow-hidden rounded-[16px]">
      <div className="flex h-[56px] items-center gap-3 px-[18px]">
        <svg viewBox="0 0 24 24" className="h-[18px] w-[18px] text-panel-dim" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round">
          <circle cx="11" cy="11" r="7" />
          <path d="M20 20l-3.5-3.5" />
        </svg>
        <span className="min-w-0 flex-1 truncate text-[17px]">
          {typedN === 0 ? <span className="text-panel-dim">Spotlight Search</span> : <Typed text={query} n={typedN} ink />}
        </span>
      </div>
      <div className="overflow-hidden transition-[height] duration-200" style={{ height: shown === 0 ? 0 : shown * 50 + 12 }}>
        <ul className="p-[6px]" style={{ borderTop: "1px solid var(--panel-line)" }}>
          {results.slice(0, shown).map((r, i) => (
            <li key={r.title} className="flex h-[50px] items-center gap-3 rounded-[10px] px-[10px]" style={{ background: i === 0 ? "var(--panel-row)" : undefined }}>
              <span className="h-[28px] w-[28px] shrink-0 rounded-[8px]" style={{ background: "var(--panel-row)" }} />
              <div className="min-w-0 flex-1">
                <div className="truncate text-[14px]">{r.title}</div>
                <div className="mt-[2px] text-[11px] text-panel-dim">{r.kind}</div>
              </div>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}

function AppWindow({ kind, p, done }: { kind: Example["window"]; p: number; done: boolean }) {
  if (kind === "messages") {
    const msg = "I’m running late — 10 min";
    const n = Math.floor(p * msg.length);
    return (
      <Win title="Mom" tint="#34c759">
        <div className="space-y-2 p-3 text-[12px]">
          <div className="w-fit max-w-[70%] rounded-[12px] rounded-bl-[4px] px-3 py-1.5" style={{ background: "var(--win-skel)" }}>
            Are you on your way?
          </div>
          {n > 0 && (
            <div className="ml-auto w-fit max-w-[70%] rounded-[12px] rounded-br-[4px] bg-[#0a84ff] px-3 py-1.5 text-white">
              <Typed text={msg} n={n} ink />
            </div>
          )}
          <div className="h-3 text-right text-[10px] text-win-muted">{done ? "Delivered" : ""}</div>
        </div>
      </Win>
    );
  }
  if (kind === "docs") {
    const title = "Q4 plan";
    const n = Math.floor(Math.min(1, p * 2) * title.length);
    const lines = Math.floor(Math.max(0, p - 0.5) * 2 * 4);
    return (
      <Win title="Google Docs" tint="#4285f4">
        <div className="p-3">
          <div className="flex items-center justify-between">
            <div className="text-[13px] font-medium">
              <Typed text={title} n={n} ink />
            </div>
            <div className={`rounded-full px-2 py-0.5 text-[10px] transition-opacity duration-200 ${done ? "opacity-100" : "opacity-0"}`} style={{ background: "var(--accent-soft)", color: "var(--accent)" }}>
              Shared · Sam
            </div>
          </div>
          <div className="mt-3 space-y-2">
            {[0.9, 1, 0.75, 0.6].map((w, i) => (
              <div key={i} className="h-2 rounded transition-opacity duration-200" style={{ width: `${w * 100}%`, background: "var(--win-skel)", opacity: i < lines ? 1 : 0 }} />
            ))}
          </div>
        </div>
      </Win>
    );
  }
  const dark = p > 0.5;
  return (
    <Win title="Appearance" tint="#8e8e93" dark={dark}>
      <div className="flex items-center justify-between p-3 text-[12px]">
        <div>
          <div className="font-medium">Appearance</div>
          <div className="text-[10px] opacity-60">{dark ? "Dark" : "Light"}</div>
        </div>
        <div className="flex gap-2">
          {["Light", "Dark"].map((o) => {
            const on = (o === "Dark") === dark;
            return (
              <div key={o} className="flex flex-col items-center gap-1">
                <div
                  className="h-8 w-12 rounded-[6px] border-2 transition-colors duration-200"
                  style={{ borderColor: on ? "var(--accent)" : "transparent", background: o === "Dark" ? "#2c2c2e" : "#f2f2f7" }}
                />
                <span className="text-[10px] opacity-70">{o}</span>
              </div>
            );
          })}
        </div>
      </div>
      <div className={`flex items-center gap-1 px-3 pb-3 text-[10px] opacity-70 ${done ? "" : "invisible"}`}>
        <Check className="h-2.5 w-2.5" /> Applied
      </div>
    </Win>
  );
}
