import { stripeConfigured } from "@/lib/billing";
import { int, usd } from "@/lib/admin/format";
import { requireAdmin } from "@/lib/admin/guard";
import { loadOverview } from "@/lib/admin/overview";
import { getDb } from "@/lib/db";
import { env } from "@/lib/env";
import { LIST_PRICES_USD } from "@/lib/plans";
import { CostRevenueChart, DayBars, TierMix } from "../_components/charts";
import { Card, Tile } from "../_components/ui";
import s from "../admin.module.css";

export const dynamic = "force-dynamic";

export default async function Overview() {
  await requireAdmin();
  const now = new Date();
  const o = await loadOverview(await getDb(), now);
  const margin = o.mrrUsd - (o.cost30dUsd * 365) / 12 / 30;
  const stripe = stripeConfigured();
  const stripeTest = (env.stripeSecretKey ?? "").startsWith("sk_test");

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
        <Tile label="MRR (estimate)" value={usd(o.mrrUsd, 0)} foot={`list prices $${LIST_PRICES_USD.pro.month}/$${LIST_PRICES_USD.pro_recall.month}`} />
        <Tile label="Vendor cost" value={usd(o.costTodayUsd)} foot={`today · ${usd(o.cost30dUsd)} in 30d`} />
        <Tile label="Monthly margin (est.)" value={usd(margin, 0)} foot="MRR − 30-day cost run-rate" />
        <Tile label="Waitlist" value={int(o.waitlist)} />
      </div>

      <div className={s.stack}>
        <Card title="Vendor cost vs revenue — last 30 days">
          <CostRevenueChart days={o.days} />
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
          Revenue is estimated from paying subscriptions (status active / past_due) × monthly list price; yearly plans count at the
          monthly rate. Billing:{" "}
          {stripe ? (
            <a className={s.muted} href={`https://dashboard.stripe.com/${stripeTest ? "test/" : ""}subscriptions`} target="_blank" rel="noreferrer">
              Stripe {stripeTest ? "(test mode)" : ""} dashboard ↗
            </a>
          ) : (
            "Stripe is not configured on this deployment."
          )}
        </div>
      </footer>
    </>
  );
}
