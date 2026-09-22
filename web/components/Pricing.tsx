"use client";

import { useState } from "react";
import { setSource } from "@/lib/source";

type Plan = {
  name: string;
  blurb: string;
  monthly: number;
  yearly: number;
  features: string[];
  featured?: boolean;
  id: string;
};

const plans: Plan[] = [
  {
    id: "free",
    name: "Free",
    blurb: "Everything that runs on your Mac.",
    monthly: 0,
    yearly: 0,
    features: ["Apps, files, calculator, system toggles", "20 answers a day", "5 tasks a day", "No card needed"],
  },
  {
    id: "pro",
    name: "Pro",
    blurb: "For people who talk to their Mac all day.",
    monthly: 20,
    yearly: 192,
    features: ["Unlimited answers", "300 tasks a month", "Voice control", "Priority routing", "7-day free trial"],
    featured: true,
  },
  {
    id: "pro-recall",
    name: "Pro + Recall",
    blurb: "Pro, plus a memory of your screen.",
    monthly: 30,
    yearly: 288,
    features: ["Everything in Pro", "Screen memory, read locally", "Notes in a vault you own", "“What was I doing yesterday?”"],
  },
];

export function Pricing() {
  const [yearly, setYearly] = useState(false);

  return (
    <section id="pricing" className="scroll-mt-16 px-6 py-24 md:py-32">
      <div className="mx-auto max-w-7xl">
        <div className="grid grid-cols-1 gap-8 lg:grid-cols-12">
          <div className="lg:col-span-5">
            <h2 className="h-section">One app. One subscription.</h2>
            <p className="lede mt-5">No API keys, no model pickers. Start free; upgrade when you hit the wall.</p>
          </div>
          <div className="flex items-end lg:col-span-7 lg:justify-end">
            <div role="group" aria-label="Billing period" className="inline-flex rounded-full border border-line p-1 text-sm">
              <Toggle active={!yearly} onClick={() => setYearly(false)}>
                Monthly
              </Toggle>
              <Toggle active={yearly} onClick={() => setYearly(true)}>
                Yearly <span className="tnum ml-1 text-xs text-fg-dim">−20%</span>
              </Toggle>
            </div>
          </div>
        </div>

        <div className="mt-12 grid grid-cols-1 gap-4 md:grid-cols-3 md:gap-6">
          {plans.map((p) => (
            <article key={p.name} className={`card flex h-full flex-col p-6 ${p.featured ? "border-fg/40" : ""}`}>
              <div className="flex items-baseline justify-between">
                <h3 className="h-card">{p.name}</h3>
                {p.featured && <span className="text-[13px] text-fg-dim">Most people</span>}
              </div>
              <p className="mt-1 text-sm text-fg-muted">{p.blurb}</p>
              <div className="mt-6 flex items-baseline gap-1">
                <span className="tnum text-[32px] font-semibold leading-none tracking-[-0.02em]">${yearly ? p.yearly : p.monthly}</span>
                <span className="text-sm text-fg-dim">{p.monthly === 0 ? "forever" : yearly ? "/ year" : "/ month"}</span>
              </div>
              <div className="tnum mt-1 h-4 text-xs text-fg-dim">
                {p.monthly > 0 && (yearly ? `$${(p.yearly / 12).toFixed(0)} a month, billed yearly` : `or $${p.yearly} a year`)}
              </div>
              <ul className="mt-6 flex-1 divide-y divide-line border-y border-line text-sm">
                {p.features.map((f) => (
                  <li key={f} className="py-2.5 text-fg-muted">
                    {f}
                  </li>
                ))}
              </ul>
              <a href="#waitlist" onClick={() => setSource(`pricing-${p.id}`)} className={`mt-6 !h-10 ${p.featured ? "btn-primary" : "btn-secondary"}`}>
                Join the waitlist
              </a>
            </article>
          ))}
        </div>
      </div>
    </section>
  );
}

function Toggle({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      type="button"
      aria-pressed={active}
      onClick={onClick}
      className={`rounded-full px-4 py-1.5 transition-colors duration-150 ${active ? "bg-fg text-bg" : "text-fg-muted hover:text-fg"}`}
    >
      {children}
    </button>
  );
}
