# Native computer use = typesafe-computer-use

Navi's native computer-use driver (the Jev-first driver, `NaviSettings.agentDriver = .jevFirst`)
follows [typesafe-computer-use](https://github.com/awlevin/typesafe-computer-use) ("jev").
That repository is the **source of truth** for how the driver thinks. It is vendored, pinned,
at `vendor/typesafe-computer-use` (`UPSTREAM_COMMIT`), and ported to Swift module by module in
`Navi/Agent/TypesafeCU/`. Read upstream's `VISION.md` and `docs/how-a-step-works.md` first:
this page only says where each piece lives here and where Navi differs.

The one idea: **the classifier picks, code decides facts, and the writer only writes free
text.** Anything a model would have to work out (a date, whether a field is focused, which of
three "Buy" buttons is meant, what was already tried) is computed in code and handed to Jev as
state. When Jev stops, the writer reads the screen and answers — or gives Jev back one move to
make. The writer never picks an action.

## Keeping it in step with upstream

```bash
scripts/typesafe-cu/sync.sh            # re-vendor main (or pass a commit)
git diff vendor/typesafe-computer-use   # what changed upstream
```

The script lists the upstream commits since the pinned one. Carry every change in the modules
below into the Swift file beside it, and its test case into `NaviTests/TypesafeCUTests.swift`
(those tests are upstream's own cases, converted from capture pixels at scale 2 to points).

| upstream (`typesafe_computer_use/`) | Swift | what it owns |
|---|---|---|
| `models.py` | `CUModels.swift` | `CUItem`, `CUField`, `CUGuidance`, `CUSignature` + `same(as:)` |
| `dates.py`, layout helpers in `decide.py` | `CUFacts.swift` | dates → "in N days", row mates, regions, now, goal echo |
| `perception.py`, `ax_walk.py` | `CUPerception.swift`, `AXSnapshot.swift` (walk) | one item list from controls + text (+ OCR), the merge, the budget, reading order, off-screen controls, OCR reuse |
| `decide.py` | `CUDecide.swift` | state, criteria, the one request, `Decision`, typed-value check |
| `writer.py` | `CUWriter.swift` (+ `ClaudeClient.structured`) | field text, URL, the answer with focus/question, credential guard |
| `runner.py` (stop rules, hand-off) | `CURunState.swift`, `AgentRun.mainJevFirst` | idle/repeat/stall/stuck, tried-here, earlier screens, the hand-off loop |
| `actions.py` | `ActionExecutor.swift`, `AgentRun.historyLine` | executing, history lines, restoring a failed fill |
| `calls.py`, `report.py`, run folder | `CUCalls`, `CURunFolder.swift` | the calls line, `~/Library/Logs/Navi/runs/<ts>/` |
| `macos.py` | `AXSnapshot.swift`, `InputController.swift`, `ScreenCapture.swift` | the platform |
| `browser/*` (CDP backend) | — | not used; Chromium web steps stay on vendored jev-ultrafast (below) |

## A step

1. **Observe.** `AXSnapshotter` walks the target app's window (150 ms box). `CUPerception`
   makes one numbered list: every control (`ax`), every line of static text (`text` — the tree
   hands text over exactly, where upstream needs OCR), OCR blocks the tree did not carry
   (`ocr`), and a control merged with the text naming it (`ax+ocr`). A symbol read off a
   button's icon is dropped (the button stands for it); text inside the focused one-line field
   is the field's value, not an item; lines echoing the goal are dropped; past 255 items the
   faintest text goes first and a control never goes for text. Labelled controls the walk
   pruned as off the window but that take `AXPress` are offered separately (`press_offscreen`).
2. **Facts.** Dates ("dated 2026-10-13 (in 27 days)", "near a line dated …"), the row of a
   repeated label ("in the row of 'Coldplay', 'Oct 2'"), a coarse region, the focused field,
   checked/selected/"holds '…'", and the actions already tried on this same screen.
3. **Decide.** One Jev request: `kind` over a mutually exclusive action set, and speculatively
   the target each kind would use. Confidence is the kind's, lowered by the target's for kinds
   that land somewhere (click, press, type, choose, shortcut) — never by `site` or `app`.
4. **Act.** `ActionExecutor`. Typed text is either submitted with Return (the writer's
   `submit`) or checked by a Jev noul; under 0.5 only our own write is undone, through the
   same element, never with keys.
5. **Stop.** `done`, `none`, confidence under the threshold (0.4), three actions in a row that
   left the screen as it was, two in a row already tried on this screen, or the step limit.
   The writer reads the screen (screenshot, screen text, earlier screens) and answers
   `{achieved, answer, focus, question}`. A focus sends Jev back to work with `current_focus`
   in its state; a focus that led to no action leaves its answer standing; a third stall with
   no new page is final (`stuck`); `maxClaudeFallbacks` bounds the hand-backs (voice: 2).

## What Navi adds (gaps upstream lists, or needs of an app that is not a CLI)

- **Keyboard shortcuts** (`press_shortcut` + the app's playbook shortcuts). Upstream's
  OBSERVATIONS: "jev has no right-click or keyboard shortcuts" (9 steps vs 6). Return, Escape
  and Back stay kinds of their own, so no two options mean the same thing.
- **Typing into a chosen field** (`type_text` + `field`): one step instead of click-then-type.
- **Pop-up values** (`choose_option`), **switching apps** (`open_app`), and the goal's own
  sites on `use_browser`'s `site` question instead of upstream's personal catalog.
- **App knowledge in the state**: `playbook` (`AppSkills`), `experience` (`AgentExperience`),
  `conversation` (what was said before).
- **The user's own way in the state** (`UserMoves`, from screen memory): items this user clicks
  in this app/site carry `user_clicks` (and "this user clicks this here (N×)" in their criteria),
  the item they usually click after the last one clicked carries `user_next`, their shortcuts join
  the shortcut question ("this user presses it here"), and `how_this_user_works` holds similar
  tasks they did before with their steps, their habits and most-clicked controls. Upstream has
  no notion of a particular user; these are facts code computed, Jev still picks.
- **Approval gate**: `is_irreversible` / `is_prohibited` ride along in the same call and feed
  `JevGate` — upstream has no approvals.
- **Background mode**, **RecipientPicker** (contacts in To:/Cc:), typing sounds: unchanged.
- **Perception escalates before a model does**: a screen Jev stopped on is re-read once with
  OCR and decided again before the writer is asked.

## Deliberate differences

- **OCR is a fallback, not every step.** Upstream OCRs the front window each step (0.3–0.7 s).
  Navi's tree carries static text exactly, so OCR runs where the tree is thin
  (`CUOCRPolicy`: fewer than 8 labelled controls and 3 text lines, or a known CEF/terminal/canvas
  app), and on a screen Jev stopped on. The OCR cache is upstream's tile comparison without the
  per-rectangle re-read: an unchanged window reuses its lines, a changed one is read whole.
- **`drawn()` is not ported** (it needs the capture every step). Controls come from the tree,
  and clicks go through `AXPress` first.
- **Jev's sure `done` is accepted without a review** when the goal asked for an effect, work was
  done and Jev is ≥ 0.9 (`AgentRun.acceptDoneConfidence`): the writer's read costs 2–5 s and the
  user is looking at the result. Lookups, unsure `done`s and every other stop are reviewed.
- **Questions end the run.** Navi has no reply box mid-run; the writer's question is shown (or
  spoken) with its answer, and the user's reply is the next request, which carries this one in
  `QueryContext.conversation`.
- **Quoted text in the goal is typed as is** (`TextCandidates.obviousText`) — a fact read from
  the goal, not free text; without a writer, `FieldText.localGuess` types what the goal spells out.
- **Chromium web steps** keep the jev-ultrafast CDP runner (the user's real Chrome, background
  tabs). Every other browser — and Chrome without the runtime — goes through this driver.
- **Claude drives only when Jev is unreachable** (`claudeTakeover`), or when the user picks the
  Claude-only driver.

## Debugging a run

- `~/Library/Logs/Navi/runs/<timestamp>/`: `step-NNN-payload.json` (the exact state and
  questions), `step-NNN-answers.json` (every probability, the decision, `idle_actions`,
  `repeated_actions`, `already_tried_on_this_screen`), `step-NNN-review.json` + `.png` (what
  the writer read and said), `run.json` (history, hand-offs, calls). The newest 30 are kept.
- The calls line at the end of every run: `calls: jev 14 (82%, 3.9s)  writer 3 (17%, 21.4s)
  handoffs 1`. Jev's share is the number the design stands on: a task the writer had to steer
  at every turn needs a fix in the state Jev reads, not more hand-offs.
- `scripts/axprobe/build.sh` → `build/axprobe <bundle-id> [goal…]` prints the item list exactly
  as the driver builds it and, with `TYPESAFE_API_KEY` set, Jev's decision — read-only.
