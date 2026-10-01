import { Wordmark } from "./Glyph";

const CLOUD = process.env.NEXT_PUBLIC_NAVI_CLOUD_URL?.replace(/\/+$/, "");
const SIGNUPS_OPEN = process.env.NEXT_PUBLIC_SIGNUPS_OPEN === "1" && Boolean(CLOUD);

/** Account links appear once Navi Cloud is live; Download once sign-ups are open (the DMG lives on /account). */
const accountLinks = CLOUD
  ? [
      ...(SIGNUPS_OPEN ? [{ href: `${CLOUD}/account#download`, label: "Download" }] : []),
      { href: `${CLOUD}/account`, label: "Account" },
    ]
  : [];

const columns = [
  {
    title: "Product",
    links: [
      { href: "/#what", label: "What it does" },
      { href: "/#how", label: "How it works" },
      { href: "/#voice", label: "Voice" },
      { href: "/#recall", label: "Recall" },
      { href: "/#pricing", label: "Pricing" },
      ...accountLinks,
    ],
  },
  {
    title: "Company",
    links: [
      { href: "/#waitlist", label: "Waitlist" },
      { href: "/#faq", label: "FAQ" },
      { href: "mailto:hello@buildnavi.com", label: "Contact" },
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
    <footer className="bg-[#dfe7f5] px-4 pb-10 pt-6 sm:px-6">
      <div className="mx-auto grid max-w-6xl grid-cols-2 gap-x-6 gap-y-10 border-t border-[rgba(60,80,130,0.12)] pt-12 md:grid-cols-12">
        <div className="col-span-2 md:col-span-6">
          <Wordmark className="text-[18px]" />
          <p className="mt-3 max-w-xs text-[14px] text-fg-muted">A menu-bar app for macOS. ⌘Space, but it does things.</p>
        </div>
        {columns.map((c) => (
          <nav key={c.title} className="md:col-span-2" aria-label={c.title}>
            <div className="text-[13px] font-medium text-fg">{c.title}</div>
            <ul className="mt-3 space-y-2 text-[13.5px]">
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
      <div className="mx-auto mt-12 flex max-w-6xl flex-col gap-2 text-[12.5px] text-fg-dim sm:flex-row sm:items-center sm:justify-between">
        <span className="tnum">© 2026 Navi</span>
        <span>Private beta · macOS 26 Tahoe · Apple silicon</span>
      </div>
    </footer>
  );
}
