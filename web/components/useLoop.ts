"use client";

import { useInView, useReducedMotion } from "framer-motion";
import { useCallback, useEffect, useRef, useState, type RefObject } from "react";

/**
 * Drives a looping demo as a pure function of elapsed time.
 * - `derive(t)` returns the frame for `t` ms into the loop; `key(frame)` must change whenever the
 *   rendered output would, so React only re-renders on real changes (not 60× a second).
 * - Starts when the element scrolls into view, pauses off-screen and resumes where it left off.
 *   Timelines end with a long rest so a section plays once, then loops slowly.
 * - With reduced motion it renders `derive(staticT)` once and never ticks.
 * - `seek(t)` jumps the clock (used by the chips in "Navi does").
 */
export function useLoop<F>(
  ref: RefObject<Element | null>,
  { duration, derive, key, staticT }: { duration: number; derive: (t: number) => F; key: (f: F) => string; staticT: number },
): { frame: F; seek: (t: number) => void } {
  const reduce = useReducedMotion();
  const inView = useInView(ref, { amount: 0.3 });
  const [frame, setFrame] = useState<F>(() => derive(reduce ? staticT : 0));
  const elapsed = useRef(0);
  const start = useRef(0);

  useEffect(() => {
    if (reduce) {
      setFrame(derive(staticT));
      return;
    }
    if (!inView) return;
    let raf = 0;
    let lastKey = "";
    start.current = performance.now() - elapsed.current;
    const tick = (now: number) => {
      const t = (now - start.current) % duration;
      elapsed.current = t;
      const f = derive(t);
      const k = key(f);
      if (k !== lastKey) {
        lastKey = k;
        setFrame(f);
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
    // derive/key are module-level constants at every call site.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [inView, reduce, duration, staticT]);

  const seek = useCallback(
    (t: number) => {
      elapsed.current = t;
      start.current = performance.now() - t;
      setFrame(derive(t));
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [],
  );

  return { frame, seek };
}
