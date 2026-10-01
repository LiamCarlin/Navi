"use client";

import { motion, useInView, useReducedMotion } from "framer-motion";
import { useEffect, useMemo, useRef, useState } from "react";
import { Bar } from "./Bar";
import { Glyph } from "../Glyph";
import { exampleBody, liveRows, visitorBody } from "./bodies";
import { decide, EXAMPLES, KIND_LABEL, KIND_TINT, type Decision, type Kind } from "@/lib/demo";
import { EASE } from "@/lib/motion";

type Auto = { i: number; typed: number; phase: "typing" | "hold" | "erasing"; since: number };

const HOLD: Record<Kind, number> = { open: 2600, calc: 2800, answer: 5600, task: 4400, schedule: 3800, remind: 3200, recall: 4600 };

/**
 * The hero's ⌘Space bar. On its own it types the scripted examples, routing on every
 * keystroke like the app does. Click it and it's yours: type anything and the toy router
 * in lib/demo.ts decides what Navi would do with it.
 */
export function LiveBar() {
  const reduce = useReducedMotion();
  const wrap = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const inView = useInView(wrap, { amount: 0.3 });
  const [mode, setMode] = useState<"auto" | "user">("auto");
  const [auto, setAuto] = useState<Auto>({ i: 0, typed: 0, phase: "typing", since: 0 });
  const [now, setNow] = useState(0);
  const [value, setValue] = useState("");
  const [entered, setEntered] = useState(false);

  // Reduced motion: show the first example finished, no ticking.
  useEffect(() => {
    if (reduce) setAuto({ i: 2, typed: EXAMPLES[2].q.length, phase: "hold", since: -1e6 });
  }, [reduce]);

  // The scripted typist.
  useEffect(() => {
    if (mode !== "auto" || reduce || !inView) return;
    const ex = EXAMPLES[auto.i];
    let id: ReturnType<typeof setTimeout>;
    if (auto.phase === "typing") {
      if (auto.typed < ex.q.length) {
        const ch = ex.q[auto.typed];
        id = setTimeout(() => setAuto((a) => ({ ...a, typed: a.typed + 1 })), ch === " " ? 90 : 38 + Math.random() * 46);
      } else {
        id = setTimeout(() => setAuto((a) => ({ ...a, phase: "hold", since: performance.now() })), 520);
      }
    } else if (auto.phase === "hold") {
      const tick = setInterval(() => setNow(performance.now()), 50);
      id = setTimeout(() => setAuto((a) => ({ ...a, phase: "erasing" })), HOLD[ex.kind]);
      return () => {
        clearInterval(tick);
        clearTimeout(id);
      };
    } else {
      if (auto.typed > 0) id = setTimeout(() => setAuto((a) => ({ ...a, typed: Math.max(0, a.typed - 3) })), 14);
      else id = setTimeout(() => setAuto((a) => ({ i: (a.i + 1) % EXAMPLES.length, typed: 0, phase: "typing", since: 0 })), 260);
    }
    return () => clearTimeout(id);
  }, [auto, mode, reduce, inView]);

  const ex = EXAMPLES[auto.i];
  const text = mode === "auto" ? ex.q.slice(0, auto.typed) : value;
  const decision = useMemo(() => decide(text), [text]);

  let view: { body: React.ReactNode; key: string; hints: { keys: string; label?: string }[] } | null = null;
  if (mode === "auto" && auto.phase === "hold") view = exampleBody(ex, reduce ? 1e6 : now - auto.since);
  else if (mode === "user" && entered && decision) view = visitorBody(value, decision);
  else if (decision) view = liveRows(text, decision);

  function takeOver() {
    if (mode === "user") return;
    setMode("user");
    setValue("");
    setEntered(false);
    requestAnimationFrame(() => inputRef.current?.focus());
  }

  const input =
    mode === "user" ? (
      <input
        ref={inputRef}
        value={value}
        onChange={(e) => {
          setValue(e.target.value);
          setEntered(false);
        }}
        onKeyDown={(e) => {
          if (e.key === "Enter" && value.trim()) setEntered(true);
          if (e.key === "Escape") {
            if (entered) setEntered(false);
            else setValue("");
          }
        }}
        onBlur={() => {
          if (!value.trim()) setMode("auto");
        }}
        aria-label="Type a command to see what Navi would do"
        placeholder="Type anything: “open notion”, “12% of 340”, “email ana the deck”…"
        spellCheck={false}
        autoComplete="off"
        className="min-w-0 flex-1 bg-transparent leading-none text-panel-fg outline-none placeholder:text-panel-dim focus-visible:outline-none"
        style={{ fontSize: "calc(var(--u) * 21)", letterSpacing: "-0.01em" }}
      />
    ) : (
      <button
        type="button"
        onClick={takeOver}
        onFocus={takeOver}
        className="min-w-0 flex-1 cursor-text truncate text-left leading-none focus-visible:outline-none"
        style={{ fontSize: "calc(var(--u) * 21)", letterSpacing: "-0.01em" }}
        aria-label="Navi bar demo. Press to type your own command."
      >
        {text || <span className="text-panel-dim">Ask Navi anything</span>}
        <span className="caret" style={{ background: "#5e5ce6" }} />
      </button>
    );

  return (
    <div ref={wrap}>
      <Desk>
        <div className="stage mx-auto w-full max-w-[680px]">
          <Bar query={text} input={input} body={view?.body} bodyKey={view?.key} hints={view?.hints} />
        </div>
      </Desk>
      <div className="mx-auto max-w-[680px]">
        <Meter decision={decision} mode={mode} />
      </div>
    </div>
  );
}

/** A slice of a Mac desktop: the wallpaper and a menu bar, with the bar where Spotlight sits. */
function Desk({ children }: { children: React.ReactNode }) {
  return (
    <div className="relative h-[460px] overflow-hidden rounded-[22px] border border-line sm:h-[540px] sm:rounded-[28px]" style={{ background: "var(--wall)" }}>
      <div
        className="absolute inset-x-0 top-0 flex h-7 items-center gap-4 px-4 text-[12px] backdrop-blur-md"
        style={{ background: "var(--menubar)", color: "var(--menubar-fg)" }}
        aria-hidden="true"
      >
        <svg viewBox="0 0 24 24" fill="currentColor" className="h-3.5 w-3.5">
          <path d="M16.4 12.7c0-2.4 2-3.6 2-3.7-1.1-1.6-2.8-1.8-3.4-1.9-1.5-.1-2.8.9-3.6.9-.7 0-1.9-.8-3.1-.8-1.6 0-3.1.9-3.9 2.4-1.7 2.9-.4 7.2 1.2 9.6.8 1.2 1.8 2.5 3 2.4 1.2 0 1.7-.8 3.1-.8s1.9.8 3.1.8c1.3 0 2.1-1.2 2.9-2.4.9-1.3 1.3-2.6 1.3-2.7 0 0-2.6-1-2.6-3.8zM14 5.6c.6-.8 1.1-1.9 1-3-.9 0-2.1.6-2.7 1.4-.6.7-1.1 1.8-1 2.9 1 .1 2.1-.5 2.7-1.3z" />
        </svg>
        <span className="font-semibold">Finder</span>
        <span className="hidden sm:inline">File</span>
        <span className="hidden sm:inline">Edit</span>
        <span className="hidden sm:inline">View</span>
        <span className="ml-auto flex items-center gap-1.5">
          <Glyph className="h-3 w-3" style={{ color: "#bf5af2" }} />
          Navi
        </span>
        <span className="tnum">Tue 9:41</span>
      </div>
      <div className="absolute inset-x-0 top-[13%] px-3 sm:top-[16%] sm:px-8">{children}</div>
    </div>
  );
}

const ORDER: Kind[] = ["open", "calc", "answer", "task", "schedule", "remind", "recall"];

/** What the decision looked like: one probability per kind, the winner lit in its app tint. */
function Meter({ decision, mode }: { decision: Decision | null; mode: "auto" | "user" }) {
  return (
    <div className="mt-5 px-1">
      <div className="grid grid-cols-7 gap-1.5 sm:gap-3" aria-live="polite">
        {ORDER.map((k) => {
          const p = decision?.probs[k] ?? 0;
          const win = decision?.kind === k;
          return (
            <div key={k} className="min-w-0">
              <div className="relative h-[3px] overflow-hidden rounded-full bg-line">
                <motion.div
                  className="absolute inset-y-0 left-0 rounded-full"
                  style={{ background: win ? KIND_TINT[k] : "var(--fg-dim)", originX: 0 }}
                  animate={{ width: `${Math.round(p * 100)}%`, opacity: win ? 1 : 0.45 }}
                  transition={{ duration: 0.45, ease: EASE }}
                />
              </div>
              <div className={`mt-2 flex items-baseline justify-between gap-1 text-[11px] sm:text-xs ${win ? "text-fg" : "text-fg-dim"}`}>
                <span className="truncate font-medium">{KIND_LABEL[k]}</span>
                <span className="tnum hidden font-mono sm:inline">{decision ? Math.round(p * 100) : "–"}</span>
              </div>
            </div>
          );
        })}
      </div>
      <p className="label mt-4 leading-relaxed">
        {decision?.asks ? <span className="text-fg-muted">Would stop and ask {decision.asks}. </span> : null}
        {mode === "auto" ? "Click the bar and type your own. " : "Toy router running in your browser. "}
        In the app, one call to a small decision model makes this choice in about a tenth of a second.
      </p>
    </div>
  );
}
