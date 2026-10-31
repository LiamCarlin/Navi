# Task bench — is Navi getting better?

Three instruments, re-run after every change to the agent, voice or memory code:

| what | command | drives the screen? | answers |
|---|---|---|---|
| **Lag profile + history** | `scripts/taskbench/profile.py [--write] [--since YYYY-MM-DD]` | no (reads logs) | where the time goes in real runs; success rate per family over every run in the log |
| **Offline bench** | `scripts/taskbench/offline.sh [--repeat 3] [--no-memory] [--planner] [--only id,…]` | no | does Navi's decision layer understand each of 40 tasks and start it in the right place? |
| **Live bench** | `scripts/taskbench/live.sh [--dry-run] [--voice] [--only …]` | **yes — Liam runs it** | did the installed app actually finish the safe tasks, and how long did it take? |

Target: ≥ 95 % on what the user asked, across errands (end in the cart — Navi never pays), schoolwork/docs,
messaging/email and native apps. No per-site patches: a failing task here points at a rule, not a site.

## 1. Lag profile (`profile.py`)

Python 3 stdlib only, read-only. Parses `~/Library/Logs/Navi/agent-runs.log` (+ `.1`), `runs/*/run.json`
(native runs: `goal_achieved`), `ultrafast-last-run.jsonl` and, in Debug builds, the voice trace in
`debug.log`. Per run it splits wall time into **prep** (task start → first driver event: planning,
grounding, routine match, surface pick), **chrome connect** (`Connecting to Chrome…` → `Page ready`),
**native open** (`Opening <app>` → first AX snapshot), **Jev** (sum of reported latencies), **writer**
(Claude reading the screen / answering — the native driver's `calls:` tally), **coach** (Claude
diagnosing a stuck browser run), **last event → user cancelled**, and **act + settle + observe** (the
rest: executing actions, settle polling, re-reading the page/AX tree). Outcomes: `success`, `false done`
(reported *completed* but didn't do it: handed back a question, said it couldn't, `goal_achieved=false`,
or the user's next words corrected it — "I meant…"), `failed`, `cancelled`. Families are regex-tagged
from the task text (`FAMILY_RULES`).

`--write` refreshes the generated block at the end of this file; `--json` dumps per-run rows.

**Voice decision wait** cannot be measured from the installed app: the speech → commit trace is
`DebugTrace` (Debug builds only) and `Log.voice` info lines are not persisted by macOS. A Debug-build
session (`scripts/run.sh`) fills it in; meanwhile the offline bench simulates it (below).

### Top lag sources (2026-10-29 → 10-30, 38 runs; numbers from the generated block)

1. **Act + settle + observe — 41 % of all run time.** Not Jev: after every page change the runner
   re-observes until two snapshots agree (median 2, p90 4, max 9 extra observations); `Page ready` →
   first browser step done is 1.07 s median, 3.4 s p90; browser steps take 0.35 s median but 1.6 s p90 and
   up to 8.7 s.
2. **Chrome connect → Page ready — 15 %.** Every browser run pays it: 1.6 s median, 5.3 s p90, 6.8 s max
   (CDP attach + new tab + the start page's own settle).
3. **Claude coach — 13 %, and it never rescued a run.** 15 of 38 runs stopped to ask Claude (3.9 s median
   each); none of those 15 then succeeded (12 failed, 2 cancelled, 1 false done).
4. **Time to first action — 4.4 s median, 10 s p90** (user-visible: nothing happens on screen). Prep alone
   is 0.3 s median but 2 s p90 (grounding/routines awaited with a 2 s budget; the offline bench measures
   route prep at ~0.74 s median, 3 s max with Jev warm).
5. **Native app open → first AX snapshot — 1.9 s median, 20.6 s max** (the 20 s case: a false routine match
   opened the Claude app for "make a new note…"). Native writer calls add 3.0 s median per run.

Jev is not the bottleneck: 354 calls, 0.10 s median, 0.16 s p90 (8 % of run time).

**Historical success: 21 %** (8/38). Errands 13 % (3/23), schoolwork 50 % (2/4), native 38 % (3/8),
other 0/3. Top failure reasons: start page unrelated to the task (5 — burger/McDonald's run on the Canvas
tab), loops (5), "completed" without doing it (7 incl. one user correction), stuck/modal/CDP errors.

## 2. Offline bench (`tasks.json` + `NaviTests/TaskBenchTests.swift`)

`scripts/taskbench/offline.sh` takes the Jev/Claude keys from the env or the Keychain item
(`security find-generic-password -s com.liamcarlin.navi -a keys -w`; never printed), makes a
`sqlite3 ".backup"` copy of `memory.sqlite` (opened read-only; the test refuses the live path and copies
it again into the test host's scratch dir), and runs only `TaskBenchTests` in a private derived-data dir
(`build/DerivedData-bench`). Results: `build/taskbench/offline-<stamp>.{json,md}`.

Per task, hosted inside the Debug app (live Jev, nothing on screen):

1. **Voice loop.** The utterance goes through `UtteranceSegmenter` and `VoiceDecider` exactly as
   `VoiceSession` runs them: clauses with words after them are decided at 0 ms silence, the last clause
   waits through simulated silence (each `.wait` advances the clock by its retry); `.merge`/`.drop`/
   `.giveUp`/`.commit` are applied to the segmenter. Context = the task's `context` (front app, URL,
   recent instructions). Jev voice calls are not cached, so `--repeat N` measures how stable they are.
2. **Route** for every committed task, in order, each starting on the screen the previous one left:
   `VoiceCommandExecutor.isCompound/voiceSurface/continuesOnCurrentTab`, then
   `resolvePlanWithoutPlanner`'s order — grounded page/app (`TaskGrounding`), the user's routine start
   (`UserRoutines` + `AgentRun.routineStart`), `TaskSurface.classify` (Jev) when unsure, `UserHabits`
   named native app, `AppSkills.inferApp` (+ `UserKnowledge.channelApp`), `TaskSurface.startURL`
   (+ `UserKnowledge.startURL`, `UserHabits.personalize`). With no DB copy the memory steps are skipped.
   The live entry points read globals that are nil under the test host, so the harness calls the same
   statics on instances built from the copy — if those internals move, update `route()` there.
3. `--planner`: also asks `TaskPlanner` (Claude) per task — the typed ⌘Space path — reported separately.

### `tasks.json` schema

```jsonc
{ "contexts": { "<name>": { "front_app", "front_bundle", "url", "title",
                            "recent": ["“said” → outcome"], "last_was_browser",
                            "recent_work": [{ "task", "url" | "bundle"+"app", "title", "minutes_ago", "outcome" }] } },  // WorkingSurface store, newest first
  "tasks": [ { "id", "family": "errand|schoolwork|messaging|native", "utterance", "source", "context",
    "expect": {
      "commands": 1,            // exactly N committed commands ("must not be split"); or "max_commands": 2
      "kind": ["task"],         // the working (last) command: task|open_app|open_url|web_search|answer|system|control|browser|window
      "surface": ["browser"],   // browser|native_app
      "start_hosts": ["amazon.com"], // the start page contains one of these…
      "app": ["com.apple.Notes", null], // …or the native app (null = stays in the app in front); either passes when both are given
      "current_tab": false,     // starts on the tab that is open
      "continues": true,        // work_where = a recent place / the previous command's place, or the run starts in an earlier task's place (continueOn)
      "memory": { "grounds": true, "start_hosts": [...], "app": [...], "routine": "none" } // only with a DB copy
    },
    "live": { "skip": true, "why": "...", "safe_end": "...", "allow": false } } ] }
```

Unknown fields are ignored (add freely). Expectations are the *target*, not today's behaviour.

### Baseline — 2026-10-30, with memory copy, Jev live, 3 runs per task

| family | runs | pass | rate |
|---|---:|---:|---:|
| errand | 30 | 15 | 50 % |
| schoolwork | 30 | 20 | 66 % |
| messaging | 30 | 25 | 83 % |
| native | 30 | 28 | 93 % |
| **all** | 120 | 88 | **73 %** |

Simulated voice decision: the decider commits after 400 ms of silence median (650 ms p90) + ~90 ms per
Jev call. Route prep (grounding + routine + surface, Jev warm): 0.74 s median, 3 s max.

Failing tasks (k/3 passed) and what the harness shows — reported to the workstreams, not fixed here:

| task | k/3 | what happens |
|---|---|---|
| errand-03 "order me a randome chipotle bowl" | 0 | starts on the Onshape "Yarn Bowl" doc: `UserKnowledge.startURL` lets one generic word ("bowl") match a project |
| errand-04 "…from kfc under 10 bucks", errand-10 "…pizza from dominos" | 0 | a site the task names that no skill knows → Google search of the whole sentence (no generic brand → site step) |
| errand-06 "open my cart to see where I'm gonna pay" (on DoorDash) | 0 | `TaskGrounding` grounds the follow-up to an Amazon servo product (50 %); live (10-30 23:49) the run started on that page |
| errand-07 "I meant in DoorDash where we just were" | 0 | Jev `kind=open_app` → `openAppNamed("i meant doordash where we were")`; `continues_previous` 11–23 % despite "I meant". Live: 8 tries to open that "app" |
| school-03 "Open up a Google Doc and write some random phrase into it." | 2 | one run split into open Chrome + "write some random phrase into it" → Googled the phrase |
| school-04 "to my most recent cannabis assignment" (ASR for "canvas") | 0 | 69 % "continues" → gave up after 6 s; another run committed but `voiceSurface` put it on the current Google tab, so grounding was never used |
| school-06 "continue where I left off" | 0 | heard as `control_navi` resume — never a task |
| school-08 "open the hci notes" | 0 | opens Apple Notes (open_app / native) instead of the HCI notes doc |
| msg-02 "text mom I'm at the store and I'll be home soon" | 2 | the dictated "and" split it; "I'll be home soon" ran as its own task in the front app |
| msg-06 "text joão are we still on for tonight" | 2 | once routed to a Slack web channel from memory (earlier run: heard as an `answer`) |
| msg-07 "open my conversation with mikey" | 0 | grounds to an Onshape doc (98 %); no app inferred → stays in Finder (`inferApp` has nothing for "conversation"; the contact's channel app is consulted only after an app was inferred) |
| native-05 "Wait, close this tab" | 1 | 2/3 ran the agent instead of `BrowserControls` (the leading "Wait," defeats the match) |

Without screen memory (`--no-memory`) errand-03/06 and msg-07's grounding failures disappear but the
memory-only checks are skipped.

## 3. Live bench (`live.sh`) — not run by the bench author

For Liam, on the installed build, when the Mac can be left alone. Per task it sets up the context (opens
the context URL in Chrome, or brings Finder/Notes/Music forward), notes Chrome's tabs, submits
`navi://run?q=<utterance>` (typed path; `--voice` renders the utterance with `say -o` and replays it
through `navi://voice?file=…`, experimental), waits for the run's terminal line in `agent-runs.log`
(`--timeout`, default 180 s; no run within 12 s ⇒ "handled without an agent run"), classifies the outcome
with `profile.py`'s rules, then closes only the Chrome tabs that appeared during the task.
Results: `build/taskbench/live-<stamp>.jsonl` + a per-family table.

It never runs tasks marked `live.skip` (anything that sends, creates, edits, quits or changes a setting),
follow-ups whose context needs earlier instructions (unless `--followups`), or any utterance matching
the send/pay/post/delete guard. Errands stop in the cart: Navi never pays (runner adaptation 27). That
leaves 19 safe tasks today; messaging is covered live only by msg-07 — sending tasks need a draft-only
mode before they can run unattended.

## Caveats

- Outcome labels in the profile are heuristics on the run's own words; "success" for a browser run means
  "Done:"/cart reached, not that the right item was bought. `--json` + the run folders give the detail.
- Jev's voice heads vary between runs and between sessions (school-06 passed in an earlier single run,
  0/3 here); use `--repeat 3` and compare rates, not single passes.
- The offline bench checks understanding and the starting place, not the steps after it — the live bench
  and the profile cover those.

<!-- profile:begin -->
_Generated 2026-10-30 20:58 by `scripts/taskbench/profile.py` from `/Users/liamcarlin/Library/Logs/Navi` — 38 runs, 2026-10-29 16:44 → 2026-10-30 23:51 UTC._

### Outcomes per family (all runs in the log)

`success` = finished and did what was asked (heuristic: "Done:" / cart reached / native run.json `goal_achieved`); `false done` = reported *completed* but didn't do it (handed back a question, said it couldn't, or the user corrected it next); `cancelled` = the user stopped it (usually because it was slow or going the wrong way).

| family | runs | success | false done | failed | cancelled | success rate |
|---|---:|---:|---:|---:|---:|---:|
| errand | 23 | 3 | 3 | 13 | 4 | 13% |
| schoolwork | 4 | 2 | 0 | 0 | 2 | 50% |
| native | 8 | 3 | 3 | 2 | 0 | 38% |
| other | 3 | 0 | 1 | 1 | 1 | 0% |
| **all** | 38 | 8 | 7 | 16 | 7 | **21%** |

**Failure reasons** (failed + false done):

| reason | runs |
|---|---:|
| start page unrelated to the task | 5 |
| loop / going in circles | 5 |
| completed without achieving the goal (run.json goal_achieved=false) | 3 |
| completed without achieving the goal | 3 |
| goal not reached (writer verdict) | 2 |
| browser session / CDP error | 1 |
| modal / overlay / banner in the way | 1 |
| action could not be executed | 1 |
| corrected by the user's next words (“I meant in DoorDash where we just were”) | 1 |
| stuck (no progress) | 1 |

<details><summary>Every run</summary>

| UTC | family | task | outcome | total | prep | chrome | jev | writer+coach | act/settle |
|---|---|---|---|---:|---:|---:|---:|---:|---:|
| 10-29 16:44 | native | play my focused playlist | false_done — completed without achieving the goal (run.json goal_achieved=false) | 11.0 | 2.2 | 0.0 | 0.4 | 4.1 | 2.4 |
| 10-29 16:46 | native | make a new note called Student Spark that says hello class | failed — goal not reached (writer verdict) | 14.5 | 0.0 | 0.0 | 1.9 | 3.7 | 6.5 |
| 10-29 16:46 | native | make a new note called Student Spark that says hello class | failed — goal not reached (writer verdict) | 17.2 | 0.0 | 0.0 | 1.9 | 6.9 | 6.6 |
| 10-29 16:48 | native | play the newest song | false_done — completed without achieving the goal (run.json goal_achieved=false) | 7.8 | 1.1 | 0.0 | 0.2 | 2.3 | 3.2 |
| 10-29 16:48 | native | press play in music | success | 3.6 | 0.3 | 0.0 | 0.3 | 1.4 | 0.7 |
| 10-29 17:11 | native | make a new note called Student Spark that says hello classho | success | 9.1 | 2.2 | 0.0 | 0.4 | 3.4 | 1.0 |
| 10-29 17:28 | native | make a new note called Student Spark that says hello class | false_done — completed without achieving the goal | 25.3 | 0.0 | 0.0 | 0.8 | 2.8 | 1.0 |
| 10-29 17:30 | other | updated it | failed — browser session / CDP error | 5.8 | 0.2 | 5.3 | 0.0 | 0.0 | 0.3 |
| 10-29 17:30 | native | Press play in music | success | 4.0 | 0.4 | 0.0 | 0.2 | 1.6 | 1.8 |
| 10-29 17:30 | errand | look for flights to Tokyo | cancelled — cancelled by the user | 12.9 | 0.2 | 3.7 | 0.5 | 0.0 | 4.9 |
| 10-29 17:38 | schoolwork | Open up a Google Doc and write some random phrase into it. | success | 9.7 | 4.5 | 4.0 | 0.3 | 0.0 | 1.0 |
| 10-29 17:39 | schoolwork | go to my last assignment I did for class | cancelled — cancelled by the user | 29.4 | 1.3 | 0.5 | 2.3 | 3.5 | 19.8 |
| 10-29 17:39 | schoolwork | to my most recent cannabis assignment | cancelled — cancelled by the user | 7.5 | 1.2 | 0.4 | 0.4 | 0.0 | 1.8 |
| 10-29 18:42 | other | open up when you do tab | cancelled — cancelled by the user | 3.9 | 2.2 | 0.0 | 0.0 | 0.0 | 0.2 |
| 10-29 18:43 | schoolwork | Open up my class canvas | success | 6.5 | 1.3 | 2.2 | 0.2 | 0.0 | 2.7 |
| 10-29 18:43 | errand | a burger | failed — start page unrelated to the task | 5.9 | 0.1 | 0.6 | 0.3 | 4.6 | 0.4 |
| 10-29 18:43 | errand | open me a burger | cancelled — cancelled by the user | 4.4 | 0.1 | 0.5 | 0.1 | 0.0 | 0.2 |
| 10-29 18:43 | errand | order me a burger | failed — start page unrelated to the task | 4.5 | 0.4 | 0.5 | 0.3 | 2.9 | 0.3 |
| 10-29 18:44 | errand | figure out how to order me a burger | failed — start page unrelated to the task | 5.7 | 0.3 | 0.5 | 0.3 | 4.3 | 0.4 |
| 10-29 18:44 | errand | Go to McDonald's | failed — start page unrelated to the task | 5.9 | 0.1 | 0.5 | 0.3 | 4.7 | 0.3 |
| 10-29 18:44 | errand | a big Mac, and add it to my car | failed — start page unrelated to the task | 5.2 | 1.1 | 0.5 | 0.2 | 3.0 | 0.4 |
| 10-30 15:12 | errand | go to mcdonalds and order me a burger | failed — loop / going in circles | 13.7 | 0.2 | 1.6 | 1.1 | 5.2 | 5.6 |
| 10-30 15:13 | errand | go to mcdonalds and order me a burger | failed — loop / going in circles | 8.9 | 0.1 | 0.9 | 1.5 | 3.7 | 2.7 |
| 10-30 15:48 | errand | go and buy me some mcdonalds burgers | cancelled — cancelled by the user | 44.6 | 0.2 | 1.5 | 9.4 | 3.6 | 28.9 |
| 10-30 15:49 | errand | order me one mcdonalds burger | failed — modal / overlay / banner in the way | 13.8 | 0.2 | 1.5 | 1.6 | 3.9 | 6.5 |
| 10-30 15:50 | errand | buy a roll of toillet paper from amazon - cheapest one possi | failed — action could not be executed | 9.8 | 0.2 | 4.4 | 0.0 | 0.0 | 5.2 |
| 10-30 17:00 | errand | order me toilet paper on amazon. chepest possible | success | 13.5 | 1.9 | 2.4 | 0.6 | 0.0 | 8.6 |
| 10-30 18:48 | errand | order me a randome chipotle bowl | failed — loop / going in circles | 17.6 | 1.2 | 5.5 | 1.6 | 3.3 | 6.0 |
| 10-30 19:10 | errand | order me a random thing from kfc under 10 bucks | false_done — completed without achieving the goal | 23.6 | 0.9 | 1.6 | 2.1 | 6.5 | 12.5 |
| 10-30 19:11 | errand | order me a randome chipotle bowl | failed — loop / going in circles | 28.2 | 0.8 | 2.3 | 3.2 | 7.5 | 14.3 |
| 10-30 23:49 | errand | order me a burger | success | 26.3 | 1.2 | 2.3 | 1.6 | 0.0 | 21.2 |
| 10-30 23:49 | errand | open my cart to see where I'm gonna pay | false_done — corrected by the user's next words (“I meant in DoorDash where we just were”) | 11.2 | 1.2 | 5.4 | 0.4 | 0.0 | 4.3 |
| 10-30 23:49 | errand | I meant in DoorDash where we just were | false_done — completed without achieving the goal (run.json goal_achieved=false) | 7.1 | 0.6 | 0.0 | 1.7 | 3.0 | 1.9 |
| 10-30 23:50 | other | Wait, close this tab | false_done — completed without achieving the goal | 7.7 | 0.2 | 5.4 | 0.4 | 0.0 | 1.8 |
| 10-30 23:50 | errand | to my cart | cancelled — cancelled by the user | 14.2 | 1.2 | 4.9 | 0.0 | 0.0 | 0.4 |
| 10-30 23:50 | errand | Cl on cart | success | 2.4 | 0.1 | 0.6 | 0.4 | 0.0 | 1.4 |
| 10-30 23:50 | errand | with... Click on sign in with DoorDash with Google | failed — loop / going in circles | 24.0 | 0.2 | 6.8 | 2.1 | 4.3 | 10.6 |
| 10-30 23:51 | errand | Sign into DoorDash with my Google account | failed — stuck (no progress) | 11.0 | 0.3 | 3.2 | 0.6 | 0.2 | 6.6 |

</details>

### Where the time goes

Per run, the run's wall time is split into: **prep** (task start → first driver event: planning, grounding, routine match, surface pick), **chrome connect** (`Connecting to Chrome…` → `Page ready`), **native open** (`Opening <app>` → first AX snapshot), **Jev** (sum of the per-step latencies Jev reports), **writer** (Claude reading the screen / answering, native driver's `calls:` tally), **coach** (Claude diagnosing a stuck browser run), and **act/settle/observe** (the rest: executing the action, waiting for the page to settle, re-reading the page/AX tree between steps, waits).

| phase | runs with it | median / run | p90 / run | total | share of all run time |
|---|---:|---:|---:|---:|---:|
| prep (plan/ground/routine) | 36 | 0.41 s | 2.05 s | 29.7 s | 6% |
| chrome connect → page ready | 28 | 1.92 s | 5.39 s | 69.6 s | 15% |
| native app open → first AX | 7 | 1.87 s | 9.67 s | 30.8 s | 6% |
| Jev decisions | 34 | 0.47 s | 2.13 s | 39.6 s | 8% |
| writer (Claude) | 9 | 3.00 s | 4.66 s | 29.2 s | 6% |
| coach (Claude, stuck) | 15 | 3.93 s | 5.97 s | 61.3 s | 13% |
| last event → user cancelled | 7 | 3.50 s | 5.36 s | 23.0 s | 5% |
| act + settle + observe | 38 | 2.55 s | 13.07 s | 194.3 s | 41% |
| **whole run** | 38 | 9.74 s | 25.60 s | 477.6 s | 100% |

| per-occurrence measure | n | median | p90 | max |
|---|---:|---:|---:|---:|
| Jev call latency | 354 | 0.10 s | 0.16 s | 0.64 s |
| browser step wall time (action → next action) | 224 | 0.35 s | 1.57 s | 8.65 s |
| native step wall time | 27 | 0.68 s | 2.79 s | 4.04 s |
| Connecting to Chrome… → Page ready | 28 | 1.60 s | 5.34 s | 6.82 s |
| Opening <app> → first AX snapshot | 7 | 1.87 s | 9.67 s | 20.59 s |
| task start → first action | 27 | 4.44 s | 9.98 s | 20.90 s |
| Page ready → first browser step done (observe + Jev + act + settle) | 25 | 1.07 s | 3.38 s | 6.92 s |
| page settle: observations per changed page | 88 | 2 | 4 | 9 |
| Claude calls per run (writer + coach) | 38 | 1 | 1 | 3 |

**Lag sources, ranked by total time across all runs:**

1. **act + settle + observe** — 194 s (41%): browser step wall median 0.35 s, p90 1.57 s; a changed page is re-observed median 2× (p90 4, max 9) before Jev sees it; Page ready → first step done median 1.07 s, p90 3.38 s
2. **chrome connect → page ready** — 70 s (15%): `Connecting to Chrome…` → `Page ready` median 1.60 s, p90 5.34 s, max 6.82 s (every browser run pays it; includes the start page's settle)
3. **coach (Claude, stuck)** — 61 s (13%): 15 runs stopped to ask Claude, median 3.93 s per run; 0 of them then succeeded
4. **Jev decisions** — 40 s (8%): 354 calls, median 0.10 s, p90 0.16 s — fast; it adds up only through step count
5. **native app open → first AX** — 31 s (6%): `Opening <app>` → first AX snapshot median 1.87 s, max 20.59 s
6. **prep (plan/ground/routine)** — 30 s (6%): median 0.34 s, p90 2.01 s before any driver starts
7. **writer (Claude)** — 29 s (6%): median 3.00 s of Claude per native run (reading the screen to stop / answer / write field text)
8. **last event → user cancelled** — 23 s (5%): 7 runs the user cancelled; median 3.50 s of nothing new on screen before they gave up

User-visible: task start → first action median 4.44 s, p90 9.98 s.

**Voice decision wait** (speech end → commit, from `debug.log`): no data — the voice trace (`DebugTrace`) is compiled into Debug builds only, and the installed Release build logs voice decisions at `.info` to the unified log, which macOS does not persist. Run a Debug build (`scripts/run.sh`) for a session, or use the offline harness's simulated voice loop (`TaskBenchTests`) for the decision itself.

<!-- profile:end -->
