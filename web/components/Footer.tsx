import { Wordmark } from "./Glyph";

const columns = [
  {
    title: "Product",
    links: [
      { href: "/#does", label: "What it does" },
      { href: "/#voice", label: "Voice" },
      { href: "/#recall", label: "Recall" },
      { href: "/#pricing", label: "Pricing" },
      { href: "/#faq", label: "FAQ" },
    ],
  },
  {
    title: "Company",
    links: [
      { href: "/#waitlist", label: "Waitlist" },
      { href: "mailto:hello@navi.app", label: "Contact" },
    ],
  },
  {
    title: "Legal",
    links: [
      { href: "/privacy", label: "Privacy" },
      { href: "/terms", label: "Terms" },
    ],
  },
];

export function Footer() {
  return (
    <footer className="border-t border-line px-6 py-16">
      <div className="mx-auto grid max-w-6xl grid-cols-2 gap-x-6 gap-y-10 md:grid-cols-12">
        <div className="col-span-2 md:col-span-5">
          <Wordmark className="text-[17px]" />
          <p className="lede mt-3 max-w-xs text-sm">
            A menu-bar app for macOS. Press ⌘Space, say what you want.
          </p>
        </div>
        {columns.map((c) => (
          <nav key={c.title} className="md:col-span-2" aria-label={c.title}>
            <div className="text-sm font-medium text-fg">{c.title}</div>
            <ul className="mt-3 space-y-2 text-sm">
              {c.links.map((l) => (
                <li key={l.href}>
                  <a href={l.href} className="text-fg-muted transition-colors duration-150 hover:text-fg">
                    {l.label}
                  </a>
                </li>
              ))}
            </ul>
          </nav>
        ))}
      </div>
      <div className="mx-auto mt-12 flex max-w-6xl flex-col gap-2 border-t border-line pt-6 text-[13px] text-fg-dim sm:flex-row sm:items-center sm:justify-between">
        <span className="tnum">© 2026 Navi</span>
        <span>Private beta · macOS 26 · Apple silicon</span>
      </div>
    </footer>
  );
}
