"use client";

import { motion, useReducedMotion, useScroll, useTransform } from "framer-motion";
import { useEffect, useRef, useState } from "react";
import { MacBook } from "./MacBook";
import { Lines, Reveal } from "./motion/Reveal";

const CHAPTERS = [
  { at: 0, end: 6, said: "Calendar, by voice", how: "Spoken, not typed. The island drops out of the notch, listens, and opens Calendar." },
  { at: 6, end: 12.5, said: "maps", how: "Typed. Four letters and Maps is already the first row, from an index on the Mac, so ⏎ opens it without waiting on anything." },
  { at: 12.5, end: 26, said: "how far away is the moon", how: "A question, so the answer streams into the bar. No browser tab, no chat window." },
  { at: 26, end: 42.3, said: "open chrome and search for flights to tokyo", how: "A task. Navi opens Chrome, goes to the flights page and fills it in step by step." },
];

/**
 * The one piece of footage on the page: a screen recording of the app on a MacBook Pro,
 * inside the CSS laptop. The laptop tilts flat and grows as it scrolls in; the chapter
 * list seeks the video and shows where it is.
 */
export function Film() {
  const reduce = useReducedMotion();
  const section = useRef<HTMLElement>(null);
  const video = useRef<HTMLVideoElement>(null);
  const [time, setTime] = useState(0);
  const [failed, setFailed] = useState(false);

  const { scrollYProgress } = useScroll({ target: section, offset: ["start end", "center center"] });
  const scale = useTransform(scrollYProgress, [0, 1], [0.84, 1]);
  const rotateX = useTransform(scrollYProgress, [0, 1], [22, 0]);
  const y = useTransform(scrollYProgress, [0, 1], [80, 0]);

  useEffect(() => {
    const el = video.current;
    if (!el || reduce) return;
    const io = new IntersectionObserver(([e]) => (e.isIntersecting ? el.play().catch(() => setFailed(true)) : el.pause()), { threshold: 0.25 });
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
    <section id="film" ref={section} className="scroll-mt-16 px-4 pb-24 pt-20 sm:px-6 md:pb-36 md:pt-28">
      <div className="mx-auto max-w-7xl">
        <div className="grid grid-cols-1 gap-6 lg:grid-cols-12 lg:gap-8">
          <Lines className="h-section lg:col-span-7" lines={["Forty-two seconds", <>of the <span className="ital">real</span> app.</>]} />
          <Reveal className="lg:col-span-5 lg:pt-3">
            <p className="lede">
              Everything else on this page is drawn to explain how Navi works. This part is a plain screen recording from a MacBook
              Pro: one spoken command, then three typed ones.
            </p>
          </Reveal>
        </div>

        <div className="mt-14 grid grid-cols-1 items-start gap-10 lg:mt-20 lg:grid-cols-12 lg:gap-8">
          <motion.div className="lg:col-span-8" style={reduce ? undefined : { scale, rotateX, y, transformPerspective: 1600, transformOrigin: "50% 0%" }}>
            <MacBook>
              {failed ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img src="/video/demo-poster.jpg" alt="" className="absolute inset-0 z-20 h-full w-full object-cover" />
              ) : (
                <video
                  ref={video}
                  className="absolute inset-0 z-20 h-full w-full object-cover"
                  src="/video/demo.mp4"
                  poster="/video/demo-poster.jpg"
                  muted
                  loop
                  playsInline
                  preload="metadata"
                  onTimeUpdate={(e) => setTime(e.currentTarget.currentTime)}
                  onError={() => setFailed(true)}
                  aria-label="Screen recording: the voice island opens Calendar, ⌘Space opens Maps, answers how far away the moon is, and runs a flight search in Chrome."
                />
              )}
            </MacBook>
          </motion.div>

          <ol className="divide-y divide-line border-y border-line lg:col-span-4">
            {CHAPTERS.map((c, i) => {
              const on = time >= c.at && time < c.end;
              const p = on ? (time - c.at) / (c.end - c.at) : time >= c.end ? 1 : 0;
              return (
                <Reveal as="li" key={c.at} i={i}>
                  <button type="button" onClick={() => seek(c.at)} className="group relative block w-full py-5 text-left">
                    <div className="flex items-baseline gap-3">
                      <span className="label tnum w-9 shrink-0">0:{String(Math.floor(c.at)).padStart(2, "0")}</span>
                      <span className={`font-medium transition-colors duration-300 ${on ? "text-fg" : "text-fg-muted group-hover:text-fg"}`}>{c.said}</span>
                    </div>
                    <p className={`body mt-1.5 pl-12 transition-opacity duration-300 ${on ? "opacity-100" : "opacity-70"}`}>{c.how}</p>
                    <span className="absolute inset-x-0 -bottom-px h-px origin-left" style={{ background: "var(--fg)", transform: `scaleX(${on ? p : 0})`, transition: "transform 250ms linear" }} />
                  </button>
                </Reveal>
              );
            })}
          </ol>
        </div>
      </div>
    </section>
  );
}
