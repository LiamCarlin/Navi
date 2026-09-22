/**
 * Fixed-window rate limiter, in process memory.
 *
 * PRODUCTION NOTE: on Vercel each function instance has its own memory, so this
 * only bounds abuse per instance. Swap `hit` for Vercel KV / Upstash Redis
 * (`INCR` + `EXPIRE` on `rl:${name}:${key}:${windowStart}`) before launch —
 * the call sites stay the same.
 */

interface Window { start: number; count: number }

export interface Limiter {
  hit(key: string): { ok: boolean; remaining: number; retryAfterSeconds: number };
  reset(): void;
}

export function createLimiter(name: string, limit: number, windowMs: number, clock: () => number = Date.now): Limiter {
  const windows = new Map<string, Window>();
  let lastSweep = 0;

  function sweep(now: number) {
    if (now - lastSweep < windowMs) return;
    lastSweep = now;
    for (const [k, w] of windows) if (now - w.start >= windowMs) windows.delete(k);
  }

  return {
    hit(key) {
      const now = clock();
      sweep(now);
      const id = `${name}:${key}`;
      let w = windows.get(id);
      if (!w || now - w.start >= windowMs) {
        w = { start: now, count: 0 };
        windows.set(id, w);
      }
      w.count += 1;
      const ok = w.count <= limit;
      return {
        ok,
        remaining: Math.max(0, limit - w.count),
        retryAfterSeconds: ok ? 0 : (w.start + windowMs - now) / 1000,
      };
    },
    reset() { windows.clear(); },
  };
}

/** Survives Next dev HMR module reloads by hanging off globalThis. */
function singleton<T>(key: string, make: () => T): T {
  const g = globalThis as unknown as Record<string, T>;
  if (!g[key]) g[key] = make();
  return g[key];
}

/** 120 requests / minute per signed-in user across all /v1 routes. */
export const perUserLimiter = singleton("navi.rl.user", () => createLimiter("user", 120, 60_000));
/** 30 requests / minute per IP on the auth routes (magic-link spam, code guessing). */
export const authIpLimiter = singleton("navi.rl.auth", () => createLimiter("auth-ip", 30, 60_000));
/** 10 / minute per IP on the waitlist. */
export const waitlistIpLimiter = singleton("navi.rl.waitlist", () => createLimiter("waitlist-ip", 10, 60_000));
