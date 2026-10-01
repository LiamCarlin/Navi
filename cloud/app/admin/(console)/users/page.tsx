import Link from "next/link";
import { ago, dateOnly } from "@/lib/admin/format";
import { requireAdmin } from "@/lib/admin/guard";
import { getDb } from "@/lib/db";
import { effectiveTier, isInTrial } from "@/lib/plans";
import { Flash, Pager, param, TierBadge } from "../../_components/ui";
import s from "../../admin.module.css";

export const dynamic = "force-dynamic";
const LIMIT = 50;

export default async function Users({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  await requireAdmin();
  const params = await searchParams;
  const q = param(params, "q");
  const offset = Math.max(0, Number(param(params, "offset")) || 0);
  const db = await getDb();
  const { rows, total } = await db.adminListProfiles({ query: q, limit: LIMIT, offset });
  const now = new Date();

  return (
    <>
      <h1 className={s.h1}>Users</h1>
      <p className={s.sub}>Search by email (or paste a user id).</p>
      <Flash params={params} />
      <form className={s.row} style={{ marginBottom: 12 }} action="/admin/users">
        <input className={s.inputWide} name="q" defaultValue={q} placeholder="email contains…" autoFocus />
        <button className={s.btn} type="submit">Search</button>
        {q && <Link className={s.btn} href="/admin/users">Clear</Link>}
      </form>
      <div className={s.card} style={{ padding: 0, overflowX: "auto" }}>
        <table className={s.table}>
          <thead>
            <tr>
              <th>Email</th>
              <th>Served as</th>
              <th>Paid tier</th>
              <th>Subscription</th>
              <th>Trial ends</th>
              <th>Signed up</th>
              <th>Flags</th>
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 && (
              <tr><td colSpan={7} className={s.muted}>No users{q ? ` matching “${q}”` : " yet"}.</td></tr>
            )}
            {rows.map((p) => (
              <tr key={p.userId}>
                <td><Link href={`/admin/users/${p.userId}`}>{p.email || <span className={s.muted}>(no email)</span>}</Link></td>
                <td><TierBadge tier={isInTrial(p, now) ? "trial" : effectiveTier(p, now)} /></td>
                <td>{p.tier}</td>
                <td>{p.subscriptionStatus ?? <span className={s.muted}>—</span>}</td>
                <td>{p.trialEndsAt ? `${dateOnly(p.trialEndsAt)} (${ago(p.trialEndsAt, now)})` : <span className={s.muted}>—</span>}</td>
                <td title={p.createdAt}>{dateOnly(p.createdAt)}</td>
                <td className={s.row}>
                  {p.disabledAt && <span className={s.badgeBad}>disabled</span>}
                  {p.tierOverride && <span className={s.badgeInfo}>override: {p.tierOverride}</span>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <Pager base="/admin/users" params={{ q }} total={total} limit={LIMIT} offset={offset} />
    </>
  );
}
