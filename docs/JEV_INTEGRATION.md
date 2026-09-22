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

## Call 4 — Voice segmentation (`Navi/Voice/VoiceDecider.swift`)

Live voice control never waits for the user to stop talking: the on-device
recognizer streams words, `UtteranceSegmenter` proposes a clause (the words
after the cursor up to the first "and" / "then" / punctuation), and Jev
answers, per candidate, *is this a complete instruction, and what kind?* —
re-asked as words arrive (150 ms debounce), ~160–250 ms warm.

State (JSON):

```jsonc
{
  "mode": "Live voice control. The user talks continuously; Navi carries out each instruction the moment it is complete…",
  "transcript": { "HEAD": "open the notes app", "CONNECTOR": "and", "FOLLOWING": "make hello the title",
                  "silence_ms_since_last_word": 106, "recent_instructions_already_carried_out": [] },
  "screen": { "frontmost_app": "Google Chrome", "window_title": "…", "browser_url": "https://…" },
  "navi": { "queued_instructions": 0, "listening_paused": false, "busy_with": "Opening Notes", "awaiting_user_approval_for": null },
  "installed_apps_possibly_named_in_HEAD": [ { "id": "a1", "app": "Notes" } ]
}
```

| Name | Type | Criteria / use |
|---|---|---|
| `boundary` | choice | `complete` (act now; FOLLOWING starts something else), `continues` (FOLLOWING or words to come belong to HEAD), `not_a_command` (chatter). The only head that gates acting. |
| `kind` | choice | `open_app`, `do_in_app`, `browse_or_search`, `answer`, `system_setting`, `control_navi`, `none` → `VoiceCommand`. |
| `control` | choice | `stop`, `undo`, `confirm`, `deny`, `cancel_everything`, `stop_listening`, `pause`, `resume`, `none` — read only for `control_navi`; "yes"/"no" answer a pending approval. |
| `app_target` | choice | `a1…a5` from `VoiceAppMatcher` (fuzzy windows of the clause against `AppIndex`) + `none` → direct launch, no text model. |
| `surface`, `start_from` | choice | `TaskSurface` criteria (browser / native_app / unsure; current_tab / web_search) → passed to `ComputerAgent.run(options:)` so the run skips both the planner and the surface call. |
| `is_risky`, `continues_previous`, `wants_memory` | noul | shield in the island; "In Notes: …" prefix for follow-ups when that app isn't in front; memory hits for answers. |

Decision rules (`VoiceDecider.decide`, unit-tested):

```text
not_a_command ≥ 0.6 and (words follow or silence ≥ 1.5 s)   → drop
complete ≥ 0.5:
   words follow the connector, or the connector is . ? !     → commit now
   bare connector ("open notes and")                        → wait ≤ 450 ms for a word
   no boundary at all                                       → wait for 650 ms of real silence (400 ms if confidence ≥ 0.8)
continues (or complete < 0.5):
   words follow                                             → merge: that connector never splits again ("cats and dogs")
   sentence mark + 700 ms silence                           → commit
   1.6 s silence and complete ≥ 0.3, or 3.2 s and ≥ 0.12    → commit (the user trailed off)
no Jev                                                      → connectors + a 1.6 s pause decide; everything is a task
```

"Silence" is acoustic (microphone level above a running noise floor), not
time since the last word: the recognizer reports in ~1 s windows, so the
session also asks it to `finalize` after ~350 ms of real silence to get the
tail of a sentence immediately. Measured 2026-09-20 with recorded clips:
words arrive 50–300 ms after their 1 s window closes; a clause commits
~350 ms after its last word arrives when a connector follows it.

## Call 5 — Connection test (`Navi/Settings/ProvidersView.swift`)

```swift
JevClient().ask(state: "ping",
                questions: ["ok": .noul(instructions: "The word 'ping' appears in the state")],
                cacheable: false)
```

Reports round-trip latency and `P(ok)`; a healthy key returns ≈ 0.9+ in
< 300 ms. This is also the smallest possible request, so it is a fair latency
probe.

## Latency budget

Measured 2026-09-20 from Boston to TypeSafe (us-west-2): a Jev call is
**150–230 ms on a warm connection, 400–650 ms cold** (TCP+TLS ≈ 250 ms);
payload size barely matters (10 vs 120 elements: 180 → 230 ms). So Navi
keeps connections warm rather than shrinking state: `JevClient.warm()` /
`ClaudeClient.warm()` (free `GET /v1/models`) when ⌘Space opens, and the
browser runner warms TLS on a thread while Chrome navigates. It also starts
observing at `readyState == "interactive"` (identical DOM snapshot 0.9–1.3 s
before `"complete"` on Google pages).


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

### Any browser (`Agent/NativeBrowser.swift`)

Web steps have two drivers and the browser the user is looking at picks one:

- **Chromium + the jev-ultrafast runtime installed** → the CDP runner
  (`UltrafastBridge`): DOM element table, background tab. Fastest and richest,
  but it needs `uv`, the Python venv and Chrome's remote debugging switched on.
- **Anything else** — Safari, Arc, Firefox, Edge, Brave, Orion, or a fresh
  install with no runtime — → the same Jev-first loop on the browser's
  **accessibility tree**. The page is opened in that browser
  (`NativeBrowser.open`), the step is pinned to it like any app, and
  `AXSnapshotter` walks the `AXWebArea` (Chromium/Electron get
  `AXEnhancedUserInterface`). `AXSnapshot.tidyBrowserChrome` drops the
  browser's own controls Jev must never see (window buttons, tab-close ×,
  extension pop-ups, promos), keeps Back / Reload / address bar / tabs marked
  `Browser UI`, and the web skill for the page URL rides in `state.playbook`.
  A runner that cannot connect (`NativeBrowser.isRunnerUnavailable`) falls
  back to this path mid-run instead of failing.

Browser-level instructions — *close the tab, go back, reload, next tab,
scroll down, zoom in, address bar* — never reach either driver:
`BrowserControls.match` recognises them locally and presses the shortcut in
the browser (`VoiceCommand.browser`). They used to reach the page driver,
which correctly found no element, answered BLOCKED and paid for a Claude
diagnosis to say so.

Page actions ("click …", "type …", "scroll …", "select …") spoken with a
browser in front stay on the **current tab** (`TaskSurface.isPageAction`,
`VoiceCommandExecutor.continuesOnCurrentTab`) even when Jev's `start_from`
head said *web search* for a fragment — Googling the sentence once produced a
results page explaining that Google cannot click things.

### Background mode (`NaviSettings.agentRunInBackground`, default on)

The user asked for a task and went back to work; the loop above must not
touch what they are doing. Per native step `AgentRun.pinTarget` picks an
`AgentTarget` — the app the step just opened (launched with
`activates = false`), else the app that was frontmost when Navi was invoked
(`QueryContext.frontmostApp`) — and from then on:

- **Observe**: `AXSnapshotter.capture(target:)` walks that pid (focused →
  main → first window) instead of `NSWorkspace.frontmostApplication`;
  `fingerprint(target:)`/`settle` likewise. The menu bar is never walked
  (opening a background app's menu would activate it).
- **Execute**: `ActionExecutor.target` puts `InputController` on the
  `.process(pid, window)` route — `CGEvent.postToPid` with
  `kCGMouseEventWindowUnderMousePointer` set to the window from
  `AgentTarget.matchWindow` (AX frame ↔ `CGWindowList` bounds), so clicks
  reach a covered window and the real cursor never moves. `AXPress` /
  `AXValue` / `AXSelectedTextRange` do most of the work anyway; `activate()`
  is a no-op.
- **See** (Claude fallback / thumbnails): `ScreenCapture.captureWindow` —
  `SCContentFilter(desktopIndependentWindow:)`, works when occluded or on
  another Space; the window frame becomes the `ScreenMap` bounds so
  coordinates still land on screen points.
- **Browser steps**: `UltrafastBridge.run(background: true)` skips
  `bringBrowserForward()` and sets `NAVI_BACKGROUND_TAB`, so the runner's tab
  is never `Target.activateTarget`ed. CDP input and DOM reads don't need a
  visible tab.

Measured on macOS 26 (TextEdit behind Chrome): typing, clicks and
navigation combos (⌘→, ⇧←) all land; **menu key equivalents (⌘A, ⌘S, ⌘L…) are
silently dropped** — AppKit resolves nil-target actions through the key/main
window, which an inactive app has neither of (setting `AXMain` or `AXPress`ing
the menu item doesn't help either). `KeyCombo.isMenuEquivalent` combos
therefore go through `InputController.pressWithBriefActivation`: activate the
target, post the key, hand activation back to the previous app (~300 ms, the
only moment the mode touches focus). Text replacement uses AX selection
instead of ⌘A so it needs no flash. Known gaps: controls that dispatch
through the responder chain (some toolbar items) can look pressed and do
nothing — the no-change tracker then escalates as usual.

Verified end-to-end 2026-09-20: "open TextEdit and type …" (1 step, 3 s) and
"open Calculator and compute 12 times 34" (6 AXPress clicks, 6.4 s) with
MATLAB/Chrome frontmost throughout; the target app never came forward.

Rows, cells, tabs, menu items and radio buttons also carry `selected` (their
`AXSelected`), so "which sidebar list is current" is visible — a Reminders
recipe can say "click the named list first, then ⌘N" and Jev can tell.

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
  "recent_actions": [ { "action": "Click ‘Search’", "kind": "click", "text": null, "page_changed": true } ],
  "playbook": { "app": "Messages", "how_it_works": ["…"], "shortcuts": {"cmd+n": "New message (To: field focused)"},
                "recipes": [{"goal": "send a message / text to a person", "steps": ["KEY cmd+n", "TYPE_TEXT the name into ‘To:’", "…"]}],
                "done_when": ["…"], "avoid": ["Do not click an existing conversation to message a DIFFERENT person — use ⌘N."] },
  "experience": ["text Sam the address → Press ⌘N · Type ‘…’ into ‘To:’ · Press Return · Type ‘…’ into ‘iMessage’ · Press Return"],
  "progress": { "actions_taken": 0 }
}
```

### Playbooks and experience — what Jev is told about the app

Jev decides from labels and roles and knows nothing about the app it is in.
From the run logs that meant: seven clicks to make a Notes note that ⌘N
creates, `DONE 95 %` on a Calculator showing 0, and a text to *David* typed
into *Mikey's* open conversation. TypeSafe's own guidance is the fix — "do
not rely on knowledge stored in model weights when current information can
come from your own knowledge base" and "the model cannot choose an omitted
value" — so two knowledge sources ride in every request:

- **`AppSkills`** (`Navi/Agent/AppSkills.swift`, data in `AppSkillLibrary.swift`):
  a hand-written playbook per app — 60+ native (Messages, Mail, Outlook,
  FaceTime, Slack, Discord, WhatsApp, Telegram, Signal, Teams, Zoom, Notes,
  Reminders, Things, Todoist, Stickies, TextEdit, Obsidian, Bear, Notion,
  Freeform, Pages/Numbers/Keynote, Word/Excel/PowerPoint, Calendar, Contacts,
  Clock, Weather, Finder, System Settings, Terminal, Activity Monitor, App
  Store, QuickTime, Shortcuts, Voice Memos, Home, Translate, Dictionary, Find
  My, Photo Booth, Preview, Spotify, Music, Podcasts, TV, Books, Photos, Maps,
  News, Stocks, Safari, Chrome, Arc, Firefox, Calculator, Xcode, VS Code, Zed,
  GitHub Desktop, Figma) and 55+ web apps by host, optionally with a path
  (Google Search/Docs/Sheets/Slides/Forms/Drive/Gmail/Calendar/Maps/Flights/
  Keep/Photos/Translate/Meet/Classroom, Canvas, Gradescope, Piazza, Wikipedia,
  Stack Overflow, YouTube, Netflix, Spotify web, Twitch, TikTok, Instagram,
  Facebook, X, Reddit, LinkedIn, ChatGPT, Claude, Perplexity, Gemini, Amazon,
  shopping sites, food delivery, travel booking, Uber, reservations, tickets,
  Zillow, IMDb, GitHub, Linear, Jira, Trello, Asana, Notion, Slack/Discord/
  WhatsApp/Telegram/Teams web, Outlook web, Dropbox, Zoom web, Figma web).
  Each carries `how_it_works`, `shortcuts` (what ⌘N does *here*), `recipes`
  (goal keywords in the words people *say* → steps in Jev's operation
  vocabulary), `done_when`, `avoid` (shopping/booking skills: never pay or
  book unless asked), `field_hints` (for the Haiku text helper), `deep_links`
  (for the planner and the spoken start URL), `aliases` (spoken names) and
  `triggers` / `weak_triggers` (which app a task implies). `AppSkills.playbook(for:goal:)`
  keeps only the recipes whose keywords match the goal (≤ 3) so the state
  stays small; the skill's shortcuts are *added to the KEY head* (Outlook's ⌘2
  cannot be chosen unless offered) and re-describe the generic combos. The
  skill is re-resolved every step from the snapshot's bundle id / URL. The
  browser runner gets the web skills as `NAVI_PLAYBOOKS_JSON` (~50 KB) and
  injects the one matching the page host through the same `post_json`
  wrapper the coach uses.

**Voice: which app does a spoken task mean?** A spoken task usually names no
app ("text mom I'm running late") and voice mode skips the Claude planner, so
the step used to run in whatever was in front. `AppSkills.inferApp` ranks the
native skills by their `triggers` (nouns: "text" → Messages, "grocery list" →
Reminders, "timer" → Clock, "jazz" → a music app) and `weak_triggers` (verbs
such as "play", which do not count when the frontmost app's own skill claims
them — "play the video" in Chrome opens nothing); a skill the task names
(`mentioned`, by name or alias, common words only after an opener: "in
music", "open notes") wins outright. Ties (Music / Spotify, Mail / Outlook,
Calendar / Outlook) go to the running app, then Apple's own app.
`resolvePlanWithoutPlanner` opens and pins that app; the two best-implied
apps are also offered as `OPEN_APP` candidates mid-run, and a Jev `OPEN_APP`
in background mode re-pins the target (the Claude path already did). For
browser tasks `AppSkills.startURL` turns "play lofi beats on youtube" into the
YouTube results page for "lofi beats" and "google drive shared with me" into
that deep link, before the search-engine fallback.
- **`AgentExperience`** (`Navi/Agent/AgentExperience.swift`): Agent S–style
  episodic memory. A completed step stores `(bundle id, goal, action labels)`
  — labels only, never typed text — in
  `~/Library/Application Support/Navi/agent-experience.json`; a later goal in
  the same app that shares ≥ 2 content words gets up to three "goal → actions"
  lines as `state.experience`.

Measured on the failing screens (live Jev, same request shape): Messages
with Mikey's chat open went from `CLICK Compose 42–56 %` to `KEY ⌘N 99 %`;
Notes "create a new note" from clicking around to `KEY ⌘N`; Calculator's
first-digit target confidence 77 % → 94 % with `task_complete` 0.08 → 0.03.
Latency unchanged (~400–460 ms).

**Premature DONE**: a first-step `DONE` / `task_complete` on a goal that asks
for an effect (`!AgentRun.isLookup`), before any action, is not final unless
≥ 95 % sure: the screen is re-observed once and Jev asked again with
`progress.note`; the second answer stands (`Decision.prematureDone`).

### Questions (one call)

| Name | Type | Offered when | Criteria |
|---|---|---|---|
| `operation` | choice | always | `CLICK`, `TYPE_TEXT`, `SELECT`, `KEY`, `OPEN_APP`, `OPEN_URL` only when they have ≥ 1 target; `SCROLL_UP`, `SCROLL_DOWN`, `WAIT`, `DONE`, `BLOCKED`, `NEED_VISION` always. Instructions `{goal, rules: NEXT_ACTION}` (jev-ultrafast text, verbatim). |
| `click_target` | choice | any element | `"<index>"` → `{element: "[i] label", current_value, role, checked?, selected?, expanded?, context}` — instructions `{goal, operation, rules: [NEXT_ACTION, TARGET]}` |
| `type_text_target` | choice | editable, non-secure fields | same shape |
| `select_target` | choice | pop-ups with enumerable options | `"<index>:<option>"` |
| `key_target` | choice | always | Return, Escape, Tab, Delete, Space, arrows, ⌘L/T/W/F/A/C/V/Z/S, ⌘⏎, ⌘⇧T, ⌃Tab — plus the app skill's own shortcuts (`AppSkills.keyCombos`), generic ones re-described for the app |
| `open_app_target` / `open_url_target` | choice | task names an app / URL (`TextCandidates`) | `{app}` / `{url}` |
| `task_complete` | noul | always | "The user's goal is already fully accomplished, as evidenced by the current screen" (+ "judged against `playbook.done_when`" when a skill applies) |
| `is_irreversible`, `is_prohibited` | noul | always | `JevGate.questions` wording — gating stays in one place |

Only the head belonging to the chosen operation is read; the others are
speculative and discarded. `JevClient.Question` currently takes string
instructions/criteria, so the structured objects above are sent as compact
JSON strings (see integrator notes in the handoff).

### Decision rules (`JevDriver.decide`)

```text
task_complete > 0.8 or operation == DONE        → .completed(summary from history)
   … unless nothing has been done yet on an effect goal and confidence < 0.95
                                                → .prematureDone: re-observe, ask once more
operation head fails validate_choice            → fallback to Claude
   (choice offered and == argmax, all finite in [0,1]; ids the API omitted count as 0,
    unoffered keys are ignored, Σ may drift by rounding — looser than jev-ultrafast's
    validate_choice on purpose: a 24 % ⌘N once failed on a missing key and cost 10 s of vision)
operation == NEED_VISION                        → fallback to Claude
operation == BLOCKED, 3 consecutive non-WAIT actions with page_changed == false,
   or FailureTracker ≥ 3 (no change / same element again / action error)
                                                → Claude COACHES once (see below), then .failed
operation confidence < agentJevConfidenceThreshold (0.5):
   task_complete ≥ 0.5 and something was done  → .completed (nothing sure left to do = done)
   confidence ≥ actFloor (0.22) and the action is cheap to undo
      (CLICK / TYPE_TEXT / SELECT / SCROLL / WAIT / OPEN_*, KEY ∈ tentativeKeys —
       never ⌘W, ⌘↩, Delete, ⌘S)                → .actTentatively: taken as a hunch; the
                                                  FailureTracker → coach catches a wrong one
   otherwise                                    → fallback to Claude
target head for the operation fails validation  → fallback to Claude
TYPE_TEXT: text = the task's single quoted string (zero-latency) else Claude Haiku
   with jev-ultrafast's TEXT_VALUE prompt; {"text": null} / invalid JSON →
   FieldText.localGuess (what the goal spells out: "tell her I'm late", "look up X" into a
   search field) → only then fallback to Claude
state.progress carries last_action / last_typed / last_action_submitted so task_complete
   can see that the Return after the typed message was the end of the goal
approval: JevGate.decide(is_irreversible, is_prohibited ∨ keyword heuristic, mode, readOnly = WAIT/SCROLL)
   — same rules as the Claude-only driver; a declined action proposed again ends the run
```

**Claude fallback** is one bounded turn of the existing `computer_toolset_20260801`
loop (≤ 3 tool rounds, then a one-line "Did:/Done:/Stopped:" summary that is
appended to Jev's history). Budget: `agentMaxClaudeFallbacks` (6; voice runs
cap it at 2 — the user is watching and can say the next thing). Needs an
Anthropic key **and** Screen Recording; without them the run continues
Jev-only and fails with a clear message the first time a fallback is needed.
If Jev itself errors mid-run, Claude takes over the remaining steps.

**Coaching** (`JevCoach`, once per step): Jev does not hand the wheel to
Claude when it flails — Claude diagnoses. It gets the goal, a screenshot, the
element table Jev sees (with indexes) and the recent actions with their
effects, and returns `{diagnosis, guidance, next_operation?, next_target?}`.
The guidance is added to Jev's `state.guidance` and to every question's
`instructions.guidance` for the rest of the step; a suggested next action is
validated against the offered targets (`JevDriver.coachAction`) before it is
taken. A second failure streak after coaching ends the step with the
diagnosis. The browser runner applies the same policy (guidance injected
into every Jev request through a `post_json` wrapper).

**Speculative text**: while Jev decides, `FieldText.obviousField` (the
focused empty text field, else the only empty one) already has Haiku writing
its value in parallel; the value is used only if Jev picks that very field.
The browser runner does the same, keyed by the exact `field_context`.

**Planning** (`TaskPlanner`, one Haiku call, prefetched while the user
types via `ComputerAgentRunning.prepare`): the task is split into the fewest
single-surface steps — a browser tab or one app — each with a self-contained
goal, a clean search query / URL for browser steps, and `{{result}}` hand-off
(Haiku distils the final page/screen text of a `needs_result` step into the
next goal). The planner's state carries `reference` (`AppSkills.plannerReference`:
known app names and web deep links) so a Drive step starts on
`/drive/shared-with-me` instead of an invented URL. Browser steps go to
`ComputerAgent.browserRunner` (Chrome brought forward, tab activated); app
steps activate the app, then run this driver.

**What the browser runner now sees and survives** (`scripts/ultrafast/navi_runner.py`,
adaptations 13–17): Google Drive's file cards (`role=gridcell` holding a
"More actions" button) and list/inbox rows (`role=row`) were never in the
element table — Jev saw a results page with nothing on it — and are now
offered as items with an "Open (double-click): …" action; the Google Docs
page body (a canvas editor with a hidden iframe) is offered as a textbox
that is filled by clicking the page, ⌘↓, insert (never select-all); a text
helper answering `{"text": null}` is a failed step that hides that field
from TYPE_TEXT instead of ending the run; and the start page / a fresh
navigation gets one extra look 300 ms later so a shell that is still filling
in (Drive's sidebar before its grid) is not called BLOCKED. `decision`
events carry the element table Jev chose from, so
`ultrafast-last-run.jsonl` explains a wrong pick without a re-run.

**The window is the deliverable.** The browser runner used to close its tab
on exit — "make a Google Doc" ended with the doc closing. Now
`NAVI_TAB_POLICY` (`UltrafastBridge.tabPolicy`) keeps the tab whenever
anything happened on it; in background mode a completed *effect* task
(`!AgentRun.isLookup`) gets `reveal` (tab fronted, Chrome activated) and a
completed lookup gets `close` (its answer is in the panel). Failures always
keep the tab so the user can take over. Native steps do the same:
`AgentTarget.reveal()` brings the app forward after a completed effect task
(`NaviSettings.agentRevealWhenDone`, default on).
Without an Anthropic key one Jev choice (`TaskSurface`: browser / native_app
/ unsure) picks the surface instead.

Events: `.planned("Jev-driven · 34 candidates on screen · walk 41 ms")`,
`.status("Jev · CLICK [7] 91% · 118 ms")` per step, `.status("Handing step to
Claude: …")`, `.completed(summary:)` built from the step log.
