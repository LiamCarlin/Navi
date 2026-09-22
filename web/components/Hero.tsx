import { HeroLoop } from "./HeroLoop";
import { MacBook } from "./MacBook";

export function Hero() {
  return (
    <section className="relative overflow-x-clip px-6 pb-16 pt-12 sm:pt-16 md:pb-24 lg:pt-20">
      <div className="mx-auto grid max-w-6xl grid-cols-1 items-center gap-12 lg:grid-cols-12 lg:gap-8">
        <div className="lg:col-span-5">
          <h1 className="h-display rise">Say it. It’s done.</h1>
          <div className="rise" style={{ "--rise-delay": "80ms" } as React.CSSProperties}>
            <p className="lede mt-6 text-lg">
              Navi opens apps, answers questions, and does things on your Mac — by keyboard or voice, in under a
              second.
            </p>
          </div>
          <div className="rise" style={{ "--rise-delay": "120ms" } as React.CSSProperties}>
            <div className="mt-8 flex flex-col gap-3 sm:flex-row">
              <a href="#waitlist" className="btn-primary w-full sm:w-auto">
                Join the waitlist
              </a>
              <a href="#does" className="btn-secondary w-full sm:w-auto">
                See how it works ↓
              </a>
            </div>
          </div>
          <p className="rise mt-5 text-sm text-fg-dim" style={{ "--rise-delay": "160ms" } as React.CSSProperties}>
            Private beta · macOS 26 · Apple silicon
          </p>
          <p className="rise mt-10 text-sm text-fg-muted" style={{ "--rise-delay": "200ms" } as React.CSSProperties}>
            <span className="keycap">⌥ Space</span> to talk · <span className="keycap">⌘ Space</span> to type.
          </p>
        </div>

        {/* On phones the laptop runs wider than the viewport so the screen stays legible; the section clips it. */}
        <div className="rise w-[134%] -translate-x-[12.7%] sm:w-full sm:translate-x-0 lg:col-span-7" style={{ "--rise-delay": "100ms" } as React.CSSProperties}>
          <MacBook>
            <HeroLoop />
          </MacBook>
        </div>
      </div>
    </section>
  );
}
