import Link from "next/link";
import { notFound } from "next/navigation";
import { ago, dateOnly, dateTime, int, stripeCustomerUrl, usd } from "@/lib/admin/format";
import { requireAdmin } from "@/lib/admin/guard";
import { effectiveQuotas, getConfig } from "@/lib/config";
import { getDb } from "@/lib/db";
import { usageSummary } from "@/lib/metering";
import { effectiveTier, ENTITLEMENT_KEYS, entitlementsFor, isInTrial, TIERS } from "@/lib/plans";
import {
  deleteUserAction,
  extendTrialAction,
  grantEntitlementAction,
  resetQuotaAction,
  revokeEntitlementAction,
  setDisabledAction,
  setTierOverrideAction,
  signOutAllAction,
} from "../../../actions";
import { ConfirmButton } from "../../../_components/client";
import { Card, Flash, Hidden, TierBadge } from "../../../_components/ui";
import s from "../../../admin.module.css";

export const dynamic = "force-dynamic";

export default async function UserDetail({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  await requireAdmin();
  const { id } = await params;
  const sp = await searchParams;
  const db = await getDb();
  const profile = await db.getProfile(id);
  if (!profile) notFound();

  const now = new Date();
  const [grants, byFeature, cfg] = await Promise.all([db.listEntitlements(id), db.adminUsageByFeature(id), getConfig(db)]);
  const tier = effectiveTier(profile, now);
  const trial = isInTrial(profile, now);
  const ent = entitlementsFor(tier, grants, now);
  const quotas = effectiveQuotas(tier, cfg);
  const usage = await usageSummary(db, id, tier, now, profile.quotaReset, cfg);
  const totalCost = byFeature.reduce((n, f) => n + f.costUsd, 0);
  const totalRuns = byFeature.reduce((n, f) => n + f.runs, 0);
  const uid = { userId: id };

  return (
    <>
      <div className={s.rowBetween}>
        <div>
          <h1 className={s.h1}>{profile.email || "(no email)"}</h1>
          <p className={s.sub}>
            <TierBadge tier={trial ? "trial" : tier} />{" "}
            {profile.disabledAt && <span className={s.badgeBad}>disabled {ago(profile.disabledAt, now)}</span>}{" "}
            {profile.tierOverride && <span className={s.badgeInfo}>override: {profile.tierOverride}</span>}
          </p>
        </div>
        <Link className={s.btn} href="/admin/users">← All users</Link>
      </div>
      <Flash params={sp} />

      <div className={`${s.grid} ${s.cols2}`}>
        <Card title="Account">
          <dl className={s.kv}>
            <dt>User id</dt><dd className={s.mono}>{profile.userId}</dd>
            <dt>Signed up</dt><dd>{dateTime(profile.createdAt)}</dd>
            <dt>Paid tier</dt><dd>{profile.tier}</dd>
            <dt>Served as</dt><dd>{tier}{trial ? " (trial)" : ""}{profile.tierOverride ? " (override)" : ""}</dd>
            <dt>Trial ends</dt><dd>{profile.trialEndsAt ? `${dateTime(profile.trialEndsAt)} · ${ago(profile.trialEndsAt, now)}` : "—"}</dd>
            <dt>Stripe</dt>
            <dd>
              {profile.stripeCustomerId ? (
                <a href={stripeCustomerUrl(profile.stripeCustomerId)} target="_blank" rel="noreferrer">{profile.stripeCustomerId} ↗</a>
              ) : (
                <span className={s.muted}>no customer</span>
              )}
              {profile.subscriptionStatus && <> · {profile.subscriptionStatus}</>}
            </dd>
            <dt>Entitlements</dt>
            <dd>{ENTITLEMENT_KEYS.map((k) => <span key={k} className={ent[k] ? s.badgeGood : s.badge} style={{ marginRight: 4 }}>{k}</span>)}</dd>
            {profile.disabledAt && (<><dt>Disabled</dt><dd>{dateTime(profile.disabledAt)}{profile.disabledReason ? ` — ${profile.disabledReason}` : ""}</dd></>)}
          </dl>
        </Card>

        <Card title="Quota now">
          <table className={s.table}>
            <thead><tr><th>Counter</th><th className={s.num}>Used</th><th className={s.num}>Cap</th></tr></thead>
            <tbody>
              <tr><td>Answers today</td><td className={s.num}>{usage.answersToday}</td><td className={s.num}>{quotas.answersPerDay ?? "∞"}</td></tr>
              <tr><td>Tasks today</td><td className={s.num}>{usage.tasksToday}</td><td className={s.num}>{quotas.tasksPerDay ?? "—"}</td></tr>
              <tr><td>Tasks this month</td><td className={s.num}>{usage.tasksThisMonth}</td><td className={s.num}>{quotas.tasksPerMonth ?? "—"}</td></tr>
            </tbody>
          </table>
          <p className={s.muted} style={{ margin: "8px 0 0" }}>Resets {dateTime(usage.resetsAt)}.</p>
          <div className={s.row} style={{ marginTop: 10 }}>
            <form action={resetQuotaAction}><Hidden values={{ ...uid, scope: "day" }} /><button className={s.btn}>Reset today&apos;s quota</button></form>
            <form action={resetQuotaAction}><Hidden values={{ ...uid, scope: "month" }} /><button className={s.btn}>Reset this month&apos;s tasks</button></form>
          </div>
        </Card>
      </div>

      <div className={`${s.grid} ${s.cols2} ${s.section}`}>
        <Card title="Usage by feature" right={<span className={s.muted}>{int(totalRuns)} runs · {usd(totalCost)} to date</span>}>
          <table className={s.table}>
            <thead><tr><th>Feature</th><th className={s.num}>Runs</th><th className={s.num}>Cost</th><th>Last used</th></tr></thead>
            <tbody>
              {byFeature.length === 0 && <tr><td colSpan={4} className={s.muted}>No usage yet.</td></tr>}
              {byFeature.map((f) => (
                <tr key={f.feature}><td>{f.feature}</td><td className={s.num}>{int(f.runs)}</td><td className={s.num}>{usd(f.costUsd)}</td><td>{f.lastDay ?? "—"}</td></tr>
              ))}
            </tbody>
          </table>
          <p className={s.muted} style={{ margin: "8px 0 0" }}>Metadata only — Navi Cloud keeps no prompts or answers.</p>
        </Card>

        <Card title="Entitlement grants (comps, beta)">
          <table className={s.table}>
            <thead><tr><th>Key</th><th>Granted by</th><th>Expires</th><th /></tr></thead>
            <tbody>
              {grants.length === 0 && <tr><td colSpan={4} className={s.muted}>None — the tier decides.</td></tr>}
              {grants.map((g) => (
                <tr key={g.key}>
                  <td>{g.key}</td>
                  <td className={s.muted}>{g.grantedBy}</td>
                  <td>{g.expiresAt ? `${dateOnly(g.expiresAt)} (${ago(g.expiresAt, now)})` : "never"}</td>
                  <td className={s.num}>
                    <form action={revokeEntitlementAction}><Hidden values={{ ...uid, key: g.key }} /><button className={s.btnDanger}>Revoke</button></form>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <form action={grantEntitlementAction} className={s.row} style={{ marginTop: 10 }}>
            <Hidden values={uid} />
            <select className={s.select} name="key" defaultValue="recall">
              {ENTITLEMENT_KEYS.map((k) => <option key={k} value={k}>{k}</option>)}
            </select>
            <label className={s.row} style={{ color: "var(--text-2)" }}>until <input className={s.input} type="date" name="expiresAt" /></label>
            <button className={s.btn}>Grant</button>
          </form>
        </Card>
      </div>

      <div className={`${s.grid} ${s.cols2} ${s.section}`}>
        <Card title="Plan">
          <div className={s.stack}>
            <form action={setTierOverrideAction} className={s.row}>
              <Hidden values={uid} />
              <span className={s.muted} style={{ width: 110 }}>Tier override</span>
              <select className={s.select} name="tier" defaultValue={profile.tierOverride ?? "none"}>
                <option value="none">none (paid tier / trial)</option>
                {TIERS.map((t) => <option key={t} value={t}>{t}</option>)}
              </select>
              <button className={s.btn}>Set</button>
            </form>
            <form action={extendTrialAction} className={s.row}>
              <Hidden values={uid} />
              <span className={s.muted} style={{ width: 110 }}>Extend trial</span>
              <input className={s.inputSmall} type="number" name="days" min={1} max={365} defaultValue={7} /> days
              <button className={s.btn}>Extend</button>
            </form>
          </div>
        </Card>

        <Card title="Access">
          <div className={s.stack}>
            {profile.disabledAt ? (
              <form action={setDisabledAction} className={s.row}>
                <Hidden values={{ ...uid, disable: "0" }} />
                <button className={s.btnGood}>Enable account</button>
              </form>
            ) : (
              <form action={setDisabledAction} className={s.row}>
                <Hidden values={{ ...uid, disable: "1" }} />
                <input className={s.inputWide} name="reason" placeholder="internal reason (never shown to the user)" />
                <ConfirmButton className={s.btnDanger} message="Disable this account? Every /v1 call will return 403.">Disable account</ConfirmButton>
              </form>
            )}
            <form action={signOutAllAction}>
              <Hidden values={uid} />
              <ConfirmButton message="Revoke every session for this user?">Sign out all sessions</ConfirmButton>
            </form>
            <form action={deleteUserAction} className={s.row}>
              <Hidden values={uid} />
              <input className={s.inputWide} name="confirmEmail" placeholder="type the email to confirm delete" autoComplete="off" />
              <ConfirmButton className={s.btnDanger} message="Permanently delete this user, their grants and usage?">Delete user</ConfirmButton>
            </form>
            {profile.stripeSubscriptionId && profile.subscriptionStatus !== "canceled" && (
              <div className={s.banner} style={{ margin: 0 }}>Has a Stripe subscription — cancel it in Stripe before deleting, or they keep being billed.</div>
            )}
          </div>
        </Card>
      </div>
    </>
  );
}
