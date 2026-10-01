"use client";

import Lenis from "lenis";
import { useEffect } from "react";

declare global {
  interface Window {
    __lenis?: Lenis;
  }
}

/**
 * Inertial scrolling for the whole page (wheel and trackpad; touch stays native).
 * Off under reduced motion. Anchor links glide to their section, offset for the nav.
 */
export function SmoothScroll() {
  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      document.documentElement.style.scrollBehavior = "smooth";
      return;
    }
    const lenis = new Lenis({
      duration: 1.1,
      easing: (t) => 1 - Math.pow(1 - t, 4),
      smoothWheel: true,
      autoRaf: true,
      anchors: { offset: -64 },
    });
    window.__lenis = lenis;
    return () => {
      lenis.destroy();
      delete window.__lenis;
    };
  }, []);
  return null;
}
