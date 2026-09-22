import type { CSSProperties, ReactNode } from "react";

/** A small macOS window: traffic lights, a title, themed chrome. Used by the story demos. */
export function Win({
  title,
  tint,
  children,
  className = "",
  style,
  dark = false,
}: {
  title: string;
  tint: string;
  children: ReactNode;
  className?: string;
  style?: CSSProperties;
  dark?: boolean;
}) {
  return (
    <div
      className={`win overflow-hidden rounded-[10px] ${className}`}
      style={dark ? { ...style, background: "#1c1c1f", color: "rgba(255,255,255,0.85)", borderColor: "rgba(255,255,255,0.08)" } : style}
    >
      <div
        className="flex h-7 items-center gap-2 border-b px-3 text-[11px]"
        style={
          dark
            ? { background: "rgba(255,255,255,0.05)", borderColor: "rgba(255,255,255,0.08)", color: "rgba(255,255,255,0.6)" }
            : { background: "var(--win-bar)", borderColor: "var(--win-line)", color: "var(--win-muted)" }
        }
      >
        <span className="flex gap-1.5" aria-hidden="true">
          <span className="h-2 w-2 rounded-full bg-[#ff5f57]" />
          <span className="h-2 w-2 rounded-full bg-[#febc2e]" />
          <span className="h-2 w-2 rounded-full bg-[#28c840]" />
        </span>
        <span className="ml-1 h-2.5 w-2.5 rounded-[3px]" style={{ background: tint }} aria-hidden="true" />
        <span className="truncate">{title}</span>
      </div>
      {children}
    </div>
  );
}

/** A macOS notification banner: app tile, title, line. */
export function Notice({ app, tint, title, line, icon }: { app: string; tint: string; title: string; line: string; icon?: ReactNode }) {
  return (
    <div className="glass flex w-[250px] items-center gap-3 rounded-[12px] px-3 py-2.5 text-panel-fg">
      <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-[8px] text-white" style={{ background: tint }} aria-hidden="true">
        {icon}
      </span>
      <div className="min-w-0">
        <div className="flex items-baseline justify-between gap-2">
          <span className="truncate text-[12px] font-medium">{title}</span>
          <span className="shrink-0 text-[10px] text-panel-dim">{app}</span>
        </div>
        <div className="truncate text-[11px] text-panel-muted">{line}</div>
      </div>
    </div>
  );
}

export function Check({ className = "h-3 w-3" }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M5 12l5 5 9-10" />
    </svg>
  );
}

export function Shield({ className = "" }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M12 3l7 3v5c0 5-3.5 8.5-7 10-3.5-1.5-7-5-7-10V6l7-3z" />
      <path d="M9 12l2 2 4-4" />
    </svg>
  );
}

/** Text that has been "typed" up to `n` characters, with a caret while unfinished. */
export function Typed({ text, n, caret = true, ink = false }: { text: string; n: number; caret?: boolean; ink?: boolean }) {
  const done = n >= text.length;
  return (
    <>
      {text.slice(0, Math.max(0, n))}
      {caret && !done && <span className={`caret ${ink ? "caret-ink" : ""}`} />}
    </>
  );
}

/** How many characters of `text` are visible at `t`, typing from `from` at `ms` per character. */
export function typed(text: string, t: number, from: number, ms: number) {
  if (t < from) return 0;
  return Math.min(text.length, Math.floor((t - from) / ms));
}

/** How many words of `text` are visible at `t`. */
export function words(text: string, t: number, from: number, ms: number) {
  const parts = text.split(" ");
  if (t < from) return "";
  return parts.slice(0, Math.min(parts.length, Math.floor((t - from) / ms) + 1)).join(" ");
}
