import Link from "next/link";
import { dateTime } from "@/lib/admin/format";
import { requireAdmin } from "@/lib/admin/guard";
import { getDb } from "@/lib/db";
import { Pager, param } from "../../_components/ui";
import s from "../../admin.module.css";

export const dynamic = "force-dynamic";
const LIMIT = 100;

export default async function Audit({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  await requireAdmin();
  const params = await searchParams;
  const q = param(params, "q");
  const offset = Math.max(0, Number(param(params, "offset")) || 0);
  const { rows, total } = await (await getDb()).adminListAudit({ query: q, limit: LIMIT, offset });

  return (
    <>
      <h1 className={s.h1}>Audit log</h1>
      <p className={s.sub}>Every admin action, newest first. Details are metadata only (never key material).</p>
      <form className={s.row} style={{ marginBottom: 12 }} action="/admin/audit">
        <input className={s.inputWide} name="q" defaultValue={q} placeholder="actor, action or target contains…" />
        <button className={s.btn} type="submit">Search</button>
        {q && <Link className={s.btn} href="/admin/audit">Clear</Link>}
      </form>
      <div className={s.card} style={{ padding: 0, overflowX: "auto" }}>
        <table className={s.table}>
          <thead><tr><th>When</th><th>Admin</th><th>Action</th><th>Target</th><th>Details</th></tr></thead>
          <tbody>
            {rows.length === 0 && <tr><td colSpan={5} className={s.muted}>Nothing logged{q ? ` matching “${q}”` : " yet"}.</td></tr>}
            {rows.map((e) => (
              <tr key={e.id ?? `${e.at}-${e.action}`}>
                <td style={{ whiteSpace: "nowrap" }}>{dateTime(e.at)}</td>
                <td>{e.actor}</td>
                <td><code>{e.action}</code></td>
                <td>{e.target ?? <span className={s.muted}>—</span>}</td>
                <td className={s.details}>{Object.keys(e.details).length ? JSON.stringify(e.details) : ""}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <Pager base="/admin/audit" params={{ q }} total={total} limit={LIMIT} offset={offset} />
    </>
  );
}
