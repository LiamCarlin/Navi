"use client";

import { useRef } from "react";
import { Section } from "./Section";
import { useLoop } from "./useLoop";
import { Check } from "./Windows";

/* A race on a 1-second ruler. Keystroke at 0; Navi decides at ~100 ms, done at 0.9 s.
   The chatbot's cursor blinks, then tokens stream, still going long after. */
const KEY = 400;
const DECIDE = KEY + 100;
const DONE = KEY + 900;
const TOKENS_AT = KEY + 1500;
const TOKEN_MS = 85;
const REPLY =
  "Sure — I can help with that. To find flights to Tokyo, first open your browser and go to a flight search site. Then enter your departure city and";
const TOKENS = REPLY.split(" ");
const STOP = TOKENS_AT + TOKENS.length * TOKEN_MS + 800;
const LOOP = STOP + 3600;

type Frame = { pressed: boolean; naviMs: number; botMs: number; decided: boolean; done: boolean; tokens: number; cursor: boolean };

function derive(t: number): Frame {
  const pressed = t >= KEY;
  const naviMs = Math.max(0, Math.min(900, t - KEY));
  const botMs = Math.max(0, Math.min(STOP - KEY, t - KEY));
  const tokens = t < TOKENS_AT ? 0 : Math.min(TOKENS.length, Math.floor((t - TOKENS_AT) / TOKEN_MS) + 1);
  return {
    pressed,
    naviMs: Math.floor(naviMs / 10) * 10,
    botMs: Math.floor(botMs / 50) * 50,
    decided: t >= DECIDE,
    done: t >= DONE,
    tokens,
    cursor: pressed && t < STOP,
  };
}
const keyOf = (f: Frame) => `${f.pressed}|${f.naviMs}|${f.botMs}|${f.decided}|${f.done}|${f.tokens}|${f.cursor}`;

export function Decides() {
  const ref = useRef<HTMLDivElement>(null);
  const { frame: f } = useLoop(ref, { duration: LOOP, derive, key: keyOf, staticT: STOP - 400 });
  const naviX = f.pressed ? (f.done ? 90 : f.decided ? 10 + ((f.naviMs - 100) / 800) * 80 : (f.naviMs / 100) * 10) : 0;

  return (
    <Section
      n="02"
      title="Fast because it decides, not chats."
      flip
      visual={
        <div ref={ref} className="border-t border-line pt-6" aria-label="Navi decides in about 100 ms and is done under a second; a chatbot is still typing">
          <div className="mb-8 flex items-center justify-between text-[13px] text-fg-dim">
            <span className="flex items-center gap-2">
              <span className={`keycap transition-transform duration-100 ${f.pressed ? "translate-y-px" : ""}`}>⏎</span>
              keystroke
            </span>
            <span className="tnum">0 ms — 1 s</span>
          </div>

          <Lane label="Navi" ms={f.naviMs} fixed={f.done} tone="fg">
            <Ruler />
            <div
              className="absolute inset-y-0 left-0 rounded-full bg-accent"
              style={{ width: "10%", transform: `scaleX(${f.pressed ? Math.min(1, naviX / 10) : 0})`, transformOrigin: "left" }}
            />
            <div
              className="absolute inset-y-0 rounded-full bg-accent/35"
              style={{ left: "10%", width: "80%", transform: `scaleX(${f.decided ? Math.max(0, (naviX - 10) / 80) : 0})`, transformOrigin: "left" }}
            />
            <Marker x={naviX} done={f.done} />
            <Tick x={10} label="decision · ≈100 ms" />
            <Tick x={90} label="done · 0.9 s" />
          </Lane>

          <Lane label="A chatbot" ms={f.botMs} fixed={false} tone="muted" className="mt-14">
            <Ruler />
            <div
              className="absolute inset-y-0 left-0 w-full rounded-full bg-[repeating-linear-gradient(90deg,var(--line-strong)_0_6px,transparent_6px_12px)]"
              style={{ transform: `scaleX(${f.pressed ? Math.min(1, f.botMs / 1000) : 0})`, transformOrigin: "left" }}
            />
            <Marker x={f.pressed ? Math.min(100, f.botMs / 10) : 0} done={false} muted />
          </Lane>

          <div className="mt-6 min-h-[64px] rounded-[10px] border border-line p-3 text-[13px] leading-relaxed text-fg-muted">
            {f.tokens === 0 ? (
              <span className="text-fg-dim">{f.cursor ? <span className="caret caret-ink" /> : "Waiting for a keystroke"}</span>
            ) : (
              <>
                {TOKENS.slice(0, f.tokens).join(" ")}
                {f.cursor && <span className="caret caret-ink" />}
              </>
            )}
          </div>
        </div>
      }
    >
      Navi doesn’t wait on a chatbot. A small decision model returns a typed decision — open, answer, do, which app,
      risky? — in about 100 ms. The heavier model only runs when text or vision is needed.
    </Section>
  );
}

function Lane({ label, ms, fixed, tone, className = "", children }: { label: string; ms: number; fixed: boolean; tone: "fg" | "muted"; className?: string; children: React.ReactNode }) {
  return (
    <div className={`grid grid-cols-[80px_1fr_64px] items-center gap-3 sm:grid-cols-[96px_1fr_72px] ${className}`}>
      <span className={`text-sm font-medium ${tone === "fg" ? "text-fg" : "text-fg-muted"}`}>{label}</span>
      <div className="relative h-4" style={{ containerType: "inline-size" }}>
        {children}
      </div>
      <span className={`tnum text-right text-[13px] ${fixed ? "text-fg" : "text-fg-dim"}`}>{ms >= 1000 ? `${(ms / 1000).toFixed(1)} s` : `${ms} ms`}</span>
    </div>
  );
}

function Ruler() {
  return <div className="absolute inset-x-0 top-1/2 h-px -translate-y-1/2 bg-line-strong" aria-hidden="true" />;
}

function Tick({ x, label }: { x: number; label: string }) {
  return (
    <span className="tnum absolute top-6 -translate-x-1/2 whitespace-nowrap text-[11px] text-fg-dim" style={{ left: `${x}%` }}>
      {label}
    </span>
  );
}

function Marker({ x, done, muted = false }: { x: number; done: boolean; muted?: boolean }) {
  return (
    <span
      className={`absolute top-1/2 flex h-5 w-5 items-center justify-center rounded-full ${
        done ? "bg-accent text-accent-ink" : muted ? "bg-fg-dim" : "bg-fg"
      }`}
      style={{ left: 0, transform: `translate(calc(${x}cqw - 10px), -50%)`, transition: "background-color 150ms", boxShadow: "0 0 0 3px var(--bg)" }}
    >
      {done && <Check className="h-3 w-3" />}
    </span>
  );
}
