import Link from "next/link";
import { ago, dateOnly } from "@/lib/admin/format";
import { requireAdmin } from "@/lib/admin/guard";
import { getDb } from "@/lib/db";
import { inviteAction, markInvitedAction } from "../../actions";
import { Flash, Hidden, Pager, param } from "../../_components/ui";
import s from "../../admin.module.css";

export const dynamic = "force-dynamic";
const LIMIT = 100;

export default async function Waitlist({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  await requireAdmin();
  const params = await searchParams;
  const q = param(params, "q");
  const offset = Math.max(0, Number(param(params, "offset")) || 0);
  const db = await getDb();
  const { rows, total } = await db.adminListWaitlist({ query: q, limit: LIMIT, offset });
  const now = new Date();
  const exportHref = `/admin/waitlist/export${q ? `?q=${encodeURIComponent(q)}` : ""}`;

  return (
    <>
      <div className={s.rowBetween}>
        <div>
          <h1 className={s.h1}>Waitlist</h1>
          <p className={s.sub}>{total} {q ? `matching “${q}”` : "people"}. “Invite” sends the Supabase invite email and marks them invited.</p>
        </div>
        <a className={s.btn} href={exportHref}>Export CSV</a>
      </div>
      <Flash params={params} />
      <form className={s.row} style={{ marginBottom: 12 }} action="/admin/waitlist">
        <input className={s.inputWide} name="q" defaultValue={q} placeholder="email contains…" />
        <button className={s.btn} type="submit">Search</button>
        {q && <Link className={s.btn} href="/admin/waitlist">Clear</Link>}
      </form>
      <div className={s.card} style={{ padding: 0, overflowX: "auto" }}>
        <table className={s.table}>
          <thead><tr><th>Email</th><th>Source</th><th>Note</th><th>Joined</th><th>Invited</th><th /></tr></thead>
          <tbody>
            {rows.length === 0 && <tr><td colSpan={6} className={s.muted}>Nobody here{q ? ` matching “${q}”` : " yet"}.</td></tr>}
            {rows.map((w) => (
              <tr key={w.email}>
                <td>{w.email}</td>
                <td>{w.source ?? <span className={s.muted}>—</span>}</td>
                <td className={s.muted} style={{ maxWidth: 280 }}>{w.note ?? ""}</td>
                <td title={w.createdAt}>{dateOnly(w.createdAt)}</td>
                <td>{w.invitedAt ? <span className={s.badgeGood}>{ago(w.invitedAt, now)}</span> : <span className={s.muted}>—</span>}</td>
                <td className={s.num}>
                  <div className={s.row} style={{ justifyContent: "flex-end" }}>
                    <form action={inviteAction}><Hidden values={{ email: w.email, q }} /><button className={s.btn}>{w.invitedAt ? "Re-invite" : "Invite"}</button></form>
                    {!w.invitedAt && (
                      <form action={markInvitedAction}><Hidden values={{ email: w.email, q }} /><button className={s.btn} title="Mark invited without sending an email">Mark invited</button></form>
                    )}
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <Pager base="/admin/waitlist" params={{ q }} total={total} limit={LIMIT} offset={offset} />
    </>
  );
}
