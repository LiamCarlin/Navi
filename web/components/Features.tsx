import { Reveal } from "./Reveal";
import { Glyph } from "./Glyph";

const features = [
  {
    title: "Instant",
    tag: "Local · free",
    body: "Apps, files, a calculator, and system toggles. Type two letters and hit return. Nothing leaves your Mac.",
    demo: <InstantDemo />,
  },
  {
    title: "Answers",
    tag: "In the bar",
    body: "Ask a question and the answer streams right into the panel. No tabs, no chat window, no waiting.",
    demo: <AnswerDemo />,
  },
  {
    title: "Does it for you",
    tag: "Hands off",
    body: "Navi drives your apps and browser while you keep working. It asks before anything it can't undo.",
    demo: <TaskDemo />,
  },
];

export function Features() {
  return (
    <section id="features" className="scroll-mt-20 px-4 py-20 sm:px-6 md:py-28">
      <div className="mx-auto max-w-6xl">
        <Reveal>
          <h2 className="text-balance text-3xl font-semibold tracking-tight sm:text-4xl">
            One bar. Three speeds.
          </h2>
          <p className="mt-3 max-w-xl text-fg-muted">
            Navi decides what you meant in under a second, then does the fastest thing that gets you there.
          </p>
        </Reveal>
        <div className="mt-12 grid grid-cols-1 gap-5 md:grid-cols-3">
          {features.map((f, i) => (
            <Reveal key={f.title} delay={i * 0.08}>
              <article className="card flex h-full flex-col p-6">
                <div className="mb-6 h-36 overflow-hidden rounded-xl border border-line bg-bg/60">{f.demo}</div>
                <div className="mb-2 text-xs font-medium uppercase tracking-wider text-accent">{f.tag}</div>
                <h3 className="text-xl font-semibold tracking-tight">{f.title}</h3>
                <p className="mt-2 text-sm leading-relaxed text-fg-muted">{f.body}</p>
              </article>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}

function MiniBar({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex items-center gap-2 border-b border-line px-3 py-2 text-sm text-fg">
      <Glyph className="h-3.5 w-3.5 text-accent" />
      <span className="truncate">{children}</span>
    </div>
  );
}

function InstantDemo() {
  return (
    <div className="text-sm">
      <MiniBar>
        sa<span className="caret" />
      </MiniBar>
      <ul className="space-y-1 p-2 text-[13px]">
        <li className="flex items-center gap-2 rounded-lg bg-accent-soft px-2 py-1.5 text-fg">
          <span className="h-5 w-5 rounded-md bg-gradient-to-br from-sky-400 to-blue-600" /> Safari
          <span className="keycap ml-auto">⏎ Open</span>
        </li>
        <li className="flex items-center gap-2 px-2 py-1.5 text-fg-muted">
          <span className="h-5 w-5 rounded-md bg-gradient-to-br from-zinc-400 to-zinc-700" /> Sales deck.key
          <span className="ml-auto text-xs text-fg-dim">Keynote</span>
        </li>
      </ul>
    </div>
  );
}

function AnswerDemo() {
  return (
    <div className="text-sm">
      <MiniBar>How long does a flight to Lisbon take?</MiniBar>
      <p className="p-3 text-[13px] leading-relaxed text-fg-muted">
        From San Francisco, about <span className="text-fg">11 h nonstop</span>. Most routes connect through
        London or Newark and take 14–16 h<span className="caret" />
      </p>
    </div>
  );
}

function TaskDemo() {
  const steps = ["Opened Chrome", "Searched “flights to Lisbon”", "Clicked the first result"];
  return (
    <div className="text-sm">
      <MiniBar>Open Chrome, search for flights to Lisbon</MiniBar>
      <ul className="space-y-1.5 p-3 text-[13px]">
        {steps.map((s, i) => (
          <li key={s} className={`flex items-center gap-2 ${i === 2 ? "text-fg" : "text-fg-muted"}`}>
            <span
              className={`flex h-4 w-4 items-center justify-center rounded-full text-[10px] ${
                i === 2 ? "bg-accent text-bg" : "bg-white/10 text-fg-muted"
              }`}
            >
              ✓
            </span>
            {s}
          </li>
        ))}
        <li className="flex items-center gap-2 text-fg-dim">
          <span className="h-4 w-4 animate-pulse rounded-full border border-dashed border-fg-dim" />
          Waiting for you before booking
        </li>
      </ul>
    </div>
  );
}
