#!/usr/bin/env python3
"""Auto-mode scenarios: 400 tasks, from one-step (Calculator) to long cross-app chains.

Each scenario = what the user types/says (`utterance`), the screen it is said over (`context`),
and the CORRECT ENDING: the typed verdict (RunVerdict), whether auto mode must stop for an approval
(irreversible: send / delete / pay-adjacent / share / accept), the end state on screen, and what must
never happen. Rows live in rows_*.py; this script validates them and writes

    scripts/taskbench/scenarios.json   — tasks.json schema (+ tier, ending) → NAVI_BENCH_TASKS for the offline bench
    docs/AUTO_MODE_SCENARIOS.md        — the readable list

    python3 scripts/taskbench/scenarios/build.py

Row = S(family, tier, context, utterance, verdict, end, approval=None, must_not=(), expect=None, live=None)
  family   native | web | errand | messaging | calendar | schoolwork | memory | multi | edge
  tier     1 one action · 2 a few steps, one surface · 3 multi-step with data entry/judgement
           4 cross-app or grounded in the user's own memory · 5 long chains (5+ sub-goals, 2+ surfaces)
  verdict  achieved | needs_user | impossible | partial  (only achieved is .completed; purchases end
           achieved in the cart: "Ready for you to place the order" — Navi never pays)
  approval None, or what auto mode must ask about ONCE before doing it: send | delete | share |
           book | submit | accept | quit_unsaved | settings  (approve ⇒ the verdict above)
  expect   tasks.json `expect` (kind/surface/app/start_hosts/current_tab/continues/commands)
"""
import json, os, re, sys, importlib.util
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

FAMILIES = ["native", "web", "errand", "messaging", "calendar", "schoolwork", "memory", "multi", "edge"]
VERDICTS = {"achieved", "needs_user", "impossible", "partial"}
APPROVALS = {None, "send", "delete", "share", "book", "submit", "accept", "quit_unsaved", "settings"}
KINDS = {"task", "open_app", "open_url", "web_search", "answer", "system", "control", "browser", "window"}

def chrome(url, title, recent=None, work=None):
    c = {"front_app": "Google Chrome", "front_bundle": "com.google.Chrome", "url": url, "title": title}
    if recent: c["recent"] = recent; c["last_was_browser"] = True
    if work: c["recent_work"] = work
    return c

def app(name, bundle, title=None, recent=None, work=None):
    c = {"front_app": name, "front_bundle": bundle, "title": title or name}
    if recent: c["recent"] = recent
    if work: c["recent_work"] = work
    return c

# The existing bench contexts (scripts/taskbench/tasks.json) plus the screens these scenarios need.
_base = json.load(open(os.path.join(ROOT, "scripts/taskbench/tasks.json")))["contexts"]
CONTEXTS = dict(_base)
CONTEXTS.update({
    "calculator": app("Calculator", "com.apple.calculator"),
    "finder_docs": app("Finder", "com.apple.finder", "Documents"),
    "safari_wiki": {"front_app": "Safari", "front_bundle": "com.apple.Safari",
                    "url": "https://en.wikipedia.org/wiki/Fourier_transform", "title": "Fourier transform - Wikipedia"},
    "chrome_youtube": chrome("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "Lo-fi beats to study to - YouTube"),
    "chrome_gmail": chrome("https://mail.google.com/mail/u/0/#inbox", "Inbox (12) - liamzcarlin@gmail.com - Gmail"),
    "chrome_gdoc": chrome("https://docs.google.com/document/d/1hciNOTES/edit", "HCI Notes - Google Docs"),
    "chrome_gsheet": chrome("https://docs.google.com/spreadsheets/d/1budget/edit", "Fall Budget - Google Sheets"),
    "chrome_amazon_product": chrome("https://www.amazon.com/dp/B0SERVO123", "Amazon.com: MG996R Servo Motor 4-pack",
                                    ["“find me cheap servos on amazon” → Done: opened MG996R Servo Motor 4-pack"],
                                    [{"task": "find me cheap servos on amazon", "url": "https://www.amazon.com/dp/B0SERVO123",
                                      "title": "Amazon.com: MG996R Servo Motor 4-pack", "minutes_ago": 1, "outcome": "Done"}]),
    "chrome_github_pr": chrome("https://github.com/LiamCarlin/Navi/pull/84", "Premium UI apple style by LiamCarlin · Pull Request #84"),
    "chrome_onshape": chrome("https://cad.onshape.com/documents/abc123/w/def/e/ghi", "Yarn Bowl | Part Studio 1 - Onshape"),
    "chrome_flights": chrome("https://www.google.com/travel/flights", "Google Flights"),
    "messages_mom": app("Messages", "com.apple.MobileSMS", "Mama",
                        ["“text mom I'm on my way” → Done: sent ‘I'm on my way’ to Mama"],
                        [{"task": "text mom I'm on my way", "bundle": "com.apple.MobileSMS", "app": "Messages",
                          "title": "Mama", "minutes_ago": 2, "outcome": "Completed"}]),
    "mail_inbox": app("Mail", "com.apple.mail", "Inbox – iCloud"),
    "outlook_inbox": app("Microsoft Outlook", "com.microsoft.Outlook", "Inbox • liam.carlin@olin.edu"),
    "slack": app("Slack", "com.tinyspeck.slackmacgap", "general (Channel) - Olin Robotics - Slack"),
    "calendar_week": app("Calendar", "com.apple.iCal", "Calendar"),
    "textedit_doc": app("TextEdit", "com.apple.TextEdit", "Untitled"),
    "preview_pdf": app("Preview", "com.apple.Preview", "MTH3180_PSet4.pdf"),
    "xcode": app("Xcode", "com.apple.dt.Xcode", "Navi — PanelViewModel.swift"),
    "system_settings": app("System Settings", "com.apple.systempreferences", "Wi-Fi"),
    "spotify": app("Spotify", "com.spotify.client", "Spotify Premium"),
    "terminal": app("Terminal", "com.apple.Terminal", "liamcarlin — -zsh — 80×24"),
    "chrome_canvas_assignment": chrome("https://canvas.olin.edu/courses/1079/assignments/88213",
                                       "Assignment 02: Fourier Series - MTH3180 Fall 2026"),
    "chrome_ubereats_cart": chrome("https://www.ubereats.com/store/sweetgreen-wellesley/xyz", "Sweetgreen (Wellesley) Menu | Uber Eats",
                                   ["“order me a harvest bowl from sweetgreen” → Ready for you to place the order — Navi never pays"],
                                   [{"task": "order me a harvest bowl from sweetgreen",
                                     "url": "https://www.ubereats.com/store/sweetgreen-wellesley/xyz",
                                     "title": "Sweetgreen (Wellesley) Menu | Uber Eats", "minutes_ago": 1,
                                     "outcome": "Ready for you to place the order — Navi never pays"}]),
})

ROWS = []
def S(family, tier, context, utterance, verdict, end, approval=None, must_not=(), expect=None, live=None):
    ROWS.append(dict(family=family, tier=tier, context=context, utterance=utterance, verdict=verdict,
                     end=end, approval=approval, must_not=list(must_not), expect=expect or {}, live=live))

def load_rows():
    for fn in sorted(os.listdir(HERE)):
        if fn.startswith("rows_") and fn.endswith(".py"):
            spec = importlib.util.spec_from_file_location(fn[:-3], os.path.join(HERE, fn))
            mod = importlib.util.module_from_spec(spec)
            mod.S = S
            spec.loader.exec_module(mod)

def validate():
    errs, seen = [], set()
    for i, r in enumerate(ROWS):
        w = f"row {i} ({r['utterance'][:40]!r})"
        if r["family"] not in FAMILIES: errs.append(f"{w}: family {r['family']}")
        if r["tier"] not in (1, 2, 3, 4, 5): errs.append(f"{w}: tier {r['tier']}")
        if r["context"] not in CONTEXTS: errs.append(f"{w}: context {r['context']}")
        if r["verdict"] not in VERDICTS: errs.append(f"{w}: verdict {r['verdict']}")
        if r["approval"] not in APPROVALS: errs.append(f"{w}: approval {r['approval']}")
        if not r["end"] or len(r["end"]) < 15: errs.append(f"{w}: end too short")
        for k in r["expect"].get("kind", []):
            if k not in KINDS: errs.append(f"{w}: kind {k}")
        key = r["utterance"].strip().lower()
        if key in seen: errs.append(f"{w}: duplicate utterance")
        seen.add(key)
    return errs

def main():
    load_rows()
    errs = validate()
    if errs:
        print("\n".join(errs)); sys.exit(1)
    # Stable order: family, then tier; ids am-001…
    order = {f: i for i, f in enumerate(FAMILIES)}
    rows = sorted(ROWS, key=lambda r: (order[r["family"]], r["tier"]))
    tasks, fam_n = [], Counter()
    for r in rows:
        fam_n[r["family"]] += 1
        live = r["live"] or ({"skip": True, "why": f"needs approval: {r['approval']}"} if r["approval"] else {"safe_end": r["end"]})
        t = {"id": f"{r['family']}-{fam_n[r['family']]:03d}", "family": r["family"], "tier": r["tier"],
             "source": "auto-mode scenarios 2026-11-01", "context": r["context"], "utterance": r["utterance"],
             "expect": r["expect"],
             "ending": {"verdict": r["verdict"], "approval": r["approval"], "end": r["end"],
                        **({"must_not": r["must_not"]} if r["must_not"] else {})},
             "live": live}
        tasks.append(t)
    out = {"version": 1,
           "about": __doc__.strip().splitlines()[0] + " `ending` is the correct final state in auto mode "
                    "(approvals only for irreversible actions). Generated by scripts/taskbench/scenarios/build.py.",
           "contexts": {k: CONTEXTS[k] for k in sorted({t["context"] for t in tasks})},
           "tasks": tasks}
    json.dump(out, open(os.path.join(ROOT, "scripts/taskbench/scenarios.json"), "w"), indent=1, ensure_ascii=False)
    write_md(tasks)
    tiers = Counter(t["tier"] for t in tasks)
    print(f"{len(tasks)} scenarios · families {dict(Counter(t['family'] for t in tasks))} · tiers {dict(sorted(tiers.items()))}")

def write_md(tasks):
    L = ["# Auto-mode test scenarios", "",
         f"{len(tasks)} tasks for Navi in **auto mode** (Jev-first driver, approvals only for irreversible actions), "
         "from one-step to long cross-app chains. Each row: what the user says, the screen it is said over, and the "
         "**correct ending** — the typed verdict (only `achieved` counts as completed), whether auto mode must stop "
         "once for an approval, and the end state.", "",
         "Generated from `scripts/taskbench/scenarios/rows_*.py` by `python3 scripts/taskbench/scenarios/build.py`, "
         "which also writes `scripts/taskbench/scenarios.json` (tasks.json schema + `tier`, `ending`) — run it through "
         "the offline bench with `NAVI_BENCH_TASKS=scripts/taskbench/scenarios.json`. Edit the rows, not the outputs.", "",
         "**Tiers:** 1 one action · 2 a few steps on one surface · 3 multi-step with data entry or judgement · "
         "4 cross-app or grounded in the user's own memory · 5 long chains.  ",
         "**Approval:** auto mode asks exactly once, right before that step; the ending assumes the user approves.  ",
         "**Purchases** end in the cart (\"Ready for you to place the order\") — Navi never pays.", ""]
    tiers = Counter(t["tier"] for t in tasks)
    L += ["| family | count |", "|---|---:|"] + [f"| {f} | {sum(1 for t in tasks if t['family']==f)} |" for f in FAMILIES]
    L += ["", "| tier | count |", "|---|---:|"] + [f"| {k} | {tiers[k]} |" for k in sorted(tiers)] + [""]
    esc = lambda s: s.replace("|", "\\|").replace("\n", " ")
    for f in FAMILIES:
        ft = [t for t in tasks if t["family"] == f]
        if not ft: continue
        L += [f"## {f}", "", "| id | tier | context | prompt | correct ending | verdict | approval |", "|---|---:|---|---|---|---|---|"]
        for t in ft:
            e = t["ending"]
            end = e["end"] + (" **Never:** " + "; ".join(e["must_not"]) + "." if e.get("must_not") else "")
            L.append(f"| {t['id']} | {t['tier']} | {t['context']} | {esc(t['utterance'])} | {esc(end)} | {e['verdict']} | {e['approval'] or '—'} |")
        L.append("")
    open(os.path.join(ROOT, "docs/AUTO_MODE_SCENARIOS.md"), "w").write("\n".join(L))

if __name__ == "__main__":
    main()
