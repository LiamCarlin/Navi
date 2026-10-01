import { Lines, Reveal } from "./motion/Reveal";

const STAYS = [
  "The index of your apps, files and settings, and the calculator",
  "Turning your speech into text",
  "Reading the text in a window, for tasks and for Recall",
  "The check for personal details you’ve blocked, which runs before anything is sent",
  "Your Recall notes: Markdown files in a folder you own",
  "A step-by-step log of every task",
];

const LEAVES = [
  ["What you type or say", "so the decision model can tell what it is. Local results never wait for that, and a question’s text goes on to be answered."],
  ["During a task", "the controls and text of the one window it’s working in, a step at a time. A screenshot of that window only when the text isn’t enough."],
  ["With Recall on", "text from frames that passed the local check, to judge what matters; for the moments that do, a request to summarize them, with personal details redacted. A frame that needed redacting is never sent as an image."],
];

export function Privacy() {
  return (
    <section id="privacy" className="scroll-mt-16 border-t border-line px-4 py-24 sm:px-6 md:py-36">
      <div className="mx-auto max-w-7xl">
        <div className="grid grid-cols-1 gap-6 lg:grid-cols-12 lg:gap-8">
          <Lines className="h-section lg:col-span-7" lines={["What stays on your Mac,", "and what doesn’t."]} />
          <Reveal className="lg:col-span-5 lg:pt-3">
            <p className="lede">
              Navi needs a server to decide and to write. Here’s exactly what it sends, and when. There are no API keys to paste and
              no models to pick; Navi’s own service handles that part.
            </p>
          </Reveal>
        </div>

        <div className="mt-16 grid grid-cols-1 gap-12 lg:mt-20 lg:grid-cols-12 lg:gap-8">
          <div className="lg:col-span-5">
            <Reveal>
              <h3 className="flex items-center gap-2.5 text-[15px] font-medium">
                <span className="h-2 w-2 rounded-full bg-[#30d158]" />
                Never leaves your Mac
              </h3>
            </Reveal>
            <ul className="mt-5 divide-y divide-line border-y border-line">
              {STAYS.map((s, i) => (
                <Reveal as="li" key={s} i={i} className="py-3.5 text-[15.5px]">
                  {s}
                </Reveal>
              ))}
            </ul>
          </div>
          <div className="lg:col-span-6 lg:col-start-7">
            <Reveal>
              <h3 className="flex items-center gap-2.5 text-[15px] font-medium">
                <span className="h-2 w-2 rounded-full bg-[#ff9f0a]" />
                Sent, only to do what you asked
              </h3>
            </Reveal>
            <dl className="mt-5 divide-y divide-line border-y border-line">
              {LEAVES.map(([k, v], i) => (
                <Reveal key={k} i={i} className="grid grid-cols-1 gap-1 py-4 sm:grid-cols-[10rem_1fr] sm:gap-6">
                  <dt className="text-[15.5px] font-medium">{k}</dt>
                  <dd className="body">{v}</dd>
                </Reveal>
              ))}
            </dl>
            <Reveal>
              <p className="label mt-5 leading-relaxed">
                Recall also skips apps you exclude, never keeps password fields, and pauses for an hour or the rest of the day from
                the menu bar.
              </p>
            </Reveal>
          </div>
        </div>
      </div>
    </section>
  );
}
