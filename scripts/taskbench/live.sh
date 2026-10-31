#!/bin/zsh
# Live task bench: runs the tasks in scripts/taskbench/tasks.json through the INSTALLED Navi,
# one at a time, and records what actually happened. It drives your Mac — run it yourself,
# when you can leave the machine alone for a few minutes.
#
#   scripts/taskbench/live.sh --dry-run            # list what would run / be skipped; opens nothing
#   scripts/taskbench/live.sh                      # every safe task, typed path (navi://run?q=…)
#   scripts/taskbench/live.sh --only errand-02,native-03
#   scripts/taskbench/live.sh --family errand
#   scripts/taskbench/live.sh --voice              # spoken path: `say -o clip.aiff` → navi://voice?file=clip.aiff
#   scripts/taskbench/live.sh --followups          # also tasks whose context includes earlier instructions
#   scripts/taskbench/live.sh --timeout 240        # per-task limit in seconds (default 180)
#
# Per task: set up its context (opens the context's page in Chrome, or brings Finder/Notes/Music
# forward), note Chrome's open tabs, submit the task, wait for the run's terminal line in
# ~/Library/Logs/Navi/agent-runs.log (completed / failed / cancelled), record outcome + duration +
# the time split (same parser as profile.py), then close only the Chrome tabs that appeared during
# the task. Results: build/taskbench/live-<stamp>.jsonl and a summary table.
#
# Never runs: tasks marked live.skip, messaging tasks that would send, and any utterance that could
# send, pay, post or delete (regex guard below). Errands end in the cart: Navi never pays
# (runner adaptation 27) — the guard is a second line of defence, not the only one.
set -euo pipefail
cd "$(dirname "$0")/../.."
exec python3 - "$@" <<'PY'
import argparse, datetime as dt, importlib.util, json, os, re, subprocess, sys, time, urllib.parse
from pathlib import Path

ROOT = Path.cwd()
TASKS = ROOT / "scripts/taskbench/tasks.json"
LOG = Path.home() / "Library/Logs/Navi/agent-runs.log"
spec = importlib.util.spec_from_file_location("taskbench_profile", ROOT / "scripts/taskbench/profile.py")
prof = importlib.util.module_from_spec(spec); spec.loader.exec_module(prof)

RISKY = re.compile(r"\b(send|text|txt|email|e-mail|message|reply|respond|dm|slack|tell \w+|pay|checkout|check out|place (the |my |your )?order|"
                   r"buy now|purchase now|delete|remove|post|tweet|submit|transfer|venmo|quit|shut ?down|restart|empty (the )?trash)\b", re.I)

ap = argparse.ArgumentParser()
ap.add_argument("--dry-run", action="store_true")
ap.add_argument("--only", default="")
ap.add_argument("--family", default="")
ap.add_argument("--voice", action="store_true")
ap.add_argument("--followups", action="store_true")
ap.add_argument("--timeout", type=int, default=180)
ap.add_argument("--start-timeout", type=int, default=12, help="seconds to wait for an agent run to begin")
a = ap.parse_args()

data = json.loads(TASKS.read_text())
contexts = data["contexts"]
only = {s.strip() for s in a.only.split(",") if s.strip()}

def skip_reason(t):
    live = t.get("live") or {}
    if only and t["id"] not in only: return "not selected"
    if a.family and t["family"] != a.family: return "not selected"
    if live.get("skip"): return "live.skip: " + live.get("why", "")
    if RISKY.search(t["utterance"]) and not live.get("allow"): return "could send/pay/delete (guard)"
    ctx = contexts.get(t.get("context") or "", {})
    if ctx.get("recent") and not a.followups: return "follow-up (needs --followups)"
    return None

def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return r.stdout.strip()

def chrome_tabs():
    out = osa('if application "Google Chrome" is running then tell application "Google Chrome" to get id of every tab of every window')
    return set(re.findall(r"\d+", out))

def close_new_tabs(before):
    now = chrome_tabs()
    new = now - before
    for tid in new:
        osa(f'tell application "Google Chrome" to repeat with w in windows\nrepeat with t in tabs of w\nif (id of t as text) is "{tid}" then close t\nend repeat\nend repeat')
    return len(new)

def setup(ctx):
    url, bundle = ctx.get("url"), ctx.get("front_bundle")
    if url:
        subprocess.run(["open", "-b", "com.google.Chrome", url]); time.sleep(2.5)
    elif bundle:
        subprocess.run(["open", "-b", bundle]); time.sleep(1.0)

def log_size():
    return LOG.stat().st_size if LOG.exists() else 0

def wait_for_run(offset, task_text):
    """New runs appended after `offset`; returns the first run whose terminal line arrived (or None)."""
    t0 = time.time()
    started = False
    while time.time() - t0 < a.timeout:
        time.sleep(1.0)
        if not LOG.exists(): continue
        with LOG.open("rb") as f:
            f.seek(offset); chunk = f.read().decode("utf-8", "replace")
        tmp = ROOT / "build/taskbench/.live-chunk.log"
        tmp.write_text(chunk)
        runs = prof.parse_runs([tmp])
        if runs: started = True
        for r in runs:
            if any(m in ("cancelled",) or m.startswith(("completed", "failed")) for _, m in r["events"]):
                return r, time.time() - t0
        if not started and time.time() - t0 > a.start_timeout:
            return None, time.time() - t0
    return ("timeout", time.time() - t0)

stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
outdir = ROOT / "build/taskbench"; outdir.mkdir(parents=True, exist_ok=True)
out = outdir / f"live-{stamp}.jsonl"
rows = []
for t in data["tasks"]:
    why = skip_reason(t)
    if why:
        if why != "not selected": print(f"skip  {t['id']:<10} {why}")
        continue
    ctx = contexts.get(t.get("context") or "", {})
    if a.dry_run:
        print(f"run   {t['id']:<10} [{t.get('context')}] {t['utterance']}"); continue
    setup(ctx)
    before = chrome_tabs()
    offset = log_size()
    if a.voice:
        clip = outdir / f"clip-{t['id']}.aiff"
        subprocess.run(["say", "-o", str(clip), t["utterance"]], check=True)
        subprocess.run(["open", "navi://voice?file=" + urllib.parse.quote(str(clip))])
    else:
        subprocess.run(["open", "navi://run?q=" + urllib.parse.quote(t["utterance"])])
    run, secs = wait_for_run(offset, t["utterance"])
    row = {"id": t["id"], "family": t["family"], "utterance": t["utterance"], "mode": "voice" if a.voice else "typed", "wall_s": round(secs, 1)}
    if run is None:
        row.update(outcome="no_agent_run", reason="handled without an agent run (app / answer / system / card) or never started")
    elif run == "timeout":
        row.update(outcome="timeout", reason=f"no terminal line within {a.timeout} s")
    else:
        outcome, reason, _ = prof.classify_outcome(run, None)
        times, counts, extra = prof.time_breakdown(run)
        row.update(outcome=outcome, reason=reason, task_logged=run["task"], times={k: round(v, 2) for k, v in times.items()},
                   first_action=extra.get("first_action"), safe_end=(t.get("live") or {}).get("safe_end"))
    time.sleep(1.5)
    row["tabs_closed"] = close_new_tabs(before)
    rows.append(row)
    with out.open("a") as f: f.write(json.dumps(row) + "\n")
    print(f"{row['outcome']:<13} {t['id']:<10} {row['wall_s']:>6.1f}s  {row.get('reason', '')}")
    time.sleep(2.0)

if rows:
    print("\n| family | ran | success | rate | median s |\n|---|---:|---:|---:|---:|")
    for fam in sorted({r["family"] for r in rows}):
        g = [r for r in rows if r["family"] == fam]
        ok = sum(r["outcome"] == "success" for r in g)
        med = sorted(r["wall_s"] for r in g)[len(g) // 2]
        print(f"| {fam} | {len(g)} | {ok} | {100 * ok // len(g)}% | {med} |")
    print(f"\nResults: {out}  (outcome 'success' still needs a glance: the run's own words decide it)")
PY
