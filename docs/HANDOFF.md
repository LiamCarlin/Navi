# Overnight build handoff — 2026-09-19

Everything below is on `main` (15 commits), builds clean with Xcode 26.6, and
passes 124 unit tests. A Release build is installed at `/Applications/Navi.app`.

## What you need to do (10 minutes)

1. **Launch** `/Applications/Navi.app`. It lives in the menu bar (✦). The window
   opens with a 5-step setup.
2. **Keys → AI Providers.** Paste and hit *Test* for each:
   - Jev, either of:
     - TypeSafe direct: https://console.typesafe.ai/keys (early access), or
     - **Vercel AI Gateway**: Vercel dashboard → AI Gateway → API Keys
       (model `typesafe-ai/jev`, no waitlist). Paste into "Jev via Vercel AI
       Gateway" and hit Test.
     Until one exists Navi routes with local heuristics — the pill says
     "local" instead of "Jev · 92%".
   - Claude: https://platform.claude.com (your YC $500 credit is already
     redeemed on this account).
   - Gemini (optional, cheapest screen digest): https://aistudio.google.com/apikey
3. **Permissions** (Settings → Permissions, each has a button): Accessibility,
   Screen Recording, Automation. Quit & relaunch Navi once after granting.
4. **Free up ⌘Space.** Spotlight still owns it on this Mac (I did not change
   system settings). Settings → General → *Disable Spotlight's ⌘Space for me*
   (may need a logout) — or record ⌥Space instead.
5. Optional: General → Launch at login. Screen Memory → toggle on, pick the
   vault folder (default `~/Navi Vault`), open it in Obsidian → Graph view.

## What was verified live (no API keys on this machine)

- Panel opens, types, routes, performs: `maps` → Maps launches; `12*34 + 1` →
  409 copied; `dark mode` → system command; `open chrome and search for jev
  then click the first result` → "Do it: …" agent row with approval-mode
  subtitle; questions → "Ask Navi" row (explains the missing key gracefully).
- Settings window: all 8 sections + onboarding render; Dock icon shows only
  while the window is open; closing it leaves the ⌘Space agent running.
- Memory service starts/stops from the menu, refuses to capture when the screen
  is locked, and reports permission problems in `status.lastError`.

## What is NOT yet verified (needs your keys)

- A real Jev round-trip (request/response shape is built from the docs at
  docs.typesafe.ai and unit-tested against the documented sample).
- A real Claude computer-use run (`computer_toolset_20260801`). If the API
  rejects `strict: true` on the custom tools, drop that key in
  `Navi/Agent/AgentTools.swift` (`AgentCustomTools.tool`).
- Screenshots of the Liquid Glass panel over a real wallpaper in dark mode.
  The `#Preview`s in `Navi/Panel/Views/PanelPreviews.swift` cover every state.

## Cost posture

- Jev: $0.042 / MTok input, output free → routing is ~100–300 tokens per
  keystroke-debounce; memory triage ~1k tokens per stored frame (~50–75k/hour
  of active use ≈ $0.003/hour).
- Digest: Gemini 2.5 Flash-Lite if a key exists, else Claude Haiku 4.5, else
  local-only (no LLM). ~20–30k input tokens/hour.
- Answers/agent: Claude Opus 5 by default (change to Sonnet 5 in AI Providers
  to cut cost 2.5×). Usage counters + $ estimate live in Settings → Usage.
- YC deals worth redeeming next: Google ($2k GCP/Gemini, deal 4768), OpenAI
  ($1k), Respan ($3k gateway — set `ANTHROPIC_BASE_URL`), Langfuse ($600).

## Ideas queued (not built)

- Voice input via Deepgram ($15k YC credit) — `Keychain.Key.deepgram` exists.
- Web answers via Firecrawl (10k credits) for `webSearch` intent.
- Browser tasks via Browser Use instead of raw computer use for Chrome-only work.
- Clipboard history, snippets, window switcher rows.
