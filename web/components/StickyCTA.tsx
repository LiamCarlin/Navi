"use client";

import { useEffect, useState } from "react";
import { ctaDismissed, joined } from "@/lib/source";
import { WaitlistForm } from "./WaitlistForm";
import { useOverDark } from "@/lib/useOverDark";

/**
 * A slim bar (desktop) / bottom sheet (phone) with the email field, once the hero has scrolled
 * past. Hidden while the waitlist section is on screen, after signing up, or once dismissed
 * (remembered in localStorage, guarded).
 */
export function StickyCTA() {
  const [pastHero, setPastHero] = useState(false);
  const [nearForm, setNearForm] = useState(false);
  const [hidden, setHidden] = useState(true);
  const overDark = useOverDark("-92% 0px 0px 0px");

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
      className={`fixed inset-x-0 bottom-0 z-30 transition-transform duration-500 ease-[cubic-bezier(0.22,1,0.36,1)] ${show ? "translate-y-0" : "translate-y-full"} ${overDark ? "stage-dark" : ""}`}
      aria-hidden={!show}
    >
      <div className="border-t border-line bg-bg/85 backdrop-blur-xl">
        <div className="mx-auto flex max-w-7xl items-center gap-3 px-4 py-2.5 sm:gap-6 sm:px-6 sm:py-3">
          <div className="min-w-0 flex-1 truncate text-sm text-fg">
            <span className="font-medium">Navi for macOS.</span> <span className="hidden text-fg-muted sm:inline">⌘Space, but it does things.</span>
          </div>
          <div className="flex shrink-0 items-center gap-2 sm:w-[440px]">
            <a href="#waitlist" className="btn-primary !h-9 !px-4 !text-sm sm:hidden">
              Join the waitlist
            </a>
            <div className="hidden flex-1 sm:block">
              <WaitlistForm source="sticky" compact />
            </div>
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
