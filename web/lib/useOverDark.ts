"use client";

import { useEffect, useState } from "react";

/**
 * True while a dark stage (`.stage-dark`) sits under a horizontal band of the viewport,
 * so fixed chrome over it (nav, sticky bar) can switch to the dark palette.
 * `band` is the rootMargin selecting that band, e.g. the top 64 px or the bottom 72 px.
 */
export function useOverDark(band: string) {
  const [dark, setDark] = useState(false);
  useEffect(() => {
    const els = document.querySelectorAll(".stage-dark");
    if (!els.length) return;
    const on = new Set<Element>();
    const io = new IntersectionObserver(
      (es) => {
        es.forEach((e) => (e.isIntersecting ? on.add(e.target) : on.delete(e.target)));
        setDark(on.size > 0);
      },
      { rootMargin: band },
    );
    els.forEach((el) => io.observe(el));
    return () => io.disconnect();
  }, [band]);
  return dark;
}
