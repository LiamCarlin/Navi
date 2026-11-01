#!/usr/bin/env python3
"""Overnight live bench: runs the safe auto-mode scenarios (scripts/taskbench/scenarios.json) through the
INSTALLED Navi, one at a time, and keeps everything needed to see what Navi did in each one.

    python3 scripts/taskbench/overnight.py --dry-run          # what would run / be skipped
    caffeinate -dimsu python3 scripts/taskbench/overnight.py  # all safe scenarios
    python3 scripts/taskbench/overnight.py --out build/taskbench/overnight-X --resume   # continue a cut-off night
    python3 scripts/taskbench/overnight.py --only native-001,web-002

Per scenario, in <out>/<id>/:
    before.jpg, shot-NN.jpg (every --shot-every s while it runs), after.jpg   — the screen, 1280 px
    agent-runs.log.txt     the scenario's slice of ~/Library/Logs/Navi/agent-runs.log (every step + status)
    runs/<stamp>/          native run folders Navi wrote (per-step Jev payload/answers, writer reviews)
    ultrafast.jsonl        the browser runner's event stream when it ran
    record.json            the row below
and one line per scenario in <out>/results.jsonl (+ summary.md, rewritten as it goes).

Never runs (skipped, recorded as such): scenarios whose correct ending needs an approval (send, delete, share,
submit, book, accept, settings, quit) and any prompt the guard says could send, pay, post, delete, change the
network or end the session. A run that gets to a send-like step in a chat/mail app anyway is stopped at once.
A run still going at its time limit is stopped (Stop button, else Navi is restarted).
"""
import argparse, datetime as dt, importlib.util, json, os, re, shutil, subprocess, sys, time, urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOGDIR = Path.home() / "Library/Logs/Navi"
LOG = LOGDIR / "agent-runs.log"
RUNS = LOGDIR / "runs"
ULTRA = LOGDIR / "ultrafast-last-run.jsonl"
spec = importlib.util.spec_from_file_location("taskbench_profile", ROOT / "scripts/taskbench/profile.py")
prof = importlib.util.module_from_spec(spec); spec.loader.exec_module(prof)

RISKY = re.compile(
    r"\b(send|text|txt|email|e-mail|mail it|message|msg|reply|respond|dm|slack|tell \w+|pay|checkout|check out|"
    r"place (the |my |your )?order|buy now|purchase|delete|remove|post|tweet|comment|submit|share|invite|transfer|"
    r"venmo|quit|shut ?down|restart|reboot|log ?out|sign out|lock|sleep|empty (the |my )?trash|wi-?fi|bluetooth|"
    r"airplane|filevault|firewall|uninstall|disk access|password|forward|rsvp|accept|decline|unsubscribe|book|"
    r"reserve|merge|call|facetime|zoom)\b", re.I)
CHAT_APPS = re.compile(r"\b(Messages|WhatsApp|Slack|Mail|Outlook|Discord|Gmail|Teams|Telegram|Signal)\b")
SENDISH = re.compile(r"press Return|press ⏎|⌘↩|⌘Return|‘Send’|'Send'|Click ‘Send|Click 'Send|Post\b", re.I)

# Placeholder screens in scenarios.json → real ones on this Mac (scratch docs instead of editing real ones).
FIXTURES = ROOT / "build/taskbench/fixtures"
CONTEXT_OVERRIDES = {
    "chrome_gdoc": {"url": "https://docs.new", "note": "a fresh scratch Google Doc, never a real one"},
    "chrome_gsheet": {"url": "https://sheets.new", "note": "a fresh scratch Google Sheet"},
    "chrome_onshape": {"url": "https://cad.onshape.com/documents/32e37de59ab28fc24b1e11ec/w/d02c25ab78711e3f65d3d392/e/ecd770352dab5363d369d4f5"},
    "chrome_canvas_assignment": {"url": "https://canvas.olin.edu/courses/1079/assignments/20649"},
    "chrome_amazon_product": {"url": "https://www.amazon.com/dp/B0H9XPQNNS"},
    "preview_pdf": {"file": str(FIXTURES / "MTH3180_PSet4.pdf"), "note": "a copy of a real problem set"},
}
# Not run unattended, beyond the guard: 1-click purchases, real files/settings/mail state, sign-ins, forms with
# personal data, third-party downloads, anything that builds/launches a second Navi.
SKIP_IDS = {
    "web-013": "toggle on the account: a rerun un-likes the video the first run liked",
    "web-017": "toggle on the account: subscribe/unsubscribe", "errand-014": "toggle on the account: Etsy favorite",
    "calendar-013": "moves a real calendar event",
    "edge-001": "Amazon 'buy it now' — 1-click could place a real order",
    "edge-008": "bank sign-in", "edge-016": "bank sign-in", "edge-015": "submits a sign-up form with personal data",
    "native-064": "moves real files out of Downloads", "native-083": "reorganises the real Desktop",
    "native-018": "leaves the Mac in dark mode", "native-075": "changes the Dock", "native-017": "leaves the Mac muted",
    "native-056": "builds and launches a second (Debug) Navi", "native-085": "builds Navi in Xcode",
    "multi-008": "runs the Navi test suite (launches a test-host Navi)",
    "web-023": "downloads a third-party installer",
    "messaging-004": "marks the whole real inbox read", "messaging-049": "archives/flags real mail",
    "messaging-037": "composes a real email to a professor",
    "errand-008": "no Uber Eats cart to continue on this Mac", "errand-032": "no Uber Eats cart to continue on this Mac",
}

ap = argparse.ArgumentParser()
ap.add_argument("--tasks", default=str(ROOT / "scripts/taskbench/scenarios.json"))
ap.add_argument("--out", default="")
ap.add_argument("--resume", action="store_true")
ap.add_argument("--only", default="")
ap.add_argument("--limit", type=int, default=0)
ap.add_argument("--dry-run", action="store_true")
ap.add_argument("--shot-every", type=float, default=4.0)
ap.add_argument("--start-timeout", type=int, default=15)
ap.add_argument("--trigger", choices=["hotkey", "url"], default="hotkey",
                help="hotkey: ⌘Space, paste the prompt, ⏎ after routing — what a person does (the app in front stays in "
                     "front). url: navi://run?q=… (activates Navi, so Navi is 'the app in front')")
ap.add_argument("--route-wait", type=float, default=1.5, help="seconds between pasting the prompt and ⏎ (hotkey)")
ap.add_argument("--first-not-in", default="", help="a results.jsonl: scenarios not in it run first")
a = ap.parse_args()

data = json.loads(Path(a.tasks).read_text())
contexts = data["contexts"]
only = {s.strip() for s in a.only.split(",") if s.strip()}

def skip_reason(t):
    if only and t["id"] not in only: return "not selected"
    if t["id"] in SKIP_IDS: return "not run unattended: " + SKIP_IDS[t["id"]]
    e = t.get("ending") or {}
    if e.get("approval"): return f"needs approval ({e['approval']}) — not run unattended"
    if RISKY.search(t["utterance"]): return "could send/pay/delete/change the session (guard)"
    return None

def time_limit(t):
    return {1: 90, 2: 120, 3: 150, 4: 180, 5: 240}.get(t.get("tier", 3), 150)

def as_applescript(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'

def submit_hotkey(text, since):
    """⌘Space, paste, wait for routing, ⏎. Returns None if the panel never showed (then the caller uses navi://),
    "card" when the scheduler/reminder card came up — ⏎ there books a real event (and sends invites), so it is
    withheld and the card is closed after a screenshot — else "ok"."""
    osa(f'set the clipboard to {as_applescript(text)}')
    osa('tell application "System Events" to keystroke " " using command down')
    time.sleep(0.7)
    osa('tell application "System Events" to keystroke "v" using command down')
    time.sleep(a.route_wait)
    panel = sh("/usr/bin/log", "show", "--start", since, "--predicate",
               'subsystem == "com.liamcarlin.navi" and category == "panel"', "--info", "--style", "compact", timeout=30)
    if "show(prefill" not in panel:
        return None
    if "scheduler card for" in panel or "reminder card" in panel:
        return "card"
    osa('tell application "System Events" to key code 36')
    return "ok"

def ordered(tasks):
    """Round-robin over families, easy first inside each, so a cut-off night still covers everything."""
    fams = {}
    for t in sorted(tasks, key=lambda t: (t.get("tier", 3), t["id"])):
        fams.setdefault(t["family"], []).append(t)
    out = []
    while any(fams.values()):
        for f in list(fams):
            if fams[f]: out.append(fams[f].pop(0))
    if a.first_not_in and os.path.exists(a.first_not_in):
        seen = {json.loads(l)["id"] for l in open(a.first_not_in) if l.strip()}
        out = [t for t in out if t["id"] not in seen] + [t for t in out if t["id"] in seen]
    return out

def sh(*cmd, timeout=20):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except Exception:
        return ""

def osa(script):
    return sh("osascript", "-e", script)

def chrome_tabs():
    out = osa('if application "Google Chrome" is running then tell application "Google Chrome" to get id of every tab of every window')
    return set(re.findall(r"\d+", out))

def close_new_tabs(before):
    new = chrome_tabs() - before
    for tid in new:
        osa(f'tell application "Google Chrome" to repeat with w in windows\nrepeat with t in tabs of w\n'
            f'if (id of t as text) is "{tid}" then close t\nend repeat\nend repeat')
    return len(new)

def front_app():
    return osa('tell application "System Events" to get name of first process whose frontmost is true')

def shot(path):
    tmp = str(path) + ".png"
    sh("screencapture", "-x", "-C", tmp, timeout=15)
    if os.path.exists(tmp):
        sh("sips", "-Z", "1280", "-s", "format", "jpeg", "-s", "formatOptions", "60", tmp, "--out", str(path), timeout=15)
        os.remove(tmp)

def setup(ctx):
    url, bundle = ctx.get("url"), ctx.get("front_bundle")
    if ctx.get("file"):
        sh("open", "-b", bundle or "com.apple.Preview", ctx["file"]); time.sleep(2.5)
    elif url:
        if ctx.get("front_bundle") == "com.apple.Safari":
            sh("open", "-b", "com.apple.Safari", url)
        else:
            sh("open", "-b", "com.google.Chrome", url)
        time.sleep(3.0)
    elif bundle:
        sh("open", "-b", bundle); time.sleep(1.5)

def log_size():
    return LOG.stat().st_size if LOG.exists() else 0

def read_chunk(offset):
    if not LOG.exists(): return ""
    with LOG.open("rb") as f:
        f.seek(offset); return f.read().decode("utf-8", "replace")

def parse(chunk, scratch):
    scratch.write_text(chunk)
    return prof.parse_runs([scratch])

def terminal(run):
    return any(m == "cancelled" or m.startswith(("completed", "failed")) for _, m in run["events"])

def navi_running():
    return bool(sh("pgrep", "-x", "Navi"))

def navi_pid():
    return sh("pgrep", "-x", "Navi")

def installed_commit():
    try: return (Path.home() / "Library/Caches/com.liamcarlin.navi.install/installed").read_text().split()[0][:9]
    except Exception: return None

def app_log(since):
    """Navi's own unified-log lines (panel routing, router, agent) since `since` — what it did when no agent ran."""
    return sh("/usr/bin/log", "show", "--start", since, "--predicate", 'subsystem == "com.liamcarlin.navi"',
              "--info", "--style", "compact", timeout=60)

def press_stop():
    """The panel's Stop button (AX), opened via navi://query; returns True if it was pressed."""
    sh("open", "navi://query?q=")
    time.sleep(1.2)
    r = osa('tell application "System Events" to tell process "Navi"\n'
            'set bs to every button of entire contents of every window whose (name is "Stop" or description is "Stop" or help is "Stop the agent (esc)")\n'
            'repeat with b in bs\nclick b\nreturn "pressed"\nend repeat\nend tell\nreturn "none"')
    return "pressed" in r

def restart_navi():
    sh("pkill", "-f", "navi_runner.py")
    sh("pkill", "-x", "Navi")
    time.sleep(3)
    sh("open", "-a", "/Applications/Navi.app")
    time.sleep(15)   # a navi:// link that arrives while Navi is still launching crashes it (AppDelegate.application(_:open:))

def dismiss_panel():
    if front_app() == "Navi":
        osa('tell application "System Events" to key code 53')
        time.sleep(0.4)
        if front_app() == "Navi": osa('tell application "System Events" to key code 53')

def last_line(run, prefixes):
    for _, m in reversed(run["events"]):
        if m.startswith(prefixes): return m
    return None

stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
out = Path(a.out) if a.out else ROOT / f"build/taskbench/overnight-{stamp}"
out.mkdir(parents=True, exist_ok=True)
results = out / "results.jsonl"
done = set()
if a.resume and results.exists():
    done = {json.loads(l)["id"] for l in results.read_text().splitlines() if l.strip()}
scratch = out / ".chunk.log"

plan, skipped = [], []
for t in ordered(data["tasks"]):
    why = skip_reason(t)
    if why == "not selected": continue
    (skipped if why else plan).append((t, why))
if a.limit: plan = plan[: a.limit]
print(f"{len(plan)} to run, {len(skipped)} skipped (approval/guard) → {out}", flush=True)
if a.dry_run:
    for t, _ in plan: print(f"run  {t['id']:<15} t{t.get('tier')} [{t.get('context')}] {t['utterance']}")
    for t, why in skipped: print(f"skip {t['id']:<15} {why}")
    sys.exit(0)
with (out / "skipped.jsonl").open("w") as f:
    for t, why in skipped:
        f.write(json.dumps({"id": t["id"], "family": t["family"], "tier": t.get("tier"), "utterance": t["utterance"],
                            "why": why, "ending": t.get("ending")}, ensure_ascii=False) + "\n")

def summary():
    rows = [json.loads(l) for l in results.read_text().splitlines() if l.strip()] if results.exists() else []
    L = [f"# Overnight live bench — {out.name}", "", f"{len(rows)} run · {len(skipped)} skipped (approval/guard) · "
         f"updated {dt.datetime.now():%H:%M}", "", "| family | ran | completed | failed | cancelled/timeout | no agent run | median s |",
         "|---|---:|---:|---:|---:|---:|---:|"]
    for fam in sorted({r["family"] for r in rows}):
        g = [r for r in rows if r["family"] == fam]
        c = lambda *o: sum(r["outcome"] in o for r in g)
        med = sorted(r["wall_s"] for r in g)[len(g) // 2]
        L.append(f"| {fam} | {len(g)} | {c('success')} | {c('failed', 'false_done')} | {c('cancelled', 'timeout', 'stopped_guard')} | {c('no_agent_run')} | {med} |")
    L += ["", "| id | tier | outcome | s | prompt | Navi's last word |", "|---|---:|---|---:|---|---|"]
    for r in rows:
        L.append(f"| {r['id']} | {r['tier']} | {r['outcome']} | {r['wall_s']} | {r['utterance'][:70]} | {(r.get('final') or '')[:140].replace('|', '/')} |")
    (out / "summary.md").write_text("\n".join(L) + "\n")

consecutive_dead = 0
for i, (t, _) in enumerate(plan, 1):
    if t["id"] in done: continue
    if not navi_running(): restart_navi()
    pid0, commit0 = navi_pid(), installed_commit()
    since = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    d = out / t["id"]; d.mkdir(exist_ok=True)
    ctx = {**contexts.get(t.get("context") or "", {}), **CONTEXT_OVERRIDES.get(t.get("context") or "", {})}
    tabs_before = chrome_tabs()
    sh("pkill", "-x", "screencapture")   # an interactive screenshot left by the last scenario swallows ⌘Space
    setup(ctx)
    shot(d / "before.jpg")
    offset = log_size()
    runs_before = set(os.listdir(RUNS)) if RUNS.exists() else set()
    ultra_m = ULTRA.stat().st_mtime if ULTRA.exists() else 0
    t0 = time.time()
    trigger = a.trigger
    if trigger == "hotkey":
        sent = submit_hotkey(t["utterance"], since)
        if sent is None:
            trigger = "url (hotkey panel did not show)"
        elif sent == "card":
            trigger = "hotkey (card shown; Return withheld, it would book a real event)"
            shot(d / "card.jpg")
            for _ in range(2):   # esc: card → results, then close the panel
                osa('tell application "System Events" to key code 53'); time.sleep(0.4)
    if trigger.startswith("url"):
        sh("open", "navi://run?q=" + urllib.parse.quote(t["utterance"]))
    limit, n_shot, last_shot = time_limit(t), 0, 0.0
    run, status, guard_hit, paused = None, None, None, False
    while True:
        now = time.time() - t0
        if now - last_shot >= a.shot_every:
            n_shot += 1; last_shot = now
            shot(d / f"shot-{n_shot:02d}.jpg")
        time.sleep(0.8)
        runs = parse(read_chunk(offset), scratch)
        run = runs[0] if runs else None
        if run:
            msgs = [m for _, m in run["events"]]
            if any(re.search(r"approv|waiting for you|asks? you|question", m, re.I) for m in msgs): paused = True
            steps = [m for m in msgs if re.match(r"step \d+:", m)]
            if steps and SENDISH.search(steps[-1]) and (CHAT_APPS.search(" ".join(msgs)) or CHAT_APPS.search(ctx.get("front_app", ""))):
                guard_hit = steps[-1]
            if terminal(run): status = "done"; break
        if guard_hit:
            status = "guard"; break
        if not run and now > a.start_timeout:
            status = "no_run"; break
        if now > limit:
            status = "timeout"; break
    if status in ("guard", "timeout"):
        if not press_stop():
            restart_navi()
        else:
            for _ in range(10):
                time.sleep(1)
                runs = parse(read_chunk(offset), scratch)
                if runs and terminal(runs[0]): break
            else:
                restart_navi()
    if status == "no_run":
        for k in range(2):       # whatever it did instead (an app opened, an answer, a card) is on screen now
            time.sleep(2.5); n_shot += 1; shot(d / f"shot-{n_shot:02d}.jpg")
    wall = round(time.time() - t0, 1)
    time.sleep(1.0)
    shot(d / "after.jpg")
    chunk = read_chunk(offset)
    (d / "agent-runs.log.txt").write_text(chunk)
    (d / "navi-app.log").write_text("\n".join(l for l in app_log(since).splitlines()
                                               if "TCC" not in l and "notification settings" not in l and "SMAppService" not in l))
    runs = parse(chunk, scratch)
    run = runs[0] if runs else None
    for r in sorted(set(os.listdir(RUNS)) - runs_before) if RUNS.exists() else []:
        try: shutil.copytree(RUNS / r, d / "runs" / r)
        except Exception: pass
    if ULTRA.exists() and ULTRA.stat().st_mtime > ultra_m:
        shutil.copy(ULTRA, d / "ultrafast.jsonl")
    row = {"id": t["id"], "family": t["family"], "tier": t.get("tier"), "context": t.get("context"),
           "utterance": t["utterance"], "expected": t.get("ending"), "wall_s": wall, "screens": n_shot,
           "paused_for_user": paused, "front_app_after": front_app(), "runs_in_scenario": len(runs),
           "navi_build": commit0, "navi_restarted": navi_pid() != pid0, "trigger": trigger}
    if status == "no_run":
        row.update(outcome="no_agent_run", final=None, reason="handled without an agent run (app / answer / card / system) or never started")
    elif run is None:
        row.update(outcome="timeout" if status == "timeout" else "unknown", reason=status)
    else:
        outcome, reason, _ = prof.classify_outcome(run, None)
        if status == "timeout": outcome, reason = "timeout", f"stopped at the {limit} s limit"
        if status == "guard": outcome, reason = "stopped_guard", f"send-like step in a chat/mail app: {guard_hit}"
        times, counts, extra = prof.time_breakdown(run)
        row.update(outcome=outcome, reason=reason, task_logged=run["task"],
                   final=last_line(run, ("completed", "failed", "cancelled")),
                   steps=[m for _, m in run["events"] if re.match(r"step \d+:", m)],
                   times={k: round(v, 2) for k, v in times.items()}, first_action=extra.get("first_action"))
    (d / "record.json").write_text(json.dumps(row, indent=1, ensure_ascii=False))
    with results.open("a") as f: f.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(f"[{i}/{len(plan)}] {row['outcome']:<13} {t['id']:<15} {wall:>6.1f}s  {(row.get('final') or row.get('reason') or '')[:110]}", flush=True)
    consecutive_dead = consecutive_dead + 1 if row["outcome"] in ("no_agent_run", "unknown") and t.get("tier", 1) >= 3 else 0
    if consecutive_dead >= 4:
        print("4 tier-3+ scenarios in a row never started a run — restarting Navi", flush=True)
        restart_navi(); consecutive_dead = 0
    dismiss_panel()
    close_new_tabs(tabs_before)
    summary()
    time.sleep(2.0)

summary()
print(f"\nDone → {out}/summary.md", flush=True)
