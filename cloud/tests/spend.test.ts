import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  buildLedger,
  clearMoneyCache,
  estimateSupabase,
  fetchSupabase,
  fetchVercel,
  loadMoney,
  monthlyAmountUsd,
  parseJsonl,
  summarizeStripe,
  summarizeVercel,
  supabaseRef,
  windowStart,
  type Money,
} from "@/lib/admin/spend";
import { invalidateKeyCache } from "@/lib/keys";
import { useMemoryEnv } from "./helpers";

const NOW = new Date("2026-10-15T12:00:00Z");
const PRICES = { pro_month: "price_pm", pro_year: "price_py", pro_recall_month: "price_rm", pro_recall_year: "price_ry" };
const ts = (iso: string) => Math.floor(new Date(iso).getTime() / 1000);
const saved = { ...process.env };

beforeEach(() => {
  useMemoryEnv({ VERCEL_API_TOKEN: undefined, SUPABASE_ACCESS_TOKEN: undefined, VERCEL_TEAM_ID: undefined, VERCEL_PROJECT_ID: undefined });
  invalidateKeyCache();
  clearMoneyCache();
});
afterEach(() => {
  process.env = { ...saved };
  vi.restoreAllMocks();
});

function sub(status: string, price: string, cents: number, interval = "month", quantity = 1) {
  return { status, items: { data: [{ quantity, price: { id: price, unit_amount: cents, currency: "usd", recurring: { interval, interval_count: 1 } } }] } };
}

function jsonRes(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

describe("window", () => {
  it("reaches back to the 1st on the 31st, else 30 days", () => {
    expect(windowStart(NOW).toISOString().slice(0, 10)).toBe("2026-09-16");
    expect(windowStart(new Date("2026-10-31T08:00:00Z")).toISOString().slice(0, 10)).toBe("2026-10-01");
  });
});

describe("Stripe", () => {
  it("normalizes prices to a month", () => {
    expect(monthlyAmountUsd(2000, 1, "month", 1)).toBe(20);
    expect(monthlyAmountUsd(24000, 1, "year", 1)).toBe(20);
    expect(monthlyAmountUsd(2000, 2, "month", 3)).toBeCloseTo(13.33, 2);
    expect(monthlyAmountUsd(100, 1, "week", 1)).toBeCloseTo(4.33, 2);
  });

  it("sums collected revenue, refunds and fees per day; MRR from active + past_due only", () => {
    const m = summarizeStripe({
      txns: [
        { type: "charge", amount: 2000, fee: 88, currency: "usd", created: ts("2026-10-15T09:00:00Z") },
        { type: "payment", amount: 3000, fee: 117, currency: "usd", created: ts("2026-10-01T09:00:00Z") },
        { type: "refund", amount: -2000, fee: 0, currency: "usd", created: ts("2026-10-15T10:00:00Z") },
        { type: "payout", amount: -5000, fee: 0, currency: "usd", created: ts("2026-10-02T00:00:00Z") },
        { type: "charge", amount: 1500, fee: 50, currency: "eur", created: ts("2026-10-03T00:00:00Z") },
      ],
      subs: [
        sub("active", "price_pm", 2000),
        sub("active", "price_ry", 36000, "year"),
        sub("past_due", "price_rm", 3000),
        sub("trialing", "price_pm", 2000),
        sub("canceled", "price_pm", 2000),
      ],
      prices: PRICES,
      testMode: true,
      now: NOW,
    });
    expect(m.byDay["2026-10-15"]).toBe(0);
    expect(m.byDay["2026-10-01"]).toBe(30);
    expect(m.feesByDay["2026-10-15"]).toBeCloseTo(0.88);
    expect(m.refunds30dUsd).toBe(20);
    expect(m.otherCurrencies).toEqual(["EUR"]);
    expect(m.mrrUsd).toBe(20 + 30 + 30);
    expect(m.subscriptions).toEqual({ active: 2, pastDue: 1, trialing: 1, byPlan: { pro: 1, pro_recall: 2, other: 0 } });
  });
});

describe("Vercel", () => {
  it("parses JSONL (skipping a cut-off line) and sums billed cost by day and service", () => {
    const text = [
      JSON.stringify({ BilledCost: "1.50", ChargePeriodStart: "2026-10-14T00:00:00Z", ServiceName: "Function Duration" }),
      JSON.stringify({ BilledCost: 20, ChargePeriodStart: "2026-10-01T00:00:00Z", ServiceName: "Pro Plan" }),
      JSON.stringify({ BilledCost: 0.25, ChargePeriodStart: "2026-10-14T00:00:00Z", ServiceName: "Function Duration" }),
      JSON.stringify({ BilledCost: 0, ChargePeriodStart: "2026-10-14T00:00:00Z", ServiceName: "Edge Requests" }),
      '{"BilledCost": 3, "ChargePer',
    ].join("\n");
    const rows = parseJsonl<{ BilledCost: number | string; ChargePeriodStart: string; ServiceName?: string }>(text);
    expect(rows).toHaveLength(4);
    const v = summarizeVercel(rows, NOW, { team: "acme", plan: "pro" });
    expect(v.byDay).toEqual({ "2026-10-14": 1.75, "2026-10-01": 20 });
    expect(v.services).toEqual([{ name: "Pro Plan", usd: 20 }, { name: "Function Duration", usd: 1.75 }]);
  });

  it("is not configured without a token", async () => {
    expect((await fetchVercel(NOW, vi.fn())).status).toBe("not_configured");
  });

  it("finds the team, and reads a Hobby team's costs_not_found as no charges", async () => {
    process.env.VERCEL_API_TOKEN = "vercel-token-123456";
    const urls: string[] = [];
    const fetchImpl = vi.fn(async (url: string) => {
      urls.push(url);
      if (url.includes("/v2/teams?")) return jsonRes({ teams: [{ id: "team_1", slug: "acme" }] });
      if (url.includes("/v2/teams/team_1")) return jsonRes({ id: "team_1", slug: "acme", billing: { plan: "hobby" } });
      if (url.includes("/v1/billing/charges")) return jsonRes({ error: { code: "costs_not_found", message: "Costs not found" } }, 404);
      return jsonRes({}, 500);
    });
    const r = await fetchVercel(NOW, fetchImpl);
    expect(r).toMatchObject({ status: "ok", data: { team: "acme", plan: "hobby", byDay: {}, services: [] } });
    const charges = new URL(urls.find((u) => u.includes("/v1/billing/charges"))!);
    expect(charges.searchParams.get("teamId")).toBe("team_1");
    expect(charges.searchParams.get("from")).toBe("2026-09-16T00:00:00.000Z");
    expect(charges.searchParams.get("to")).toBe("2026-10-16T00:00:00.000Z");
  });

  it("reports an error without leaking the token", async () => {
    process.env.VERCEL_API_TOKEN = "vercel-token-123456";
    process.env.VERCEL_TEAM_ID = "team_1";
    const fetchImpl = vi.fn(async (url: string) =>
      url.includes("/v1/billing/charges") ? new Response("bad token vercel-token-123456", { status: 403 }) : jsonRes({ id: "team_1" }),
    );
    const r = await fetchVercel(NOW, fetchImpl);
    expect(r.status).toBe("error");
    expect(JSON.stringify(r)).not.toContain("vercel-token-123456");
    expect(JSON.stringify(r)).toContain("HTTP 403");
  });
});

describe("Supabase", () => {
  it("takes the ref from SUPABASE_URL", () => {
    expect(supabaseRef("https://oqvuejmxkkfaogelwraz.supabase.co")).toBe("oqvuejmxkkfaogelwraz");
    expect(supabaseRef("http://localhost:54321")).toBeNull();
  });

  it("free plan costs nothing", () => {
    const e = estimateSupabase({ org: "Navi", plan: "free", projects: [{ ref: "a", name: "navi", status: "ACTIVE_HEALTHY", computeSize: "nano", addons: [] }] });
    expect(e.monthlyUsd).toBe(0);
  });

  it("pro = plan + compute per running project + priced add-ons − the compute credit", () => {
    const e = estimateSupabase({
      org: "Navi",
      plan: "pro",
      projects: [
        {
          ref: "a", name: "navi", status: "ACTIVE_HEALTHY", computeSize: "micro",
          addons: [
            { type: "compute_instance", variant: { id: "ci_micro", name: "Micro", price: { type: "usage", interval: "hourly", amount: 0.01344 } } },
            { type: "ipv4", variant: { id: "ipv4_default", name: "Dedicated IPv4", price: { type: "fixed", interval: "monthly", amount: 4 } } },
          ],
        },
        { ref: "b", name: "old", status: "INACTIVE", computeSize: "small", addons: [] },
        { ref: "c", name: "staging", status: "ACTIVE_HEALTHY", computeSize: "small", addons: [] },
      ],
    });
    // 25 plan + 10 micro (usage-typed addon price falls back to the size table) + 15 small + 4 IPv4 − 10 credit
    expect(e.monthlyUsd).toBe(44);
    expect(e.activeProjects).toBe(2);
    expect(e.lines.map((l) => l.label)).toContain("Compute credit");
  });

  it("can't price a contract plan", () => {
    expect(estimateSupabase({ org: "Navi", plan: "enterprise", projects: [] }).monthlyUsd).toBeNull();
  });

  it("walks project → org → projects → add-ons", async () => {
    process.env.SUPABASE_URL = "https://oqvuejmxkkfaogelwraz.supabase.co";
    process.env.DB_DRIVER = "memory";
    process.env.SUPABASE_ACCESS_TOKEN = "sbp_test_token_123";
    const fetchImpl = vi.fn(async (url: string) => {
      if (url.endsWith("/v1/projects/oqvuejmxkkfaogelwraz")) return jsonRes({ organization_slug: "org1" });
      if (url.endsWith("/v1/organizations/org1")) return jsonRes({ name: "Navi", plan: "pro" });
      if (url.includes("/v1/organizations/org1/projects")) {
        return jsonRes({ projects: [{ ref: "oqvuejmxkkfaogelwraz", name: "navi", status: "ACTIVE_HEALTHY", databases: [{ type: "PRIMARY", infra_compute_size: "micro" }] }] });
      }
      if (url.includes("/billing/addons")) return jsonRes({ selected_addons: [] });
      return jsonRes({}, 404);
    });
    const r = await fetchSupabase(NOW, fetchImpl);
    expect(r).toMatchObject({ status: "ok", data: { org: "Navi", slug: "org1", plan: "pro", monthlyUsd: 25 } });
  });
});

describe("ledger", () => {
  const days = Array.from({ length: 30 }, (_, i) => {
    const d = new Date(NOW.getTime() - (29 - i) * 86_400_000).toISOString().slice(0, 10);
    return { day: d, costUsd: 1 };
  });

  it("adds every priced source and takes Stripe fees off the profit", () => {
    const money: Money = {
      stripe: {
        status: "ok",
        fetchedAt: NOW.toISOString(),
        data: {
          testMode: false, byDay: { "2026-10-15": 40, "2026-10-01": 60 }, feesByDay: { "2026-10-15": 2, "2026-10-01": 3 }, refunds30dUsd: 0,
          mrrUsd: 100, subscriptions: { active: 5, pastDue: 0, trialing: 0, byPlan: { pro: 5, pro_recall: 0, other: 0 } }, otherCurrencies: [], truncated: false,
        },
      },
      vercel: { status: "ok", fetchedAt: NOW.toISOString(), data: { team: "acme", plan: "pro", byDay: { "2026-10-01": 20 }, services: [] } },
      supabase: { status: "ok", fetchedAt: NOW.toISOString(), data: { org: "Navi", slug: "org1", plan: "pro", monthlyUsd: 36.5, lines: [], activeProjects: 1 } },
    };
    const l = buildLedger({ now: NOW, days, aiMtdUsd: 15, money, estimatedMrrUsd: 0 });
    expect(l.revenue).toEqual({ today: 40, mtd: 100, d30: 100 });
    expect(l.supabase).toEqual({ today: 1.2, mtd: 18, d30: 36 });
    expect(l.spend).toEqual({ today: 2.2, mtd: 53, d30: 86 });
    expect(l.profit).toEqual({ today: 35.8, mtd: 42, d30: 9 });
    expect(l.days[0].revenueRunRateUsd).toBeCloseTo((100 * 12) / 365);
  });

  it("without Stripe there is no profit line, and spend is what could be priced", () => {
    const money: Money = {
      stripe: { status: "not_configured", hint: "" },
      vercel: { status: "error", error: "HTTP 403", fetchedAt: NOW.toISOString() },
      supabase: { status: "not_configured", hint: "" },
    };
    const l = buildLedger({ now: NOW, days, aiMtdUsd: 15, money, estimatedMrrUsd: 0 });
    expect(l.revenue).toBeNull();
    expect(l.profit).toBeNull();
    expect(l.spend).toEqual({ today: 1, mtd: 15, d30: 30 });
  });
});

describe("loadMoney cache", () => {
  it("fetches once per 10 minutes, and again with fresh", async () => {
    process.env.VERCEL_API_TOKEN = "vercel-token-123456";
    process.env.VERCEL_TEAM_ID = "team_1";
    const fetchImpl = vi.fn(async (url: string) => (url.includes("/v1/billing/charges") ? new Response("", { status: 200 }) : jsonRes({ id: "team_1" })));
    await loadMoney(NOW, { fetchImpl });
    const calls = fetchImpl.mock.calls.length;
    await loadMoney(new Date(NOW.getTime() + 5 * 60_000), { fetchImpl });
    expect(fetchImpl.mock.calls.length).toBe(calls);
    await loadMoney(new Date(NOW.getTime() + 5 * 60_000), { fetchImpl, fresh: true });
    expect(fetchImpl.mock.calls.length).toBe(calls * 2);
  });
});
