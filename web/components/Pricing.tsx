"use client";

import { useState } from "react";
import { Reveal } from "./Reveal";

type Plan = {
  name: string;
  blurb: string;
  monthly: number;
  yearly: number;
  features: string[];
  featured?: boolean;
  cta: string;
};

const plans: Plan[] = [
  {
    name: "Free",
    blurb: "Everything that runs on your Mac, for nothing.",
    monthly: 0,
    yearly: 0,
    features: ["Apps, files, calculator, system toggles", "20 answers a day", "5 tasks a day", "No card needed"],
    cta: "Join the waitlist",
  },
  {
    name: "Pro",
    blurb: "For people who talk to their Mac all day.",
    monthly: 20,
    yearly: 192,
    features: ["Unlimited answers", "300 tasks a month", "Voice control", "Priority routing", "7-day free trial"],
    featured: true,
    cta: "Join the waitlist",
  },
  {
    name: "Pro + Recall",
    blurb: "Pro, plus a memory of everything on your screen.",
    monthly: 30,
    yearly: 288,
    features: ["Everything in Pro", "Screen memory, read locally", "Obsidian vault you own", "“What was I doing yesterday?”"],
    cta: "Join the waitlist",
  },
];

export function Pricing() {
  const [yearly, setYearly] = useState(false);

  return (
    <section id="pricing" className="scroll-mt-20 px-4 py-20 sm:px-6 md:py-28">
      <div className="mx-auto max-w-6xl">
        <Reveal>
          <div className="flex flex-col items-start justify-between gap-6 md:flex-row md:items-end">
            <div>
              <h2 className="text-balance text-3xl font-semibold tracking-tight sm:text-4xl">
                One app. One subscription.
              </h2>
              <p className="mt-3 max-w-xl text-fg-muted">
                No API keys, no model pickers. Start free and upgrade when you hit the wall.
              </p>
            </div>
            <div
              role="group"
              aria-label="Billing period"
              className="inline-flex rounded-full border border-line bg-glass p-1 text-sm"
            >
              <Toggle active={!yearly} onClick={() => setYearly(false)}>
                Monthly
              </Toggle>
              <Toggle active={yearly} onClick={() => setYearly(true)}>
                Yearly <span className="ml-1 text-xs text-accent">−20%</span>
              </Toggle>
            </div>
          </div>
        </Reveal>

        <div className="mt-12 grid gap-5 md:grid-cols-3">
          {plans.map((p, i) => (
            <Reveal key={p.name} delay={i * 0.08}>
              <article
                className={`card flex h-full flex-col p-6 ${p.featured ? "gradient-border bg-accent-soft/20" : ""}`}
              >
                <div className="flex items-center justify-between">
                  <h3 className="text-lg font-semibold">{p.name}</h3>
                  {p.featured && (
                    <span className="rounded-full bg-accent px-2 py-0.5 text-[11px] font-medium text-bg">Popular</span>
                  )}
                </div>
                <p className="mt-1 text-sm text-fg-muted">{p.blurb}</p>
                <div className="mt-6 flex items-baseline gap-1">
                  <span className="text-4xl font-semibold tracking-tight">
                    ${yearly ? p.yearly : p.monthly}
                  </span>
                  <span className="text-sm text-fg-dim">
                    {p.monthly === 0 ? "forever" : yearly ? "/ year" : "/ month"}
                  </span>
                </div>
                {p.monthly > 0 && (
                  <div className="mt-1 h-4 text-xs text-fg-dim">
                    {yearly ? `$${(p.yearly / 12).toFixed(0)} a month, billed yearly` : `or $${p.yearly} a year`}
                  </div>
                )}
                {p.monthly === 0 && <div className="mt-1 h-4" />}
                <ul className="mt-6 flex-1 space-y-2.5 text-sm">
                  {p.features.map((f) => (
                    <li key={f} className="flex gap-2 text-fg-muted">
                      <span className="mt-[3px] text-accent">✦</span>
                      <span>{f}</span>
                    </li>
                  ))}
                </ul>
                <a
                  href="#waitlist"
                  className={`mt-8 block rounded-full px-4 py-2.5 text-center text-sm font-medium transition-transform hover:scale-[1.02] active:scale-[0.98] ${
                    p.featured ? "bg-fg text-bg" : "border border-line-strong bg-glass text-fg"
                  }`}
                >
                  {p.cta}
                </a>
              </article>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}

function Toggle({
  active,
  onClick,
  children,
}: {
  active: boolean;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      aria-pressed={active}
      onClick={onClick}
      className={`rounded-full px-4 py-1.5 transition-colors ${active ? "bg-fg text-bg" : "text-fg-muted hover:text-fg"}`}
    >
      {children}
    </button>
  );
}
