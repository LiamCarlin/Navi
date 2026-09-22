import { PanelDemo } from "./PanelDemo";
import { Reveal } from "./Reveal";

export function Hero() {
  return (
    <section className="relative px-4 pb-20 pt-16 sm:px-6 sm:pt-24 md:pb-28 md:pt-28">
      <div className="mx-auto max-w-4xl text-center">
        <Reveal>
          <p className="mx-auto mb-6 inline-flex items-center gap-2 rounded-full border border-line bg-glass px-3 py-1 text-xs text-fg-muted">
            <span className="h-1.5 w-1.5 rounded-full bg-accent shadow-[0_0_10px_var(--accent)]" />
            Now in private beta for macOS
          </p>
        </Reveal>
        <Reveal delay={0.05}>
          <h1 className="text-balance text-4xl font-semibold tracking-[-0.03em] sm:text-6xl md:text-7xl">
            Press{" "}
            <span className="inline-flex items-baseline gap-1 rounded-xl border border-line-strong bg-glass px-2 align-baseline text-[0.85em] shadow-[inset_0_-2px_0_rgba(0,0,0,0.4)]">
              <span className="text-accent">⌘</span>Space
            </span>
            .<br />
            Say what you want.
          </h1>
        </Reveal>
        <Reveal delay={0.1}>
          <p className="mx-auto mt-6 max-w-2xl text-balance text-lg text-fg-muted sm:text-xl">
            Navi opens apps, answers questions, and does things on your Mac — in under a second.
          </p>
        </Reveal>
        <Reveal delay={0.15}>
          <div className="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
            <a
              href="#waitlist"
              className="w-full rounded-full bg-fg px-6 py-3 text-sm font-medium text-bg transition-transform hover:scale-[1.03] active:scale-[0.98] sm:w-auto"
            >
              Join the waitlist
            </a>
            <a
              href="#features"
              className="w-full rounded-full border border-line-strong bg-glass px-6 py-3 text-sm font-medium text-fg transition-colors hover:border-accent/50 sm:w-auto"
            >
              See what it does
            </a>
          </div>
        </Reveal>
      </div>

      <Reveal delay={0.25} className="mt-14 sm:mt-20">
        <PanelDemo />
      </Reveal>
    </section>
  );
}
