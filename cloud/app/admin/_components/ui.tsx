import Link from "next/link";
import type { ReactNode } from "react";
import { TIER_LABEL } from "@/lib/admin/format";
import s from "../admin.module.css";

type Params = Record<string, string | string[] | undefined>;

export function param(p: Params, k: string): string {
  const v = p[k];
  return typeof v === "string" ? v : "";
}

/** The ?ok= / ?err= banner every action redirects back with. */
export function Flash({ params }: { params: Params }) {
  const ok = param(params, "ok");
  const err = param(params, "err");
  if (err) return <div className={s.flashErr} role="alert">{err}</div>;
  if (ok) return <div className={s.flashOk} role="status">{ok}</div>;
  return null;
}

export function Tile({ label, value, foot }: { label: string; value: ReactNode; foot?: ReactNode }) {
  return (
    <div className={s.tile}>
      <div className={s.tileLabel}>{label}</div>
      <div className={s.tileValue}>{value}</div>
      {foot != null && <div className={s.tileFoot}>{foot}</div>}
    </div>
  );
}

export function TierBadge({ tier }: { tier: string }) {
  const cls = tier === "free" ? s.badge : tier === "trial" ? s.badgeWarn : tier === "pro_recall" ? s.badgeGood : s.badgeInfo;
  return <span className={cls}>{TIER_LABEL[tier] ?? tier}</span>;
}

export function Card({ title, children, right }: { title?: ReactNode; children: ReactNode; right?: ReactNode }) {
  return (
    <section className={s.card}>
      {(title || right) && (
        <div className={s.rowBetween} style={{ marginBottom: 10 }}>
          {title ? <h2 className={s.h2} style={{ margin: 0 }}>{title}</h2> : <span />}
          {right}
        </div>
      )}
      {children}
    </section>
  );
}

export function Pager({ base, params, total, limit, offset }: { base: string; params: Record<string, string>; total: number; limit: number; offset: number }) {
  if (total <= limit) return <div className={s.pager}>{total} total</div>;
  const href = (o: number) => {
    const q = new URLSearchParams({ ...params, offset: String(o) });
    for (const [k, v] of [...q.entries()]) if (!v) q.delete(k);
    return `${base}?${q.toString()}`;
  };
  return (
    <div className={s.pager}>
      <span>{offset + 1}–{Math.min(offset + limit, total)} of {total}</span>
      {offset > 0 && <Link className={s.btn} href={href(Math.max(0, offset - limit))}>← Newer</Link>}
      {offset + limit < total && <Link className={s.btn} href={href(offset + limit)}>Older →</Link>}
    </div>
  );
}

/** Hidden inputs for a form. */
export function Hidden({ values }: { values: Record<string, string> }) {
  return <>{Object.entries(values).map(([k, v]) => <input key={k} type="hidden" name={k} value={v} />)}</>;
}
