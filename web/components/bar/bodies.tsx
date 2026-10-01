import type { ReactNode } from "react";
import { AnswerBody, CalcBody, RecallBody, ReminderCard, Rows, ScheduleCard, TaskBody, type Hint, type RowData, type StepData, type Tile } from "./Bar";
import type { Decision, Example } from "@/lib/demo";

/** What the panel shows while you type: the same three-ish rows the app shows. */
export function liveRows(q: string, d: Decision): { body: ReactNode; key: string; hints: Hint[] } {
  const query = q.trim();
  const ask: RowData = { tile: "ask", title: `Ask Navi: ${query}`, sub: "Answer this question", action: "answer" };
  const doIt: RowData = { tile: "task", title: `Ask Navi: ${query}`, sub: "Do this for me · runs in the background", action: "run" };
  const web: RowData = { tile: "search", title: `Search the web for “${query}”`, sub: "Default browser" };
  let rows: RowData[];
  switch (d.kind) {
    case "open":
      rows = d.app ? [{ tile: d.app.tile as Tile, title: d.app.name, sub: d.app.sub, action: d.app.sub === "System" ? "run" : "open" }, ask, web] : [ask, web];
      break;
    case "task":
      rows = [doIt, ask, web];
      break;
    case "recall":
      rows = [{ tile: "memory", title: `Ask your memory: ${query}`, sub: "Recall · read from your screen history", action: "ask" }, ask];
      break;
    case "schedule":
      rows = [{ tile: "calendar", title: "New meeting", sub: "Opens the scheduler card", action: "plan" }, ask];
      break;
    case "remind":
      rows = [{ tile: "reminders", title: "New reminder", sub: "Opens the reminder card", action: "add" }, ask];
      break;
    case "calc":
      return { body: <CalcBody {...d.calc!} />, key: "calc", hints: [{ keys: "esc", label: "close" }] };
    default:
      rows = [ask, web];
  }
  return { body: <Rows rows={rows} />, key: `rows-${d.kind}-${rows[0].title}`, hints: [{ keys: "↑↓", label: "navigate" }, { keys: "⏎", label: rows[0].action ?? "open" }, { keys: "⌘⏎", label: "ask" }] };
}

export const SCHEDULE = {
  title: "Meeting with Maya and Theo",
  when: "Tue, Oct 14 · 30 min",
  people: [
    { name: "You", initials: "YO", tint: "#5e5ce6", busy: [[9.5, 10.5], [12, 13], [15.5, 16.5]] as [number, number][] },
    { name: "Maya", initials: "MP", tint: "#ff375f", busy: [[9, 11], [13, 14], [16, 17.5]] as [number, number][] },
    { name: "Theo", initials: "TA", tint: "#ff9f0a", busy: [[10, 12], [13.5, 14], [15, 15.5]] as [number, number][] },
  ],
  slots: ["2:00 pm", "2:30 pm", "4:30 pm"],
  range: [14, 14.5] as [number, number],
};

export const RECALL = {
  answer:
    "Mostly the pricing doc. You were in Pages from about 1:10 to 2:40, then read two articles about annual billing in Safari, and spent the last hour in Xcode on the results-list animation.",
  moments: [
    { time: "13:10", app: "doc" as Tile, line: "Pages · “Pricing: Free, Pro, Pro + Recall”" },
    { time: "14:42", app: "browser" as Tile, line: "Safari · two articles on annual vs. monthly plans" },
    { time: "16:05", app: "app" as Tile, line: "Xcode · ResultsListView.swift" },
  ],
};

/** What the panel shows after ⏎ for a scripted example, `t` ms after it was pressed. */
export function exampleBody(ex: Example, t: number): { body: ReactNode; key: string; hints: Hint[] } {
  const f = ex.final;
  switch (f.type) {
    case "open":
      return {
        body: <Rows rows={[{ tile: f.tile as Tile, title: f.app, sub: f.sub === "System" ? "Done · Dark Mode is on" : "Opened", action: f.sub === "System" ? "run" : "open" }]} />,
        key: "open-" + f.app,
        hints: [{ keys: "esc", label: "close" }],
      };
    case "calc":
      return { body: <CalcBody expr={f.expr} result={f.result} note={f.note} />, key: "calc", hints: [{ keys: "esc", label: "close" }] };
    case "answer": {
      const shown = Math.floor(Math.max(0, t - 350) / 14);
      return { body: <AnswerBody text={f.text} shown={Math.min(f.text.length, shown)} source={f.source} />, key: "answer", hints: [{ keys: "⌘C", label: "copy" }, { keys: "esc", label: "back" }] };
    }
    case "task": {
      const per = 650;
      const steps: StepData[] = f.steps.map((label, i) => ({ label, state: t > (i + 1) * per ? "done" : t > i * per ? "running" : "waiting" }));
      const asking = f.ask && t > f.steps.length * per + 150;
      return {
        body: <TaskBody title={f.title} app={f.app as Tile} steps={steps} ask={asking ? f.ask : undefined} />,
        key: "task",
        hints: asking ? [{ keys: "⌘⏎", label: "approve" }, { keys: "⌘⌫", label: "deny" }] : [{ keys: "esc", label: "stop" }],
      };
    }
    case "schedule":
      return {
        body: <ScheduleCard {...SCHEDULE} picked={0} />,
        key: "schedule",
        hints: [{ keys: "↑↓", label: "time" }, { keys: "⌘[ ⌘]", label: "day" }, { keys: "⌘- ⌘=", label: "length" }, { keys: "⏎", label: "book" }],
      };
    case "remind":
      return { body: <ReminderCard task={f.task} due={f.due} list={f.list} chip={f.chip} repeat={f.repeat} />, key: "remind", hints: [{ keys: "↑↓", label: "when" }, { keys: "⏎", label: "add" }] };
    case "recall":
      return { body: <RecallBody {...RECALL} />, key: "recall", hints: [{ keys: "⏎", label: "open note" }, { keys: "esc", label: "back" }] };
  }
}

/** After ⏎ on something a visitor typed: honest about being a page, not the app. */
export function visitorBody(q: string, d: Decision): { body: ReactNode; key: string; hints: Hint[] } {
  switch (d.kind) {
    case "calc":
      return { body: <CalcBody {...d.calc!} />, key: "calc", hints: [{ keys: "esc", label: "close" }] };
    case "open":
      return {
        body: <Rows rows={[{ tile: (d.app?.tile ?? "app") as Tile, title: d.app?.name ?? q, sub: "On your Mac this would open instantly, no network involved" }]} />,
        key: "v-open",
        hints: [{ keys: "esc", label: "back" }],
      };
    case "task":
      return {
        body: (
          <TaskBody
            title={q}
            app="task"
            steps={[
              { label: "Plan: split it into one step per app", state: "done" },
              { label: "Run each step in the background", state: "waiting" },
            ]}
            ask={d.asks ? `stop and ask you ${d.asks}` : undefined}
          />
        ),
        key: "v-task",
        hints: [{ keys: "esc", label: "stop" }],
      };
    default:
      return {
        body: (
          <AnswerBody
            text={`This bar is a demo on a web page, so nothing runs here. In Navi, ${
              d.kind === "recall" ? "the answer would come from notes about your own screen, kept on your Mac." : d.kind === "schedule" ? "the scheduler card would open with everyone’s free times." : d.kind === "remind" ? "the reminder card would open with the due date filled in." : "the answer would stream into the bar right here."
            }`}
            source="Join the waitlist to try the real one."
          />
        ),
        key: "v-" + d.kind,
        hints: [{ keys: "esc", label: "back" }],
      };
  }
}
