/**
 * Fixed-window rate limiter.
 *
 *   - Supabase configured → Postgres: one row per (bucket, window) in `public.rate_limits`,
 *     incremented by the atomic `rate_limit_hit` RPC (supabase/migrations/0003_account.sql).
 *     Every Vercel instance shares the count, so the limit is global.
 *   - Otherwise (dev, tests) → process memory.
 *
 * Windows are aligned to the epoch (a 60 s window runs :00–:59), so every instance agrees on
 * which window a hit belongs to. The limiter fails OPEN: if the RPC errors, the hit is counted
 * in memory instead and the request goes through — a database hiccup must never take the API
 * down. Call sites: `const rl = await limiter.hit(key); if (!rl.ok) throw rateLimited(rl.retryAfterSeconds)`.
 */

export interface RateResult {
  ok: boolean;
  remaining: number;
  retryAfterSeconds: number;
}

export interface Limiter {
  readonly name: string;
  readonly limit: number;
  readonly windowMs: number;
  hit(key: string): Promise<RateResult>;
  /** Test hook: forget every in-memory window (the Postgres rows are left to the purge job). */
  reset(): void;
}

/** Start of the epoch-aligned window that contains `now`. */
export function windowStart(now: number, windowMs: number): number {
  return Math.floor(now / windowMs) * windowMs;
}

function result(count: number, limit: number, windowEndMs: number, now: number): RateResult {
  const ok = count <= limit;
  return {
    ok,
    remaining: Math.max(0, limit - count),
    retryAfterSeconds: ok ? 0 : Math.max(1, Math.ceil((windowEndMs - now) / 1000)),
  };
}

// MARK: - Memory

export interface MemoryLimiter extends Limiter {
  /** Synchronous core, shared with the Postgres limiter's fallback. */
  hitSync(key: string): RateResult;
}

export function createMemoryLimiter(name: string, limit: number, windowMs: number, clock: () => number = Date.now): MemoryLimiter {
  const windows = new Map<string, { start: number; count: number }>();
  let lastSweep = 0;

  function sweep(now: number) {
    if (now - lastSweep < windowMs) return;
    lastSweep = now;
    const current = windowStart(now, windowMs);
    for (const [k, w] of windows) if (w.start < current) windows.delete(k);
  }

  function hitSync(key: string): RateResult {
    const now = clock();
    sweep(now);
    const start = windowStart(now, windowMs);
    const id = `${name}:${key}`;
    let w = windows.get(id);
    if (!w || w.start !== start) {
      w = { start, count: 0 };
      windows.set(id, w);
    }
    w.count += 1;
    return result(w.count, limit, start + windowMs, now);
  }

  return {
    name,
    limit,
    windowMs,
    hitSync,
    async hit(key) { return hitSync(key); },
    reset() { windows.clear(); },
  };
}

// MARK: - Postgres

/** `rate_limit_hit(p_bucket, p_window_start, p_window_seconds)` → the bucket's count in that window. */
export type RateLimitRpc = (bucket: string, windowStartIso: string, windowSeconds: number) => Promise<number>;

export function createPostgresLimiter(
  name: string,
  limit: number,
  windowMs: number,
  rpc: RateLimitRpc,
  clock: () => number = Date.now,
): Limiter {
  const fallback = createMemoryLimiter(name, limit, windowMs, clock);
  let warned: number | null = null;
  return {
    name,
    limit,
    windowMs,
    async hit(key) {
      const now = clock();
      const start = windowStart(now, windowMs);
      try {
        const count = await rpc(`${name}:${key}`, new Date(start).toISOString(), Math.round(windowMs / 1000));
        return result(count, limit, start + windowMs, now);
      } catch (e) {
        // Fail open onto the per-instance window; log at most once a minute.
        if (warned === null || now - warned > 60_000) {
          warned = now;
          console.warn(`[navi-cloud] rate limiter "${name}" fell back to memory:`, (e as Error).message);
        }
        return fallback.hitSync(key);
      }
    },
    reset() { fallback.reset(); },
  };
}

/** The RPC over the service-role client. Imported lazily so memory-mode never loads supabase-js. */
async function supabaseRpc(): Promise<RateLimitRpc> {
  const { serviceClient } = await import("./db-supabase");
  const sb = serviceClient();
  return async (bucket, windowStartIso, windowSeconds) => {
    const { data, error } = await sb.rpc("rate_limit_hit", {
      p_bucket: bucket,
      p_window_start: windowStartIso,
      p_window_seconds: windowSeconds,
    });
    if (error) throw new Error(error.message);
    const n = typeof data === "number" ? data : Number(data);
    if (!Number.isFinite(n)) throw new Error(`rate_limit_hit returned ${JSON.stringify(data)}`);
    return n;
  };
}

/**
 * A limiter that picks its backend on first use from the environment: Postgres when the
 * Supabase driver is active, memory otherwise.
 */
export function createLimiter(name: string, limit: number, windowMs: number): Limiter {
  let impl: Limiter | undefined;
  let pending: Promise<Limiter> | undefined;
  async function resolve(): Promise<Limiter> {
    if (impl) return impl;
    pending ??= (async () => {
      const { env } = await import("./env");
      if (env.dbDriver === "supabase" && env.supabaseUrl && env.supabaseServiceKey) {
        const rpc = await supabaseRpc();
        impl = createPostgresLimiter(name, limit, windowMs, rpc);
      } else {
        impl = createMemoryLimiter(name, limit, windowMs);
      }
      return impl;
    })();
    return pending;
  }
  return {
    name,
    limit,
    windowMs,
    async hit(key) { return (await resolve()).hit(key); },
    reset() { impl?.reset(); },
  };
}

/** Survives Next dev HMR module reloads by hanging off globalThis. */
function singleton<T>(key: string, make: () => T): T {
  const g = globalThis as unknown as Record<string, T>;
  if (!g[key]) g[key] = make();
  return g[key];
}

/** 120 requests / minute per signed-in user across all /v1 routes. */
export const perUserLimiter = singleton("navi.rl.user.v2", () => createLimiter("user", 120, 60_000));
/** 30 requests / minute per IP on the auth routes (magic-link spam, code guessing). */
export const authIpLimiter = singleton("navi.rl.auth.v2", () => createLimiter("auth-ip", 30, 60_000));
/** 10 / minute per IP on the waitlist. */
export const waitlistIpLimiter = singleton("navi.rl.waitlist.v2", () => createLimiter("waitlist-ip", 10, 60_000));

// MARK: account — per-email limits on the sign-in page
/** 5 sign-in emails per address per 15 minutes (on top of Supabase's own SMTP limits). */
export const otpSendEmailLimiter = singleton("navi.rl.otp-send", () => createLimiter("otp-send", 5, 15 * 60_000));
/** 10 code attempts per address per 15 minutes — a 6-digit code cannot be walked. */
export const otpVerifyEmailLimiter = singleton("navi.rl.otp-verify", () => createLimiter("otp-verify", 10, 15 * 60_000));
