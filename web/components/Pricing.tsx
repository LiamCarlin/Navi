"use client";

import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { useState } from "react";
import { Head, Reveal } from "./motion/Reveal";
import { setSource } from "@/lib/source";
import { EASE } from "@/lib/motion";

type Plan = { id: string; name: string; blurb: string; monthly: number; yearly: number };

const PLANS: Plan[] = [
  { id: "free", name: "Free", blurb: "Everything that runs on your Mac.", monthly: 0, yearly: 0 },
  { id: "pro", name: "Pro", blurb: "For people who talk to their Mac all day.", monthly: 20, yearly: 192 },
  { id: "pro-recall", name: "Pro + Recall", blurb: "Pro, plus a memory of your screen.", monthly: 30, yearly: 288 },
];

type Cell = boolean | string;
const ROWS: [string, Cell, Cell, Cell][] = [
  ["Apps, files, settings, calculator", true, true, true],
  ["Answers in the bar", "20 a day", "Unlimited", "Unlimited"],
  ["Tasks", "5 a day", "300 a month", "300 a month"],
  ["Voice control", false, true, true],
  ["Priority routing", false, true, true],
  ["Recall: screen memory, read locally", false, false, true],
  ["Notes in a folder you own", false, false, true],
  ["“What was I doing yesterday?”", false, false, true],
  ["Free trial", false, "7 days", "7 days"],
];

export function Pricing() {
  const [yearly, setYearly] = useState(false);
  const reduce = useReducedMotion();

  const price = (p: Plan) => (
    <div className="flex h-10 items-baseline gap-1 overflow-hidden">
      <AnimatePresence mode="popLayout" initial={false}>
        <motion.span
          key={`${p.id}-${yearly}`}
          className="tnum text-[2.6rem] font-medium leading-none tracking-[-0.04em]"
          initial={reduce ? false : { y: "100%", opacity: 0 }}
          animate={{ y: 0, opacity: 1 }}
          exit={reduce ? undefined : { y: "-100%", opacity: 0 }}
          transition={{ duration: 0.45, ease: EASE }}
        >
          ${yearly ? p.yearly : p.monthly}
        </motion.span>
      </AnimatePresence>
      <span className="text-sm text-fg-dim">{p.monthly === 0 ? "forever" : yearly ? "/ year" : "/ month"}</span>
    </div>
  );

  const cta = (p: Plan) => (
    <a href="#waitlist" onClick={() => setSource(`pricing-${p.id}`)} className={`${p.id === "pro" ? "btn-primary" : "btn-secondary"} !h-10 w-full`}>
      Join the waitlist
    </a>
  );

  return (
    <section id="pricing" className="scroll-mt-16 px-4 py-24 sm:px-6 md:py-32">
      <div className="mx-auto max-w-6xl">
        <Head title={["Simple pricing"]} sub="Start free. Everything that runs on your Mac stays free. Upgrade when you hit the limits." />
          <Reveal className="mt-8 flex justify-center">
            <div role="group" aria-label="Billing period" className="relative inline-flex rounded-full bg-bg-soft p-1 text-sm ring-1 ring-line">
              {[false, true].map((y) => (
                <button
                  key={String(y)}
                  type="button"
                  aria-pressed={yearly === y}
                  onClick={() => setYearly(y)}
                  className={`relative rounded-full px-4 py-1.5 transition-colors duration-200 ${yearly === y ? "text-fg" : "text-fg-muted hover:text-fg"}`}
                >
                  {yearly === y && <motion.span layoutId="billing" className="absolute inset-0 rounded-full bg-white shadow-[0_1px_3px_rgba(0,0,0,0.12)]" transition={{ duration: 0.4, ease: EASE }} />}
                  <span className="relative">
                    {y ? "Yearly" : "Monthly"}
                    {y && <span className="tnum ml-1 text-xs opacity-70">−20%</span>}
                  </span>
                </button>
              ))}
            </div>
          </Reveal>

        {/* Desktop: a real comparison table */}
        <Reveal className="mt-16 hidden md:block">
          <table className="w-full table-fixed border-collapse text-left">
            <thead>
              <tr>
                <th className="w-[34%]" />
                {PLANS.map((p) => (
                  <th key={p.id} className={`px-6 pb-6 pt-7 align-top font-normal ${p.id === "pro" ? "rounded-t-[28px] bg-bg-soft" : ""}`}>
                    <div className="flex items-baseline justify-between">
                      <span className="text-[17px] font-medium">{p.name}</span>
                      {p.id === "pro" && <span className="rounded-full bg-accent-soft px-2 py-0.5 text-[11px] font-medium text-accent">7-day trial</span>}
                    </div>
                    <p className="mt-1 min-h-[2.6em] text-sm text-fg-muted">{p.blurb}</p>
                    <div className="mt-4">{price(p)}</div>
                    <div className="tnum mt-1 h-4 text-xs text-fg-dim">
                      {p.monthly > 0 && (yearly ? `$${(p.yearly / 12).toFixed(0)} a month, billed yearly` : `or $${p.yearly} a year`)}
                    </div>
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {ROWS.map(([label, ...cells]) => (
                <tr key={label} className="border-t border-line">
                  <th scope="row" className="py-3.5 pr-6 text-[15px] font-normal text-fg-muted">
                    {label}
                  </th>
                  {cells.map((c, i) => (
                    <td key={i} className={`px-6 py-3.5 text-[15px] ${PLANS[i].id === "pro" ? "bg-bg-soft" : ""}`}>
                      <CellView c={c} />
                    </td>
                  ))}
                </tr>
              ))}
              <tr>
                <td />
                {PLANS.map((p) => (
                  <td key={p.id} className={`px-6 pb-7 pt-4 ${p.id === "pro" ? "rounded-b-[28px] bg-bg-soft" : ""}`}>
                    {cta(p)}
                  </td>
                ))}
              </tr>
            </tbody>
          </table>
        </Reveal>

        {/* Phones: one card per plan */}
        <div className="mt-12 grid gap-4 md:hidden">
          {PLANS.map((p, pi) => (
            <Reveal key={p.id} i={pi} className={`card p-5`}>
              <div className="text-[17px] font-medium">{p.name}</div>
              <p className="mt-1 text-sm text-fg-muted">{p.blurb}</p>
              <div className="mt-4">{price(p)}</div>
              <ul className="mt-4 divide-y divide-line border-y border-line text-[14.5px]">
                {ROWS.filter((r) => r[pi + 1] !== false).map((r) => (
                  <li key={r[0]} className="flex justify-between gap-4 py-2.5">
                    <span className="text-fg-muted">{r[0]}</span>
                    <CellView c={r[pi + 1]} />
                  </li>
                ))}
              </ul>
              <div className="mt-5">{cta(p)}</div>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}

function CellView({ c }: { c: Cell }) {
  if (c === true)
    return (
      <svg viewBox="0 0 24 24" className="h-4 w-4 text-fg" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-label="Included">
        <path d="M5 12l5 5 9-10" />
      </svg>
    );
  if (c === false)
    return (
      <span className="text-fg-dim" aria-label="Not included">
        –
      </span>
    );
  return <span className="tnum shrink-0">{c}</span>;
}
