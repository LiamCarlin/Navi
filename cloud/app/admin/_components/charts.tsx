/**
 * Server-rendered inline-SVG charts (no chart library). One y-axis per chart; hover
 * tooltips are native <title>s on a full-height hit target per day.
 */

import type { DayPoint } from "@/lib/admin/overview";
import { usd } from "@/lib/admin/format";
import s from "../admin.module.css";

const W = 720;
const PAD = { l: 48, r: 8, t: 8, b: 22 };

function niceMax(v: number): number {
  if (!(v > 0)) return 1;
  const p = 10 ** Math.floor(Math.log10(v));
  for (const m of [1, 2, 2.5, 5, 10]) if (m * p >= v) return m * p;
  return 10 * p;
}

function Axis({ max, h, fmt }: { max: number; h: number; fmt: (n: number) => string }) {
  const ticks = [0, 0.25, 0.5, 0.75, 1];
  return (
    <g>
      {ticks.map((t) => {
        const y = PAD.t + (h - PAD.t - PAD.b) * (1 - t);
        return (
          <g key={t}>
            <line className={s.chartGrid} x1={PAD.l} x2={W - PAD.r} y1={y} y2={y} />
            <text className={s.chartAxis} x={PAD.l - 6} y={y + 3} textAnchor="end">{fmt(max * t)}</text>
          </g>
        );
      })}
    </g>
  );
}

function XLabels({ days, h }: { days: DayPoint[]; h: number }) {
  const step = (W - PAD.l - PAD.r) / days.length;
  return (
    <g>
      {days.map((d, i) =>
        i % 7 === (days.length - 1) % 7 ? (
          <text key={d.day} className={s.chartAxis} x={PAD.l + step * (i + 0.5)} y={h - 6} textAnchor="middle">{d.day.slice(5)}</text>
        ) : null,
      )}
    </g>
  );
}

/** Daily vendor cost (bars) against revenue run-rate (line), both USD/day on one axis. */
export function CostRevenueChart({ days }: { days: DayPoint[] }) {
  const h = 200;
  const max = niceMax(Math.max(...days.map((d) => Math.max(d.costUsd, d.revenueUsd)), 0.0001) * 1.1);
  const plotH = h - PAD.t - PAD.b;
  const step = (W - PAD.l - PAD.r) / days.length;
  const barW = Math.max(2, step - 2);
  const y = (v: number) => PAD.t + plotH * (1 - v / max);
  const line = days.map((d, i) => `${i ? "L" : "M"}${(PAD.l + step * (i + 0.5)).toFixed(1)},${y(d.revenueUsd).toFixed(1)}`).join(" ");
  return (
    <div>
      <div className={s.legend}>
        <span><span className={s.swatch} style={{ background: "var(--series-2)" }} />Vendor cost / day</span>
        <span><span className={s.swatchLine} style={{ background: "var(--series-1)" }} />Revenue / day (MRR run-rate)</span>
      </div>
      <svg className={s.chart} viewBox={`0 0 ${W} ${h}`} role="img" aria-label="Vendor cost per day versus revenue per day, last 30 days">
        <Axis max={max} h={h} fmt={(n) => usd(n, max >= 10 ? 0 : 2)} />
        {days.map((d, i) => {
          const x = PAD.l + step * i + 1;
          const top = y(d.costUsd);
          return (
            <g key={d.day} className={s.bar}>
              {d.costUsd > 0 && <rect x={x} y={top} width={barW} height={Math.max(1, PAD.t + plotH - top)} rx={2} fill="var(--series-2)" />}
              <rect x={PAD.l + step * i} y={PAD.t} width={step} height={plotH} fill="transparent">
                <title>{`${d.day}\nCost ${usd(d.costUsd)} · revenue ${usd(d.revenueUsd)}\n${d.runs} runs · ${d.activeUsers} active users`}</title>
              </rect>
            </g>
          );
        })}
        <path d={line} fill="none" stroke="var(--series-1)" strokeWidth={2} pointerEvents="none" />
        <XLabels days={days} h={h} />
      </svg>
    </div>
  );
}

/** One series per day as bars (active users, signups). */
export function DayBars({ days, pick, label, color = "var(--series-1)" }: { days: DayPoint[]; pick: (d: DayPoint) => number; label: string; color?: string }) {
  const h = 130;
  const max = niceMax(Math.max(...days.map(pick), 1));
  const plotH = h - PAD.t - PAD.b;
  const step = (W - PAD.l - PAD.r) / days.length;
  return (
    <svg className={s.chart} viewBox={`0 0 ${W} ${h}`} role="img" aria-label={`${label} per day, last 30 days`}>
      <Axis max={max} h={h} fmt={(n) => (Number.isInteger(n) ? String(n) : n.toFixed(1))} />
      {days.map((d, i) => {
        const v = pick(d);
        const top = PAD.t + plotH * (1 - v / max);
        return (
          <g key={d.day} className={s.bar}>
            {v > 0 && <rect x={PAD.l + step * i + 1} y={top} width={Math.max(2, step - 2)} height={PAD.t + plotH - top} rx={2} fill={color} />}
            <rect x={PAD.l + step * i} y={PAD.t} width={step} height={plotH} fill="transparent">
              <title>{`${d.day}: ${v} ${label.toLowerCase()}`}</title>
            </rect>
          </g>
        );
      })}
      <XLabels days={days} h={h} />
    </svg>
  );
}

/** Tier mix as one stacked bar with a legend that carries the counts. */
export function TierMix({ mix }: { mix: Record<"free" | "trial" | "pro" | "pro_recall", number> }) {
  const parts = [
    { k: "pro_recall", label: "Pro + Recall", color: "var(--series-3)" },
    { k: "pro", label: "Pro", color: "var(--series-1)" },
    { k: "trial", label: "Trial", color: "var(--series-4)" },
    { k: "free", label: "Free", color: "#55555f" },
  ] as const;
  const total = parts.reduce((n, p) => n + mix[p.k], 0);
  let x = 0;
  return (
    <div>
      <div className={s.legend}>
        {parts.map((p) => (
          <span key={p.k}><span className={s.swatch} style={{ background: p.color }} />{p.label} · {mix[p.k]}{total ? ` (${Math.round((mix[p.k] / total) * 100)}%)` : ""}</span>
        ))}
      </div>
      <svg className={s.chart} viewBox="0 0 720 18" role="img" aria-label="Users by effective tier">
        {total === 0 && <rect x={0} y={0} width={720} height={18} rx={4} fill="var(--line)" />}
        {parts.map((p) => {
          const w = total ? (mix[p.k] / total) * 720 : 0;
          const rect = w > 0 ? (
            <rect key={p.k} x={x} y={0} width={Math.max(1, w - 2)} height={18} rx={3} fill={p.color}>
              <title>{`${p.label}: ${mix[p.k]}`}</title>
            </rect>
          ) : null;
          x += w;
          return rect;
        })}
      </svg>
    </div>
  );
}
