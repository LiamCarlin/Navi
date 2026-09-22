import type { ReactNode } from "react";
import { Glyph } from "./Glyph";
import { u } from "@/lib/u";

/**
 * A 14" MacBook Pro, straight on, drawn in CSS from the real proportions:
 * a 16:10 screen inside a thin uniform black bezel, inside an aluminium lid
 * (silver in light mode, space black in dark), a narrow short notch, and a
 * continuous base — slim front lip with the trackpad cutout, rounded ends,
 * a soft shadow underneath. A ≤4° lean, no pointer tilt.
 *
 * Everything on the screen is laid out in screen units (`--u`, see globals.css)
 * so the UI scales with the laptop and stays crisp at 2× DPR.
 */
export const NOTCH_W = 126; // u — about 1/7 of the 880u screen
export const NOTCH_H = 24; // u — short

export function MacBook({ children, className = "" }: { children?: ReactNode; className?: string }) {
  return (
    <div className={`relative mx-auto w-full select-none ${className}`} style={{ perspective: "2400px" }}>
      {/* Lid */}
      <div
        className="relative rounded-[2.4%/3.7%] p-[1.05%] pb-[1.15%]"
        style={{
          transform: "rotateX(3deg)",
          transformOrigin: "50% 100%",
          background: "var(--mb-lid)",
          boxShadow: "var(--mb-lid-shadow), inset 0 1px 0 var(--mb-lid-hi), inset 0 -1px 0 rgba(0,0,0,0.35)",
        }}
      >
        {/* Bezel: uniform, thin */}
        <div className="rounded-[1.6%/2.5%] bg-[#0b0b0c] p-[2.1%]">
          {/* Screen, 16:10 */}
          <div className="screen relative overflow-hidden rounded-[0.9%/1.45%] bg-[#0d0d12]" style={{ aspectRatio: "16 / 10" }}>
            <div className="absolute inset-0" style={{ background: "var(--wall)" }} aria-hidden="true" />
            <MenuBar />
            <Dock />
            <div className="absolute inset-0">{children}</div>
            {/* Notch, drawn last so the island reads as the notch itself growing. */}
            <div className="pointer-events-none absolute inset-x-0 top-0 z-30 flex justify-center" aria-hidden="true">
              <div className="bg-[#0b0b0c]" style={{ width: u(NOTCH_W), height: u(NOTCH_H), borderRadius: `0 0 ${u(10)} ${u(10)}` }} />
            </div>
            {/* Glass: a faint reflection band */}
            <div
              className="pointer-events-none absolute inset-0 z-40"
              style={{ background: "linear-gradient(105deg, rgba(255,255,255,0.07) 0%, rgba(255,255,255,0.02) 24%, rgba(255,255,255,0) 40%)" }}
              aria-hidden="true"
            />
          </div>
        </div>
      </div>

      {/* Base: continuous with the lid — front lip with the trackpad cutout, rounded ends, shadow under it. */}
      <div className="relative -mt-px" aria-hidden="true">
        <div
          className="relative mx-auto w-[112%] -ml-[6%] overflow-hidden"
          style={{
            height: "clamp(9px, 1.9vw, 19px)",
            borderRadius: "0 0 clamp(6px, 1.2vw, 12px) clamp(6px, 1.2vw, 12px) / 0 0 100% 100%",
            background: "var(--mb-base)",
            boxShadow: "inset 0 1px 0 var(--mb-base-hi), inset 0 -2px 3px rgba(0,0,0,0.25)",
          }}
        >
          {/* Trackpad cutout: the finger notch on the front edge */}
          <div
            className="absolute left-1/2 top-0 -translate-x-1/2"
            style={{ width: "13%", height: "42%", background: "var(--mb-cut)", borderRadius: "0 0 999px 999px" }}
          />
        </div>
        {/* Soft drop shadow on the desk */}
        <div
          className="pointer-events-none absolute left-1/2 top-[40%] h-[220%] w-[118%] -translate-x-1/2"
          style={{ background: "radial-gradient(50% 50% at 50% 30%, var(--mb-shadow), transparent 70%)", zIndex: -1 }}
        />
      </div>
    </div>
  );
}

function MenuBar() {
  return (
    <div
      className="absolute inset-x-0 top-0 z-10 flex items-center backdrop-blur-md"
      style={{ height: u(NOTCH_H), padding: `0 ${u(12)}`, fontSize: u(11), background: "var(--menubar)", color: "var(--menubar-fg)" }}
      aria-hidden="true"
    >
      <svg viewBox="0 0 24 24" fill="currentColor" style={{ width: u(12), height: u(12), marginRight: u(14) }}>
        <path d="M16.4 12.7c0-2.4 2-3.6 2-3.7-1.1-1.6-2.8-1.8-3.4-1.9-1.5-.1-2.8.9-3.6.9-.7 0-1.9-.8-3.1-.8-1.6 0-3.1.9-3.9 2.4-1.7 2.9-.4 7.2 1.2 9.6.8 1.2 1.8 2.5 3 2.4 1.2 0 1.7-.8 3.1-.8s1.9.8 3.1.8c1.3 0 2.1-1.2 2.9-2.4.9-1.3 1.3-2.6 1.3-2.7 0 0-2.6-1-2.6-3.8zM14 5.6c.6-.8 1.1-1.9 1-3-.9 0-2.1.6-2.7 1.4-.6.7-1.1 1.8-1 2.9 1 .1 2.1-.5 2.7-1.3z" />
      </svg>
      <span className="font-semibold">Finder</span>
      <span style={{ marginLeft: u(14) }}>File</span>
      <span style={{ marginLeft: u(14) }}>Edit</span>
      <span style={{ marginLeft: u(14) }}>View</span>
      <span className="ml-auto flex items-center" style={{ gap: u(12) }}>
        <span className="flex items-center" style={{ gap: u(4) }}>
          <Glyph className="text-accent" style={{ width: u(11), height: u(11) }} />
          <span>Navi</span>
        </span>
        <span className="rounded-[2px] border border-current opacity-80" style={{ width: u(16), height: u(8), padding: u(1) }}>
          <span className="block h-full w-[80%] rounded-[1px] bg-current" />
        </span>
        <span className="tnum">Mon 9:41</span>
      </span>
    </div>
  );
}

const DOCK = ["#3b82f6", "#22c55e", "#f59e0b", "#ef4444", "#a855f7", "#14b8a6", "#64748b"];

function Dock() {
  return (
    <div
      className="absolute bottom-0 left-1/2 z-10 flex -translate-x-1/2 items-center backdrop-blur-md"
      style={{ gap: u(6), padding: u(5), marginBottom: u(8), borderRadius: u(12), background: "var(--dock)", border: "1px solid var(--panel-line)" }}
      aria-hidden="true"
    >
      {DOCK.map((c, i) => (
        <span
          key={i}
          className="block shadow-[inset_0_1px_0_rgba(255,255,255,0.35)]"
          style={{ width: u(22), height: u(22), borderRadius: u(6), background: `linear-gradient(160deg, ${c}, ${c}99)` }}
        />
      ))}
    </div>
  );
}
