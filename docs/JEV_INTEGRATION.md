# How Navi uses Jev

Jev is TypeSafe AI's *System One* model. You POST some `state` and a map of
typed `questions`; it returns one typed `answer` per question with calibrated
probabilities — never free text — in roughly 70–500 ms. Navi uses it wherever
a decision has to feel instant or has to be *checkable*: routing a query,
gating an agent step, deciding whether a screen frame is worth remembering.

Full API docs are mirrored in `docs/jev-docs-full.txt`. The client is
`Navi/Providers/JevClient.swift`; the question constants live next to the code
that uses them (Router, Agent, Memory) so a reviewer can read the questions
and thresholds in one place.

## The call

```http
POST https://api.typesafe.ai/v1/systemone
Authorization: Bearer $TYPESAFE_API_KEY
Content-Type: application/json

{
  "state": "…",                    # plain text, but structured (labelled sections)
  "model": "jev-latest",           # NaviSettings.jevModel
  "questions": {
    "<name>": { "type": "choice", "instructions": "…", "criteria": { "key": "description", … } },
    "<name>": { "type": "score",  "instructions": "…", "criteria": [ "level0", "level1", … ] },
    "<name>": { "type": "noul",   "instructions": "…" }
  }
}
```

```jsonc
// response
{
  "model": "jev-…",
  "answers": {
    "<choice q>": { "type": "choice", "choice": "openApp", "probabilities": { "openApp": 0.91, … }, "confidence": 0.88 },
    "<score q>":  { "type": "score",  "score": 2.3, "legend": { "0": "…", … }, "confidence": 0.7 },
    "<noul q>":   { "type": "noul",   "noul": 0.04 }          // P(statement is true)
  },
  "usage": { "input_tokens": 812, "output_tokens": 0 }
}
```

`JevClient.Question` encodes the three types; `JevClient.Answer` decodes them
and exposes `.choice`, `.probabilities`, `.score`, `.noul`, `.isTrue`
(`noul ≥ 0.5`) and a uniform `.confidence` (for nouls, distance from 0.5 ×2).

Client behaviour that matters:

- **Cache.** Identical `(state, model, questions)` bodies within 120 s return
  the cached response (an actor-backed LRU, 200 entries). Retyping or
  backspacing to the same query costs nothing.
- **Timeouts.** 8 s request timeout, `waitsForConnectivity = false` — a dead
  network fails fast into the heuristic path instead of hanging the panel.
- **Accounting.** Every non-cached call increments `usageJevCalls` (Usage page).
- **Errors** are typed `NaviError` (`missingAPIKey`, `http`, `decoding`) and
  are never shown as raw JSON; callers degrade gracefully (below).

### Writing state

Jev is trained on program state, so state is always **labelled sections, not
prose**, and the same section order every time:

```text
QUERY: open chrome and search for jev
FRONTMOST_APP: com.apple.Safari (Safari)
WINDOW_TITLE: TypeSafe — Documentation
CLIPBOARD: https://docs.typesafe.ai/primitives
RECENT_QUERIES: maps | 12% of 340
TIME: 2026-09-19T14:02:11-07:00 (Friday afternoon)
```

Long fields are truncated (clipboard ≤ 2 000 chars, OCR excerpt ≤ ~1 500
chars) so a call stays around 1–2k input tokens.

## Call 1 — Intent routing (`Navi/Router/QueryRouter.swift`)

One call, four questions, fired once per debounced query (~80 ms after the
last keystroke). Instant local results are already on screen; this call
re-ranks them or swaps in the right result set.

| Name | Type | Instructions (abridged) | Criteria |
|---|---|---|---|
| `intent` | choice | "What does the user want Navi to do with QUERY, given the context?" | `Intent.allCases` → `Intent.jevCriteria` (openApp, openFile, openURL, webSearch, calculate, askQuestion, computerTask, recallMemory, systemCommand, settings) |
| `is_risky` | noul | "Acting on this query immediately would do something hard to undo (send, pay, delete, post, change system settings)." | — |
| `needs_clarification` | noul | "The query is too ambiguous to act on without asking the user a question." | — |
| `wants_memory` | noul | "The user is asking about something they themselves saw, read, wrote or did earlier on this computer." | — |

Decision logic:

```text
decision.intent      = answers.intent.choice
decision.confidence  = answers.intent.confidence
if confidence < NaviSettings.jevConfidenceThreshold (0.55):
    show top local match AND an "Ask Navi" row; do not auto-perform
if is_risky:          mark the primary result; ⏎ shows a confirm chip
if needs_clarification: primary result becomes "Ask Navi: <query>?"
if wants_memory && intent != recallMemory: append memory hits below the primary results
```

Why one call with a *speculative fan-out* instead of a decision tree: every
extra round trip is another ~100 ms of perceived lag, while extra questions on
the same state are nearly free (the state is tokenised once). The
probabilities are also used directly: if `openApp` and `openFile` are within
0.15 of each other Navi shows both buckets rather than trusting the argmax.

Fallback: no key, timeout or HTTP error ⇒ `RouteDecision.heuristic(…)`
(`source = .heuristic`): app-name match ⇒ `openApp`; URL regex ⇒ `openURL`;
math regex ⇒ `calculate`; ends with `?` or starts with wh-word ⇒
`askQuestion`; otherwise `webSearch`. The panel shows a subtle "offline
routing" hint so the user knows why ranking feels dumber.

## Call 2 — Agent step gating (`Navi/Agent/ComputerAgent.swift`)

After every Claude computer-use step, Navi asks Jev about the **textual step
log** — not the screenshot. That keeps the gate at ~100 ms and a few hundred
tokens, so the loop stays snappy.

State:

```text
TASK: open chrome, search for jev and click the first result
STEP: 4 / 40
LAST_ACTIONS:
  3. left_click (412, 96) — Chrome address bar
  4. type "jev" + key Return
NEXT_PLANNED: left_click (233, 310) — first result "TypeSafe AI – Jev"
FRONTMOST_APP: com.google.Chrome
WINDOW_TITLE: jev - Google Search
SCREEN_CHANGED_SINCE_LAST_STEP: yes
```

| Name | Type | Instructions (abridged) | Used for |
|---|---|---|---|
| `is_irreversible` | noul | "NEXT_PLANNED would send a message, make a purchase or payment, delete or overwrite data, publish or post, or change account/security settings." | `askForRisky` mode ⇒ `.needsApproval(id, description, risk)`; `alwaysAsk` asks regardless; `autonomous` ignores. |
| `is_prohibited` | noul | "NEXT_PLANNED enters credentials, card or bank details, or government IDs; executes a financial trade or transfer; or solves a CAPTCHA." | Any mode ⇒ `.failed("Navi won't do this step; please do it yourself")`. |
| `task_complete` | noul | "Given TASK and LAST_ACTIONS, the task is already accomplished." | Stop early with `.completed(summary)` instead of burning steps. |
| `is_stuck` | noul | "The last three actions repeat the same action or the screen has not changed; the agent is not making progress." | Stop with `.failed("stuck")` and offer to retry. |

Thresholds: `is_irreversible ≥ 0.5` and `is_prohibited ≥ 0.35` (deliberately
low — a false positive costs one click, a false negative could cost money).
`task_complete ≥ 0.8`; `is_stuck ≥ 0.7`.

Fallback: if Jev is unavailable the agent runs as if `alwaysAsk` were set
(every step is confirmed) and shows why.

## Call 3 — Memory triage (`Navi/Memory/MemoryService.swift`)

Every captured frame is OCR'd on-device, then triaged by Jev **before**
anything is stored or sent to a vision model.

State:

```text
APP: com.apple.Safari (Safari)
WINDOW_TITLE: Chase — Accounts
URL: https://secure.chase.com/…
TIME: 14:02  Friday
PREVIOUS_CONTEXT: coding — Xcode — Navi/Memory/Digester.swift
OCR_EXCERPT:
  Checking ****1234  Available balance $…
```

| Name | Type | Instructions (abridged) | Criteria / use |
|---|---|---|---|
| `activity` | choice | "What is the user doing in this frame?" | `coding`, `browsing`, `writing`, `chat`, `meeting`, `media`, `other` — stored as the frame's tag and used for daily-note sections. |
| `is_sensitive` | noul | "The frame shows passwords, one-time codes, banking or payment details, medical or legal records, or a private conversation the user would not want recorded." | `≥ 0.5` ⇒ frame dropped entirely; not even OCR text is stored. |
| `is_new_context` | noul | "Compared with PREVIOUS_CONTEXT this frame is a different task, document or topic." | Starts a new "moment" in the store; new-context frames are preferred for the digest. |
| `importance` | score | "How worth remembering is this frame for a personal work journal?" | `["noise", "routine", "useful", "notable", "milestone"]` — `< 1.5` ⇒ text only; `≥ 1.5` ⇒ keep frame for the vision digest; `≥ 3` ⇒ digest even if the interval hasn't elapsed. |

Why triage with Jev instead of sending every frame to a vision model: at
30 s intervals that is ~1 000 frames a day. Sending them all to Gemini
Flash-Lite would cost dollars and leak everything; Jev's triage costs about
1–2k tokens per frame ($0.04–0.08 per *day*) and drops the sensitive ones
before they exist anywhere.

Fallback: without Jev the memory service still OCRs and indexes text locally,
but never sends frames to a digest model (`digestProvider` behaves as
`.localOnly`) and only excluded-bundle-ID filtering applies — the Memory page
shows this state.

## Call 4 — Connection test (`Navi/Settings/ProvidersView.swift`)

```swift
JevClient().ask(state: "ping",
                questions: ["ok": .noul(instructions: "The word 'ping' appears in the state")],
                cacheable: false)
```

Reports round-trip latency and `P(ok)`; a healthy key returns ≈ 0.9+ in
< 300 ms. This is also the smallest possible request, so it is a fair latency
probe.

## Latency budget

| Stage | Target | Notes |
|---|---|---|
| Keystroke → instant rows | < 16 ms (one frame) | pure local; `instantResults` must return in < 5 ms |
| Last keystroke → Jev request sent | 80 ms debounce | cancelled and re-issued on every keystroke |
| Jev round trip (routing) | 70–300 ms typical, 8 s timeout | cache hit ⇒ 0 |
| Re-rank / result swap animation | ≤ 150 ms spring | rows never jump under a pending ⏎: if the user hits ⏎ before Jev answers, the instant top result is performed |
| Agent gate per step | ~100 ms | in series with the Claude call (seconds), so ≈ 2–5 % overhead |
| Memory triage per frame | ~100–200 ms | off the main thread; frames are queued, never dropped for latency |

Everything Jev does is *additive*: the UI is correct without it (heuristics,
confirmations, local-only memory) and better with it.

## Observability

- `Log.jev` (`os.Logger`, subsystem `com.liamcarlin.navi`, category `jev`)
  logs answer count, latency and input tokens at debug level; never the state.
- `RouteDecision.latencyMs` and `.source` (`jev` / `heuristic` / `cache`) are
  shown in the panel's footer in Debug builds.
- Usage → *Jev calls* counts non-cached requests; cost is estimated at
  `calls × ~1 200 tokens × $0.042/MTok`.
- Optional: point `Langfuse` at the same events (YC deal) for traces across
  Jev + Claude — see README.


## Transports

`JevClient` speaks two wire protocols and picks one from `NaviSettings.jevProvider`
(`auto` → TypeSafe if that key exists, else Vercel):

| | TypeSafe direct | Vercel AI Gateway |
|---|---|---|
| URL | `POST https://api.typesafe.ai/v1/systemone` | `POST https://ai-gateway.vercel.sh/v4/ai/evaluation-model` |
| Auth | `Authorization: Bearer $TYPESAFE_API_KEY` | `Authorization: Bearer $AI_GATEWAY_API_KEY` + `ai-gateway-auth-method: api-key` |
| Model | body `model: "jev-latest"` | header `ai-model-id: typesafe-ai/jev` (+ `ai-evaluation-model-specification-version: 4`, `ai-gateway-protocol-version: 0.0.1`) |
| Yes/no | `{"type":"noul"}` → `{"noul": p}` | `{"type":"boolean"}` → `{"type":"boolean","probability": p}` |
| Confidence | per answer | `providerMetadata.typesafe.confidence[name]` if present, else `top − runner-up` probability |

The Vercel shape was lifted from `@ai-sdk/gateway` 4.0.87
(`GatewayEvaluationModel.doEvaluate`) because Vercel's docs only show the AI
SDK. Both parsers are unit-tested in `NaviTests/JevClientTests.swift`.

## Computer use — the Jev-first driver (`Navi/Agent/JevDriver.swift`)

Default driver (`NaviSettings.agentDriver = .jevFirst`). The policy is
browser-use/jev-ultrafast's, ported from the DOM to the macOS Accessibility
tree: *finding the candidates is the work; Jev picks.* Per step:

1. **Observe** — `AXSnapshotter.capture` walks the frontmost app's focused
   window (`kAXFocusedWindowAttribute`, else `kAXWindowsAttribute[0]`),
   hard time-boxed at **150 ms** (depth ≤ 25, ≤ 4 000 nodes, per-app
   messaging timeout 0.2 s) on a serial `AXQueue`. Chrome/Electron apps get
   `AXEnhancedUserInterface` + `AXManualAccessibility` once per run. The menu
   bar is walked only when the task mentions a menu (`AXSnapshot.taskMentionsMenu`).
   Candidates are the actionable roles (buttons, links, fields, pop-ups, menu
   items, cells, tabs, …; images/text/groups only with `AXPress`), deduped on
   (role, label, frame), focused first then reading order, capped at **120**
   (closest to the window / last acted-on element win). Browser URL comes
   from the `AXWebArea`'s `AXURL` — no Apple Events in the loop.
2. **Decide** — one `JevClient.ask` (~220–500 ms measured). Nothing else
   costs more than a few ms.
3. **Execute** — `ActionExecutor`: `AXPress` first, CGEvent click at the
   frame centre as fallback; `AXValue` set-and-verify for fields, else
   select-all + type; pop-ups opened and the matching `AXMenuItem` pressed.
4. **Settle** — poll a 3-call AX fingerprint (focused window title + focused
   element) every 40 ms; return on the first change, cap 250 ms (500 ms after
   Return, 800 ms after OPEN_APP / OPEN_URL). Re-observe → `page_changed`.

No screenshots are taken in this loop. A 400 px thumbnail goes to the panel
every third step when the live overlay is on and Screen Recording is granted;
it is never sent to Jev.

### State (JSON, serialised to the `state` string)

```jsonc
{
  "app": "Safari", "bundle": "com.apple.Safari", "window": "Acme — Home",
  "url": "https://acme.test/", "step": "2 of 40",
  "text": "…first 1500 chars of visible AXStaticText…",
  "elements": [
    { "index": 1, "role": "AXTextField", "label": "Search", "value": "", "focused": true,
      "path": "Toolbar", "operations": ["CLICK", "TYPE_TEXT"] },
    { "index": 3, "role": "AXPopUpButton", "label": "Size", "value": "Medium",
      "options": ["Small", "Medium", "Large"], "operations": ["CLICK", "SELECT"] }
  ],
  "recent_actions": [ { "action": "Click ‘Search’", "kind": "click", "text": null, "page_changed": true } ]
}
```

### Questions (one call)

| Name | Type | Offered when | Criteria |
|---|---|---|---|
| `operation` | choice | always | `CLICK`, `TYPE_TEXT`, `SELECT`, `KEY`, `OPEN_APP`, `OPEN_URL` only when they have ≥ 1 target; `SCROLL_UP`, `SCROLL_DOWN`, `WAIT`, `DONE`, `BLOCKED`, `NEED_VISION` always. Instructions `{goal, rules: NEXT_ACTION}` (jev-ultrafast text, verbatim). |
| `click_target` | choice | any element | `"<index>"` → `{element: "[i] label", current_value, role, checked?, selected?, expanded?, context}` — instructions `{goal, operation, rules: [NEXT_ACTION, TARGET]}` |
| `type_text_target` | choice | editable, non-secure fields | same shape |
| `select_target` | choice | pop-ups with enumerable options | `"<index>:<option>"` |
| `key_target` | choice | always | Return, Escape, Tab, Delete, Space, arrows, ⌘L/T/W/F/A/C/V/Z/S, ⌘⏎, ⌘⇧T, ⌃Tab |
| `open_app_target` / `open_url_target` | choice | task names an app / URL (`TextCandidates`) | `{app}` / `{url}` |
| `task_complete` | noul | always | "The user's goal is already fully accomplished, as evidenced by the current screen" |
| `is_irreversible`, `is_prohibited` | noul | always | `JevGate.questions` wording — gating stays in one place |

Only the head belonging to the chosen operation is read; the others are
speculative and discarded. `JevClient.Question` currently takes string
instructions/criteria, so the structured objects above are sent as compact
JSON strings (see integrator notes in the handoff).

### Decision rules (`JevDriver.decide`)

```text
task_complete > 0.8 or operation == DONE        → .completed(summary from history)
operation head fails validate_choice            → fallback to Claude
   (choice offered, probabilities cover exactly the offered ids, all finite in [0,1],
    Σ ≈ 1 ± 0.02, chosen == argmax — same as jev-ultrafast model.validate_choice)
operation == NEED_VISION                        → fallback to Claude
operation == BLOCKED, or 3 consecutive non-WAIT actions with page_changed == false
                                                → one Claude fallback ("try a different approach"), then .failed
operation confidence < agentJevConfidenceThreshold (0.5) → fallback to Claude
target head for the operation fails validation  → fallback to Claude
TYPE_TEXT: text = the task's single quoted string (zero-latency) else Claude Haiku
   with jev-ultrafast's TEXT_VALUE prompt; {"text": null} / invalid JSON → fallback to Claude
approval: JevGate.decide(is_irreversible, is_prohibited ∨ keyword heuristic, mode, readOnly = WAIT/SCROLL)
   — same rules as the Claude-only driver; a declined action proposed again ends the run
```

**Claude fallback** is one bounded turn of the existing `computer_toolset_20260801`
loop (≤ 3 tool rounds, then a one-line "Did:/Done:/Stopped:" summary that is
appended to Jev's history). Budget: `agentMaxClaudeFallbacks` (6). Needs an
Anthropic key **and** Screen Recording; without them the run continues
Jev-only and fails with a clear message the first time a fallback is needed.
If Jev itself errors mid-run, Claude takes over the remaining steps.

**Task surface**: when `ComputerAgent.browserRunner` is registered, one Jev
choice (`surface`: browser / native_app / unsure over `{task, frontmost_app,
window_title}`) runs first and browser tasks are handed to that runner with a
start URL (first URL in the task, else the current tab).

Events: `.planned("Jev-driven · 34 candidates on screen · walk 41 ms")`,
`.status("Jev · CLICK [7] 91% · 118 ms")` per step, `.status("Handing step to
Claude: …")`, `.completed(summary:)` built from the step log.
