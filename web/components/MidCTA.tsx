import { WaitlistForm } from "./WaitlistForm";

/** A single line between sections: the ask, and the field. */
export function MidCTA({ source }: { source: string }) {
  return (
    <div className="px-6">
      <div className="mx-auto flex max-w-7xl flex-col gap-4 border-y border-line py-6 lg:grid lg:grid-cols-12 lg:items-center lg:gap-8">
        <p className="text-[17px] text-fg lg:col-span-5">
          Want this on your Mac? <span className="text-fg-muted">Join the waitlist →</span>
        </p>
        <div className="lg:col-span-6 lg:col-start-6">
          <WaitlistForm source={source} compact className="max-w-lg" />
        </div>
      </div>
    </div>
  );
}
