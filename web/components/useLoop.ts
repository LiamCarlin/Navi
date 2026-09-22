"use client";

import { useInView, useReducedMotion } from "framer-motion";
import { useEffect, useRef, useState, type RefObject } from "react";

/**
 * Drives a looping demo as a pure function of elapsed time.
 * - `derive(t)` returns the frame for `t` ms into the loop; `key(frame)` must change whenever the
 *   rendered output would, so React only re-renders on real changes (not 60× a second).
 * - Pauses while the element is off-screen and resumes where it left off.
 * - With reduced motion it renders `derive(staticT)` once and never ticks.
 */
export function useLoop<F>(
  ref: RefObject<Element | null>,
  { duration, derive, key, staticT }: { duration: number; derive: (t: number) => F; key: (f: F) => string; staticT: number },
): F {
  const reduce = useReducedMotion();
  const inView = useInView(ref, { amount: 0.3 });
  const [frame, setFrame] = useState<F>(() => derive(reduce ? staticT : 0));
  const elapsed = useRef(0);

  useEffect(() => {
    if (reduce) {
      setFrame(derive(staticT));
      return;
    }
    if (!inView) return;
    let raf = 0;
    let lastKey = "";
    const start = performance.now() - elapsed.current;
    const tick = (now: number) => {
      const t = (now - start) % duration;
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

  return frame;
}
