import Link from "next/link";
import { Wordmark } from "./Glyph";

const links = [
  { href: "#features", label: "Features" },
  { href: "#pricing", label: "Pricing" },
  { href: "#faq", label: "FAQ" },
];

export function Nav() {
  return (
    <header className="sticky top-0 z-40 w-full">
      <div className="mx-auto flex h-16 max-w-6xl items-center justify-between px-4 sm:px-6">
        <Link href="/" className="text-lg text-fg" aria-label="Navi home">
          <Wordmark />
        </Link>
        <nav className="hidden items-center gap-8 text-sm text-fg-muted md:flex" aria-label="Primary">
          {links.map((l) => (
            <a key={l.href} href={l.href} className="transition-colors hover:text-fg">
              {l.label}
            </a>
          ))}
        </nav>
        <a
          href="#waitlist"
          className="rounded-full bg-fg px-4 py-2 text-sm font-medium text-bg transition-transform hover:scale-[1.03] active:scale-[0.98]"
        >
          Join the waitlist
        </a>
      </div>
      {/* Glass strip that only shows once content scrolls beneath it. */}
      <div className="pointer-events-none absolute inset-0 -z-10 border-b border-line/60 bg-bg/70 backdrop-blur-xl [mask-image:linear-gradient(to_bottom,black,black)]" />
    </header>
  );
}
