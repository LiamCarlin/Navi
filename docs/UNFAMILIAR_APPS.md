# Apps Navi has never seen, and tasks that take many steps

Design note, 2026-11-02. The problem: a task in an app or site with no hand-written playbook
(Onshape, Fusion, SolidWorks, Blender, a lab's LIMS, next year's app) fails or wanders, and a
long task fails even in apps Navi knows. Both get worse as users bring their own software.
The goal is to do what the user asked, in the order it has to happen, as fast as a playbook
app, and to *know* when it is done — without writing a playbook per app.

## What the bench says (`docs/AUTO_MODE_BENCH_2026-11-01.md`)

| scenario | what happened | why |
|---|---|---|
| schoolwork-022 "export the bowl as an stl" (Onshape) | Jev BLOCKED on step 1 → run restarted on a Google search of the sentence → "impossible: needs a 3D modeling app" | no Onshape playbook; nothing on the Part Studio screen says "export" (it is in a right-click menu) |
| schoolwork-014 "make a new part studio" (Onshape) | Jev clicked the feature list's "new folder" 3× → Claude takeover found the bottom "+" | the only visible "new" control was the wrong one; nothing told Jev where the real one is |
| memory-031 "put the stuff from my last onshape session in this note" | planner's step 1 "review the design in Onshape" → 80 s clicking the CAD canvas and tabs | a step with no "done when"; no way to know the step was pointless |
| web-042 Onshape doc + McMaster bearing | searched the generic word "bearing" | no per-step evidence of what the earlier step produced |
| tier 5 (long compound) | 0 pass / 10 | each step runs to its own `done`; a wrong `done` (Navi's "completed" was wrong 20 of 45 times) feeds the next step a wrong state |
| multi-014 "open the hci doc, copy the action items into reminders…" | 'Next steps level 1' clicked 3× in a row, 4 times | the stuck rule fires per screen, the plan never re-plans from the screen |

## Why, in the code

1. **No playbook ⇒ Jev only sees the screen.** `AppSkills.skill(bundleID:url:)` is nil for an unknown
   app, so `state.playbook` is absent and the KEY head offers the 24 generic combos
   (`CUDecide.keyCombos`). The doc comment on `AppSkill` says what happens then: Jev treats every
   app like a web form.
2. **The app's own manual is never read.** Every native Mac app documents every command and its
   shortcut in its menu bar, but the walk reads only the menu *titles*, and only when the task
   says "menu", "file", "export"… (`AXSnapshot.taskMentionsMenu`, `walk(includeMenuBar:)`).
   Fusion's Measure, Blender's Export, Affinity's Document Setup are invisible to Jev.
3. **Nothing learned is reusable.** `AgentExperience` keeps "goal → action labels" per app and
   recalls by word overlap (3 lines). A failed run teaches nothing; a success never becomes a
   recipe; nothing is shared between users.
4. **Plans have no checks.** `TaskPlanner.Step` is surface + goal + app/url. No `done_when`,
   no ordering constraint, no re-plan. A step ends when Jev says `done` ≥ 0.9 or the writer
   says achieved, and the next step starts from whatever that left.
5. **Exploration is one Jev step at a time.** When Jev stops, the writer hands back one move
   (`focus`); the takeover is 6 rounds. In an unfamiliar app that is trial and error at
   0.5–1.5 s a step plus a screen read.

## The design: learn the app before touching it, plan against what it can do, check each step, keep what worked

Five layers, each usable alone, in build order. Everything stays "classifier picks, code
decides facts, writer writes text": the new knowledge arrives as *state*, Jev still picks.

### 1. `AppManual` — the app's own command reference, read by code (no model)

- On first contact with an app (and when its version changes) walk the **whole menu bar**
  through AX: every menu, submenu, item title, ⌘ equivalent, enabled state. 200–800 items,
  100–300 ms, cached at `Application Support/Navi/manuals/<bundleID>-<version>.json`. Also the
  window's `AXToolbar` items and the top-level groups (sidebar sections, tab names) as a
  layout summary.
- Web apps have no menu bar: the first visit per host collects the page's persistent chrome
  (toolbars, `role=menubar/menuitem`, `aria-label`s, shortcut hints in titles — Onshape's
  "Extrude (Shift+E)") into a host manual the same way, in the runner (`navi_runner.py`).
- Per step: the manual's items whose title or path matches the goal's words (+ synonyms:
  export/save as/download, measure/dimension/inspect, new/create/add) — at most 40 — are
  offered as `press_offscreen` candidates ("menu item ‘File → Export…’ (⇧⌘E), enabled"). The kind
  already exists, so the action set stays mutually exclusive. Pressing = `AXPress` on the item
  element (works without opening the menu for Cocoa apps), else its shortcut via
  `pressWithBriefActivation`, else clicking the menu path. The KEY head's combos come from the
  manual instead of the generic list (`AppSkills.keyCombos(for:base:)` takes them).
- Effect: "measure this in Fusion" / "export as STL" / "save as PDF" reach the command on step 1
  with no playbook at all. Jev's 32.5k-token input cap is respected by the 40-item cut.

### 2. `SkillSynthesizer` — a playbook generated the first time, cached forever

- When `AppSkills.skill(...)` is nil: ask Claude (Sonnet, once per app, ~4–8 s) for an
  `AppSkill` of the same shape the library uses — `howItWorks`, `shortcuts`, `recipes` for the
  goals people ask in this app, `doneWhen`, `avoid`, `fieldHints`, `deepLinks`, `aliases`,
  `triggers` — from (a) the app's name / bundle id / host, (b) the manual (menus, toolbars,
  layout), (c) one AX/DOM snapshot of the current window, (d) what Claude knows of the app.
  Stored at `Application Support/Navi/skills/<id>.json`; `AppSkills.all` = library + generated
  (library wins). `hosts` are seeded from the user's own history (`UserHabits` sites:
  olinbaja.onshape.com, cad.onshape.com), so routing gains the app too — "open my yarn bowl in
  onshape" (schoolwork-015) stops being an answer.
- When it runs: from `ComputerAgent.prepare` while the user types (the app the task names or
  the one in front); at `AgentTarget` pin time when a run opens an app with no skill, in
  parallel with the first Jev step (used from step 2). Web: the runner asks Navi over its event
  channel for a host it has no playbook for; the result joins `NAVI_PLAYBOOKS_JSON` for the
  next page.
- Per-goal recipe on demand: when the (generated or library) skill has no recipe matching the
  goal, one small Haiku call — "the steps for *this* goal in this app, in Jev's vocabulary,
  using these menus/controls" — 1.5–3 s, cached per (app, goal words). Started with the
  prefetch, so it costs nothing at run start.
- Guardrail: a generated recipe is state for Jev (`playbook.recipes`), never pressed by code
  until a run has proved it (layer 4). `avoid` and `doneWhen` from the synthesizer are advisory.

### 3. Plans with checks — `TaskPlanner` steps carry evidence, the run keeps a ledger

- Each planner step gets `done_when` (visible evidence: "the Export dialog shows STL", "the
  note holds the dates") and `must_not` (what would mean the wrong path), written by the same
  planner call. A one-step plan gets them from the skill's `doneWhen` or the recipe.
- The per-step Jev call gets `plan`: `[✓ step 1 — produced: …, → step 2 (done when …), step 3]`
  — the shape `this_users_way` already uses — and a `step_done` noul with the step's criterion
  as structured state. A step advances only when `step_done` ≥ 0.7 *and* the screen changed
  since the step began (or the criterion names the screen as-is). `done` from Jev alone no
  longer ends a step in an app without a library playbook.
- A stall (`CURunState` third stall) re-plans **from the current screen**: the writer already
  reads it; it now returns the remaining steps, not one move. memory-031's 80 s on the canvas
  becomes one re-plan ("the note is the target; Onshape has nothing to review").
- What a step produced (`needs_result`) is carried as text in the ledger, so web-042's step 2
  searches the bearing's part number, not "bearing".

### 4. Learning — what worked becomes a recipe, what failed becomes `avoid`

- After a run in an app with a generated skill: the action trace (labels only, as
  `AgentExperience` already redacts) becomes a recipe for that goal class in the skill file
  (`source: "learned"`, `worked`/`failed` counts like `Routine`). The last screen + action of a
  failed run goes to `avoid` ("the feature list's new-folder button is not a new Part Studio").
- A learned recipe done ≥ 2× is **followed by code** the way a user routine is: build a
  `Routine` from it and hand it to `UserRoute.direct` — navigation-only steps (menu items,
  tabs, links, a harmless shortcut) pressed when the control is on screen exactly once, Jev
  keeps typing/sending/anything irreversible, a step that changes nothing stops following.
  This is the existing machinery, fed from a second source.
- `CUReplay` stays as is (exact replay of the same goal in the same app); recipes generalise
  across goals of a class.

### 4b. The manual grows with the user's own use — every click and keystroke, processed, not stored

Liam, 2026-11-02: the user already shows Navi how each app works, every day. Screen memory is
not only screenshots: `ActionJournal` records **every** click (the AX control under the
pointer: role, label, menu path, shortcut), every ⌘/⌃ shortcut (named by the menu item it
runs), and where typing starts (the field's label, once per stretch) — at event rate, not on
the capture timer. Plain keys and typed text are never recorded; only the fact that typing
happened and the Return that sent it. That journal is already what `RoutineMiner`,
`UserMoves` and `UserPaths` read.

What this layer adds is that the *app knowledge* reads it too (`AppUse`, cached 5 min per app):

- **Commands the user runs** (menu picks and the shortcuts that run them, with counts) rank
  first when the manual's commands are offered to Jev (`AppManual.commands(for:used:)`), so
  Navi reaches for *their* Export, not the first one in the menu.
- **Their shortcuts** go into the generated playbook as its shortcuts ("cmd+shift+e: File ›
  Export… (this user's shortcut)") and win over the model's guesses.
- **Their routines** in the app (from `RoutineMiner`) become recipes of the generated playbook
  ("export the bowl (how this user did it)"), and the synthesizer's packet carries
  `how_this_user_works_here` (commands, shortcuts, most-clicked controls, routine steps), so
  the playbook Claude writes is already shaped by this user.
- **Runs refine the file** (layer 4): a run that achieved its goal stores its actions as a
  `learned` recipe; one that did not counts a failure on the recipe that matched and writes
  the dead end to `avoid`; a recipe that failed twice without a success is withdrawn.

Processing, not storing: `AppUse` is an aggregate (command → count, control → count, the
routines' step lines) rebuilt from the journal on demand; nothing new is written for it. The
journal itself keeps 90 days of labels, which the personal-data cleanup already redacts.

Not in this pass: a finer key stream (navigation keys, typing-run lengths per field) — it
would need a new monitor; the journal's shortcuts and clicks already carry what a manual
needs. A later pass can add per-field "how they fill this form" from Return/Tab patterns
without storing a single key.

### 5. Shared knowledge (later, needs the backend)

Generated + learned skills carry app labels, menu paths and recipes — never user text — so they
can be uploaded per app version and pulled on first contact. Once one Navi learns Fusion, every
Navi has it. Opt-in; the personal-data cleanup covers the files.

## What this does not do

It never drives an app through its API or an MCP server (Onshape has both; a measurement
through the REST API would be exact). That does not generalise to SolidWorks or Fusion, adds
dependencies, and needs per-app auth. Worth adding later as an accelerator for the few apps that
have one, behind the same `AppSkill` (a recipe whose step is "ask the API"), not as the answer.

## Expected effect, per bench case

| case | after |
|---|---|
| schoolwork-022 export STL | layer 2's Onshape recipe (right-click the Part Studio tab / the part → Export → STL); no BLOCKED, no restart |
| schoolwork-014 new part studio | recipe "+ at the bottom → Create Part Studio"; `avoid` the feature list's new-folder button |
| Fusion / SolidWorks / Blender measure, export, save as | layer 1 alone: the menu item is a `press_offscreen` candidate on step 1 |
| memory-031 | layer 3: a `done_when` on the note, a re-plan from the screen after the first stall |
| tier 5 | layer 3: ledger + `step_done`; a wrong `done` no longer ends a step |
| schoolwork-015 "open my yarn bowl in onshape" | layer 2 seeds `hosts`/`aliases` ⇒ routed as an app task |

## Cost per step

Layer 1 adds nothing per step (the items ride in the same Jev call). Layer 2 is one Sonnet call
per new app, prefetched; per-goal recipes one Haiku call, prefetched. Layer 3 adds one noul to
the existing call. Layer 4 is local. Jev's input cap: ≤ 40 manual items, the ledger ≤ 8 lines.

## What is built (2026-11-02, this branch)

Layers 1, 2, 3 and 4b, with the learning half of 4:

| piece | where |
|---|---|
| Menu-bar manual, cached per app version on disk, read on the AX queue (≤ 800 commands, 1.2 s box; Open Recent / Services / the Window menu's window names skipped) | `Agent/AppManual.swift` (`AppManual`, `AppManualStore`) |
| Goal-relevant commands (goal words + synonyms, the user's own commands first) as `press_offscreen` candidates: "menu item ‘File › Export…’ (a command in the app's menu bar; shortcut ⇧⌘E)"; pressed through AX by title, the shortcut as fallback; generic combos re-described with the app's meaning; `app_manual` (menus) in Jev's state | `AppManual.offscreenElements/merge/keyCombos`, `CUDecide.offscreenCriterion` + `menuCommandsRule`, `ActionExecutor` `.press`, `AgentRun` `observe()` |
| The user's own use of an app from the journal and routines | `Agent/AppUse.swift` |
| Generated playbooks: Claude writes an `AppSkill` of the library's shape (structured output, the agent model, once per app/site) from name + manual + one snapshot's labels + the user's use; stored under `Application Support/Navi/skills/`; `AppSkills.all` = library + generated (library wins); aliases/triggers reach routing (`mentioned`, `rankApps`) | `Agent/SkillSynthesizer.swift` (`StoredSkill`, `GeneratedSkillStore`, `SkillSynthesizer`) |
| Per-goal recipe when a generated playbook has none for the goal (Haiku, stored in the file, `source: goal`) | `SkillSynthesizer.ensureRecipe` |
| Learning from runs: `learned` recipes, failure counts, `avoid` | `SkillSynthesizer.learn`, called from `AgentRun` `remember()` / `conclude` |
| While typing: the manual + playbook of the app in front and of a running app the task names | `AppKnowledge.prepare` from `ComputerAgent.prepare` |
| "Delete everything" removes manuals and generated skills | `PrivacyData` |
| Planner steps carry `done_when` (visible evidence) and `must_not`; `PlanLedger` puts the whole plan in Jev's state (`plan`: ✓ done with what it produced, → current with its evidence, pending) and in the writer's packet; Jev's `kind` rule and the writer's system prompt say `done` / achieved mean the current step's evidence; a `step_done` noul rides in the same call, and Jev's own `done` ends an effect step unread only at ≥ 0.9 **and** `step_done` ≥ 0.7 when the step has evidence (else the writer reads) | `Agent/PlanLedger.swift`, `TaskPlanner.Step`, `CUDecide.Input.plan/stepDoneWhen`, `CUDecide.Verdict.stepDone`, `AgentRun.execute/handOff/startReview` |
| A step that stops short (not_achieved / partial, never needs_user / impossible) re-plans the **remaining** steps from the screen as it is now, once per run (`TaskPlanner.replan`: the same planner with `replan` = steps done + findings, the step that failed + what happened, the still-planned steps, and `screen_now`); the new steps replace the rest of the plan and the run goes on | `TaskPlanner.replan`, `AgentRun.execute` |
| Tests | `NaviTests/AppManualTests.swift`, `NaviTests/PlanLedgerTests.swift` |

Not yet: the web host manual in the runner (a generated web skill reaches the runner through
`NAVI_PLAYBOOKS_JSON` only if it exists before the run starts — it is written during the first run
on that site and used from the second); the ledger and `step_done` for browser steps run by the
Chrome CDP runner (its own judge decides; `NAVI_PLAN_JSON` would carry the ledger); following a
learned recipe by code; cloud sharing. None of this is live-tested yet: the next step is the task
bench's tier 4–5 scenarios and an unfamiliar-app set (Fusion, Blender, Onshape).

## Build order

1. `AppManual` + manual items as `press_offscreen` + manual shortcuts on the KEY head. ~1 day.
   A/B with `scripts/axprobe` on Fusion, Blender, Affinity, Numbers (skill removed): "export as
   STL", "measure", "save as PDF", "new sheet".
2. `SkillSynthesizer` + store + prefetch + per-goal recipe; web host manual in the runner. ~2 days.
   Live on Onshape: export STL, new part studio, measure a distance, rename a part.
3. Planner `done_when`/`must_not`, ledger, `step_done`, re-plan from the screen. ~2 days. Bench
   tiers 4–5.
4. Learned recipes → `avoid` / recipes / followed routes. ~1 day.
5. Cloud share. Later.

Measure with a new bench family `unfamiliar-*` (apps and sites with no library skill, plus
Onshape/Fusion tasks) in `scripts/taskbench/scenarios.json`; grade "done" only against the
scenario's visible ending, as the bench already does.
