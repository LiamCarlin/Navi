"use client";

import { motion, useScroll, useSpring } from "framer-motion";

/** A hairline in Navi's gradient along the top edge that fills as you read. */
export function ScrollProgress() {
  const { scrollYProgress } = useScroll();
  const x = useSpring(scrollYProgress, { stiffness: 200, damping: 40, restDelta: 0.001 });
  return (
    <motion.div
      aria-hidden="true"
      className="pointer-events-none fixed inset-x-0 top-0 z-50 h-[2px] origin-left"
      style={{ scaleX: x, background: "var(--grad)" }}
    />
  );
}
