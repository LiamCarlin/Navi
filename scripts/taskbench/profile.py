#!/usr/bin/env python3
"""Navi task lag profile + historical outcomes, from the logs Navi already writes.

    scripts/taskbench/profile.py                 # print the report (markdown)
    scripts/taskbench/profile.py --write         # also refresh the generated block in docs/TASK_BENCH.md
    scripts/taskbench/profile.py --json          # machine-readable per-run rows
    scripts/taskbench/profile.py --since 2026-10-30   # only runs from that day on
    scripts/taskbench/profile.py --logs DIR      # another copy of ~/Library/Logs/Navi

Reads (all optional except agent-runs.log):
    agent-runs.1.log, agent-runs.log   every run, one event per line, seconds since the run began
    runs/<stamp>/run.json              native-driver runs: goal_achieved, outcome, call counts
    ultrafast-last-run.jsonl           browser runner's last run (step elapsed_ms, settle counts)
    debug.log                          Debug builds only: the voice trace (speech → commit)

Python 3 standard library only. Read-only: it never writes to the log directory.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_LOGS = Path.home() / "Library/Logs/Navi"
DOC = ROOT / "docs/TASK_BENCH.md"
BEGIN, END = "<!-- profile:begin -->", "<!-- profile:end -->"

RUN_HEAD = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) \+0000  task: (.*)$")
EVENT = re.compile(r"^\s+(\d+(?:\.\d+)?)s  (.*)$")
JEV_LINE = re.compile(r"^status: Jev · (\S+)(?: \[[^\]]*\])?(?: (\d+)%)? · (\d+) ms")
CALLS = re.compile(r"calls: jev (\d+) \([^,]*, ([\d.]+)s\)\s+writer (\d+) \([^,]*, ([\d.]+)s\)\s+handoffs (\d+)")
SETTLED = re.compile(r"settled after (\d+) observation")
NATIVE_PERCEPTION = re.compile(r"^status: Jev-driven · .* · (\d+) ms")
WRITER_READ = re.compile(r"^status: Read the screen in (\d+) ms")
COACH = re.compile(r"^status: Claude · (\d+) ms")


# ----------------------------------------------------------------------------- parsing

def parse_runs(paths):
    runs = []
    for p in paths:
        if not p.exists():
            continue
        cur = None
        for raw in p.read_text(errors="replace").splitlines():
            m = RUN_HEAD.match(raw)
            if m:
                cur = {"start": dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").replace(tzinfo=dt.timezone.utc),
                       "task": m.group(2).strip(), "events": []}
                runs.append(cur)
                continue
            if cur is None:
                continue
            m = EVENT.match(raw)
            if m:
                cur["events"].append((float(m.group(1)), m.group(2)))
            elif raw.strip() and cur["events"]:
                # continuation line (a completion's follow-up question, multi-line guidance)
                t, msg = cur["events"][-1]
                cur["events"][-1] = (t, msg + "\n" + raw.strip())
    runs.sort(key=lambda r: r["start"])
    return runs


def load_run_folders(logs: Path):
    out = []
    d = logs / "runs"
    if not d.is_dir():
        return out
    for sub in sorted(d.iterdir()):
        f = sub / "run.json"
        if not f.exists():
            continue
        try:
            j = json.loads(f.read_text())
            stamp = dt.datetime.strptime(sub.name.split(".")[0], "%Y%m%dT%H%M%S")  # local time
            j["_local_start"] = stamp
            out.append(j)
        except Exception:
            continue
    return out


# ----------------------------------------------------------------------------- families & outcomes

FAMILY_RULES = [
    # Unambiguous native-app phrasings first ("a new note … hello class" is Notes, not a class).
    ("native", r"\b(new note|notes app|in notes|apple music|in music|playlist|song|finder|system settings|dark mode)\b"),
    ("errand", r"\b(order|buy|purchase|cart|checkout|doordash|uber ?eats|grubhub|mcdonald'?s?|mcdonalds|chipotle|kfc|amazon|burgers?|big mac|pizza|deliver(y)?|flights?|book (a|me)|reserve|tickets?|groceries|toil+et paper)\b"),
    ("messaging", r"\b(text|message|messages|imessage|whatsapp|slack|email|e-mail|mail|outlook|gmail|reply|respond|dm|send (a |an )?(message|email|text)|tell \w+ that)\b"),
    ("schoolwork", r"\b(canvas|assignment|assignments|homework|class|course|courses|syllabus|quiz|lecture|google docs?|docs|document|doc|sheet|spreadsheet|slides|essay|lab report|onshape|cannabis assignment)\b"),
    ("native", r"\b(notes?|music|playlist|song|play|pause|calendar|event|finder|folder|file|settings|system settings|dark mode|wi-?fi|bluetooth|volume|reminders?|photos|maps|safari|preview|terminal|app)\b"),
]


def family(task: str) -> str:
    t = task.lower()
    for name, rx in FAMILY_RULES:
        if re.search(rx, t):
            return name
    return "other"


SUCCESS_PREFIX = re.compile(r"^(Done:|Ready for you to place the order|Completed in \d+ steps?)")
NOT_ACHIEVED = re.compile(
    r"\b(I don'?t see|I couldn'?t|couldn'?t|can'?t confirm|cannot|can not|isn'?t confirmed|not confirmed|hasn'?t been|has not been|"
    r"wasn'?t able|unable to|I'?d need to|Nothing to do|no longer|didn'?t find|not found|isn'?t possible)\b", re.I)
CORRECTION = re.compile(r"^(i meant|no[, ]|nope|not that|wrong|that'?s not|i said|actually)", re.I)

FAIL_REASONS = [
    ("start page unrelated to the task", r"unrelated to this (page|canvas|site)|unrelated to this|no food[- ]ordering"),
    ("loop / going in circles", r"going in circles|keeps re-?(opening|clicking)|toggling|re-clicking|repeatedly clicking|loop"),
    ("modal / overlay / banner in the way", r"modal|overlay|banner|qr-?code|popup|pop-up"),
    ("stuck (no progress)", r"stuck|changed nothing|stalled"),
    ("browser session / CDP error", r"Session with given id|Broken pipe|websocket|CDP|-320\d\d"),
    ("action could not be executed", r"execution was not confirmed|can'?t be clicked|could not (click|type)"),
    ("goal not reached (writer verdict)", r"hasn'?t been created|has not been created|not titled|still empty|not .*yet"),
]


def fail_reason(text: str) -> str:
    for name, rx in FAIL_REASONS:
        if re.search(rx, text, re.I):
            return name
    return "other"


def classify_outcome(run, folder):
    """success | false_done (said completed but didn't do it) | failed | cancelled | unknown"""
    term = None
    for t, msg in run["events"]:
        for k in ("completed", "failed", "cancelled"):
            if msg == k or msg.startswith(k + ":"):
                term = (k, msg[len(k) + 1:].strip() if ":" in msg[: len(k) + 1] else "", t)
    if term is None:
        return "unknown", "no terminal event", None
    kind, text, t = term
    if kind == "cancelled":
        return "cancelled", "cancelled by the user", t
    if kind == "failed":
        return "failed", fail_reason(text), t
    first = text.split("\n")[0]
    if folder is not None and folder.get("goal_achieved") is False:
        return "false_done", "completed without achieving the goal (run.json goal_achieved=false)", t
    if folder is not None and folder.get("outcome") == "question":
        return "false_done", "ended with a question", t
    if SUCCESS_PREFIX.match(first) and not re.search(r"\(0 steps", first):
        if re.search(r"\bcannot\b|\bI can only\b", first, re.I):
            return "false_done", "claimed done but said it could not act", t
        return "success", "", t
    if NOT_ACHIEVED.search(first) or "\n" in text:  # a follow-up question means it handed the task back
        return "false_done", "completed without achieving the goal", t
    return "success", "", t


# ----------------------------------------------------------------------------- timing

def is_driver_start(msg: str) -> bool:
    return (msg.startswith("planned: Jev Ultrafast") or msg.startswith("status: Connecting to Chrome")
            or msg.startswith("status: Opening ") or msg.startswith("status: Jev-driven"))


def time_breakdown(run):
    ev = run["events"]
    out = defaultdict(float)
    counts = Counter()
    if not ev:
        return out, counts, {}
    end = ev[-1][0]
    out["total"] = end
    extra = {"jev_latencies": [], "settle_obs": [], "step_walls": [], "chrome_connect": None,
             "first_action": None, "native_open": None, "surface": None, "ready_to_first_step": None}
    ready_at = None
    # prep: task start → first driver event (planning, grounding, routines, surface pick)
    prep_end = next((t for t, m in ev if is_driver_start(m)), None)
    if prep_end is not None:
        out["prep"] = prep_end
    else:
        out["prep"] = end
    connect_at = opening_at = None
    last_jev_t = None
    writer_from_calls = None
    reading = False
    for i, (t, m) in enumerate(ev):
        if m.startswith("status: Connecting to Chrome"):
            connect_at = t
            extra["surface"] = "browser"
        elif m.startswith("status: Page ready") and connect_at is not None:
            extra["chrome_connect"] = t - connect_at
            out["chrome_connect"] += t - connect_at
            connect_at = None
            ready_at = t
        elif m.startswith("status: Opening "):
            opening_at = t
            extra["surface"] = extra["surface"] or "native"
        mp = NATIVE_PERCEPTION.match(m)
        if mp:
            extra["surface"] = extra["surface"] or "native"
            if opening_at is not None:
                extra["native_open"] = t - opening_at
                out["native_open"] += t - opening_at
                opening_at = None
            out["perception"] += int(mp.group(1)) / 1000.0
        mj = JEV_LINE.match(m)
        if mj:
            lat = int(mj.group(3)) / 1000.0
            out["jev"] += lat
            counts["jev_calls"] += 1
            extra["jev_latencies"].append(lat)
            if ready_at is not None and extra["ready_to_first_step"] is None:
                extra["ready_to_first_step"] = t - ready_at
        # One wall-clock step = one action line to the next (the runner emits Jev lines in bursts).
        if m.startswith("step ") and "Coach" not in m and "Check Not done" not in m:
            if extra["first_action"] is None:
                extra["first_action"] = t
            if last_jev_t is not None and t > last_jev_t:
                extra["step_walls"].append(t - last_jev_t)
            last_jev_t = t
        ms = SETTLED.search(m)
        if ms:
            extra["settle_obs"].append(int(ms.group(1)))
        mw = WRITER_READ.match(m)
        if mw:
            out["writer_reads"] += int(mw.group(1)) / 1000.0
            counts["writer_calls"] += 1
        mc = COACH.match(m)
        if mc:
            out["coach"] += int(mc.group(1)) / 1000.0
            counts["coach_calls"] += 1
        if "diagnosis was unavailable" in m and i > 0:
            out["coach"] += t - ev[i - 1][0]
        mcalls = CALLS.search(m)
        if mcalls:
            writer_from_calls = float(mcalls.group(4))
            counts["writer_calls"] = max(counts["writer_calls"], int(mcalls.group(3)))
            counts["handoffs"] += int(mcalls.group(5))
        if "reading the screen" in m:
            reading = True
    # Writer: the native driver's own tally when it printed one; else the browser coach/writer reads
    out["writer"] = writer_from_calls if writer_from_calls is not None else out["writer_reads"]
    out.pop("writer_reads", None)
    if len(ev) > 1 and ev[-1][1] == "cancelled":
        out["cancel_wait"] = ev[-1][0] - ev[-2][0]
    accounted = out["prep"] + out["chrome_connect"] + out["native_open"] + out["jev"] + out["writer"] + out["coach"] + out["cancel_wait"]
    # "perception" in native runs overlaps native_open for the first snapshot: not added separately.
    out["act_settle_observe"] = max(0.0, end - accounted)
    return out, counts, extra


# ----------------------------------------------------------------------------- voice trace

DEBUG_LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) (.*)$")


def voice_waits(logs: Path):
    """speech end (last ASR change of the clause) → commit, from the Debug-build trace."""
    f = logs / "debug.log"
    if not f.exists():
        return [], 0
    last_asr = None
    waits = []
    commits = []
    for raw in f.read_text(errors="replace").splitlines():
        m = DEBUG_LINE.match(raw)
        if not m:
            continue
        ts = dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f")
        msg = m.group(2)
        if msg.startswith("voice asr") or msg.startswith("voice transcript"):
            last_asr = ts
        elif msg.startswith("voice commit") or msg.startswith("voice replace"):
            if last_asr is not None:
                waits.append((ts - last_asr).total_seconds())
            commits.append((ts, msg))
        elif msg.startswith("voice listener ready"):
            last_asr = None
    return waits, len(commits)


# ----------------------------------------------------------------------------- stats

def pct(xs, p):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    if len(xs) == 1:
        return xs[0]
    k = (len(xs) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def fmt(x, unit="s"):
    return "—" if x is None else (f"{x:.2f} {unit}" if unit == "s" else f"{x:.0f} {unit}")


def match_folder(run, folders):
    for f in folders:
        if f.get("goal", "").strip() != run["task"].strip():
            continue
        # run folders are local time; agent-runs.log is UTC. Accept a match within ±14 h by goal, nearest.
        return f
    return None


def analyse(logs: Path, since: dt.date | None):
    runs = parse_runs([logs / "agent-runs.1.log", logs / "agent-runs.log"])
    if since:
        runs = [r for r in runs if r["start"].date() >= since]
    folders = load_run_folders(logs)
    rows = []
    for i, r in enumerate(runs):
        folder = None
        local = r["start"].astimezone().replace(tzinfo=None)
        for f in folders:
            if f.get("goal", "").strip() == r["task"].strip() and abs((f["_local_start"] - local).total_seconds()) < 120:
                folder = f
                break
        outcome, reason, _ = classify_outcome(r, folder)
        nxt = runs[i + 1] if i + 1 < len(runs) else None
        if outcome == "success" and nxt and CORRECTION.match(nxt["task"]) and (nxt["start"] - r["start"]).total_seconds() < 60:
            outcome, reason = "false_done", f"corrected by the user's next words (“{nxt['task'][:40]}”)"
        times, counts, extra = time_breakdown(r)
        rows.append({"start": r["start"].isoformat(), "task": r["task"], "family": family(r["task"]),
                     "outcome": outcome, "reason": reason, "times": dict(times), "counts": dict(counts),
                     "extra": extra})
    return rows


def report(rows, logs: Path) -> str:
    L = []
    if not rows:
        return "No runs found in agent-runs.log.\n"
    first, last = rows[0]["start"][:16].replace("T", " "), rows[-1]["start"][:16].replace("T", " ")
    L.append(f"_Generated {dt.datetime.now().strftime('%Y-%m-%d %H:%M')} by `scripts/taskbench/profile.py` from `{logs}` — "
             f"{len(rows)} runs, {first} → {last} UTC._\n")

    # ---- outcomes per family
    L.append("### Outcomes per family (all runs in the log)\n")
    L.append("`success` = finished and did what was asked (heuristic: \"Done:\" / cart reached / native run.json `goal_achieved`); "
             "`false done` = reported *completed* but didn't do it (handed back a question, said it couldn't, or the user corrected it next); "
             "`cancelled` = the user stopped it (usually because it was slow or going the wrong way).\n")
    fams = ["errand", "schoolwork", "messaging", "native", "other"]
    L.append("| family | runs | success | false done | failed | cancelled | success rate |")
    L.append("|---|---:|---:|---:|---:|---:|---:|")
    tot = Counter()
    for f in fams:
        rs = [r for r in rows if r["family"] == f]
        if not rs:
            continue
        c = Counter(r["outcome"] for r in rs)
        tot.update(c)
        tot["runs"] += len(rs)
        L.append(f"| {f} | {len(rs)} | {c['success']} | {c['false_done']} | {c['failed']} | {c['cancelled']} | {100 * c['success'] / len(rs):.0f}% |")
    L.append(f"| **all** | {tot['runs']} | {tot['success']} | {tot['false_done']} | {tot['failed']} | {tot['cancelled']} | "
             f"**{100 * tot['success'] / max(1, tot['runs']):.0f}%** |\n")

    L.append("**Failure reasons** (failed + false done):\n")
    reasons = Counter(r["reason"] for r in rows if r["outcome"] in ("failed", "false_done"))
    L.append("| reason | runs |")
    L.append("|---|---:|")
    for k, v in reasons.most_common():
        L.append(f"| {k} | {v} |")
    L.append("")

    # ---- per-run table
    L.append("<details><summary>Every run</summary>\n")
    L.append("| UTC | family | task | outcome | total | prep | chrome | jev | writer+coach | act/settle |")
    L.append("|---|---|---|---|---:|---:|---:|---:|---:|---:|")
    for r in rows:
        t = r["times"]
        task = r["task"].replace("|", "/")[:60]
        L.append(f"| {r['start'][5:16].replace('T', ' ')} | {r['family']} | {task} | {r['outcome']}"
                 f"{(' — ' + r['reason']) if r['reason'] else ''} | {t.get('total', 0):.1f} | {t.get('prep', 0):.1f} | "
                 f"{t.get('chrome_connect', 0):.1f} | {t.get('jev', 0):.1f} | {t.get('writer', 0) + t.get('coach', 0):.1f} | "
                 f"{t.get('act_settle_observe', 0):.1f} |")
    L.append("\n</details>\n")

    # ---- lag profile
    L.append("### Where the time goes\n")
    L.append("Per run, the run's wall time is split into: **prep** (task start → first driver event: planning, grounding, "
             "routine match, surface pick), **chrome connect** (`Connecting to Chrome…` → `Page ready`), **native open** "
             "(`Opening <app>` → first AX snapshot), **Jev** (sum of the per-step latencies Jev reports), **writer** "
             "(Claude reading the screen / answering, native driver's `calls:` tally), **coach** (Claude diagnosing a stuck "
             "browser run), and **act/settle/observe** (the rest: executing the action, waiting for the page to settle, "
             "re-reading the page/AX tree between steps, waits).\n")
    cats = ["prep", "chrome_connect", "native_open", "jev", "writer", "coach", "cancel_wait", "act_settle_observe"]
    names = {"prep": "prep (plan/ground/routine)", "chrome_connect": "chrome connect → page ready",
             "native_open": "native app open → first AX", "jev": "Jev decisions", "writer": "writer (Claude)",
             "coach": "coach (Claude, stuck)", "act_settle_observe": "act + settle + observe",
             "cancel_wait": "last event → user cancelled"}
    total_all = sum(r["times"].get("total", 0) for r in rows)
    L.append("| phase | runs with it | median / run | p90 / run | total | share of all run time |")
    L.append("|---|---:|---:|---:|---:|---:|")
    shares = {}
    for c in cats:
        xs = [r["times"].get(c, 0) for r in rows if r["times"].get(c, 0) > 0]
        s = sum(xs)
        shares[c] = s
        L.append(f"| {names[c]} | {len(xs)} | {fmt(pct(xs, .5))} | {fmt(pct(xs, .9))} | {s:.1f} s | {100 * s / max(total_all, 1e-9):.0f}% |")
    tots = [r["times"].get("total", 0) for r in rows]
    L.append(f"| **whole run** | {len(rows)} | {fmt(pct(tots, .5))} | {fmt(pct(tots, .9))} | {total_all:.1f} s | 100% |\n")

    jl = [x for r in rows for x in r["extra"]["jev_latencies"]]
    sw = [x for r in rows if r["extra"]["surface"] == "browser" for x in r["extra"]["step_walls"]]
    swn = [x for r in rows if r["extra"]["surface"] == "native" for x in r["extra"]["step_walls"]]
    so = [x for r in rows for x in r["extra"]["settle_obs"]]
    cc = [r["extra"]["chrome_connect"] for r in rows if r["extra"]["chrome_connect"] is not None]
    no = [r["extra"]["native_open"] for r in rows if r["extra"]["native_open"] is not None]
    fa = [r["extra"]["first_action"] for r in rows if r["extra"]["first_action"] is not None]
    L.append("| per-occurrence measure | n | median | p90 | max |")
    L.append("|---|---:|---:|---:|---:|")
    for label, xs in [("Jev call latency", jl), ("browser step wall time (action → next action)", sw),
                      ("native step wall time", swn), ("Connecting to Chrome… → Page ready", cc),
                      ("Opening <app> → first AX snapshot", no), ("task start → first action", fa)]:
        L.append(f"| {label} | {len(xs)} | {fmt(pct(xs, .5))} | {fmt(pct(xs, .9))} | {fmt(max(xs) if xs else None)} |")
    rf = [r["extra"]["ready_to_first_step"] for r in rows if r["extra"]["ready_to_first_step"] is not None]
    L.append(f"| Page ready → first browser step done (observe + Jev + act + settle) | {len(rf)} | {fmt(pct(rf, .5))} | "
             f"{fmt(pct(rf, .9))} | {fmt(max(rf) if rf else None)} |")
    if so:
        L.append(f"| page settle: observations per changed page | {len(so)} | {pct(so, .5):.0f} | {pct(so, .9):.0f} | {max(so)} |")
    wc = [r["counts"].get("writer_calls", 0) + r["counts"].get("coach_calls", 0) for r in rows]
    L.append(f"| Claude calls per run (writer + coach) | {len(wc)} | {pct(wc, .5):.0f} | {pct(wc, .9):.0f} | {max(wc)} |")
    L.append("")

    # ---- ranked lag sources
    def per_run(c):
        return [r["times"][c] for r in rows if r["times"].get(c, 0) > 0]

    L.append("**Lag sources, ranked by total time across all runs:**\n")
    evidence = {
        "act_settle_observe": f"browser step wall median {fmt(pct(sw, .5))}, p90 {fmt(pct(sw, .9))}; a changed page is re-observed "
                              f"median {pct(so, .5) or 0:.0f}× (p90 {pct(so, .9) or 0:.0f}, max {max(so) if so else 0}) before Jev "
                              f"sees it; Page ready → first step done median {fmt(pct(rf, .5))}, p90 {fmt(pct(rf, .9))}",
        "chrome_connect": f"`Connecting to Chrome…` → `Page ready` median {fmt(pct(cc, .5))}, p90 {fmt(pct(cc, .9))}, "
                          f"max {fmt(max(cc) if cc else None)} (every browser run pays it; includes the start page's settle)",
        "coach": f"{len(per_run('coach'))} runs stopped to ask Claude, median {fmt(pct(per_run('coach'), .5))} per run",
        "jev": f"{len(jl)} calls, median {fmt(pct(jl, .5))}, p90 {fmt(pct(jl, .9))} — fast; it adds up only through step count",
        "writer": f"median {fmt(pct(per_run('writer'), .5))} of Claude per native run (reading the screen to stop / answer / write field text)",
        "native_open": f"`Opening <app>` → first AX snapshot median {fmt(pct(no, .5))}, max {fmt(max(no) if no else None)}",
        "prep": f"median {fmt(pct([r['times'].get('prep', 0) for r in rows], .5))}, "
                f"p90 {fmt(pct([r['times'].get('prep', 0) for r in rows], .9))} before any driver starts",
        "cancel_wait": f"{len(per_run('cancel_wait'))} runs the user cancelled; median {fmt(pct(per_run('cancel_wait'), .5))} "
                       f"of nothing new on screen before they gave up",
    }
    for n, (c, s) in enumerate(sorted(shares.items(), key=lambda kv: -kv[1]), 1):
        L.append(f"{n}. **{names[c]}** — {s:.0f} s ({100 * s / max(total_all, 1e-9):.0f}%): {evidence[c]}")
    L.append(f"\nUser-visible: task start → first action median {fmt(pct(fa, .5))}, p90 {fmt(pct(fa, .9))}.\n")

    waits, ncommits = voice_waits(logs)
    L.append("**Voice decision wait** (speech end → commit, from `debug.log`): " + (
        f"{len(waits)} commits, median {fmt(pct(waits, .5))}, p90 {fmt(pct(waits, .9))}." if waits else
        "no data — the voice trace (`DebugTrace`) is compiled into Debug builds only, and the installed Release build "
        "logs voice decisions at `.info` to the unified log, which macOS does not persist. Run a Debug build "
        "(`scripts/run.sh`) for a session, or use the offline harness's simulated voice loop (`TaskBenchTests`) for the "
        "decision itself.") + "\n")
    return "\n".join(L) + "\n"


def write_doc(md: str):
    text = DOC.read_text() if DOC.exists() else f"# Task bench\n\n{BEGIN}\n{END}\n"
    if BEGIN not in text:
        text += f"\n{BEGIN}\n{END}\n"
    pre, rest = text.split(BEGIN, 1)
    _, post = rest.split(END, 1)
    DOC.write_text(pre + BEGIN + "\n" + md + END + post)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--logs", type=Path, default=DEFAULT_LOGS)
    ap.add_argument("--since", type=lambda s: dt.date.fromisoformat(s))
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--write", action="store_true", help=f"refresh the block between {BEGIN} and {END} in docs/TASK_BENCH.md")
    a = ap.parse_args()
    rows = analyse(a.logs, a.since)
    if a.json:
        json.dump(rows, sys.stdout, indent=1, default=str)
        print()
        return
    md = report(rows, a.logs)
    print(md)
    if a.write:
        write_doc(md)
        print(f"wrote {DOC}", file=sys.stderr)


if __name__ == "__main__":
    main()
