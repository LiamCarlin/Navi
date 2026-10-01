/**
 * Money in and out for the Overview, each from its own source of truth:
 *   Stripe   — revenue actually collected (balance transactions) and MRR from live subscriptions
 *   Vercel   — hosting charges (FOCUS billing API, `/v1/billing/charges`)
 *   Supabase — plan + compute + add-ons. The Management API has no invoice endpoint, so this is an
 *              estimate of the fixed part of the bill; usage overages (egress, storage) are not in it.
 * AI vendor cost stays the proxy's own metering (the usage table, see overview.ts).
 *
 * Every source is fetched with a timeout, cached for 10 minutes per server instance (errors for
 * 1 minute) and fails on its own: a revoked token blanks one row, not the page. The summarizers
 * are pure so the tests hand them plain objects.
 */

import { getStripe, planFromPriceId, stripeConfigured, type Plan, type PriceTable } from "../billing";
import { env } from "../env";
import { resolveVendorKey, scrubKey } from "../keys";
import { dayKey } from "../plans";

export type SourceState<T> =
  | { status: "ok"; data: T; fetchedAt: string }
  | { status: "not_configured"; hint: string }
  | { status: "error"; error: string; fetchedAt: string };

type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

const DAY_MS = 86_400_000;
/** Supabase and Vercel price compute by the hour; a month is 730 of them. */
const HOURS_PER_MONTH = 730;

export function monthStartKey(now: Date): string {
  return `${dayKey(now).slice(0, 8)}01`;
}

/** First day (UTC) any source needs: 30 days back or the 1st of the month, whichever is earlier. */
export function windowStart(now: Date): Date {
  const d30 = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()) - 29 * DAY_MS);
  const m = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  return d30 < m ? d30 : m;
}

/** Sums a per-day map over [from, to] (inclusive day keys). */
export function sumDays(byDay: Record<string, number>, from: string, to: string): number {
  let n = 0;
  for (const [day, v] of Object.entries(byDay)) if (day >= from && day <= to) n += v;
  return n;
}

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

// MARK: - Stripe

/** Structural subsets of Stripe.BalanceTransaction / Stripe.Subscription. */
export interface BalanceTxnLike { type: string; amount: number; fee: number; currency: string; created: number }
export interface SubscriptionLike {
  status: string;
  items: {
    data: {
      quantity?: number | null;
      price: { id: string; unit_amount: number | null; currency: string; recurring: { interval: string; interval_count: number } | null };
    }[];
  };
}

export interface StripeMoney {
  testMode: boolean;
  /** Charges − refunds per UTC day, USD. */
  byDay: Record<string, number>;
  feesByDay: Record<string, number>;
  refunds30dUsd: number;
  /** Monthly recurring revenue from active + past_due subscriptions at their price (before coupons). */
  mrrUsd: number;
  subscriptions: { active: number; pastDue: number; trialing: number; byPlan: Record<Plan | "other", number> };
  /** Non-USD activity is left out of the totals and named here. */
  otherCurrencies: string[];
  /** More transactions than we page through — totals are a floor. */
  truncated: boolean;
}

const REVENUE_TYPES = new Set(["charge", "payment"]);
const REFUND_TYPES = new Set(["refund", "payment_refund", "payment_failure_refund"]);

/** Price → USD per month. Yearly at /12, weekly at 52/12, daily at 365/12. */
export function monthlyAmountUsd(unitAmountCents: number, quantity: number, interval: string, intervalCount: number): number {
  const per = unitAmountCents * quantity / 100 / Math.max(1, intervalCount);
  switch (interval) {
    case "month": return per;
    case "year": return per / 12;
    case "week": return (per * 52) / 12;
    case "day": return (per * 365) / 12;
    default: return 0;
  }
}

export function summarizeStripe(input: {
  txns: BalanceTxnLike[];
  subs: SubscriptionLike[];
  prices: PriceTable;
  testMode: boolean;
  now: Date;
  truncated?: boolean;
}): StripeMoney {
  const byDay: Record<string, number> = {};
  const feesByDay: Record<string, number> = {};
  const other = new Set<string>();
  let refunds = 0;
  const since30 = dayKey(new Date(input.now.getTime() - 29 * DAY_MS));
  for (const t of input.txns) {
    const counted = REVENUE_TYPES.has(t.type) || REFUND_TYPES.has(t.type);
    if (!counted) continue;
    if (t.currency.toLowerCase() !== "usd") {
      other.add(t.currency.toUpperCase());
      continue;
    }
    const day = dayKey(new Date(t.created * 1000));
    byDay[day] = (byDay[day] ?? 0) + t.amount / 100;
    feesByDay[day] = (feesByDay[day] ?? 0) + t.fee / 100;
    if (REFUND_TYPES.has(t.type) && day >= since30) refunds += -t.amount / 100;
  }

  const subscriptions = { active: 0, pastDue: 0, trialing: 0, byPlan: { pro: 0, pro_recall: 0, other: 0 } as Record<Plan | "other", number> };
  let mrr = 0;
  for (const sub of input.subs) {
    if (sub.status === "trialing") {
      subscriptions.trialing += 1;
      continue;
    }
    if (sub.status !== "active" && sub.status !== "past_due") continue;
    if (sub.status === "active") subscriptions.active += 1;
    else subscriptions.pastDue += 1;
    const first = sub.items.data[0]?.price;
    subscriptions.byPlan[planFromPriceId(first?.id, input.prices) ?? "other"] += 1;
    for (const item of sub.items.data) {
      const p = item.price;
      if (!p.recurring || p.unit_amount == null) continue;
      if (p.currency.toLowerCase() !== "usd") {
        other.add(p.currency.toUpperCase());
        continue;
      }
      mrr += monthlyAmountUsd(p.unit_amount, item.quantity ?? 1, p.recurring.interval, p.recurring.interval_count);
    }
  }

  return {
    testMode: input.testMode,
    byDay,
    feesByDay,
    refunds30dUsd: round2(refunds),
    mrrUsd: round2(mrr),
    subscriptions,
    otherCurrencies: [...other].sort(),
    truncated: input.truncated ?? false,
  };
}

const STRIPE_TXN_CAP = 5000;

async function fetchStripe(now: Date): Promise<SourceState<StripeMoney>> {
  if (!stripeConfigured()) {
    return { status: "not_configured", hint: "Set STRIPE_SECRET_KEY on the deployment (DEPLOY.md §5); revenue and MRR show here once it is." };
  }
  const stripe = getStripe();
  const gte = Math.floor(windowStart(now).getTime() / 1000);
  const [txns, ...subLists] = await Promise.all([
    stripe.balanceTransactions.list({ created: { gte }, limit: 100 }).autoPagingToArray({ limit: STRIPE_TXN_CAP }),
    ...(["active", "past_due", "trialing"] as const).map((status) =>
      stripe.subscriptions.list({ status, limit: 100 }).autoPagingToArray({ limit: 2000 }),
    ),
  ]);
  const data = summarizeStripe({
    txns: txns as unknown as BalanceTxnLike[],
    subs: subLists.flat() as unknown as SubscriptionLike[],
    prices: env.stripePrices,
    testMode: (env.stripeSecretKey ?? "").startsWith("sk_test") || (env.stripeSecretKey ?? "").startsWith("rk_test"),
    now,
    truncated: txns.length >= STRIPE_TXN_CAP,
  });
  return { status: "ok", data, fetchedAt: now.toISOString() };
}

// MARK: - Vercel

/** A structural subset of one FOCUS v1.3 charge row. Costs arrive as numbers or numeric strings. */
export interface FocusChargeLike { BilledCost: number | string; ChargePeriodStart: string; ServiceName?: string; BillingCurrency?: string }

export interface VercelMoney {
  team: string | null;
  /** hobby / pro / enterprise, when the API says. */
  plan: string | null;
  byDay: Record<string, number>;
  /** Last 30 days by service, largest first. */
  services: { name: string; usd: number }[];
}

export function parseJsonl<T>(text: string): T[] {
  const out: T[] = [];
  for (const line of text.split("\n")) {
    const l = line.trim();
    if (!l) continue;
    try {
      out.push(JSON.parse(l) as T);
    } catch {
      /* a truncated last line is skipped, not fatal */
    }
  }
  return out;
}

export function summarizeVercel(rows: FocusChargeLike[], now: Date, meta: { team: string | null; plan: string | null }): VercelMoney {
  const byDay: Record<string, number> = {};
  const services = new Map<string, number>();
  const since30 = dayKey(new Date(now.getTime() - 29 * DAY_MS));
  for (const r of rows) {
    const cost = typeof r.BilledCost === "number" ? r.BilledCost : Number.parseFloat(r.BilledCost);
    if (!Number.isFinite(cost) || cost === 0) continue;
    const day = (r.ChargePeriodStart ?? "").slice(0, 10);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) continue;
    byDay[day] = (byDay[day] ?? 0) + cost;
    if (day >= since30) {
      const name = r.ServiceName || "Other";
      services.set(name, (services.get(name) ?? 0) + cost);
    }
  }
  return {
    ...meta,
    byDay,
    services: [...services].map(([name, usd]) => ({ name, usd: round2(usd) })).sort((a, b) => b.usd - a.usd),
  };
}

async function vercelJson<T>(fetchImpl: FetchLike, path: string, token: string): Promise<{ res: Response; body: T | null }> {
  const res = await fetchImpl(`https://api.vercel.com${path}`, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(10_000) });
  const body = res.ok ? ((await res.json().catch(() => null)) as T | null) : null;
  if (!res.ok) await res.body?.cancel().catch(() => undefined);
  return { res, body };
}

interface VercelTeam { id: string; slug?: string; name?: string; billing?: { plan?: string } | null }

/** VERCEL_TEAM_ID, else the token's only team, else the team that owns this deployment's project. */
async function resolveVercelTeam(fetchImpl: FetchLike, token: string): Promise<VercelTeam | null> {
  const forced = env.vercelTeamId;
  if (forced) {
    const { body } = await vercelJson<VercelTeam>(fetchImpl, `/v2/teams/${encodeURIComponent(forced)}`, token);
    return body ?? { id: forced };
  }
  const { res, body } = await vercelJson<{ teams?: VercelTeam[] }>(fetchImpl, "/v2/teams?limit=20", token);
  if (!res.ok) throw new Error(`listing teams failed (HTTP ${res.status})`);
  const teams = body?.teams ?? [];
  if (teams.length === 0) return null; // a personal account
  let team = teams[0];
  const projectId = process.env.VERCEL_PROJECT_ID;
  if (teams.length > 1 && projectId) {
    for (const t of teams) {
      const r = await vercelJson<unknown>(fetchImpl, `/v9/projects/${encodeURIComponent(projectId)}?teamId=${encodeURIComponent(t.id)}`, token);
      if (r.res.ok) {
        team = t;
        break;
      }
    }
  }
  // The list may omit billing; one more call gets the plan.
  if (!team.billing?.plan) {
    const { body: full } = await vercelJson<VercelTeam>(fetchImpl, `/v2/teams/${encodeURIComponent(team.id)}`, token);
    if (full) team = { ...team, ...full };
  }
  return team;
}

export async function fetchVercel(now: Date, fetchImpl: FetchLike = fetch): Promise<SourceState<VercelMoney>> {
  const { key: token } = await resolveVendorKey("vercel");
  if (!token) {
    return { status: "not_configured", hint: "Add a Vercel token on the Keys page (vercel.com/account/tokens, scoped to the team)." };
  }
  try {
    const team = await resolveVercelTeam(fetchImpl, token);
    const from = windowStart(now).toISOString();
    const to = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()) + DAY_MS).toISOString();
    const q = new URLSearchParams({ from, to });
    if (team) q.set("teamId", team.id);
    const res = await fetchImpl(`https://api.vercel.com/v1/billing/charges?${q}`, {
      headers: { authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(15_000),
    });
    const text = await res.text();
    let rows: FocusChargeLike[] = [];
    if (res.ok) rows = parseJsonl<FocusChargeLike>(text);
    // Hobby teams (and quiet months) have no cost rows: Vercel answers 404 costs_not_found.
    else if (!(res.status === 404 && text.includes("costs_not_found"))) {
      throw new Error(`billing charges: HTTP ${res.status} ${scrubKey(text.slice(0, 200), token)}`);
    }
    const data = summarizeVercel(rows, now, { team: team?.slug ?? team?.name ?? null, plan: team?.billing?.plan ?? null });
    return { status: "ok", data, fetchedAt: now.toISOString() };
  } catch (e) {
    return { status: "error", error: scrubKey(e instanceof Error ? e.message : String(e), token), fetchedAt: now.toISOString() };
  }
}

// MARK: - Supabase

/** Plan fees per org per month (supabase.com/pricing). Enterprise/platform are contracts: unknown. */
export const SUPABASE_PLAN_USD: Record<string, number> = { free: 0, pro: 25, team: 599 };
/** Paid plans include this much compute credit per month. */
export const SUPABASE_COMPUTE_CREDIT_USD = 10;
/** Compute per project per month by size (used when the add-on list doesn't carry a price). */
export const SUPABASE_COMPUTE_USD: Record<string, number> = {
  nano: 0, micro: 10, small: 15, medium: 60, large: 110, xlarge: 210, "2xlarge": 410, "4xlarge": 960,
  "8xlarge": 1870, "12xlarge": 2800, "16xlarge": 3730,
};
/** Projects in these states don't run compute. */
const SUPABASE_IDLE = new Set(["INACTIVE", "REMOVED", "GOING_DOWN", "PAUSING", "INIT_FAILED", "PAUSE_FAILED", "RESTORE_FAILED"]);

export interface SupabaseAddonLike {
  type: string;
  variant: { id?: string; name?: string; price?: { type?: string; interval?: string; amount?: number } };
}
export interface SupabaseProjectLike { ref: string; name: string; status: string; computeSize?: string | null; addons: SupabaseAddonLike[] }

export interface SupabaseMoney {
  org: string;
  /** For the dashboard's billing link. */
  slug: string;
  plan: string;
  /** Fixed monthly estimate; null when the plan is a contract we can't price. */
  monthlyUsd: number | null;
  lines: { label: string; usd: number }[];
  activeProjects: number;
}

function addonMonthlyUsd(a: SupabaseAddonLike): number | null {
  const p = a.variant.price;
  if (!p || typeof p.amount !== "number" || p.type === "usage") return null;
  return p.interval === "hourly" ? p.amount * HOURS_PER_MONTH : p.amount;
}

export function estimateSupabase(input: { org: string; slug?: string; plan: string; projects: SupabaseProjectLike[] }): SupabaseMoney {
  const slug = input.slug ?? input.org;
  const plan = input.plan || "free";
  const active = input.projects.filter((p) => !SUPABASE_IDLE.has(p.status));
  const lines: { label: string; usd: number }[] = [];
  const fee = SUPABASE_PLAN_USD[plan];
  lines.push({ label: `${plan[0].toUpperCase()}${plan.slice(1)} plan`, usd: fee ?? 0 });
  if (plan === "free") {
    return { org: input.org, slug, plan, monthlyUsd: 0, lines, activeProjects: active.length };
  }

  let compute = 0;
  for (const p of active) {
    const ci = p.addons.find((a) => a.type === "compute_instance");
    const fromAddon = ci ? addonMonthlyUsd(ci) : null;
    const size = p.computeSize ?? ci?.variant.id?.replace(/^ci_/, "") ?? "micro";
    const usd = fromAddon ?? SUPABASE_COMPUTE_USD[size] ?? 0;
    compute += usd;
    lines.push({ label: `${p.name} · ${size} compute`, usd: round2(usd) });
    for (const a of p.addons) {
      if (a.type === "compute_instance") continue;
      const m = addonMonthlyUsd(a);
      if (m != null && m > 0) lines.push({ label: `${p.name} · ${a.variant.name ?? a.type}`, usd: round2(m) });
    }
  }
  const credit = Math.min(SUPABASE_COMPUTE_CREDIT_USD, compute);
  if (credit > 0) lines.push({ label: "Compute credit", usd: -credit });
  const total = lines.reduce((n, l) => n + l.usd, 0);
  return { org: input.org, slug, plan, monthlyUsd: fee == null ? null : round2(total), lines, activeProjects: active.length };
}

/** `https://<ref>.supabase.co` → ref. */
export function supabaseRef(url: string | undefined): string | null {
  const m = /^https:\/\/([a-z0-9]{10,40})\.supabase\.co\/?$/i.exec(url ?? "");
  return m ? m[1] : null;
}

const SUPABASE_PROJECT_CAP = 10;

export async function fetchSupabase(now: Date, fetchImpl: FetchLike = fetch): Promise<SourceState<SupabaseMoney>> {
  const { key: token } = await resolveVendorKey("supabase");
  const ref = supabaseRef(env.supabaseUrl);
  if (!token || !ref) {
    return {
      status: "not_configured",
      hint: ref
        ? "Add a Supabase personal access token on the Keys page (supabase.com/dashboard/account/tokens)."
        : "SUPABASE_URL isn't a hosted *.supabase.co project.",
    };
  }
  const get = async <T>(path: string): Promise<T> => {
    const res = await fetchImpl(`https://api.supabase.com${path}`, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(10_000) });
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new Error(`${path.split("?")[0]}: HTTP ${res.status} ${scrubKey(text.slice(0, 160), token)}`);
    }
    return (await res.json()) as T;
  };
  try {
    const project = await get<{ organization_slug?: string; organization_id?: string }>(`/v1/projects/${ref}`);
    const slug = project.organization_slug ?? project.organization_id;
    if (!slug) throw new Error("the project has no organization");
    const [org, list] = await Promise.all([
      get<{ name?: string; plan?: string }>(`/v1/organizations/${encodeURIComponent(slug)}`),
      get<{ projects?: { ref: string; name: string; status: string; databases?: { type?: string; infra_compute_size?: string }[] }[] }>(
        `/v1/organizations/${encodeURIComponent(slug)}/projects?limit=100`,
      ),
    ]);
    const projects = (list.projects ?? []).slice(0, SUPABASE_PROJECT_CAP);
    const paid = (org.plan ?? "free") !== "free";
    const withAddons: SupabaseProjectLike[] = await Promise.all(
      projects.map(async (p) => ({
        ref: p.ref,
        name: p.name,
        status: p.status,
        computeSize: p.databases?.find((d) => d.type !== "READ_REPLICA")?.infra_compute_size ?? null,
        addons: paid && !SUPABASE_IDLE.has(p.status)
          ? ((await get<{ selected_addons?: SupabaseAddonLike[] }>(`/v1/projects/${p.ref}/billing/addons`).catch(() => ({ selected_addons: [] })))
              .selected_addons ?? [])
          : [],
      })),
    );
    const data = estimateSupabase({ org: org.name ?? slug, slug, plan: org.plan ?? "free", projects: withAddons });
    return { status: "ok", data, fetchedAt: now.toISOString() };
  } catch (e) {
    return { status: "error", error: scrubKey(e instanceof Error ? e.message : String(e), token), fetchedAt: now.toISOString() };
  }
}

// MARK: - All together, cached

export interface Money {
  stripe: SourceState<StripeMoney>;
  vercel: SourceState<VercelMoney>;
  supabase: SourceState<SupabaseMoney>;
}

const OK_TTL_MS = 10 * 60_000;
const ERROR_TTL_MS = 60_000;

interface Cached { at: number; value: SourceState<unknown> }

function moneyCache(): Map<string, Cached> {
  const g = globalThis as unknown as { __naviMoneyCache?: Map<string, Cached> };
  g.__naviMoneyCache ??= new Map();
  return g.__naviMoneyCache;
}

export function clearMoneyCache(): void {
  moneyCache().clear();
}

async function cached<T>(name: string, nowMs: number, fresh: boolean, load: () => Promise<SourceState<T>>): Promise<SourceState<T>> {
  const hit = moneyCache().get(name);
  if (!fresh && hit) {
    const ttl = hit.value.status === "error" ? ERROR_TTL_MS : OK_TTL_MS;
    if (nowMs - hit.at < ttl) return hit.value as SourceState<T>;
  }
  let value: SourceState<T>;
  try {
    value = await load();
  } catch (e) {
    value = { status: "error", error: e instanceof Error ? e.message : String(e), fetchedAt: new Date(nowMs).toISOString() };
  }
  // "not configured" is cheap to re-check and should flip the moment a token is stored.
  if (value.status !== "not_configured") moneyCache().set(name, { at: nowMs, value });
  return value;
}

export async function loadMoney(now = new Date(), opts: { fresh?: boolean; fetchImpl?: FetchLike } = {}): Promise<Money> {
  const nowMs = now.getTime();
  const fresh = opts.fresh ?? false;
  const [stripe, vercel, supabase] = await Promise.all([
    cached("stripe", nowMs, fresh, () => fetchStripe(now)),
    cached("vercel", nowMs, fresh, () => fetchVercel(now, opts.fetchImpl)),
    cached("supabase", nowMs, fresh, () => fetchSupabase(now, opts.fetchImpl)),
  ]);
  return { stripe, vercel, supabase };
}

// MARK: - The P&L the page shows

export interface Period { today: number; mtd: number; d30: number }

export interface Ledger {
  /** Stripe: charges − refunds. Null when Stripe isn't connected. */
  revenue: Period | null;
  stripeFees: Period | null;
  ai: Period;
  vercel: Period | null;
  supabase: Period | null;
  /** Everything we could price (sources that failed count as 0 and are flagged on the page). */
  spend: Period;
  /** Revenue − Stripe fees − spend; null without Stripe. */
  profit: Period | null;
  /** Per-day series for the chart, same days as the overview. */
  days: { day: string; aiUsd: number; vercelUsd: number; supabaseUsd: number; revenueRunRateUsd: number }[];
}

export function buildLedger(input: {
  now: Date;
  days: { day: string; costUsd: number }[];
  aiMtdUsd: number;
  money: Money;
  /** Fallback revenue run-rate per day when Stripe isn't connected (profiles × list price). */
  estimatedMrrUsd: number;
}): Ledger {
  const { now, days, money } = input;
  const today = dayKey(now);
  const mStart = monthStartKey(now);
  const since30 = days[0]?.day ?? today;
  const dayOfMonth = now.getUTCDate();
  const period = (byDay: Record<string, number>): Period => ({
    today: round2(byDay[today] ?? 0),
    mtd: round2(sumDays(byDay, mStart, today)),
    d30: round2(sumDays(byDay, since30, today)),
  });

  const aiByDay = Object.fromEntries(days.map((d) => [d.day, d.costUsd]));
  const ai: Period = { today: round2(aiByDay[today] ?? 0), mtd: round2(input.aiMtdUsd), d30: round2(sumDays(aiByDay, since30, today)) };

  const stripe = money.stripe.status === "ok" ? money.stripe.data : null;
  const revenue = stripe ? period(stripe.byDay) : null;
  const stripeFees = stripe ? period(stripe.feesByDay) : null;
  const vercel = money.vercel.status === "ok" ? period(money.vercel.data.byDay) : null;
  const sbMonthly = money.supabase.status === "ok" ? money.supabase.data.monthlyUsd : null;
  const sbDaily = sbMonthly != null ? (sbMonthly * 12) / 365 : null;
  const supabase = sbDaily != null ? { today: round2(sbDaily), mtd: round2(sbDaily * dayOfMonth), d30: round2(sbDaily * days.length) } : null;

  const add = (...ps: (Period | null)[]): Period => ({
    today: round2(ps.reduce((n, p) => n + (p?.today ?? 0), 0)),
    mtd: round2(ps.reduce((n, p) => n + (p?.mtd ?? 0), 0)),
    d30: round2(ps.reduce((n, p) => n + (p?.d30 ?? 0), 0)),
  });
  const spend = add(ai, vercel, supabase);
  const profit = revenue && stripeFees
    ? { today: round2(revenue.today - stripeFees.today - spend.today), mtd: round2(revenue.mtd - stripeFees.mtd - spend.mtd), d30: round2(revenue.d30 - stripeFees.d30 - spend.d30) }
    : null;

  const mrr = stripe?.mrrUsd ?? input.estimatedMrrUsd;
  const vercelByDay = money.vercel.status === "ok" ? money.vercel.data.byDay : {};
  return {
    revenue,
    stripeFees,
    ai,
    vercel,
    supabase,
    spend,
    profit,
    days: days.map((d) => ({
      day: d.day,
      aiUsd: d.costUsd,
      vercelUsd: vercelByDay[d.day] ?? 0,
      supabaseUsd: sbDaily ?? 0,
      revenueRunRateUsd: (mrr * 12) / 365,
    })),
  };
}
