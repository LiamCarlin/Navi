"use client";

import { motion, useReducedMotion, useScroll, useTransform } from "framer-motion";
import { useEffect, useRef, useState } from "react";
import { Sky } from "./Sky";
import { WaitlistCount } from "./WaitlistCount";
import { WaitlistForm } from "./WaitlistForm";

const d = (ms: number) => ({ "--rise-delay": `${ms}ms` }) as React.CSSProperties;

const CHAPTERS = [
  { at: 0, end: 6, label: "Calendar, by voice" },
  { at: 6, end: 12.5, label: "“maps”" },
  { at: 12.5, end: 26, label: "A question" },
  { at: 26, end: 42.3, label: "A task in Chrome" },
];

/**
 * Sky, a serif headline, one form, and the real screen recording rising out of the mountains.
 * The recording plays while it's on screen; the chips under it jump to each part.
 */
export function Hero() {
  const reduce = useReducedMotion();
  const video = useRef<HTMLVideoElement>(null);
  const frame = useRef<HTMLDivElement>(null);
  const [time, setTime] = useState(0);
  const [failed, setFailed] = useState(false);

  const { scrollYProgress } = useScroll({ target: frame, offset: ["start end", "end start"] });
  const scale = useTransform(scrollYProgress, [0.15, 0.5], [0.94, 1]);

  useEffect(() => {
    const el = video.current;
    if (!el || reduce) return;
    const io = new IntersectionObserver(([e]) => (e.isIntersecting ? el.play().catch(() => setFailed(true)) : el.pause()), { threshold: 0.2 });
    io.observe(el);
    return () => io.disconnect();
  }, [reduce]);

  function seek(t: number) {
    const el = video.current;
    if (!el) return;
    el.currentTime = t + 0.05;
    el.play().catch(() => {});
  }

  return (
    <section className="relative px-4 pb-16 pt-32 sm:px-6 sm:pt-36 md:pb-24">
      <Sky className="h-[780px] sm:h-[860px]" />

      <div className="relative mx-auto max-w-4xl text-center text-white">
        <h1 className="h-display rise [text-shadow:0_2px_30px_rgba(20,60,140,0.25)]" style={d(0)}>
          <span className="keycap-hero">⌘</span> <span className="keycap-hero">space</span>, but
          <br />
          it <span className="italic">does</span> things.
        </h1>
        <div className="mx-auto mt-6 h-px w-40 bg-white/40 rise" style={d(120)} />
        <p className="rise mx-auto mt-6 max-w-[34rem] text-[17px] font-medium leading-relaxed text-white/95 sm:text-[19px]" style={d(160)}>
          Navi replaces Spotlight. Open apps, get answers, and hand off small jobs it finishes in the background. Type it or
          say it.
        </p>
        <div className="rise mx-auto mt-8 max-w-md" style={d(240)}>
          <WaitlistForm source="hero" pill />
          <WaitlistCount className="mt-3 !text-white/80" />
        </div>
      </div>

      <div ref={frame} className="frame-up relative mx-auto mt-14 max-w-[1150px] sm:mt-20" style={d(380)}>
        <motion.div
          className="overflow-hidden rounded-[18px] bg-[#0d0d12] shadow-[0_40px_100px_-30px_rgba(20,40,90,0.55),0_0_0_1px_rgba(255,255,255,0.5)] sm:rounded-[24px]"
          style={reduce ? undefined : { scale }}
        >
          <div className="relative" style={{ aspectRatio: "1520 / 950" }}>
            {failed ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img src="/video/demo-poster.jpg" alt="" className="absolute inset-0 h-full w-full object-cover" />
            ) : (
              <video
                ref={video}
                className="absolute inset-0 h-full w-full object-cover"
                src="/video/demo.mp4"
                poster="/video/demo-poster.jpg"
                muted
                loop
                playsInline
                preload="metadata"
                onTimeUpdate={(e) => setTime(e.currentTarget.currentTime)}
                onError={() => setFailed(true)}
                aria-label="Screen recording of Navi: the voice island opens Calendar, ⌘Space opens Maps, answers how far away the moon is, and runs a flight search in Chrome."
              />
            )}
          </div>
        </motion.div>

        <div className="mt-5 flex flex-wrap items-center justify-center gap-2">
          <span className="mr-1 text-[13px] text-fg-dim">Real recording, not a mockup ·</span>
          {CHAPTERS.map((c) => {
            const on = time >= c.at && time < c.end;
            const p = on ? (time - c.at) / (c.end - c.at) : 0;
            return (
              <button
                key={c.at}
                type="button"
                onClick={() => seek(c.at)}
                className={`relative overflow-hidden rounded-full border px-3.5 py-1.5 text-[13px] transition-colors duration-300 ${
                  on ? "border-transparent bg-fg text-white" : "border-line-strong bg-white text-fg-muted hover:text-fg"
                }`}
              >
                <span className="relative z-10">
                  <span className="tnum opacity-60">0:{String(Math.floor(c.at)).padStart(2, "0")}</span> {c.label}
                </span>
                {on && <span className="absolute inset-y-0 left-0 bg-white/15" style={{ width: `${p * 100}%`, transition: "width 250ms linear" }} />}
              </button>
            );
          })}
        </div>
      </div>
    </section>
  );
}
