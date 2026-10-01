import type { ReactNode } from "react";
import { env } from "@/lib/env";

/** The ✦ four-point star — Navi's mark (same path as web/components/Glyph.tsx). */
export function Glyph() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" fill="currentColor">
      <path d="M12 1.5c.6 5.4 4.1 9 9.5 10.5-5.4 1.5-8.9 5.1-9.5 10.5-.6-5.4-4.1-9-9.5-10.5C7.9 10.5 11.4 6.9 12 1.5z" />
    </svg>
  );
}

export function Wordmark({ href }: { href?: string }) {
  const inner = (
    <>
      <Glyph />
      <span>Navi</span>
    </>
  );
  return href ? (
    <a className="nv-wordmark" href={href} aria-label="Navi">
      {inner}
    </a>
  ) : (
    <span className="nv-wordmark">{inner}</span>
  );
}

/** Page chrome shared by /auth/* and /account. */
export function Shell({ children, right }: { children: ReactNode; right?: ReactNode }) {
  return (
    <div className="nv-page">
      <header className="nv-top">
        <Wordmark href={env.siteUrl ?? "/"} />
        {right}
      </header>
      {children}
    </div>
  );
}

export function Foot() {
  const site = env.siteUrl;
  return (
    <p className="nv-foot">
      {site ? (
        <>
          <a href={`${site}/privacy`}>Privacy</a> · <a href={`${site}/terms`}>Terms</a> ·{" "}
        </>
      ) : null}
      <a href="mailto:hello@buildnavi.com">Help</a>
    </p>
  );
}
