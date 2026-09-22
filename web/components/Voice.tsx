import { Reveal } from "./Reveal";
import { Glyph } from "./Glyph";

const transcript = [
  { who: "you", text: "Open Messages and text Sam I'm running ten minutes late" },
  { who: "navi", text: "Sent to Sam." },
  { who: "you", text: "then play some jazz on YouTube" },
  { who: "navi", text: "Playing “Late Night Jazz” in Chrome." },
  { who: "you", text: "what's 18% of 64" },
  { who: "navi", text: "11.52" },
];

export function Voice() {
  return (
    <section id="voice" className="scroll-mt-20 px-4 py-20 sm:px-6 md:py-28">
      <div className="mx-auto grid max-w-6xl grid-cols-1 items-center gap-12 md:grid-cols-2">
        <Reveal className="md:order-2">
          <div className="mb-3 text-xs font-medium uppercase tracking-wider text-accent">Voice</div>
          <h2 className="text-balance text-3xl font-semibold tracking-tight sm:text-4xl">
            Say it out loud. The island drops out of the notch.
          </h2>
          <p className="mt-4 text-fg-muted">
            Click the sparkle and just talk. Navi hears the pause between “and” and “then”, runs each thing in
            order, and answers questions right there in the island. Say “stop” or “undo” at any time.
          </p>
          <p className="mt-4 text-sm text-fg-dim">Speech is transcribed on your Mac. Included with Pro.</p>
        </Reveal>

        <Reveal delay={0.1} className="md:order-1">
          <VoiceDemo />
        </Reveal>
      </div>
    </section>
  );
}

function VoiceDemo() {
  return (
    <div className="relative mx-auto w-full max-w-md">
      {/* A slice of the Mac's top edge: the menu bar and notch. */}
      <div className="relative h-8 rounded-t-2xl border border-b-0 border-line bg-bg-elev">
        <div className="absolute left-1/2 top-0 h-6 w-40 -translate-x-1/2 rounded-b-xl bg-black" />
        <div className="absolute left-3 top-2 flex items-center gap-1.5 text-[11px] text-fg-muted">
          <Glyph className="h-3 w-3 text-fg-muted" /> Navi
        </div>
        <div className="absolute right-3 top-2 font-mono text-[11px] text-fg-dim">Mon 09:41</div>
      </div>

      {/* The island, hanging from the notch. */}
      <div className="relative -mt-px border border-t-0 border-line bg-bg-elev px-4 pb-4 pt-2">
        <div className="mx-auto w-full max-w-sm rounded-3xl bg-black p-4 shadow-[0_20px_60px_-20px_rgba(0,0,0,0.9),inset_0_1px_0_rgba(255,255,255,0.08)]">
          <div className="mb-3 flex items-center gap-3">
            <span className="flex h-7 w-7 items-center justify-center rounded-full bg-accent-soft text-accent">
              <Glyph className="h-3.5 w-3.5" />
            </span>
            <div className="flex h-6 items-end gap-[3px]" aria-hidden="true">
              {[0.4, 0.7, 1, 0.6, 0.9, 0.5, 0.8, 0.35].map((h, i) => (
                <span
                  key={i}
                  className="voice-bar w-[3px] rounded-full bg-accent"
                  style={{ height: `${h * 100}%`, animationDelay: `${i * 0.11}s` }}
                />
              ))}
            </div>
            <span className="ml-auto text-xs text-fg-dim">Listening</span>
          </div>
          <ul className="space-y-2 text-sm">
            {transcript.map((line, i) => (
              <li
                key={i}
                className={line.who === "you" ? "text-fg" : "pl-3 text-fg-muted before:mr-2 before:text-accent before:content-['✦']"}
              >
                {line.who === "you" ? `“${line.text}”` : line.text}
              </li>
            ))}
          </ul>
        </div>
      </div>
      <div className="h-6 rounded-b-2xl border border-t-0 border-line bg-bg-elev" />
    </div>
  );
}
