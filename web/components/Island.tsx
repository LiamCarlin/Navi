"use client";

import { useEffect, useRef, useState } from "react";
import { Glyph } from "./Glyph";
import { u } from "@/lib/u";

export type Step = { label: string; state: "running" | "done" };

/**
 * The voice island: the notch itself growing downward while you talk.
 *
 * One element with a constant bottom radius (top corners square where it meets the bezel).
 * Collapsed it is exactly the notch (same width and height); open it widens and grows to fit
 * its content. Only `width`/`height` of this one box transition, and the box sits on its own
 * compositor layer, so the corners never re-rasterise — no radius flicker, no seams.
 * Content fades in after the box has grown. Sized in screen units (`--u`).
 */
export function Island({
  open,
  text,
  listening,
  steps,
  width = 420,
  notchWidth = 126,
  notchHeight = 24,
  status,
}: {
  open: boolean;
  text: string;
  listening: boolean;
  steps: Step[];
  width?: number;
  notchWidth?: number;
  notchHeight?: number;
  status?: string;
}) {
  const inner = useRef<HTMLDivElement>(null);
  const [contentPx, setContentPx] = useState(0);

  // Measure the content so the box can animate `height` to a real number.
  useEffect(() => {
    const el = inner.current;
    if (!el) return;
    // Border-box height: contentRect excludes the padding, which clipped the last line.
    const measure = () => setContentPx(el.getBoundingClientRect().height);
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    measure();
    return () => ro.disconnect();
  }, []);

  const label = status ?? (listening ? "Listening" : steps.length && steps.every((s) => s.state === "done") ? "Done" : "Working");
  const openStyle = { width: u(width), height: `calc(${u(notchHeight)} + ${contentPx}px)` };
  const closedStyle = { width: u(notchWidth), height: u(notchHeight) };

  return (
    <div
      className="overflow-hidden bg-black text-white"
      style={{
        ...(open ? openStyle : closedStyle),
        borderRadius: `0 0 ${u(20)} ${u(20)}`,
        transition: "width 280ms cubic-bezier(0.22, 1, 0.36, 1), height 280ms cubic-bezier(0.22, 1, 0.36, 1)",
        willChange: "width, height",
        transform: "translateZ(0)",
        boxShadow: open ? "0 18px 50px -12px rgba(0,0,0,0.75)" : "none",
      }}
      role="img"
      aria-label={open ? `Navi voice island: ${text}` : "Notch"}
    >
      <div style={{ height: u(notchHeight) }} />
      <div
        ref={inner}
        style={{
          width: u(width),
          padding: `${u(10)} ${u(16)} ${u(14)}`,
          opacity: open ? 1 : 0,
          transition: `opacity 160ms ease ${open ? "180ms" : "0ms"}`,
        }}
      >
        <div className="flex items-center" style={{ gap: u(10) }}>
          <span className="flex shrink-0 items-center justify-center rounded-full text-accent" style={{ width: u(24), height: u(24), background: "rgba(139,140,248,0.16)" }}>
            <Glyph style={{ width: u(12), height: u(12) }} />
          </span>
          <Waveform active={listening} />
          <span className="ml-auto text-white/55" style={{ fontSize: u(11) }}>
            {label}
          </span>
        </div>

        {text && (
          <p className="leading-snug text-white" style={{ fontSize: u(14), marginTop: u(10) }}>
            “{text}
            {listening && <span className="caret" />}”
          </p>
        )}

        {steps.length > 0 && (
          <ul className="border-t border-white/10" style={{ marginTop: u(10), paddingTop: u(8), display: "grid", gap: u(5) }}>
            {steps.map((s) => (
              <li key={s.label} className={`flex items-center ${s.state === "done" ? "text-white/85" : "text-white/60"}`} style={{ gap: u(8), fontSize: u(12.5) }}>
                <StepMark state={s.state} />
                <span className="truncate">{s.label}</span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}

function StepMark({ state }: { state: Step["state"] }) {
  if (state === "done") {
    return (
      <span className="flex shrink-0 items-center justify-center rounded-full bg-[#8b8cf8] text-black" style={{ width: u(14), height: u(14) }}>
        <svg viewBox="0 0 24 24" style={{ width: u(9), height: u(9) }} fill="none" stroke="currentColor" strokeWidth="3.2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M5 12l5 5 9-10" />
        </svg>
      </span>
    );
  }
  return <span className="spin shrink-0 rounded-full border-2 border-white/25 border-t-[#8b8cf8]" style={{ width: u(14), height: u(14) }} aria-hidden="true" />;
}

const BARS = [0.45, 0.8, 1, 0.6, 0.9, 0.5, 0.75, 0.4];

export function Waveform({ active, height = 16 }: { active: boolean; height?: number }) {
  return (
    <span className="flex items-center" style={{ height: u(height), gap: u(2.5) }} aria-hidden="true">
      {BARS.map((h, i) => (
        <span
          key={i}
          className={`rounded-full ${active ? "voice-bar bg-[#8b8cf8]" : "voice-bar-idle bg-white/35"}`}
          style={{ width: u(2.5), height: `${h * 100}%`, animationDelay: `${i * 0.09}s` }}
        />
      ))}
    </span>
  );
}
