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
        className={`pointer-events-none absolute inset-0 border-b bg-bg/75 backdrop-blur-xl transition-opacity duration-200 ${
          scrolled ? "border-line opacity-100" : "border-transparent opacity-0"
        }`}
        aria-hidden="true"
      />
      <div className="relative mx-auto flex h-16 max-w-7xl items-center justify-between px-6">
        <Link href="/" className="text-[17px] text-fg" aria-label="Navi home">
          <Wordmark />
        </Link>
        <nav className="hidden items-center gap-8 text-sm md:flex" aria-label="Primary">
          {links.map((l) => (
            <a key={l.href} href={l.href} className="navlink">
              {l.label}
            </a>
          ))}
        </nav>
        <div className="flex items-center gap-3">
          <ThemeToggle />
          <a href="#waitlist" className="btn-primary !h-9 !text-sm">
            Join the waitlist
          </a>
        </div>
      </div>
    </header>
  );
}

type Theme = "light" | "dark";

function readTheme(): Theme {
  const t = document.documentElement.dataset.theme;
  return t === "light" ? "light" : "dark";
}

function ThemeToggle() {
  // Rendered neutral on the server; the real state is read after mount so markup matches.
  const [theme, setTheme] = useState<Theme | null>(null);
  useEffect(() => setTheme(readTheme()), []);

  function toggle() {
    const next: Theme = readTheme() === "light" ? "dark" : "light";
    document.documentElement.dataset.theme = next;
    setTheme(next);
    try {
      localStorage.setItem("navi-theme", next);
    } catch {}
    // Next emits media-qualified theme-color metas that follow the system; a plain one placed first wins.
    let meta = document.querySelector<HTMLMetaElement>('meta[name="theme-color"]:not([media])');
    if (!meta) {
      meta = document.createElement("meta");
      meta.name = "theme-color";
      document.head.prepend(meta);
    }
    meta.content = next === "light" ? "#f7f7f5" : "#0a0a0b";
  }

  const isLight = theme === "light";
  return (
    <button
      type="button"
      onClick={toggle}
      aria-label={isLight ? "Switch to dark mode" : "Switch to light mode"}
      title={isLight ? "Dark mode" : "Light mode"}
      className="flex h-9 w-9 items-center justify-center rounded-full text-fg-muted transition-colors duration-150 hover:text-fg"
    >
      {theme === null ? (
        <span className="h-4 w-4" />
      ) : isLight ? (
        <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
          <path d="M20.5 14.5A8.5 8.5 0 0 1 9.5 3.5a8.5 8.5 0 1 0 11 11z" />
        </svg>
      ) : (
        <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
          <circle cx="12" cy="12" r="4" />
          <path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4" />
        </svg>
      )}
    </button>
  );
}
