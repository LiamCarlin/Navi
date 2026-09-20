# Navi

**A Jev-powered Spotlight replacement for macOS 26.**

Press ⌘Space. Type `maps` and Apple Maps opens before you finish the word. Type
`why is the sky blue` and an answer streams in. Type `open chrome, search for
jev and click the first result` and Navi does it, pausing only if it is about
to do something irreversible. Type `what was I reading yesterday` and Navi
recalls it from an Obsidian vault it has been quietly writing about your day.

Navi is a native menu-bar app (SwiftUI, Liquid Glass, no third-party
dependencies) that pairs two very different models:

| | Model | Role | Speed |
|---|---|---|---|
| **System One** | Jev (`jev-latest`, TypeSafe AI) | Typed *decisions* with calibrated probabilities: what does this query mean? is this action risky? is this frame worth remembering? | 70–500 ms |
| **System Two** | Claude (`claude-sonnet-5` by default — switchable to Opus 5 / Haiku 4.5 in Settings → Home or the ✦ menu) | Text and action: answers, computer use, digests | seconds |

## Why Jev

Spotlight feels instant because it never thinks. LLM launchers feel slow
because they always think. Jev is the in-between: it answers *structured
questions* about *structured state* and returns a choice, a score, or a
probability — never prose — in about the time a keystroke takes to register.

Every query fans out one Jev call with four questions at once:

```text
intent              choice   openApp | openFile | openURL | webSearch | calculate |
                             askQuestion | computerTask | recallMemory | systemCommand | settings
is_risky            noul     would acting on this be hard to undo?
needs_clarification noul     is the query too ambiguous to act on?
wants_memory        noul     is the user asking about their own past activity?
```

Instant local matches (installed apps, URLs, math) render on the first
keystroke; when Jev answers ~100 ms later the list re-ranks. If Jev's
confidence is below the threshold (default 0.55) Navi shows both the quick
match and "Ask Navi" rather than guessing. The same pattern gates the
computer-use agent after every step (`is_irreversible`, `task_complete`,
`is_stuck`) and triages every screen frame before any vision model sees it
(`activity`, `is_sensitive`, `is_new_context`, `importance`). See
[docs/JEV_INTEGRATION.md](docs/JEV_INTEGRATION.md).

## Features

- **Launcher** — apps, files, URLs, web search, calculator / unit / currency / time-zone math, system commands (sleep, lock, dark mode, Wi-Fi, empty trash).
- **Answers** — Claude streams into the panel; the frontmost app, window title and clipboard are passed as context.
- **Do it for me** — Claude plans the task into single-surface steps (browser tab / one app); Jev drives each step one decision at a time from the Accessibility tree (or the DOM via jev-ultrafast in Chrome), ~200 ms per step; when Jev flails Claude diagnoses once and coaches it, and only takes the wheel if Jev says it needs vision. Jev gates risky steps; you choose *ask always*, *ask for risky only*, or *autonomous*. ⌘Space reopens a running task; the floating pill has Stop/Show.
- **Screen Memory** — every 30 s (configurable) a frame is captured, OCR'd on-device with Vision, triaged by Jev, and — only if important and not sensitive — digested by a cheap vision model into an Obsidian vault of wiki-linked daily notes. Ask "what was I doing yesterday?" from the panel.
- **The Navi app** — a proper macOS window (menu bar ✦ → *Navi App & Settings…*): Home with green/amber/red status cards and one-click fixes, hotkey recorder, API keys in Keychain with per-provider connection tests, permissions with live status, memory controls, agent approval mode, usage and cost estimates.

## Two ways to reach Jev

| Transport | Key | Notes |
|---|---|---|
| **TypeSafe API** (direct) | `TYPESAFE_API_KEY` from [console.typesafe.ai/keys](https://console.typesafe.ai/keys) | Early access (waitlist). Native `noul` questions, per-answer `confidence`. |
| **Vercel AI Gateway** | `AI_GATEWAY_API_KEY` from Vercel → AI Gateway → API Keys | Model `typesafe-ai/jev`, same $0.042/MTok, no waitlist. Yes/no questions are spelled `boolean`; confidence is derived from the probability gap when the gateway doesn't send one. |

Add either key in **AI Providers** (or both — "Auto" prefers TypeSafe). The
Vercel route uses the same HTTP call `@ai-sdk/gateway` makes
(`POST ai-gateway.vercel.sh/v4/ai/evaluation-model`), so no Node runtime is
needed inside the app.

## Setup

### Requirements

- macOS 26 (Tahoe), Apple silicon or Intel
- Xcode 26 with the Swift 6.3 toolchain (the project builds in Swift 5 language mode)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Build & install

```bash
git clone https://github.com/liamcarlin/Navi && cd Navi
scripts/install.sh          # Release build → /Applications/Navi.app, strips quarantine, launches
```

For development:

```bash
scripts/run.sh              # Debug build + relaunch
scripts/test.sh             # Swift Testing unit tests
log stream --predicate 'subsystem == "com.liamcarlin.navi"' --level debug
```

### First launch

Navi opens its window with a five-step onboarding: **Welcome → API keys →
Permissions → Spotlight shortcut → Done**. You can re-run any step later from
the sidebar.

1. **API keys** (Navi → AI Providers). Keys are stored in the macOS Keychain
   under `com.liamcarlin.navi`; environment variables (`TYPESAFE_API_KEY`,
   `ANTHROPIC_API_KEY`, …) override them for development. Each row has a
   *Test* button that reports latency.
   - Jev: <https://console.typesafe.ai/keys>
   - Claude: <https://platform.claude.com>
   - Optional: Gemini (cheapest screen digests), OpenAI, Deepgram (voice), Firecrawl (web).
2. **Permissions** (Navi → Permissions). Each row shows live status, a
   *Request* button and an *Open Settings* deep link.
   - *Accessibility* — the agent clicks and types; window titles for context.
   - *Screen Recording* — the agent sees the screen; Screen Memory captures.
   - *Automation* — reading the current browser tab, AppleScript actions.
   - *Notifications* — "task finished" alerts (optional).

   macOS applies Accessibility and Screen Recording at launch; if a toggle is
   on but Navi still says *Denied*, quit and relaunch.
3. **Spotlight shortcut.** macOS gives ⌘Space to Spotlight. Navi → General
   shows whether there is a conflict and offers *Disable Spotlight's ⌘Space
   for me* (writes `com.apple.symbolichotkeys` key 64 and reloads it) or
   *Open Keyboard Shortcuts…* to do it by hand. A logout is occasionally
   needed. Or record a different hotkey for Navi — ⌥Space works well.
4. Optionally turn on **Launch at login** (General) and **Screen Memory**
   (Screen Memory, or the menu-bar toggle).

## Usage

| Type | Navi does |
|---|---|
| `maps`, `slack`, `open chrome` | opens the app (fuzzy-matched, instant) |
| `github.com`, `https://…` | opens the URL |
| `budget.xlsx`, `that pdf about jev` | finds and opens the file |
| `12% of 340`, `3 usd in eur`, `5pm PST in Tokyo` | inline result, ⏎ copies |
| `best ramen in sf` | web search |
| `what's the capital of peru`, `explain dns like I'm five` | streams a Claude answer |
| `open chrome, search for jev and click the first result` | runs the computer-use agent with a live overlay |
| `what was I working on yesterday afternoon` | searches Screen Memory, shows moments with thumbnails |
| `sleep`, `lock`, `toggle dark mode`, `wifi off`, `empty trash` | system command |
| `navi settings`, `change hotkey` | opens the Navi window |

Keyboard: ↑↓ move, ⏎ perform, ⌘⏎ secondary action (reveal / copy), ⎋ dismiss,
⌘, opens settings. `navi://query?q=…` and `navi://run?q=…` let Shortcuts,
Raycast or a shell script drive Navi.

## Screen Memory and the Obsidian vault

```text
every N s ─▶ ScreenCaptureKit frame ─▶ Vision OCR (on-device)
          ─▶ Jev: activity? sensitive? new context? importance?
               ├─ sensitive or excluded app ─▶ dropped, never stored
               ├─ low importance / same context ─▶ OCR text only (SQLite FTS5)
               └─ important & new ─▶ frame kept for the digest
every M min ─▶ digest kept frames with Gemini Flash-Lite (or Claude Haiku)
          ─▶ ~/Navi Vault/Daily/2026-09-19.md  (+ Projects/, Apps/, People/ wiki-links)
```

The vault is plain Markdown with `[[wiki links]]`, so Obsidian's graph view
shows your week as a network of projects, apps, sites and people. *Open in
Obsidian* uses the `obsidian://` URL scheme; without Obsidian it opens the
folder in Finder. Raw frames are pruned after the retention window
(default 14 days); notes are yours forever.

Exclusions: password managers are excluded by default; add any app or bundle
ID. Frames Jev flags `is_sensitive` (passwords, banking, private messages) are
dropped before storage. *Pause for 1 hour* / *until tomorrow* is one click
away in the window and the menu bar.

## Cost

Jev is priced per million input tokens ($0.042/MTok, output free) and a Navi
routing call is roughly 1–2k tokens: a full day of launching things costs a
fraction of a cent. Claude costs depend on the model you pick for answers and
the agent (Opus 5 $5/$25, Sonnet 5 $2/$10, Haiku 4.5 $1/$5 per MTok in/out).
Screen digests use Gemini Flash-Lite when a key is present, else Haiku. The
**Usage** page keeps a running estimate.

### YC student deals

| Provider | Deal | What Navi uses it for | Status |
|---|---|---|---|
| Anthropic | $500 credits + Tier 4 rate limits | Answers, computer-use agent, fallback digest | **Redeemed on this account** |
| Google Cloud / AI Studio | $2k GCP credits ([deal 4768](https://deals.ycombinator.com/deals/4768)) | Gemini 2.5 Flash-Lite screen digests (cheapest vision) | apply |
| OpenAI | $1k credits | Optional embeddings / alternate models | apply |
| Langfuse | $600 | Tracing every Jev + Claude call, latency dashboards | optional |
| Respan | $3k AI gateway | Caching, routing and spend caps in front of Claude — set `ANTHROPIC_BASE_URL` | optional |
| Browser Use | credits | Cloud browser for long, multi-page web tasks the local agent shouldn't babysit | optional |
| Firecrawl | 10k credits | Clean page text when answering from a URL | optional |
| Deepgram | $15k | Streaming speech-to-text for voice queries | optional |

All deals: <https://deals.ycombinator.com/deals?audience=students>. Jev early
access: <https://console.typesafe.ai/keys>.

## Privacy

- API keys live in the Keychain, never in UserDefaults or on disk in plain text.
- Screen frames, OCR text and the SQLite index live in
  `~/Library/Application Support/Navi`; the vault is wherever you point it.
- Only frames Jev marks *important* leave the machine, and only to the digest
  model you chose. OCR is on-device (Vision).
- Nothing is logged at info level that contains keys or OCR text.
- Navi is ad-hoc signed and not sandboxed (Accessibility, ScreenCaptureKit and
  Apple Events require it). Build it yourself; read the source.

## Troubleshooting

| Symptom | Fix |
|---|---|
| ⌘Space still opens Spotlight | General → *Disable Spotlight's ⌘Space for me*, then log out and back in; or record a different hotkey. |
| Hotkey does nothing at all | Another app owns the combo (Raycast, Alfred). Change one of them. `RegisterEventHotKey` errors appear in the log. |
| Permissions show *Denied* after enabling | Quit and relaunch Navi; macOS grants Accessibility / Screen Recording per launch. Rebuilding changes the ad-hoc signature, which can reset grants — re-tick the checkbox. |
| *Automation* shows *Unknown* | System Events isn't running; click *Request* to run a probe script. |
| "Missing API key" | AI Providers → paste → *Save* → *Test*. If an env var is set it overrides the Keychain. |
| Answers are slow / agent stalls | Check Usage for rate limits; switch the answer model to Sonnet 5; Opus 5 uses adaptive thinking. |
| Screen Memory shows *Stopped* | Needs Screen Recording; check the *last error* line on the Memory page. |
| Launch at login unavailable | `SMAppService` needs the app in `/Applications` — run `scripts/install.sh`. |
| Dock icon lingers | It shows only while the Navi window is open and hides on close; if not, quit from the menu bar. |
| Logs | `log stream --predicate 'subsystem == "com.liamcarlin.navi"' --level debug` |

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the module map, data
flow, threading model and permissions, and
[docs/JEV_INTEGRATION.md](docs/JEV_INTEGRATION.md) for every Jev call, its
schema and latency budget. Development conventions are in `CLAUDE.md`.
