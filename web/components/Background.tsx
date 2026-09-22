import { Glyph } from "./Glyph";
import { Reveal } from "./Reveal";

export function Background() {
  return (
    <section className="px-4 py-24 sm:px-6 md:py-32">
      <div className="mx-auto grid max-w-6xl grid-cols-1 items-center gap-10 md:grid-cols-2 md:gap-16">
        <Reveal>
          <div className="eyebrow mb-3">Background mode</div>
          <h2 className="h-section">It works while you work.</h2>
          <p className="lede mt-4">
            Tasks run in the app they need while your window stays in front — your cursor, your focus. Before
            anything you can’t undo — send, pay, delete — Navi stops and asks.
          </p>
          <ul className="mt-6 space-y-3 text-sm text-fg-muted">
            <li className="flex items-center gap-3">
              <Shield className="h-4 w-4 shrink-0 text-accent" /> Asks first for send, pay, and delete
            </li>
            <li className="flex items-center gap-3">
              <span className="keycap">esc</span> or “stop” halts a task instantly
            </li>
          </ul>
        </Reveal>

        <Reveal delay={0.08}>
          <Desk />
        </Reveal>
      </div>
    </section>
  );
}

/** Two windows: Chrome behind (Navi's task), your document in front, and the confirmation sheet. */
function Desk() {
  return (
    <div className="relative mx-auto aspect-[5/4] w-full max-w-lg sm:aspect-[4/3]" aria-hidden="true">
      {/* Chrome, behind, where the task is running */}
      <div className="absolute left-0 top-0 h-[74%] w-[78%] overflow-hidden rounded-[12px] border border-line bg-[#1c1c1f] shadow-[0_20px_50px_-20px_rgba(0,0,0,0.8)]">
        <TitleBar title="Flights · Tokyo" tint="#3b82f6" />
        <div className="space-y-2 p-3">
          <div className="h-2 w-2/3 rounded bg-white/10" />
          <div className="h-2 w-1/2 rounded bg-white/10" />
          <div className="mt-3 h-10 rounded-[8px] border border-accent/60 bg-accent-soft" />
          <div className="h-10 rounded-[8px] bg-white/5" />
          <div className="h-10 rounded-[8px] bg-white/5" />
        </div>
        <div className="absolute right-2 top-9 flex items-center gap-2 rounded-full border border-white/15 bg-black/70 px-2.5 py-1 text-[11px] text-white/85 backdrop-blur-md">
          <span className="spin h-2.5 w-2.5 rounded-full border-2 border-white/25 border-t-accent" />
          Navi · comparing prices
        </div>
      </div>

      {/* Your document, in front, with focus */}
      <div className="absolute bottom-[6%] right-0 h-[72%] w-[70%] overflow-hidden rounded-[12px] border border-line-strong bg-[#f5f5f7] text-[#1d1d1f] shadow-[0_30px_70px_-20px_rgba(0,0,0,0.9)]">
        <TitleBar title="Q4 plan" tint="#f59e0b" light />
        <div className="space-y-2.5 p-4">
          <div className="h-3 w-1/2 rounded bg-black/80" />
          <div className="h-2 w-full rounded bg-black/15" />
          <div className="h-2 w-11/12 rounded bg-black/15" />
          <div className="h-2 w-4/5 rounded bg-black/15" />
          <div className="mt-3 h-2 w-full rounded bg-black/15" />
          <div className="flex items-center gap-1">
            <div className="h-2 w-2/5 rounded bg-black/15" />
            <span className="caret !bg-[#1d1d1f]" />
          </div>
        </div>
      </div>

      {/* The confirmation sheet */}
      <div className="absolute bottom-0 left-[6%] w-[62%] rounded-[12px] border border-line-strong bg-[#141416] p-3.5 shadow-[0_24px_60px_-16px_rgba(0,0,0,0.9)] sm:left-[10%]">
        <div className="flex items-start gap-3">
          <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-accent-soft text-accent">
            <Shield className="h-3.5 w-3.5" />
          </span>
          <div className="min-w-0">
            <div className="text-[13px] font-medium text-fg">Book ANA for $412?</div>
            <div className="mt-0.5 text-[11px] text-fg-dim">This charges your saved card. Navi won’t continue until you say so.</div>
          </div>
        </div>
        <div className="mt-3 flex justify-end gap-2">
          <span className="rounded-[8px] border border-line px-2.5 py-1 text-[11px] text-fg-muted">Not now</span>
          <span className="rounded-[8px] bg-fg px-2.5 py-1 text-[11px] font-medium text-bg">Book it</span>
        </div>
      </div>
    </div>
  );
}

function TitleBar({ title, tint, light = false }: { title: string; tint: string; light?: boolean }) {
  return (
    <div className={`flex h-7 items-center gap-2 border-b px-3 text-[11px] ${light ? "border-black/10 bg-[#e8e8ed] text-black/60" : "border-white/8 bg-white/5 text-white/60"}`}>
      <span className="flex gap-1">
        <span className="h-2 w-2 rounded-full bg-[#ff5f57]" />
        <span className="h-2 w-2 rounded-full bg-[#febc2e]" />
        <span className="h-2 w-2 rounded-full bg-[#28c840]" />
      </span>
      <span className="ml-1 h-2.5 w-2.5 rounded-[3px]" style={{ background: tint }} />
      <span className="truncate">{title}</span>
      <Glyph className="ml-auto h-3 w-3 text-accent opacity-0" />
    </div>
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
