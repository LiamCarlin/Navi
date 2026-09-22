import { LOGO_PATHS, SEEN_ON } from "@/lib/seenOn";

/**
 * A press strip: "As seen on" plus monochrome logos at 40 % that go to 100 % on hover.
 * Renders nothing at all while no entry is enabled — no heading, no gap.
 */
export function SeenOn({ className = "" }: { className?: string }) {
  const entries = SEEN_ON.filter((e) => e.enabled);
  if (entries.length === 0) return null;
  return (
    <section className={`px-6 ${className}`} aria-label="As seen on">
      <div className="mx-auto flex max-w-7xl flex-col items-start gap-4 border-y border-line py-6 sm:flex-row sm:items-center sm:gap-10">
        <span className="text-[13px] text-fg-dim">As seen on</span>
        <ul className="flex flex-wrap items-center gap-x-10 gap-y-4">
          {entries.map((e) => (
            <li key={e.logo}>
              <a
                href={e.href}
                target="_blank"
                rel="noopener noreferrer"
                aria-label={e.name}
                title={e.name}
                className="flex items-center gap-2 text-fg opacity-40 transition-opacity duration-150 hover:opacity-100 focus-visible:opacity-100"
              >
                <svg viewBox="0 0 24 24" className="h-5 w-5" fill="currentColor" aria-hidden="true">
                  <path d={LOGO_PATHS[e.logo]} />
                </svg>
                <span className="text-sm font-medium">{e.name}</span>
              </a>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}
