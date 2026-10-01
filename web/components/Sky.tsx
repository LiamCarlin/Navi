"use client";

import { motion, useReducedMotion, useScroll, useTransform } from "framer-motion";
import { FAR, MID, NEAR } from "@/lib/ridge";

/**
 * The hero's sky: a blue gradient, a low sun, drifting clouds and three ranges of
 * mountains that part at different speeds as you scroll. All SVG/CSS, no images.
 * Ridges come from lib/ridge.ts (fixed seed), shared with the share image.
 */
export function Sky({ className = "" }: { className?: string }) {
  const reduce = useReducedMotion();
  const { scrollY } = useScroll();
  const farY = useTransform(scrollY, [0, 900], [0, 60]);
  const midY = useTransform(scrollY, [0, 900], [0, 120]);
  const nearY = useTransform(scrollY, [0, 900], [0, 180]);
  const sunY = useTransform(scrollY, [0, 900], [0, 140]);
  const p = (v: typeof farY) => (reduce ? undefined : { y: v });

  return (
    <div className={`pointer-events-none absolute inset-0 overflow-hidden ${className}`} aria-hidden="true">
      {/* sky */}
      <div
        className="absolute inset-0"
        style={{
          background:
            "radial-gradient(60% 50% at 50% 0%, rgba(255,255,255,0.18), transparent 70%), linear-gradient(180deg, #2c7fdc 0%, #4b9be8 26%, #8cc1f0 48%, #cfe4f8 64%, #f4f8fd 78%, #ffffff 90%)",
        }}
      />
      {/* sun */}
      <motion.div className="absolute left-[84%] top-[60%] h-0 w-0" style={p(sunY)}>
        <div className="absolute -left-[340px] -top-[340px] h-[680px] w-[680px] rounded-full" style={{ background: "radial-gradient(closest-side, rgba(255,250,235,0.85), rgba(255,240,215,0.35) 40%, transparent 70%)" }} />
        <div className="absolute -left-[48px] -top-[48px] h-[96px] w-[96px] rounded-full bg-white shadow-[0_0_60px_30px_rgba(255,255,255,0.8)]" />
        <div className="absolute -left-[260px] -top-[2px] h-[4px] w-[520px] rounded-full" style={{ background: "linear-gradient(90deg, transparent, rgba(255,255,255,0.8) 45%, rgba(255,255,255,0.8) 55%, transparent)" }} />
      </motion.div>
      {/* clouds */}
      {[
        { l: "6%", t: "14%", w: 420, h: 90, o: 0.45, d: "48s" },
        { l: "58%", t: "8%", w: 520, h: 110, o: 0.35, d: "62s" },
        { l: "30%", t: "30%", w: 360, h: 70, o: 0.3, d: "54s" },
        { l: "78%", t: "26%", w: 300, h: 60, o: 0.3, d: "44s" },
      ].map((c, i) => (
        <div key={i} className="drift absolute" style={{ left: c.l, top: c.t, "--drift": c.d } as React.CSSProperties}>
          <div className="rounded-full bg-white" style={{ width: c.w, height: c.h, opacity: c.o, filter: "blur(28px)" }} />
        </div>
      ))}
      {/* mountains */}
      <svg className="absolute inset-x-0 bottom-0 h-[62%] w-full" viewBox="0 0 1600 520" preserveAspectRatio="xMidYMax slice">
        <defs>
          <linearGradient id="far" x1="0" y1="200" x2="0" y2="520" gradientUnits="userSpaceOnUse">
            <stop offset="0" stopColor="#dbe9fa" />
            <stop offset="1" stopColor="#b9d3f2" />
          </linearGradient>
          <linearGradient id="mid" x1="0" y1="120" x2="0" y2="520" gradientUnits="userSpaceOnUse">
            <stop offset="0" stopColor="#f4f8ff" />
            <stop offset="0.12" stopColor="#bcd6f6" />
            <stop offset="0.3" stopColor="#5d8fd8" />
            <stop offset="0.62" stopColor="#3f6fc0" />
            <stop offset="1" stopColor="#9bbfe9" />
          </linearGradient>
          <linearGradient id="near" x1="0" y1="380" x2="0" y2="520" gradientUnits="userSpaceOnUse">
            <stop offset="0" stopColor="#ffffff" stopOpacity="0.9" />
            <stop offset="1" stopColor="#ffffff" />
          </linearGradient>
          <linearGradient id="mist" x1="0" y1="300" x2="0" y2="520" gradientUnits="userSpaceOnUse">
            <stop offset="0" stopColor="#ffffff" stopOpacity="0" />
            <stop offset="0.6" stopColor="#ffffff" stopOpacity="0.7" />
            <stop offset="1" stopColor="#ffffff" />
          </linearGradient>
        </defs>
        <motion.path d={FAR} fill="url(#far)" style={p(farY)} />
        <motion.path d={MID} fill="url(#mid)" style={p(midY)} />
        <rect x="0" y="300" width="1600" height="220" fill="url(#mist)" />
        <motion.path d={NEAR} fill="url(#near)" style={p(nearY)} />
      </svg>
    </div>
  );
}
