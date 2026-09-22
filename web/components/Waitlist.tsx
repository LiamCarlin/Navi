import { Glyph } from "./Glyph";
import { WaitlistForm } from "./WaitlistForm";

export function Waitlist() {
  return (
    <section id="waitlist" className="scroll-mt-16 px-6 py-24 md:py-32">
      <div className="mx-auto grid max-w-7xl grid-cols-1 gap-8 border-t border-line pt-12 lg:grid-cols-12">
        <div className="lg:col-span-5">
          <Glyph className="mb-5 h-6 w-6 text-accent" />
          <h2 className="h-section">Get Navi first.</h2>
          <p className="lede mt-5">Invites go out in order. Tell us what you’d use it for and we’ll move you up.</p>
        </div>
        <div className="lg:col-span-6 lg:col-start-7">
          <WaitlistForm source="waitlist" note takePending />
          <p className="mt-3 text-xs text-fg-dim">No spam. One email when it’s your turn.</p>
        </div>
      </div>
    </section>
  );
}
