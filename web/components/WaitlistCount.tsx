"use client";

import { useEffect, useState } from "react";

/** "Join N people on the waitlist" — only once the number is real and at least 25. */
export function WaitlistCount({ className = "" }: { className?: string }) {
  const [n, setN] = useState<number | null>(null);
  useEffect(() => {
    let alive = true;
    fetch("/api/waitlist/count")
      .then((r) => (r.ok ? r.json() : null))
      .then((d: { count?: number } | null) => {
        if (alive && d && typeof d.count === "number" && d.count >= 25) setN(d.count);
      })
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, []);
  if (n === null) return null;
  return (
    <p className={`tnum text-sm text-fg-dim ${className}`}>
      Join {n.toLocaleString("en-US")} people on the waitlist.
    </p>
  );
}
