"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { Wordmark } from "./Glyph";
import { ScrollProgress } from "./motion/ScrollProgress";

/** Navi Cloud (sign-in, /account). Unset → the site stays in waitlist mode with no account links. */
const CLOUD = process.env.NEXT_PUBLIC_NAVI_CLOUD_URL?.replace(/\/+$/, "");
/** Flip to 1 at launch: the main CTA becomes "Get Navi" (sign up → account → download) instead of the waitlist. */
const SIGNUPS_OPEN = process.env.NEXT_PUBLIC_SIGNUPS_OPEN === "1" && Boolean(CLOUD);

const links = [
  { href: "#what", label: "What it does" },
  { href: "#how", label: "How it works" },
  { href: "#voice", label: "Voice" },
  { href: "#recall", label: "Recall" },
  { href: "#pricing", label: "Pricing" },
];

/**
 * White over the sky; once the hero is behind you it becomes a white glass bar with ink text.
 * The waitlist pill stays blue in both.
 */
export function Nav() {
  const [solid, setSolid] = useState(false);
  useEffect(() => {
    const onScroll = () => setSolid(window.scrollY > window.innerHeight * 0.55);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <header className="fixed inset-x-0 top-0 z-40">
      <ScrollProgress />
      <div
        className={`pointer-events-none absolute inset-0 border-b bg-white/75 backdrop-blur-xl transition-opacity duration-500 ${
          solid ? "border-line opacity-100" : "border-transparent opacity-0"
        }`}
        aria-hidden="true"
      />
      <div
        className={`relative mx-auto flex h-16 max-w-6xl items-center justify-between px-4 transition-colors duration-500 sm:px-6 ${
          solid ? "text-fg" : "text-white"
        }`}
      >
        <Link href="/" className="text-[18px]" aria-label="Navi home">
          <Wordmark />
        </Link>
        <nav className="hidden items-center gap-8 text-[14px] font-medium md:flex" aria-label="Primary">
          {links.map((l) => (
            <a key={l.href} href={l.href} className="navlink">
              {l.label}
            </a>
          ))}
        </nav>
        <div className="flex items-center gap-4">
          {CLOUD && (
            <a href={`${CLOUD}/auth/start?redirect=account`} className="navlink hidden text-[14px] font-medium sm:inline">
              Sign in
            </a>
          )}
          {SIGNUPS_OPEN ? (
            <a href={`${CLOUD}/auth/start?redirect=account`} className="btn-primary !h-9 !px-4 !text-[14px]">
              Get Navi
            </a>
          ) : (
            <a href="#waitlist" className="btn-primary !h-9 !px-4 !text-[14px]">
              Join the waitlist
            </a>
          )}
        </div>
      </div>
    </header>
  );
}
