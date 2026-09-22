"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { Wordmark } from "./Glyph";

const links = [
  { href: "#does", label: "What it does" },
  { href: "#voice", label: "Voice" },
  { href: "#pricing", label: "Pricing" },
  { href: "#faq", label: "FAQ" },
];

export function Nav() {
  const [scrolled, setScrolled] = useState(false);
  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 8);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <header className="sticky top-0 z-40 w-full">
      <div
        className={`pointer-events-none absolute inset-0 border-b bg-bg/70 backdrop-blur-xl transition-opacity duration-300 ${
          scrolled ? "border-line opacity-100" : "border-transparent opacity-0"
        }`}
        aria-hidden="true"
      />
      <div className="relative mx-auto flex h-16 max-w-6xl items-center justify-between px-4 sm:px-6">
        <Link href="/" className="text-[17px] text-fg" aria-label="Navi home">
          <Wordmark />
        </Link>
        <nav className="hidden items-center gap-8 text-sm text-fg-muted md:flex" aria-label="Primary">
          {links.map((l) => (
            <a key={l.href} href={l.href} className="transition-colors duration-200 hover:text-fg">
              {l.label}
            </a>
          ))}
        </nav>
        <a href="#waitlist" className="btn-primary !h-9 !text-sm">
          Join the waitlist
        </a>
      </div>
    </header>
  );
}
