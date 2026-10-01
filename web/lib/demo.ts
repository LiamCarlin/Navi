/**
 * A toy version of Navi's router, small enough to run in the browser.
 *
 * The app sends what you type to a decision model that returns a typed choice
 * with calibrated probabilities (open / answer / do / schedule / remind / recall…)
 * in roughly a tenth of a second. This file fakes that with a few rules so the
 * bar on the page can react to anything a visitor types. It is a demo, and the
 * page says so.
 */

export type Kind = "open" | "calc" | "answer" | "task" | "schedule" | "remind" | "recall";

export const KIND_LABEL: Record<Kind, string> = {
  open: "Open",
  calc: "Calculate",
  answer: "Answer",
  task: "Do it",
  schedule: "Schedule",
  remind: "Remind",
  recall: "Recall",
};

/** The app's own tint per result kind (PanelStyle.tint). */
export const KIND_TINT: Record<Kind, string> = {
  open: "#0a84ff",
  calc: "#ff9f0a",
  answer: "#bf5af2",
  task: "#ff375f",
  schedule: "#30d158",
  remind: "#ff9f0a",
  recall: "#5e5ce6",
};

export type Decision = {
  kind: Kind;
  probs: Record<Kind, number>;
  /** Would this need the user's OK before it happens? */
  asks: string | null;
  app?: AppHit;
  calc?: { expr: string; result: string; note?: string };
};

export type AppHit = { name: string; tile: string; sub: string };

const APPS: [string, string][] = [
  ["Maps", "maps"],
  ["Messages", "messages"],
  ["Mail", "mail"],
  ["Music", "music"],
  ["Calendar", "calendar"],
  ["Notes", "notes"],
  ["Reminders", "reminders"],
  ["Safari", "browser"],
  ["Finder", "finder"],
  ["System Settings", "settings"],
  ["Slack", "slack"],
  ["Spotify", "music"],
  ["Notion", "doc"],
  ["Pages", "doc"],
  ["Numbers", "app"],
  ["Keynote", "app"],
  ["Xcode", "app"],
  ["Visual Studio Code", "app"],
  ["Figma", "app"],
  ["Zoom", "app"],
  ["Discord", "app"],
  ["WhatsApp", "messages"],
  ["Obsidian", "app"],
  ["Linear", "app"],
  ["Things", "app"],
  ["Terminal", "app"],
  ["Arc", "browser"],
  ["Firefox", "browser"],
  ["Google Chrome", "browser"],
  ["Photos", "app"],
  ["FaceTime", "app"],
  ["Preview", "app"],
  ["Podcasts", "app"],
  ["Weather", "app"],
  ["Calculator", "app"],
  ["Contacts", "app"],
  ["Shortcuts", "app"],
  ["Microsoft Word", "doc"],
  ["Microsoft Excel", "app"],
  ["Outlook", "mail"],
  ["Microsoft Teams", "app"],
];

const SYSTEM: [RegExp, string][] = [
  [/^(toggle |turn (on|off) )?dark mode$/, "Toggle Dark Mode"],
  [/^(turn (on|off) )?(do not disturb|dnd|focus)$/, "Toggle Do Not Disturb"],
  [/^(lock( screen)?|lock my mac)$/, "Lock Screen"],
  [/^(sleep|go to sleep)$/, "Sleep"],
  [/^empty (the )?trash$/, "Empty Trash"],
  [/^(mute|unmute)$/, "Toggle Mute"],
];

export function findApp(q: string): AppHit | undefined {
  const s = q.trim().toLowerCase().replace(/^open\s+/, "");
  if (s.length < 2) return undefined;
  for (const [name, tile] of APPS) {
    const n = name.toLowerCase();
    if (n.startsWith(s) || n.split(" ").some((w) => w.length > 2 && w.startsWith(s) && s.length >= 3)) {
      return { name, tile, sub: name === "Maps" || name === "Messages" ? "Running" : "Application" };
    }
  }
  for (const [re, title] of SYSTEM) if (re.test(s)) return { name: title, tile: "settings", sub: "System" };
  return undefined;
}

/** Arithmetic, percentages and "18% tip on $64.50". Characters are whitelisted before evaluating. */
export function calculate(q: string): Decision["calc"] {
  let s = q.trim().toLowerCase();
  if (!/\d/.test(s)) return undefined;
  const pct = s.match(/^(\d+(?:\.\d+)?)\s*%\s*(?:tip\s+)?(?:of|on)\s+\$?(\d+(?:\.\d+)?)$/);
  if (pct) {
    const v = (parseFloat(pct[1]) / 100) * parseFloat(pct[2]);
    const money = s.includes("$") || s.includes("tip");
    return {
      expr: `${pct[1]}% of ${money ? "$" : ""}${pct[2]}`,
      result: money ? `$${v.toFixed(2)}` : fmt(v),
      note: money ? `total $${(v + parseFloat(pct[2])).toFixed(2)}` : undefined,
    };
  }
  s = s.replace(/[×x]/g, "*").replace(/÷/g, "/").replace(/\^/g, "**").replace(/,/g, "").replace(/^=\s*/, "");
  if (!/^[\d\s+\-*/().%]+$/.test(s) || !/[+\-*/%]/.test(s.replace(/^-/, ""))) return undefined;
  try {
    const v = Function(`"use strict";return (${s.replace(/(\d+(?:\.\d+)?)%/g, "($1/100)")})`)() as number;
    if (typeof v !== "number" || !isFinite(v)) return undefined;
    return { expr: q.trim(), result: fmt(v) };
  } catch {
    return undefined;
  }
}

const fmt = (v: number) => (Math.abs(v) >= 1e12 ? v.toExponential(4) : Number(v.toFixed(8)).toLocaleString("en-US", { maximumFractionDigits: 8 }));

const RE = {
  remind: /^(remind me|todo:?|to-do:?|don'?t forget|set a reminder|add a reminder|reminder:?)\b/,
  schedule: /\b(meeting|meet|call|sync|1:1|one on one|lunch|coffee)\b.*\bwith\b|\b(schedule|book|set up)\b.*\b(meeting|call|time)\b/,
  recall: /\b(what was i|what did i|where did i|when did i|was i (working|reading|doing)|i was (reading|looking|working)|yesterday|last (week|night|tuesday|monday|friday)|earlier today|that (article|tab|doc|page) i)\b/,
  task: /^(text|message|send|email|mail|reply|make|create|write|draft|book|find|search|look up|play|add|share|order|post|go to|open \w+ and|open \w+ then|fill|rename|move|turn|set|get me|download|summari[sz]e|translate|join)\b|\b(and|then) (search|find|send|play|open|click|text|email)\b/,
  question: /^(what|how|why|who|whom|when|where|which|is|are|can|could|does|do|did|should|would|will|explain|define|tell me)\b|\?$/,
  irreversible: /\b(text|message|send|email|mail|reply|post|order|buy|pay|delete|remove|book|share)\b/,
};

export function decide(q: string): Decision | null {
  const s = q.trim().toLowerCase();
  if (!s) return null;
  const probs: Record<Kind, number> = { open: 0.02, calc: 0.01, answer: 0.04, task: 0.03, schedule: 0.01, remind: 0.01, recall: 0.01 };
  let kind: Kind;
  let asks: string | null = null;
  const calc = calculate(q);
  const app = findApp(q);

  if (calc) kind = "calc";
  else if (RE.remind.test(s)) kind = "remind";
  else if (RE.schedule.test(s)) kind = "schedule";
  else if (RE.recall.test(s)) kind = "recall";
  else if (app && s.split(/\s+/).length <= 3) kind = "open";
  else if (RE.task.test(s)) kind = "task";
  else if (RE.question.test(s) || s.split(/\s+/).length >= 3) kind = "answer";
  else kind = app ? "open" : "answer";

  // Confidence grows with length: one or two letters are a guess, a sentence is not.
  const words = s.split(/\s+/).length;
  const sure = Math.min(0.97, 0.52 + words * 0.09 + (kind === "calc" ? 0.3 : 0) + (kind === "open" && app ? 0.3 : 0));
  probs[kind] = sure;
  const rest = 1 - sure;
  const runner: Kind = kind === "open" ? "answer" : kind === "answer" ? "task" : kind === "task" ? "answer" : kind === "recall" ? "answer" : kind === "schedule" ? "remind" : kind === "remind" ? "schedule" : "answer";
  probs[runner] = rest * 0.6;
  const others = (Object.keys(probs) as Kind[]).filter((k) => k !== kind && k !== runner);
  for (const k of others) probs[k] = (rest * 0.4) / others.length;

  if (kind === "task" && RE.irreversible.test(s)) {
    const verb = s.match(RE.irreversible)?.[1] ?? "send";
    asks = ["delete", "remove"].includes(verb) ? "before deleting" : ["buy", "pay", "order", "book"].includes(verb) ? "before paying" : "before sending";
  }
  if (kind === "schedule") asks = "before inviting anyone";
  return { kind, probs, asks, app, calc };
}

/* ------------------------------------------------------------------ examples */

export type Example = {
  q: string;
  kind: Kind;
  /** What the panel shows after ⏎, as data; rendered by components/bar/bodies.tsx. */
  final:
    | { type: "open"; app: string; tile: string; sub: string }
    | { type: "calc"; expr: string; result: string; note?: string }
    | { type: "answer"; text: string; source: string }
    | { type: "task"; title: string; app: string; steps: string[]; ask?: string }
    | { type: "schedule" }
    | { type: "remind"; task: string; due: string; repeat?: string; list: string; chip: number }
    | { type: "recall" };
};

export const EXAMPLES: Example[] = [
  { q: "maps", kind: "open", final: { type: "open", app: "Maps", tile: "maps", sub: "Running" } },
  { q: "18% tip on $64.50", kind: "calc", final: { type: "calc", expr: "18% of $64.50", result: "$11.61", note: "total $76.11" } },
  {
    q: "how far away is the moon",
    kind: "answer",
    final: {
      type: "answer",
      text: "About 384,400 km (238,855 miles) on average. The orbit is an ellipse, so it ranges from roughly 363,300 km at its closest to 405,500 km at its farthest.",
      source: "Answered in the bar · ⌘C copies it",
    },
  },
  {
    q: "text sam i’m 10 minutes late",
    kind: "task",
    final: {
      type: "task",
      title: "Text Sam “I’m 10 minutes late”",
      app: "messages",
      steps: ["Open Messages in the background", "To: “sam” → picked the contact Sam Rivera", "Type “I’m 10 minutes late”"],
      ask: "send this to Sam Rivera",
    },
  },
  { q: "meeting with maya and theo tomorrow afternoon", kind: "schedule", final: { type: "schedule" } },
  { q: "remind me to call mom tomorrow at 5", kind: "remind", final: { type: "remind", task: "Call mom", due: "Tomorrow, 5:00 PM", list: "Reminders", chip: 2 } },
  { q: "what was i working on yesterday afternoon", kind: "recall", final: { type: "recall" } },
  { q: "dark mode", kind: "open", final: { type: "open", app: "Toggle Dark Mode", tile: "settings", sub: "System" } },
];
