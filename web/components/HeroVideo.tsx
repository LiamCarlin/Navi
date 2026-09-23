"use client";

import { useEffect, useRef, useState } from "react";
import { HeroLoop } from "./HeroLoop";

/**
 * The real thing: a screen recording of Navi on a MacBook Pro, cropped to the
 * 16:10 screen so it sits inside the CSS frame (the frame's own notch overlays
 * the recording's). Muted, looping, plays only while on screen. Falls back to
 * the CSS loop when the video can't play, and shows the poster under
 * prefers-reduced-motion.
 */
export function HeroVideo() {
  const ref = useRef<HTMLVideoElement>(null);
  const [failed, setFailed] = useState(false);
  const [reduced, setReduced] = useState(false);

  useEffect(() => {
    const mq = window.matchMedia("(prefers-reduced-motion: reduce)");
    setReduced(mq.matches);
    const onChange = () => setReduced(mq.matches);
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, []);

  useEffect(() => {
    const el = ref.current;
    if (!el || reduced) return;
    const io = new IntersectionObserver(
      ([e]) => {
        if (e.isIntersecting) el.play().catch(() => setFailed(true));
        else el.pause();
      },
      { threshold: 0.2 },
    );
    io.observe(el);
    return () => io.disconnect();
  }, [reduced]);

  if (failed) return <HeroLoop />;

  return (
    <div className="absolute inset-0 z-20">
      <video
        ref={ref}
        className="h-full w-full object-cover"
        src="/video/demo.mp4"
        poster="/video/demo-poster.jpg"
        muted
        loop
        playsInline
        autoPlay={!reduced}
        preload="metadata"
        onError={() => setFailed(true)}
        aria-label="Navi on a Mac: the voice island opens Calendar, ⌘Space opens Maps, answers a question, and books a flight search in Chrome."
      />
    </div>
  );
}
