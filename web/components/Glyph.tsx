import type { CSSProperties } from "react";

const PATH = "M12 1.5c.6 5.4 4.1 9 9.5 10.5-5.4 1.5-8.9 5.1-9.5 10.5-.6-5.4-4.1-9-9.5-10.5C7.9 10.5 11.4 6.9 12 1.5z";

/** The ✦ four-point star that is Navi's mark. Rendered as SVG so it is crisp at every size. */
export function Glyph({ className = "h-5 w-5", style, gradient = false }: { className?: string; style?: CSSProperties; gradient?: boolean }) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" className={className} style={style} fill={gradient ? "url(#navi-grad)" : "currentColor"}>
      {gradient && (
        <defs>
          <linearGradient id="navi-grad" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stopColor="#5e5ce6" />
            <stop offset="0.4" stopColor="#bf5af2" />
            <stop offset="0.72" stopColor="#ff375f" />
            <stop offset="1" stopColor="#ff9f0a" />
          </linearGradient>
        </defs>
      )}
      <path d={PATH} />
    </svg>
  );
}

export function Wordmark({ className = "" }: { className?: string }) {
  return (
    <span className={`inline-flex items-center gap-2 font-semibold tracking-tight ${className}`}>
      <Glyph gradient className="h-[1.05em] w-[1.05em]" />
      <span>Navi</span>
    </span>
  );
}
