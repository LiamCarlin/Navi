/** Display helpers for the admin console (pure). */

import { env } from "../env";

export function usd(n: number, digits?: number): string {
  const d = digits ?? (Math.abs(n) >= 100 ? 0 : Math.abs(n) >= 1 ? 2 : Math.abs(n) >= 0.01 ? 3 : 5);
  return `$${n.toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d })}`;
}

export function int(n: number): string {
  return n.toLocaleString("en-US");
}

export function dateTime(iso: string | null | undefined): string {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toISOString().replace("T", " ").slice(0, 16) + " UTC";
}

export function dateOnly(iso: string | null | undefined): string {
  return iso ? iso.slice(0, 10) : "—";
}

export function ago(iso: string | null | undefined, now = new Date()): string {
  if (!iso) return "never";
  const s = Math.round((now.getTime() - new Date(iso).getTime()) / 1000);
  if (!Number.isFinite(s)) return "—";
  const future = s < 0;
  const a = Math.abs(s);
  const v = a < 60 ? `${a}s` : a < 3600 ? `${Math.round(a / 60)}m` : a < 86_400 ? `${Math.round(a / 3600)}h` : `${Math.round(a / 86_400)}d`;
  return future ? `in ${v}` : `${v} ago`;
}

export function stripeCustomerUrl(customerId: string): string {
  const test = (env.stripeSecretKey ?? "").startsWith("sk_test") || !env.stripeSecretKey;
  return `https://dashboard.stripe.com/${test ? "test/" : ""}customers/${encodeURIComponent(customerId)}`;
}

/** RFC 4180 field, with spreadsheet-formula injection defused. */
export function csvField(v: string | null | undefined): string {
  let s = v ?? "";
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

/** Appends ?ok= / ?err= for the flash banner, keeping other params. */
export function withFlash(path: string, ok: boolean, message: string): string {
  const [base, query = ""] = path.split("?");
  const p = new URLSearchParams(query);
  p.delete("ok");
  p.delete("err");
  p.set(ok ? "ok" : "err", message.slice(0, 300));
  return `${base}?${p.toString()}`;
}

export const TIER_LABEL: Record<string, string> = { free: "Free", trial: "Trial", pro: "Pro", pro_recall: "Pro + Recall" };
