import type { ReactNode } from "react";

/**
 * A story section on the 12-column grid: text in a narrow column, the visual in the wide one,
 * alternating sides. `n` is the section number in tabular figures.
 */
export function Section({
  id,
  n,
  title,
  children,
  visual,
  flip = false,
  aside,
}: {
  id?: string;
  n: string;
  title: string;
  children: ReactNode;
  visual: ReactNode;
  flip?: boolean;
  aside?: ReactNode;
}) {
  return (
    <section id={id} className="scroll-mt-16 px-6 py-24 md:py-32">
      <div className="mx-auto grid max-w-7xl grid-cols-1 items-center gap-12 lg:grid-cols-12 lg:gap-8">
        <div className={`lg:col-span-4 ${flip ? "lg:order-2 lg:col-start-9" : "lg:col-start-1"}`}>
          <div className="num">{n}</div>
          <h2 className="h-section mt-3">{title}</h2>
          <div className="lede mt-5">{children}</div>
          {aside && <div className="mt-6 text-sm text-fg-dim">{aside}</div>}
        </div>
        <div className={`lg:col-span-7 ${flip ? "lg:order-1 lg:col-start-1" : "lg:col-start-6"}`}>{visual}</div>
      </div>
    </section>
  );
}
