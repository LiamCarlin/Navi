"use client";

import { motion, useInView, useReducedMotion } from "framer-motion";
import { useEffect, useMemo, useRef, useState } from "react";
import { Bar } from "./Bar";
import { exampleBody, liveRows, visitorBody } from "./bodies";
import { decide, EXAMPLES, KIND_LABEL, type Decision, type Kind } from "@/lib/demo";
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
    <div ref={wrap} className="flex h-full flex-col">
      <div className="stage relative min-h-[230px] w-full flex-1 sm:min-h-[340px]">
        <div className="absolute inset-x-0 top-0">
          <Bar query={text} input={input} body={view?.body} bodyKey={view?.key} hints={view?.hints} />
        </div>
      </div>
      <Meter decision={decision} mode={mode} />
    </div>
  );
}

const ORDER: Kind[] = ["open", "calc", "answer", "task", "schedule", "remind", "recall"];

/** What the decision looked like: one probability per kind, the winner lit in its app tint. */
function Meter({ decision, mode }: { decision: Decision | null; mode: "auto" | "user" }) {
  return (
    <div className="mt-6 px-1">
      <div className="grid grid-cols-7 gap-1.5 sm:gap-3" aria-live="polite">
        {ORDER.map((k) => {
          const p = decision?.probs[k] ?? 0;
          const win = decision?.kind === k;
          return (
            <div key={k} className="min-w-0">
              <div className="relative h-[3px] overflow-hidden rounded-full bg-white/20">
                <motion.div
                  className="absolute inset-y-0 left-0 rounded-full bg-white"
                  style={{ originX: 0 }}
                  animate={{ width: `${Math.round(p * 100)}%`, opacity: win ? 1 : 0.45 }}
                  transition={{ duration: 0.45, ease: EASE }}
                />
              </div>
              <div className={`mt-2 flex items-baseline justify-between gap-1 text-[11px] transition-colors duration-300 sm:text-xs ${win ? "text-white" : "text-white/55"}`}>
                <span className="truncate font-medium">{KIND_LABEL[k]}</span>
                <span className="tnum hidden font-mono sm:inline">{decision ? Math.round(p * 100) : "–"}</span>
              </div>
            </div>
          );
        })}
      </div>
      <p className="mt-4 text-[13px] leading-relaxed text-white/75">
        {decision?.asks ? <span className="text-white">Would stop and ask {decision.asks}. </span> : null}
        {mode === "auto" ? "Click the bar and type your own. " : "Toy router running in your browser. "}
        In the app, one call to a small decision model makes this choice in about a tenth of a second.
      </p>
    </div>
  );
}
