/**
 * The site's motion identity. Every animation on the page uses these, so the
 * whole thing moves like one object: one curve, three durations, one entrance.
 */
export const EASE = [0.22, 1, 0.36, 1] as const; // decelerate, no overshoot
export const EASE_IN_OUT = [0.65, 0, 0.35, 1] as const; // on-screen moves
export const DUR = { quick: 0.2, base: 0.5, slow: 0.9 } as const;
/** The one entrance: rise 24 px out of a slight blur. */
export const ENTER = { y: 24, blur: 6 } as const;
/** Stagger between siblings; totals stay under ~0.4 s. */
export const STAGGER = 0.06;

export const clamp01 = (v: number) => Math.min(1, Math.max(0, v));
/** Map `v` from [a, b] to [0, 1], clamped. */
export const progress = (v: number, a: number, b: number) => clamp01((v - a) / (b - a));
