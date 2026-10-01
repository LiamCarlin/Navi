"use client";

import { motion, useReducedMotion, useScroll, useTransform } from "framer-motion";
import { useRef } from "react";
import { Glyph } from "./Glyph";
import { Lines, Reveal } from "./motion/Reveal";
import { WaitlistCount } from "./WaitlistCount";
import { WaitlistForm } from "./WaitlistForm";

/** Frosted 3D keycaps floating over the closing band; each drifts at its own speed as you scroll. */
const KEYS = [
  { k: "⌘", x: "62%", y: "8%", s: 120, rot: -14, bob: "6.5s", speed: 60 },
  { k: "⏎", x: "84%", y: "34%", s: 104, rot: 12, bob: "7.5s", speed: 110 },
  { k: "✦", x: "70%", y: "58%", s: 88, rot: -6, bob: "5.5s", speed: 30 },
  { k: "space", x: "52%", y: "70%", s: 76, rot: 6, bob: "8s", speed: 80, wide: true },
];

export function Waitlist() {
  const reduce = useReducedMotion();
  const ref = useRef<HTMLElement>(null);
  const { scrollYProgress } = useScroll({ target: ref, offset: ["start end", "end end"] });

  return (
    <section id="waitlist" ref={ref} className="relative scroll-mt-16 overflow-hidden px-4 pb-16 pt-24 sm:px-6 md:pt-32" style={{ background: "linear-gradient(180deg, #ffffff 0%, #eef3fb 35%, #dfe7f5 100%)" }}>
      <div className="pointer-events-none absolute inset-0 hidden md:block" aria-hidden="true">
        {KEYS.map((key) => (
          <Floating key={key.k} {...key} progress={scrollYProgress} reduce={!!reduce} />
        ))}
      </div>

      <div className="relative mx-auto max-w-6xl">
        <div className="max-w-xl">
          <Lines className="h-section" lines={["Get Navi first."]} />
          <Reveal>
            <p className="mt-2 text-[clamp(1.6rem,1.2rem+1.6vw,2.5rem)] font-medium leading-[1.1] tracking-[-0.035em] text-[#8f9bb8]">
              Private beta for macOS 26.
            </p>
            <p className="body mt-6 max-w-md text-[16px]">
              Invites go out in order as builds are ready. Tell us what you’d hand off first and we’ll move you up.
            </p>
          </Reveal>
          <Reveal className="mt-8 max-w-md">
            <WaitlistForm source="waitlist" note takePending />
            <p className="mt-3 text-[13px] text-fg-dim">No spam. One email when it’s your turn.</p>
            <WaitlistCount className="mt-1" />
          </Reveal>
        </div>
      </div>
    </section>
  );
}

function Floating({
  k,
  x,
  y,
  s,
  rot,
  bob,
  speed,
  wide,
  progress,
  reduce,
}: (typeof KEYS)[number] & { progress: ReturnType<typeof useScroll>["scrollYProgress"]; reduce: boolean }) {
  const ty = useTransform(progress, [0, 1], [speed, 0]);
  return (
    <motion.div className="absolute" style={{ left: x, top: y, y: reduce ? 0 : ty }}>
      <div className="bob" style={{ "--rot": `${rot}deg`, "--bob": bob } as React.CSSProperties}>
        <div
          className="flex items-center justify-center text-[#8aa0c8]"
          style={{
            width: wide ? s * 2.4 : s,
            height: s,
            borderRadius: s * 0.26,
            background: "linear-gradient(160deg, rgba(255,255,255,0.85), rgba(225,233,247,0.55))",
            boxShadow:
              "inset 0 2px 1px rgba(255,255,255,0.95), inset 0 -6px 14px rgba(150,170,210,0.35), 0 0 0 1px rgba(255,255,255,0.7), 0 30px 50px -18px rgba(60,90,160,0.4)",
            backdropFilter: "blur(14px)",
            WebkitBackdropFilter: "blur(14px)",
            fontSize: wide ? s * 0.28 : s * 0.42,
            fontWeight: 500,
          }}
        >
          {k === "✦" ? <Glyph gradient className="h-[42%] w-[42%] opacity-90" /> : k}
        </div>
      </div>
    </motion.div>
  );
}
