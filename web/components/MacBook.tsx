"use client";

import { motion, useMotionValue, useReducedMotion, useSpring, useTransform } from "framer-motion";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { Glyph } from "./Glyph";
import { u } from "./Panel";

/**
 * A 14" MacBook Pro drawn in CSS: aluminium lid, thin black bezel, notch, and a hint of the base.
 * The lid sits in perspective (leaning back ~8°) and tilts ±3° with the pointer on desktop.
 * Everything on the screen is laid out in screen units (`--u`, see globals.css) so the UI scales
 * with the laptop and stays crisp on retina — no canvas, no WebGL.
 */
export function MacBook({ children, className = "" }: { children?: ReactNode; className?: string }) {
  const reduce = useReducedMotion();
  const ref = useRef<HTMLDivElement>(null);
  const [tiltOn, setTiltOn] = useState(false);

  const px = useMotionValue(0);
  const py = useMotionValue(0);
  const sx = useSpring(px, { stiffness: 120, damping: 20, mass: 0.6 });
  const sy = useSpring(py, { stiffness: 120, damping: 20, mass: 0.6 });
  const rotateY = useTransform(sx, [-1, 1], [-3, 3]);
  const rotateX = useTransform(sy, [-1, 1], [11, 5]);

  useEffect(() => {
    if (reduce) return;
    const fine = window.matchMedia("(pointer: fine)").matches;
    if (!fine) return;
    setTiltOn(true);
    const onMove = (e: PointerEvent) => {
      const el = ref.current;
      if (!el) return;
      const r = el.getBoundingClientRect();
      // Normalised −1…1 relative to the laptop, clamped so the tilt eases out past its edges.
      const nx = Math.max(-1, Math.min(1, ((e.clientX - r.left) / r.width) * 2 - 1));
      const ny = Math.max(-1, Math.min(1, ((e.clientY - r.top) / r.height) * 2 - 1));
      px.set(nx);
      py.set(ny);
    };
    const onLeave = () => {
      px.set(0);
      py.set(0);
    };
    window.addEventListener("pointermove", onMove, { passive: true });
    document.addEventListener("pointerleave", onLeave);
    return () => {
      window.removeEventListener("pointermove", onMove);
      document.removeEventListener("pointerleave", onLeave);
    };
  }, [reduce, px, py]);

  return (
    <div ref={ref} className={`relative mx-auto w-full select-none ${className}`} style={{ perspective: "1800px" }}>
      {/* Lid */}
      <motion.div
        className="relative"
        style={{
          transformStyle: "preserve-3d",
          transformOrigin: "50% 100%",
          rotateX: tiltOn ? rotateX : 8,
          rotateY: tiltOn ? rotateY : 0,
        }}
      >
        <div
          className="relative rounded-[3.2%/4.9%] bg-[linear-gradient(180deg,#2d2d31,#1c1c1f_60%,#161618)] p-[0.7%] shadow-[0_40px_90px_-30px_rgba(0,0,0,0.9),0_2px_0_rgba(255,255,255,0.05)_inset,0_-1px_0_rgba(0,0,0,0.6)_inset]"
          style={{ aspectRatio: "1000 / 655" }}
        >
          {/* Black bezel */}
          <div className="relative h-full w-full rounded-[2.6%/4%] bg-[#050506] p-[1.5%] pt-[1.8%] pb-[1.9%]">
            {/* Screen */}
            <div className="screen relative h-full w-full overflow-hidden rounded-[1.4%/2.2%] bg-[#0d0d12]">
              <Wallpaper />
              <MenuBar />
              <Dock />
              {/* Live content (island, bar…) */}
              <div className="absolute inset-0">{children}</div>
              {/* Notch: drawn last so anything dropping from it appears to come out from behind. */}
              <div className="pointer-events-none absolute inset-x-0 top-0 z-30 flex justify-center" aria-hidden="true">
                <div className="bg-[#050506]" style={{ width: u(112), height: u(30), borderRadius: `0 0 ${u(11)} ${u(11)}` }} />
              </div>
              {/* Glass reflection */}
              <div
                className="pointer-events-none absolute inset-0 z-40 bg-[linear-gradient(112deg,rgba(255,255,255,0.09)_0%,rgba(255,255,255,0.03)_28%,rgba(255,255,255,0)_46%)]"
                aria-hidden="true"
              />
            </div>
          </div>
          {/* Hinge highlight along the bottom edge of the lid */}
          <div className="absolute inset-x-[6%] bottom-0 h-px bg-white/10" aria-hidden="true" />
        </div>
      </motion.div>

      {/* Base: keyboard deck seen from above, then the front lip. */}
      <div className="relative -mt-px" style={{ perspective: "1800px" }} aria-hidden="true">
        <div
          className="relative mx-auto w-[104%] -ml-[2%] rounded-b-[1.2%/30%] bg-[linear-gradient(180deg,#232326,#1a1a1c_50%,#151517)] shadow-[0_30px_60px_-20px_rgba(0,0,0,0.9)]"
          style={{ height: "clamp(14px, 2.6vw, 30px)", transformOrigin: "50% 0%", transform: "rotateX(62deg)" }}
        >
          <div className="absolute left-1/2 top-[18%] h-[52%] w-[52%] -translate-x-1/2 rounded-[3px] bg-[#0f0f11] shadow-[inset_0_0_0_1px_rgba(255,255,255,0.03)]" />
          <div className="absolute left-1/2 top-[76%] h-[18%] w-[22%] -translate-x-1/2 rounded-[2px] bg-[#1d1d20] shadow-[inset_0_0_0_1px_rgba(255,255,255,0.04)]" />
        </div>
        <div
          className="mx-auto w-[104%] -ml-[2%] rounded-b-[999px] bg-[linear-gradient(180deg,#2a2a2e,#141416)]"
          style={{ height: "clamp(5px, 0.8vw, 9px)", marginTop: "-1px" }}
        >
          <div className="mx-auto h-[45%] w-[8%] rounded-b-md bg-[#0c0c0e]" />
        </div>
      </div>
    </div>
  );
}

function Wallpaper() {
  return (
    <div
      className="absolute inset-0"
      aria-hidden="true"
      style={{
        background:
          "radial-gradient(75% 65% at 22% 105%, rgba(139,140,248,0.55), transparent 62%), radial-gradient(55% 45% at 88% 10%, rgba(120,90,220,0.35), transparent 60%), radial-gradient(40% 40% at 60% 60%, rgba(60,80,180,0.18), transparent 70%), linear-gradient(165deg,#1b1b30 0%,#131324 45%,#0c0c16 100%)",
      }}
    />
  );
}

function MenuBar() {
  return (
    <div
      className="absolute inset-x-0 top-0 z-10 flex items-center bg-black/25 text-white/80 backdrop-blur-md"
      style={{ height: u(24), padding: `0 ${u(12)}`, fontSize: u(11) }}
      aria-hidden="true"
    >
      <svg viewBox="0 0 24 24" fill="currentColor" style={{ width: u(12), height: u(12), marginRight: u(14) }} className="text-white/90">
        <path d="M16.4 12.7c0-2.4 2-3.6 2-3.7-1.1-1.6-2.8-1.8-3.4-1.9-1.5-.1-2.8.9-3.6.9-.7 0-1.9-.8-3.1-.8-1.6 0-3.1.9-3.9 2.4-1.7 2.9-.4 7.2 1.2 9.6.8 1.2 1.8 2.5 3 2.4 1.2 0 1.7-.8 3.1-.8s1.9.8 3.1.8c1.3 0 2.1-1.2 2.9-2.4.9-1.3 1.3-2.6 1.3-2.7 0 0-2.6-1-2.6-3.8zM14 5.6c.6-.8 1.1-1.9 1-3-.9 0-2.1.6-2.7 1.4-.6.7-1.1 1.8-1 2.9 1 .1 2.1-.5 2.7-1.3z" />
      </svg>
      <span className="font-semibold text-white/90">Finder</span>
      <span style={{ marginLeft: u(14) }}>File</span>
      <span style={{ marginLeft: u(14) }}>Edit</span>
      <span style={{ marginLeft: u(14) }}>View</span>
      <span className="ml-auto flex items-center text-white/80" style={{ gap: u(12) }}>
        <span className="flex items-center text-accent" style={{ gap: u(4) }}>
          <Glyph style={{ width: u(11), height: u(11) }} />
          <span className="text-white/85">Navi</span>
        </span>
        <span className="rounded-[2px] border border-white/60" style={{ width: u(16), height: u(8), padding: u(1) }}>
          <span className="block h-full w-[80%] rounded-[1px] bg-white/85" />
        </span>
        <span>Mon 9:41</span>
      </span>
    </div>
  );
}

const DOCK = ["#3b82f6", "#22c55e", "#f59e0b", "#ef4444", "#a855f7", "#14b8a6", "#64748b"];

function Dock() {
  return (
    <div
      className="absolute bottom-0 left-1/2 z-10 flex -translate-x-1/2 items-center border border-white/10 bg-white/10 backdrop-blur-md"
      style={{ gap: u(6), padding: u(5), marginBottom: u(8), borderRadius: u(12) }}
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
