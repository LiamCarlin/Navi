import { Head, Reveal } from "./motion/Reveal";

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
    <section id="privacy" className="scroll-mt-16 px-4 py-24 sm:px-6 md:py-32">
      <Head
        title={["What stays on your Mac,", "and what doesn’t"]}
        sub="Navi needs a server to decide and to write. Its servers pass requests on and keep your account and usage counts, not the content. Nothing is sold, and nothing is used to train models."
      />
      <div className="mx-auto mt-14 grid max-w-6xl grid-cols-1 gap-5 lg:mt-16 lg:grid-cols-2">
        <Reveal className="card p-6 sm:p-8">
          <h3 className="flex items-center gap-2.5 text-[17px] font-medium">
            <span className="h-2.5 w-2.5 rounded-full bg-[#30d158] shadow-[0_0_0_4px_rgba(48,209,88,0.15)]" />
            Never leaves your Mac
          </h3>
          <ul className="mt-5 divide-y divide-line">
            {STAYS.map((s) => (
              <li key={s} className="py-3.5 text-[15px] text-fg-muted">
                {s}
              </li>
            ))}
          </ul>
        </Reveal>
        <Reveal i={1} className="card p-6 sm:p-8">
          <h3 className="flex items-center gap-2.5 text-[17px] font-medium">
            <span className="h-2.5 w-2.5 rounded-full bg-[#ff9f0a] shadow-[0_0_0_4px_rgba(255,159,10,0.15)]" />
            Sent, only to do what you asked
          </h3>
          <dl className="mt-5 divide-y divide-line">
            {LEAVES.map(([k, v]) => (
              <div key={k} className="py-4">
                <dt className="text-[15px] font-medium">{k}</dt>
                <dd className="body mt-1 text-[14.5px]">{v}</dd>
              </div>
            ))}
          </dl>
        </Reveal>
      </div>
      <Reveal>
        <p className="mx-auto mt-8 max-w-3xl text-center text-[13.5px] leading-relaxed text-fg-dim">
          Recall is off until you turn it on, skips password managers, private windows and anything you exclude, and keeps notes 30
          days by default (7, 30, 90 days or forever). Settings → Privacy &amp; Data deletes everything Navi has stored.{" "}
          <a href="/privacy" className="font-medium text-accent hover:underline">
            Read the privacy policy
          </a>
        </p>
      </Reveal>
    </section>
  );
}
