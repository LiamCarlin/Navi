"use client";

import { motion, useMotionValueEvent, useReducedMotion, useScroll, useTransform } from "framer-motion";
import { useRef, useState } from "react";
import { Glyph } from "./Glyph";
import { Lines, Reveal } from "./motion/Reveal";
import { EASE } from "@/lib/motion";
import { progress } from "@/lib/motion";

const SAID = "open spotify and play something calm then remind me to stretch at four";
const WORDS = SAID.split(" ");

/** Clauses as word ranges [from, to) with what Navi did about each. */
const CLAUSES = [
  { from: 0, to: 2, tint: "#0a84ff", kind: "Open app", did: "Spotify is open" },
  { from: 3, to: 6, tint: "#ff375f", kind: "Do it in Spotify", did: "Playing a calm playlist" },
  { from: 7, to: 13, tint: "#ff9f0a", kind: "Reminder", did: "“Stretch”, today at 4:00 PM" },
];
const JOINERS = new Set([2, 6]); // "and", "then"

const FACTS = [
  ["Hears you locally", "Speech turns into text on your Mac. Only the words go anywhere, never the audio."],
  ["Acts while you talk", "Each instruction starts as soon as it’s complete. Spotify is opening while you’re still saying the rest."],
  ["Ignores your speakers", "Music, a video, Navi’s own answers: what your Mac plays is subtracted from the mic, so it never turns into a command."],
  ["Takes corrections", "“No, I meant Thursday” replaces what’s running instead of queueing behind it. “Stop”, “undo” and “pause” work mid-task."],
  ["From anywhere", "⌥Space starts and stops listening, in any app. Or leave it listening from login."],
];

/**
 * Voice: a dark stage that opens out to full bleed as it scrolls in, then pins while the
 * island hears one long sentence word by word and splits it into three jobs.
 */
export function Voice() {
  const reduce = useReducedMotion();
  const wrap = useRef<HTMLElement>(null);
  const pin = useRef<HTMLDivElement>(null);

  const { scrollYProgress: enter } = useScroll({ target: wrap, offset: ["start end", "start start"] });
  const inset = useTransform(enter, [0, 1], [4, 0]);
  const radius = useTransform(enter, [0, 1], [40, 0]);
  const clip = useTransform([inset, radius], ([i, r]) => `inset(0 ${i}% round ${r}px)`);

  const { scrollYProgress } = useScroll({ target: pin, offset: ["start start", "end end"] });
  const [p, setP] = useState(reduce ? 1 : 0);
  useMotionValueEvent(scrollYProgress, "change", (v) => !reduce && setP(Math.round(v * 400) / 400));

  // Words arrive over the first ~60% of the pin; each clause runs shortly after its last word.
  const heard = reduce ? WORDS.length : Math.floor(progress(p, 0.06, 0.6) * WORDS.length + 0.001);
  const open = reduce || p > 0.02;
  const state = (c: (typeof CLAUSES)[number]) => {
    const endP = 0.06 + (c.to / WORDS.length) * 0.54;
    if (p < endP + 0.02) return "none";
    if (p < endP + 0.12) return "running";
    return "done";
  };
  const allDone = CLAUSES.every((c) => state(c) === "done");

  return (
    <motion.section id="voice" ref={wrap} className="stage-dark relative scroll-mt-0 bg-[#050506]" style={reduce ? undefined : { clipPath: clip }}>
      <div className="px-4 pb-10 pt-28 sm:px-6 md:pt-40">
        <div className="mx-auto grid max-w-7xl grid-cols-1 gap-6 lg:grid-cols-12 lg:gap-8">
          <Lines className="h-section lg:col-span-7" lines={["Say three things", "in one breath."]} />
          <Reveal className="lg:col-span-5 lg:pt-3">
            <p className="lede">
              Press <span className="keycap !align-baseline">⌥ Space</span> and the island drops out of the notch. Talk the way
              you’d ask someone sitting next to you. Navi hears where one instruction ends and the next begins, and gets going on
              each.
            </p>
          </Reveal>
        </div>
      </div>

      <div ref={pin} className="relative h-[240vh]">
        <div className="sticky top-0 flex h-screen flex-col justify-center overflow-hidden px-4 sm:px-6">
          {/* The top edge of a screen: menu bar, notch, island */}
          <div className="relative mx-auto w-full max-w-5xl">
            <div className="relative h-8 rounded-t-[18px] border-x border-t border-white/10 bg-[radial-gradient(120%_200%_at_50%_0%,#1b1b2a,#0a0a0f)]">
              <div className="flex h-full items-center justify-between px-4 text-[11px] text-white/55">
                <span className="flex gap-4">
                  <span className="font-semibold text-white/80">Spotify</span>
                  <span className="hidden sm:inline">File</span>
                  <span className="hidden sm:inline">Edit</span>
                </span>
                <span className="flex items-center gap-3">
                  <Glyph gradient className="h-3 w-3" />
                  <span className="tnum">Tue 3:12</span>
                </span>
              </div>
            </div>

            <div className="absolute left-1/2 top-0 z-10 -translate-x-1/2">
              <motion.div
                className="overflow-hidden bg-black text-white"
                style={{ borderRadius: "0 0 26px 26px", boxShadow: open ? "0 30px 80px -20px rgba(0,0,0,0.9), 0 0 0 1px rgba(255,255,255,0.06)" : "none" }}
                initial={false}
                animate={{ width: open ? "min(640px, 92vw)" : 180 }}
                transition={{ duration: 0.5, ease: EASE }}
              >
                <div className="h-8" />
                <motion.div
                  initial={false}
                  animate={{ height: open ? "auto" : 0, opacity: open ? 1 : 0 }}
                  transition={{ duration: 0.5, ease: EASE }}
                >
                  <div className="px-5 pb-5 sm:px-6">
                    <div className="flex items-center gap-3">
                      <Wave active={heard < WORDS.length && open} />
                      <span className="text-[13px] text-white/60">{allDone ? "Done" : heard < WORDS.length ? "Listening" : "Working"}</span>
                    </div>
                    <p className="mt-4 min-h-[3.5em] text-[19px] leading-[1.45] sm:text-[22px]">
                      {WORDS.map((w, i) => {
                        if (i >= heard) return null;
                        const c = CLAUSES.find((c) => i >= c.from && i < c.to);
                        const recognized = c && state(c) !== "none";
                        return (
                          <motion.span
                            key={i}
                            initial={reduce ? false : { opacity: 0, filter: "blur(4px)" }}
                            animate={{ opacity: 1, filter: "blur(0px)" }}
                            transition={{ duration: 0.3 }}
                            className="relative"
                            style={{ color: JOINERS.has(i) ? "rgba(255,255,255,0.35)" : undefined }}
                          >
                            {w}
                            {c && (
                              <motion.span
                                className="absolute -bottom-0.5 left-0 right-0 h-[2px] origin-left rounded-full"
                                style={{ background: c.tint }}
                                initial={false}
                                animate={{ scaleX: recognized ? 1 : 0 }}
                                transition={{ duration: 0.4, ease: EASE, delay: recognized ? (i - c.from) * 0.03 : 0 }}
                              />
                            )}{" "}
                          </motion.span>
                        );
                      })}
                      {heard < WORDS.length && open && <span className="caret" style={{ background: "#bf5af2" }} />}
                    </p>
                    <ul className="mt-4 grid gap-2 border-t border-white/10 pt-4">
                      {CLAUSES.map((c) => {
                        const s = state(c);
                        return (
                          <motion.li
                            key={c.kind}
                            className="flex items-center gap-3 text-[14px]"
                            initial={false}
                            animate={{ opacity: s === "none" ? 0.25 : 1, x: s === "none" ? -6 : 0 }}
                            transition={{ duration: 0.4, ease: EASE }}
                          >
                            <Mark state={s} tint={c.tint} />
                            <span className="w-[8.5rem] shrink-0 text-white/55 sm:w-40">{c.kind}</span>
                            <span className="truncate">{s === "none" ? "…" : c.did}</span>
                          </motion.li>
                        );
                      })}
                    </ul>
                  </div>
                </motion.div>
              </motion.div>
            </div>
            <div className="relative h-[420px] overflow-hidden rounded-b-[18px] border-x border-b border-white/10 bg-[linear-gradient(180deg,#0a0a0f,#050506)] sm:h-[460px]">
              <ScreenBelow s={CLAUSES.map(state)} />
            </div>
          </div>
          <p className="label mx-auto mt-6 w-full max-w-5xl text-center !text-white/45">
            Joiners like “and” and “then” mark where one instruction ends. Without one, a new verb does: “open chrome search for
            cats” is two.
          </p>
        </div>
      </div>

      <div className="px-4 pb-28 sm:px-6 md:pb-40">
        <dl className="mx-auto grid max-w-7xl grid-cols-1 gap-x-8 gap-y-10 border-t border-white/10 pt-12 sm:grid-cols-2 lg:grid-cols-5">
          {FACTS.map(([k, v], i) => (
            <Reveal key={k} i={i}>
              <dt className="text-[15px] font-medium">{k}</dt>
              <dd className="body mt-2 text-[14.5px]">{v}</dd>
            </Reveal>
          ))}
        </dl>
      </div>
    </motion.section>
  );
}

/** What the three clauses did, on the screen under the island: Spotify opens, music plays, a reminder lands. */
function ScreenBelow({ s }: { s: string[] }) {
  const show = (v: boolean) => ({ opacity: v ? 1 : 0, y: v ? 0 : 16, scale: v ? 1 : 0.98 });
  return (
    <>
      <motion.div
        className="absolute bottom-[8%] left-[4%] w-[62%] overflow-hidden rounded-[12px] border border-white/10 bg-[#121214] text-white/80 shadow-[0_30px_60px_-20px_rgba(0,0,0,0.9)] sm:w-[52%]"
        initial={false}
        animate={show(s[0] !== "none")}
        transition={{ duration: 0.6, ease: EASE }}
      >
        <div className="flex h-7 items-center gap-1.5 border-b border-white/10 px-3">
          <span className="h-2 w-2 rounded-full bg-[#ff5f57]" />
          <span className="h-2 w-2 rounded-full bg-[#febc2e]" />
          <span className="h-2 w-2 rounded-full bg-[#28c840]" />
          <span className="ml-2 text-[11px] text-white/50">Spotify</span>
        </div>
        <div className="grid grid-cols-4 gap-2 p-3">
          {["#1db954", "#5e5ce6", "#ff9f0a", "#ff375f", "#40c8e0", "#bf5af2", "#30d158", "#8e8e93"].map((c, i) => (
            <div key={i} className="aspect-square rounded-md" style={{ background: `linear-gradient(150deg, ${c}, ${c}33)` }} />
          ))}
        </div>
        <motion.div
          className="flex items-center gap-3 border-t border-white/10 px-3 py-2.5"
          initial={false}
          animate={{ opacity: s[1] === "done" ? 1 : 0.25 }}
          transition={{ duration: 0.4 }}
        >
          <span className="h-7 w-7 rounded" style={{ background: "linear-gradient(150deg,#5e5ce6,#40c8e0)" }} />
          <div className="min-w-0 flex-1">
            <div className="truncate text-[12px] text-white">{s[1] === "done" ? "Calm Piano" : "Nothing playing"}</div>
            <div className="mt-1 h-[3px] overflow-hidden rounded-full bg-white/10">
              <motion.div className="h-full bg-white/70" initial={false} animate={{ width: s[1] === "done" ? "34%" : "0%" }} transition={{ duration: 1.2, ease: EASE }} />
            </div>
          </div>
        </motion.div>
      </motion.div>

      <motion.div
        className="absolute bottom-[8%] right-[4%] flex w-[250px] max-w-[42%] items-center gap-3 rounded-[14px] border border-white/10 bg-white/[0.08] px-3 py-2.5 text-white backdrop-blur-xl"
        initial={false}
        animate={show(s[2] === "done")}
        transition={{ duration: 0.6, ease: EASE }}
      >
        <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-[8px] bg-white">
          <span className="h-3 w-3 rounded-full border-2 border-[#ff9f0a]" />
        </span>
        <div className="min-w-0">
          <div className="flex items-baseline justify-between gap-2">
            <span className="truncate text-[12px] font-medium">Stretch</span>
            <span className="shrink-0 text-[10px] text-white/50">Reminders</span>
          </div>
          <div className="truncate text-[11px] text-white/60">Today, 4:00 PM</div>
        </div>
      </motion.div>
    </>
  );
}

function Mark({ state, tint }: { state: "none" | "running" | "done"; tint: string }) {
  if (state === "done")
    return (
      <span className="flex h-[18px] w-[18px] shrink-0 items-center justify-center rounded-full text-black" style={{ background: tint }}>
        <svg viewBox="0 0 24 24" className="h-[11px] w-[11px]" fill="none" stroke="currentColor" strokeWidth="3.4" strokeLinecap="round" strokeLinejoin="round">
          <path d="M5 12l5 5 9-10" />
        </svg>
      </span>
    );
  if (state === "running") return <span className="spin h-[18px] w-[18px] shrink-0 rounded-full border-2 border-white/15" style={{ borderTopColor: tint }} />;
  return <span className="h-[18px] w-[18px] shrink-0 rounded-full border border-white/20" />;
}

const BARS = [0.4, 0.75, 1, 0.55, 0.9, 0.45, 0.7, 0.35, 0.6];
function Wave({ active }: { active: boolean }) {
  return (
    <span className="flex h-5 items-center gap-[3px]" aria-hidden="true">
      {BARS.map((h, i) => (
        <span
          key={i}
          className={`w-[3px] rounded-full ${active ? "voice-bar" : "voice-bar-idle"}`}
          style={{ height: `${h * 100}%`, animationDelay: `${i * 0.08}s`, background: active ? "#fff" : "rgba(255,255,255,0.35)" }}
        />
      ))}
    </span>
  );
}
