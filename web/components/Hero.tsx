import { HeroLoop } from "./HeroLoop";
import { MacBook } from "./MacBook";

export function Hero() {
  return (
    <section className="relative overflow-x-clip px-4 pb-16 pt-10 sm:px-6 sm:pt-14 md:pb-24 lg:pt-16">
      <div className="grain" aria-hidden="true" />
      <div
        className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-[70vh] bg-[radial-gradient(55%_50%_at_50%_0%,rgba(139,140,248,0.14),transparent_70%)]"
        aria-hidden="true"
      />

      <div className="mx-auto grid max-w-6xl grid-cols-1 items-center gap-10 lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)] lg:gap-12">
        <div className="mx-auto max-w-2xl text-center lg:mx-0 lg:max-w-none lg:text-left">
          <div className="rise">
            <p className="mb-6 inline-flex items-center gap-2 rounded-full border border-line bg-glass px-3 py-1 text-xs text-fg-muted">
              <span className="h-1.5 w-1.5 rounded-full bg-accent shadow-[0_0_8px_var(--accent)]" />
              Private beta for macOS
            </p>
          </div>
          <h1 className="h-display rise" style={{ "--rise-delay": "40ms" } as React.CSSProperties}>
            Say it. It’s done.
          </h1>
          <div className="rise" style={{ "--rise-delay": "80ms" } as React.CSSProperties}>
            <p className="lede mx-auto mt-5 max-w-xl text-lg lg:mx-0">
              Navi opens apps, answers questions, and does things on your Mac — by keyboard or voice, in under a
              second.
            </p>
          </div>
          <div className="rise" style={{ "--rise-delay": "120ms" } as React.CSSProperties}>
            <div className="mt-8 flex flex-col items-center gap-3 sm:flex-row sm:justify-center lg:justify-start">
              <a href="#waitlist" className="btn-primary w-full sm:w-auto">
                Join the waitlist
              </a>
              <a href="#does" className="btn-secondary w-full sm:w-auto">
                See how it works ↓
              </a>
            </div>
          </div>
          <p className="rise mt-8 text-sm text-fg-dim" style={{ "--rise-delay": "160ms" } as React.CSSProperties}>
            <span className="keycap">⌥ Space</span> to talk · <span className="keycap">⌘ Space</span> to type.
          </p>
        </div>

        {/* On phones the laptop runs wider than the viewport so the screen stays legible; the section clips it. */}
        <div className="rise w-[134%] -translate-x-[12.7%] sm:w-full sm:translate-x-0" style={{ "--rise-delay": "100ms" } as React.CSSProperties}>
          <MacBook>
            <HeroLoop />
          </MacBook>
        </div>
      </div>
    </section>
  );
}
