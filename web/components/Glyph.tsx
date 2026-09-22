/** The ✦ four-point star that is Navi's mark. Rendered as SVG so it is crisp at every size. */
export function Glyph({ className = "h-5 w-5" }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" className={className} fill="currentColor">
      <path d="M12 1.5c.6 5.4 4.1 9 9.5 10.5-5.4 1.5-8.9 5.1-9.5 10.5-.6-5.4-4.1-9-9.5-10.5C7.9 10.5 11.4 6.9 12 1.5z" />
    </svg>
  );
}

export function Wordmark({ className = "" }: { className?: string }) {
  return (
    <span className={`inline-flex items-center gap-2 font-semibold tracking-tight ${className}`}>
      <Glyph className="h-[1.05em] w-[1.05em] text-accent" />
      <span>Navi</span>
    </span>
  );
}
