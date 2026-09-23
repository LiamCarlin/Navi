import { HeroVideo } from "./HeroVideo";
import { MacBook } from "./MacBook";
import { WaitlistCount } from "./WaitlistCount";
import { WaitlistForm } from "./WaitlistForm";

export function Hero() {
  return (
    <section className="relative overflow-x-clip px-6 pb-16 pt-12 sm:pt-16 md:pb-24 lg:pt-20">
      <div className="mx-auto grid max-w-7xl grid-cols-1 items-center gap-12 lg:grid-cols-12 lg:gap-8">
        <div className="lg:col-span-5">
          <h1 className="h-display rise">Say it. It’s done.</h1>
          <div className="rise" style={{ "--rise-delay": "80ms" } as React.CSSProperties}>
            <p className="lede mt-6 text-lg">
              Navi opens apps, answers questions, and does things on your Mac — by keyboard or voice, in under a
              second.
            </p>
          </div>
          <div className="rise mt-8 max-w-md" style={{ "--rise-delay": "120ms" } as React.CSSProperties}>
            <WaitlistForm source="hero" compact />
            <WaitlistCount className="mt-3" />
          </div>
          <div className="rise mt-5 flex flex-wrap items-center gap-x-5 gap-y-2 text-sm" style={{ "--rise-delay": "160ms" } as React.CSSProperties}>
            <a href="#does" className="navlink !text-fg">
              See how it works ↓
            </a>
            <span className="text-fg-dim">Private beta · macOS 26 · Apple silicon</span>
          </div>
          <p className="rise mt-10 text-sm text-fg-muted" style={{ "--rise-delay": "200ms" } as React.CSSProperties}>
            <span className="keycap">⌥ Space</span> to talk · <span className="keycap">⌘ Space</span> to type.
          </p>
        </div>

        {/* On phones the laptop runs wider than the viewport so the screen stays legible; the section clips it. */}
        <div className="rise w-[134%] -translate-x-[12.7%] sm:w-full sm:translate-x-0 lg:col-span-7" style={{ "--rise-delay": "100ms" } as React.CSSProperties}>
          <MacBook>
            <HeroVideo />
          </MacBook>
        </div>
      </div>
    </section>
  );
}
