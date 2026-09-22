"use client";

import { useEffect, useState } from "react";
import { ctaDismissed, joined } from "@/lib/source";
import { WaitlistForm } from "./WaitlistForm";

/**
 * A slim bar (desktop) / bottom sheet (phone) with the email field, once the hero has scrolled
 * past. Hidden while the waitlist section is on screen, after signing up, or once dismissed
 * (remembered in localStorage, guarded).
 */
export function StickyCTA() {
  const [pastHero, setPastHero] = useState(false);
  const [nearForm, setNearForm] = useState(false);
  const [hidden, setHidden] = useState(true);

  useEffect(() => {
    setHidden(ctaDismissed.get() || joined.get());
    const onScroll = () => setPastHero(window.scrollY > window.innerHeight * 0.9);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    const target = document.getElementById("waitlist");
    const io = target ? new IntersectionObserver(([e]) => setNearForm(e.isIntersecting), { rootMargin: "0px 0px -20% 0px" }) : null;
    if (target && io) io.observe(target);
    return () => {
      window.removeEventListener("scroll", onScroll);
      io?.disconnect();
    };
  }, []);

  const show = pastHero && !nearForm && !hidden;

  return (
    <div
      className={`fixed inset-x-0 bottom-0 z-30 transition-transform duration-200 ease-out ${show ? "translate-y-0" : "translate-y-full"}`}
      aria-hidden={!show}
    >
      <div className="border-t border-line bg-bg/85 backdrop-blur-xl">
        <div className="mx-auto flex max-w-7xl flex-col gap-3 px-6 py-3 sm:flex-row sm:items-center sm:gap-6">
          <div className="min-w-0 flex-1 text-sm text-fg">
            <span className="font-medium">Navi for macOS.</span> <span className="text-fg-muted">Say it, it’s done. Join the waitlist.</span>
          </div>
          <div className="flex items-center gap-2 sm:w-[440px]">
            <WaitlistForm source="sticky" compact className="flex-1" />
            <button
              type="button"
              onClick={() => {
                ctaDismissed.set();
                setHidden(true);
              }}
              aria-label="Dismiss"
              className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full text-fg-dim transition-colors duration-150 hover:text-fg"
            >
              <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
                <path d="M6 6l12 12M18 6L6 18" />
              </svg>
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
