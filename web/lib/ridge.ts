/**
 * Mountain ridges for the hero sky and the share image: midpoint displacement across
 * 1600 units plus named peaks as sharp bumps, from a fixed seed so every render matches.
 */
export function rng(seed: number) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function ridge(seed: number, base: number, amp: number, rough: number, peaks: [number, number, number][]) {
  const r = rng(seed);
  const n = 128;
  const ys = new Array(n + 1).fill(0);
  let step = n;
  let a = amp;
  while (step > 1) {
    const half = step / 2;
    for (let i = half; i < n; i += step) ys[i] = (ys[i - half] + ys[i + half]) / 2 + (r() - 0.5) * a;
    a *= rough;
    step = half;
  }
  const pts: string[] = [];
  for (let i = 0; i <= n; i++) {
    const x = (i / n) * 1600;
    let y = base + ys[i];
    for (const [px, h, w] of peaks) y -= h * Math.exp(-Math.abs(x - px) / w);
    pts.push(`${x.toFixed(1)},${y.toFixed(1)}`);
  }
  return `M0,520 L${pts.join(" L")} L1600,520 Z`;
}

export const FAR = ridge(7, 330, 60, 0.55, [[1180, 70, 120], [240, 40, 140]]);
export const MID = ridge(21, 380, 90, 0.58, [[420, 230, 70], [560, 120, 60], [980, 90, 90], [1380, 110, 80]]);
export const NEAR = ridge(5, 455, 40, 0.5, [[120, 40, 120], [1500, 50, 120]]);
