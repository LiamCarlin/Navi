"use client";

import { motion, useReducedMotion, type HTMLMotionProps } from "framer-motion";
import { DUR, EASE, ENTER, STAGGER } from "@/lib/motion";

/**
 * The page's one entrance: rise and unblur as it scrolls into view, once.
 * `i` staggers siblings by index.
 */
export function Reveal({
  i = 0,
  delay = 0,
  amount = 0.25,
  as = "div",
  children,
  ...rest
}: { i?: number; delay?: number; amount?: number; as?: "div" | "li" | "p" | "span" } & HTMLMotionProps<"div">) {
  const reduce = useReducedMotion();
  const M = motion[as] as typeof motion.div;
  return (
    <M
      initial={reduce ? false : { opacity: 0, y: ENTER.y, filter: `blur(${ENTER.blur}px)` }}
      whileInView={{ opacity: 1, y: 0, filter: "blur(0px)" }}
      viewport={{ once: true, amount }}
      transition={{ duration: DUR.slow, ease: EASE, delay: delay + i * STAGGER }}
      {...rest}
    >
      {children}
    </M>
  );
}

/**
 * A section headline whose lines rise out of a mask when it scrolls into view.
 * Pass lines as an array so the breaks are designed, not left to chance.
 */
export function Lines({ lines, className = "", as = "h2" }: { lines: React.ReactNode[]; className?: string; as?: "h1" | "h2" | "h3" }) {
  const reduce = useReducedMotion();
  const H = motion[as] as typeof motion.h2;
  return (
    <H className={className} initial="hidden" whileInView="shown" viewport={{ once: true, amount: 0.5 }}>
      {lines.map((l, i) => (
        <span key={i} className="block overflow-hidden pb-[0.08em] -mb-[0.08em]">
          <motion.span
            className="inline-block"
            variants={{
              hidden: reduce ? { y: 0 } : { y: "105%" },
              shown: { y: 0, transition: { duration: DUR.slow + 0.1, ease: EASE, delay: i * 0.09 } },
            }}
          >
            {l}
          </motion.span>
        </span>
      ))}
    </H>
  );
}
