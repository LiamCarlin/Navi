import { Glyph } from "./Glyph";
import { Lines, Reveal } from "./motion/Reveal";
import { WaitlistCount } from "./WaitlistCount";
import { WaitlistForm } from "./WaitlistForm";

export function Waitlist() {
  return (
    <section id="waitlist" className="scroll-mt-16 px-4 pb-24 sm:px-6 md:pb-36">
      <div className="mx-auto max-w-7xl overflow-hidden rounded-[28px] border border-line bg-bg-elev">
        <div className="h-[3px] w-full" style={{ background: "var(--grad)" }} />
        <div className="grid grid-cols-1 gap-10 p-6 sm:p-10 lg:grid-cols-12 lg:gap-8 lg:p-14">
          <div className="lg:col-span-6">
            <Glyph gradient className="mb-6 h-7 w-7" />
            <Lines className="h-section" lines={["Get Navi first."]} />
            <Reveal>
              <p className="lede mt-5">
                Invites go out in order as builds are ready. Tell us what you’d hand off first and we’ll move
                you up.
              </p>
            </Reveal>
          </div>
          <Reveal className="lg:col-span-5 lg:col-start-8 lg:self-end">
            <WaitlistForm source="waitlist" note takePending />
            <p className="label mt-4">No spam. One email when it’s your turn.</p>
            <WaitlistCount className="mt-2" />
          </Reveal>
        </div>
      </div>
    </section>
  );
}
