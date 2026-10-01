import { Lines, Reveal } from "./motion/Reveal";

const STAYS = [
  "The index of your apps, files and settings, and the calculator",
  "Turning your speech into text",
  "Reading the text in a window, for tasks and for Recall",
  "The check for personal details you’ve blocked, which runs before anything is sent",
  "Your Recall notes: Markdown files in a folder you own",
  "Task logs, if you turn them on for troubleshooting (kept 7 days, never uploaded)",
  "Your last 50 searches, used to rank results",
];

const LEAVES = [
  ["What you type or say", "with the app you’re in and its window title, so Navi can tell what you mean and answer. Your selected text, clipboard or screen memories only when the question refers to them. Local results never wait for any of this."],
  ["During a task", "the text and controls of the one app it’s working in, a step at a time, and sometimes a screenshot of that window."],
  ["With Recall on", "up to a few thousand characters of a moment’s screen text, to judge whether it’s worth remembering; for the ones that are, that text and up to two small screenshots, to write the summary. Details you’ve blocked are removed first, and moments that show them are never sent at all."],
];

export function Privacy() {
  return (
    <section id="privacy" className="scroll-mt-16 border-t border-line px-4 py-24 sm:px-6 md:py-36">
      <div className="mx-auto max-w-7xl">
        <div className="grid grid-cols-1 gap-6 lg:grid-cols-12 lg:gap-8">
          <Lines className="h-section lg:col-span-7" lines={["What stays on your Mac,", "and what doesn’t."]} />
          <Reveal className="lg:col-span-5 lg:pt-3">
            <p className="lede">
              Navi needs a server to decide and to write. Here’s exactly what it sends, and when. Navi’s servers pass requests on and
              keep your account and usage counts, not the content. Nothing is sold, and nothing is used to train models.
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
                Recall is off until you turn it on, skips password managers, private windows and anything you exclude, and keeps
                notes 30 days by default (7, 30, 90 days or forever). Settings → Privacy &amp; Data deletes everything Navi has stored.{" "}
                <a href="/privacy" className="underline underline-offset-2 hover:text-fg">
                  Full privacy policy
                </a>
              </p>
            </Reveal>
          </div>
        </div>
      </div>
    </section>
  );
}
