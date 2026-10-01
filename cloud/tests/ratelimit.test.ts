import { describe, expect, it, vi } from "vitest";
import { createMemoryLimiter, createPostgresLimiter, windowStart, type RateLimitRpc } from "@/lib/ratelimit";

describe("memory limiter", () => {
  it("allows `limit` hits per epoch-aligned window, then 429s with the time left", async () => {
    let now = 60_000 * 1000 + 15_000; // 15 s into a minute window
    const rl = createMemoryLimiter("t", 3, 60_000, () => now);
    expect((await rl.hit("a")).ok).toBe(true);
    expect((await rl.hit("a")).ok).toBe(true);
    const third = await rl.hit("a");
    expect(third).toEqual({ ok: true, remaining: 0, retryAfterSeconds: 0 });
    const fourth = await rl.hit("a");
    expect(fourth.ok).toBe(false);
    expect(fourth.retryAfterSeconds).toBe(45);
    // Other keys are independent.
    expect((await rl.hit("b")).ok).toBe(true);
    // The next window starts fresh.
    now += 45_000;
    expect((await rl.hit("a")).ok).toBe(true);
  });

  it("reset() forgets everything", async () => {
    const rl = createMemoryLimiter("t", 1, 60_000, () => 0);
    await rl.hit("a");
    expect((await rl.hit("a")).ok).toBe(false);
    rl.reset();
    expect((await rl.hit("a")).ok).toBe(true);
  });
});

describe("postgres limiter", () => {
  it("passes the bucket, aligned window start and window length to the RPC and trusts its count", async () => {
    const now = Date.UTC(2026, 9, 1, 12, 0, 40);
    const counts = new Map<string, number>();
    const rpc = vi.fn<RateLimitRpc>(async (bucket, start) => {
      const k = `${bucket}@${start}`;
      counts.set(k, (counts.get(k) ?? 0) + 1);
      return counts.get(k)!;
    });
    const rl = createPostgresLimiter("user", 2, 60_000, rpc, () => now);
    expect((await rl.hit("u1")).ok).toBe(true);
    expect((await rl.hit("u1")).ok).toBe(true);
    const over = await rl.hit("u1");
    expect(over).toEqual({ ok: false, remaining: 0, retryAfterSeconds: 20 });
    expect(rpc).toHaveBeenCalledWith("user:u1", new Date(windowStart(now, 60_000)).toISOString(), 60);
    expect(new Date(windowStart(now, 60_000)).toISOString()).toBe("2026-10-01T12:00:00.000Z");
  });

  it("shares the count across instances (two limiters, one table)", async () => {
    const table = new Map<string, number>();
    const rpc: RateLimitRpc = async (bucket, start) => {
      const k = `${bucket}@${start}`;
      table.set(k, (table.get(k) ?? 0) + 1);
      return table.get(k)!;
    };
    const a = createPostgresLimiter("ip", 3, 60_000, rpc, () => 5_000);
    const b = createPostgresLimiter("ip", 3, 60_000, rpc, () => 6_000);
    await a.hit("x");
    await b.hit("x");
    await a.hit("x");
    expect((await b.hit("x")).ok).toBe(false);
  });

  it("fails open onto memory when the database errors", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const rpc: RateLimitRpc = async () => { throw new Error("connection reset"); };
    const rl = createPostgresLimiter("user", 2, 60_000, rpc, () => 1_000);
    expect((await rl.hit("u")).ok).toBe(true);
    expect((await rl.hit("u")).ok).toBe(true);
    expect((await rl.hit("u")).ok).toBe(false); // still bounded per instance
    expect(warn).toHaveBeenCalledTimes(1); // logged once, not per request
    warn.mockRestore();
  });
});
