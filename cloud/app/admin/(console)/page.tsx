import Link from "next/link";
import type { ReactNode } from "react";
import { ago, int, usd } from "@/lib/admin/format";
import { requireAdmin } from "@/lib/admin/guard";
import { loadOverview } from "@/lib/admin/overview";
import { buildLedger, loadMoney, type Period, type SourceState } from "@/lib/admin/spend";
import { getDb } from "@/lib/db";
import { LIST_PRICES_USD } from "@/lib/plans";
import { CostRevenueChart, DayBars, TierMix } from "../_components/charts";
import { param, Card, Tile } from "../_components/ui";
import s from "../admin.module.css";

export const dynamic = "force-dynamic";

/** Money in the P&L: cents, a real minus sign, never "−$0.00". */
function signedUsd(n: number, digits = 2): string {
  const v = Math.round(n * 10 ** digits) / 10 ** digits;
  return v < 0 ? `−${usd(-v, digits)}` : usd(Math.abs(v), digits);
}

function SourceNote<T>({ state }: { state: SourceState<T> }) {
  if (state.status === "not_configured") return <span className={s.badge} title={state.hint}>not connected</span>;
  if (state.status === "error") return <span className={s.badgeBad} title={state.error}>unavailable</span>;
  return null;
}

function Cells({ p, sign = 1 }: { p: Period | null; sign?: 1 | -1 }) {
  if (!p) return <><td className={`${s.num} ${s.muted}`}>—</td><td className={`${s.num} ${s.muted}`}>—</td><td className={`${s.num} ${s.muted}`}>—</td></>;
  return (
    <>
      <td className={s.num}>{signedUsd(sign * p.today)}</td>
      <td className={s.num}>{signedUsd(sign * p.mtd)}</td>
      <td className={s.num}>{signedUsd(sign * p.d30)}</td>
    </>
  );
}

function Row({ label, p, sign, note, detail, href }: { label: ReactNode; p: Period | null; sign?: 1 | -1; note?: ReactNode; detail?: ReactNode; href?: string }) {
  return (
    <tr>
      <td>
        {href ? <a href={href} target="_blank" rel="noreferrer">{label} ↗</a> : label} {note}
        {detail && <div className={s.muted} style={{ fontSize: 11.5 }}>{detail}</div>}
      </td>
      <Cells p={p} sign={sign} />
    </tr>
  );
}

export default async function Overview({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  await requireAdmin();
  const params = await searchParams;
  const now = new Date();
  const [o, money] = await Promise.all([loadOverview(await getDb(), now), loadMoney(now, { fresh: param(params, "refresh") === "1" })]);
  const ledger = buildLedger({ now, days: o.days, aiMtdUsd: o.costMtdUsd, money, estimatedMrrUsd: o.mrrUsd });

  const stripe = money.stripe.status === "ok" ? money.stripe.data : null;
  const vercel = money.vercel.status === "ok" ? money.vercel.data : null;
  const supabase = money.supabase.status === "ok" ? money.supabase.data : null;
  const stripeBase = `https://dashboard.stripe.com/${stripe?.testMode ? "test/" : ""}`;
  const missing = [
    money.vercel.status !== "ok" && "Vercel",
    money.supabase.status !== "ok" && "Supabase",
    supabase?.monthlyUsd === null && "Supabase (contract plan)",
  ].filter(Boolean);
  const fetchedAt = [money.stripe, money.vercel, money.supabase]
    .map((m) => (m.status === "not_configured" ? null : m.fetchedAt))
    .filter((t): t is string => Boolean(t))
    .sort()[0];

  return (
    <>
      <h1 className={s.h1}>Overview</h1>
      <p className={s.sub}>Navi Cloud right now · {now.toISOString().slice(0, 16).replace("T", " ")} UTC</p>

      <div className={s.tiles}>
        <Tile label="Users" value={int(o.totalUsers)} foot={`${o.disabled} disabled · ${o.overrides} overrides`} />
        <Tile label="Signups" value={int(o.signups.today)} foot={`today · ${o.signups.d7} in 7d · ${o.signups.d30} in 30d`} />
        <Tile label="Active users" value={int(o.activeUsers.d1)} foot={`today (UTC) · ${o.activeUsers.d7} in 7d`} />
        <Tile label="Trials running" value={int(o.trialsRunning)} foot="free users inside the 7-day Pro trial" />
        <Tile label="Paying subscriptions" value={int(o.payingSubs.total)} foot={`${o.payingSubs.pro} Pro · ${o.payingSubs.pro_recall} Pro+Recall${o.pastDue ? ` · ${o.pastDue} past due` : ""}`} />
        <Tile label="Waitlist" value={int(o.waitlist)} />
      </div>

      <div className={s.rowBetween} style={{ margin: "6px 0 10px" }}>
        <h2 className={s.h2} style={{ margin: 0 }}>Money</h2>
        <span className={s.muted}>
          {fetchedAt ? `billing data from ${ago(fetchedAt, now)} · ` : ""}
          <Link href="/admin?refresh=1">Refresh</Link>
        </span>
      </div>
      <div className={s.tiles}>
        <Tile
          label={`Revenue · 30 days${stripe?.testMode ? " (test mode)" : ""}`}
          value={ledger.revenue ? usd(ledger.revenue.d30, 0) : "—"}
          foot={ledger.revenue ? `${usd(ledger.revenue.today, 2)} today · ${usd(ledger.revenue.mtd, 0)} this month` : "connect Stripe to see collected revenue"}
        />
        <Tile
          label={stripe ? "MRR" : "MRR (estimate)"}
          value={usd(stripe?.mrrUsd ?? o.mrrUsd, 0)}
          foot={stripe
            ? `${stripe.subscriptions.active} active${stripe.subscriptions.pastDue ? ` · ${stripe.subscriptions.pastDue} past due` : ""}${stripe.subscriptions.trialing ? ` · ${stripe.subscriptions.trialing} trialing` : ""} in Stripe`
            : `profiles × list price $${LIST_PRICES_USD.pro.month}/$${LIST_PRICES_USD.pro_recall.month}`}
        />
        <Tile label="Spend · 30 days" value={usd(ledger.spend.d30, 0)} foot={`${usd(ledger.spend.today, 2)} today${missing.length ? ` · missing ${missing.join(", ")}` : " · AI + Vercel + Supabase"}`} />
        <Tile
          label="Profit · 30 days"
          value={ledger.profit ? signedUsd(ledger.profit.d30, 0) : "—"}
          foot={ledger.profit ? `${signedUsd(ledger.profit.mtd, 0)} this month · after Stripe fees` : "needs Stripe"}
        />
      </div>

      <div className={s.stack}>
        <Card title="Where the money goes">
          <table className={s.table}>
            <thead>
              <tr><th>Source</th><th className={s.num}>Today</th><th className={s.num}>This month</th><th className={s.num}>Last 30 days</th></tr>
            </thead>
            <tbody>
              <Row
                label="Revenue (Stripe)"
                href={`${stripeBase}payments`}
                p={ledger.revenue}
                note={<>{stripe?.testMode && <span className={s.badgeWarn}>test mode</span>}<SourceNote state={money.stripe} /></>}
                detail={stripe
                  ? `charges − refunds${stripe.refunds30dUsd ? ` (${usd(stripe.refunds30dUsd, 2)} refunded in 30d)` : ""}${stripe.otherCurrencies.length ? ` · non-USD left out: ${stripe.otherCurrencies.join(", ")}` : ""}${stripe.truncated ? " · over 5,000 transactions, totals are a floor" : ""}`
                  : money.stripe.status === "not_configured" ? money.stripe.hint : money.stripe.status === "error" ? money.stripe.error : undefined}
              />
              <Row label="Stripe fees" p={ledger.stripeFees} sign={-1} href={`${stripeBase}balance`} />
              <Row label="AI vendors (metered by the proxy)" p={ledger.ai} sign={-1} detail="TypeSafe / Anthropic / Gemini at list price per request" />
              <Row
                label={`Vercel${vercel?.plan ? ` · ${vercel.plan}` : ""}`}
                href={vercel?.team ? `https://vercel.com/${vercel.team}/~/usage` : "https://vercel.com/dashboard"}
                p={ledger.vercel}
                sign={-1}
                note={<SourceNote state={money.vercel} />}
                detail={vercel
                  ? vercel.services.length
                    ? vercel.services.slice(0, 3).map((x) => `${x.name} ${usd(x.usd, 2)}`).join(" · ")
                    : vercel.plan === "hobby" ? "Hobby plan: no charges" : "no charges in this window"
                  : money.vercel.status === "not_configured" ? money.vercel.hint : money.vercel.status === "error" ? money.vercel.error : undefined}
              />
              <Row
                label={`Supabase${supabase ? ` · ${supabase.plan}` : ""}`}
                href={supabase ? `https://supabase.com/dashboard/org/${encodeURIComponent(supabase.slug)}/billing` : "https://supabase.com/dashboard"}
                p={ledger.supabase}
                sign={-1}
                note={<SourceNote state={money.supabase} />}
                detail={supabase
                  ? supabase.monthlyUsd == null
                    ? `${supabase.plan} is a contract plan — see the Supabase invoice`
                    : `estimate ${usd(supabase.monthlyUsd, 2)}/mo: ${supabase.lines.map((l) => `${l.label} ${signedUsd(l.usd)}`).join(" · ")} · usage overages not included`
                  : money.supabase.status === "not_configured" ? money.supabase.hint : money.supabase.status === "error" ? money.supabase.error : undefined}
              />
              <tr>
                <td><strong>{ledger.profit ? "Profit" : "Net (spend only — connect Stripe for revenue)"}</strong></td>
                {ledger.profit ? (
                  <>
                    <td className={s.num}><strong>{signedUsd(ledger.profit.today)}</strong></td>
                    <td className={s.num}><strong>{signedUsd(ledger.profit.mtd)}</strong></td>
                    <td className={s.num}><strong>{signedUsd(ledger.profit.d30)}</strong></td>
                  </>
                ) : (
                  <>
                    <td className={s.num}>{signedUsd(-ledger.spend.today)}</td>
                    <td className={s.num}>{signedUsd(-ledger.spend.mtd)}</td>
                    <td className={s.num}>{signedUsd(-ledger.spend.d30)}</td>
                  </>
                )}
              </tr>
            </tbody>
          </table>
          <p className={s.muted} style={{ margin: "10px 0 0", fontSize: 11.5 }}>
            Tokens for Vercel and Supabase live on the <Link href="/admin/keys">Keys</Link> page. Billing data is cached for 10 minutes.
          </p>
        </Card>
        <Card title="Spend vs revenue — last 30 days">
          <CostRevenueChart days={ledger.days} revenueLabel={stripe ? "Revenue / day (Stripe MRR run-rate)" : "Revenue / day (estimated MRR run-rate)"} />
        </Card>
        <div className={`${s.grid} ${s.cols2}`}>
          <Card title="Active users per day">
            <DayBars days={o.days} pick={(d) => d.activeUsers} label="Active users" />
          </Card>
          <Card title="Signups per day">
            <DayBars days={o.days} pick={(d) => d.signups} label="Signups" color="var(--series-3)" />
          </Card>
        </div>
        <Card title="Tier mix (as served now)">
          <TierMix mix={o.tierMix} />
        </Card>
      </div>

      <footer className={s.footer}>
        <div>
          <strong>Privacy.</strong> This console shows metadata only — accounts, tiers, usage counts per run and
          their vendor cost. Navi Cloud never stores request or response bodies (prompts, answers, screen text): the proxy
          streams them straight through, and the usage table holds user, feature, run id, day and cost. Vendor keys are
          encrypted at rest and only ever shown masked.
        </div>
        <div style={{ marginTop: 6 }}>
          Revenue is what Stripe collected (charges − refunds, USD); MRR counts active and past-due subscriptions at their price
          (yearly ÷ 12, before coupons). Vercel is its billed charges by day; Supabase is plan + compute + add-ons spread evenly
          over the month (egress/storage overages appear only on the Supabase invoice). AI cost is the proxy&apos;s own metering.
        </div>
      </footer>
    </>
  );
}
