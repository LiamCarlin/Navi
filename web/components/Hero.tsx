import { LiveBar } from "./bar/LiveBar";
import { WaitlistCount } from "./WaitlistCount";
import { WaitlistForm } from "./WaitlistForm";

const d = (ms: number) => ({ "--rise-delay": `${ms}ms` }) as React.CSSProperties;

export function Hero() {
  return (
    <section className="relative px-4 pb-8 pt-10 sm:px-6 sm:pt-16 lg:pt-20">
      <div className="mx-auto max-w-7xl">
        <div className="grid grid-cols-1 gap-10 lg:grid-cols-12 lg:items-end lg:gap-8">
          <h1 className="h-display lg:col-span-7">
            <span className="line-mask">
              <span style={d(0)}>
                <span className="keycap-xl">⌘</span> <span className="keycap-xl">space</span>,
              </span>
            </span>
            <span className="line-mask">
              <span style={d(90)}>
                but it <span className="ital">does</span> things.
              </span>
            </span>
          </h1>
          <div className="lg:col-span-5 lg:pb-2">
            <p className="lede rise" style={d(200)}>
              Navi takes over ⌘Space on your Mac. It opens apps as fast as Spotlight, answers questions right in the bar, and
              takes on small jobs like “text Sam I’m 10 minutes late”, doing them in the app while you keep working in yours.
            </p>
            <div className="rise mt-7" style={d(280)}>
              <WaitlistForm source="hero" compact />
              <WaitlistCount className="mt-3" />
            </div>
            <p className="label rise mt-4" style={d(340)}>
              Private beta · macOS 26 Tahoe · Apple silicon
            </p>
          </div>
        </div>

        <div className="rise mt-12 sm:mt-16" style={d(380)}>
          <LiveBar />
        </div>
      </div>
    </section>
  );
}
