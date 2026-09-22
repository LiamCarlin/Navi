# Navi launch roadmap — from working prototype to a paid product

_Written 2026-09-22. Owner: Liam. This is the plan the launch agents execute against;
each workstream below names its branch, the files it owns, and what "done" means._

## 1. Where Navi is today, and what actually blocks a paid launch

Navi works end to end on this Mac: ⌘Space panel, Jev routing, streaming answers,
Jev-first computer-use agent with 115+ app playbooks, screen memory → Obsidian vault,
live voice control. What stands between that and something a stranger can pay for:

| # | Blocker | Why it matters | Fix |
|---|---|---|---|
| B1 | **Bring-your-own-key.** Every call goes straight to TypeSafe / Anthropic / Gemini with keys the user pastes into Settings → AI Providers. | A paying customer gets one price, no keys. There is also no way to meter, cap, or cut off usage. | **Navi Cloud**: a small backend that owns the vendor keys, authenticates the app with a Navi account, meters every call, enforces the tier. The app's `JevClient` / `ClaudeClient` / `GeminiClient` get a second transport that points at it. (Workstreams C + D) |
| B2 | **Browser tasks run from the repo checkout.** `UltrafastBridge` looks for `vendor/jev-ultrafast/.venv/bin/python`, installed by `uv` via `scripts/ultrafast/setup.sh`. | `/Applications/Navi.app` on someone else's Mac has no repo, no uv, no Python. Browser tasks silently fail. | Bundle a relocatable Python + the venv inside `Navi.app/Contents/Resources/browser-runtime`; `UltrafastBridge` prefers the bundle, falls back to the repo for dev. (Workstream E) |
| B3 | **Dev signing.** `project.yml` signs with "Apple Development", ad-hoc install via `scripts/install.sh`. | Gatekeeper blocks it on any other Mac. No updater. | Developer ID Application + notarization + DMG + a minimal in-app updater (no Sparkle — dependency-free rule). (Workstream E) |
| B4 | **Vendor names everywhere.** "Answer with Claude", "Jev is deciding…", `Navi · claude-opus-5 · streaming`, Jev confidence pill with % and ms, About/Usage/Agent/Voice/Browser settings all talk about Jev, Claude, TypeSafe, Anthropic, model IDs, token prices. | Product must read as *Navi*. Users don't know or care what a Jev is. | Full wording pass: everything user-facing says Navi. Technical detail moves behind a hidden Developer section. (Workstream B) |
| B5 | **Result rows show paths.** App rows: `Running · /Applications`; file rows: `~/Documents/foo · 2 days ago`. | Noise. Spotlight shows the name only. | Subtitle = kind (App, Folder, PDF…) + at most "Running"; never a path. (Workstream B) |
| B6 | **Recall isn't gated.** Screen memory is a toggle in Settings. | It's the upsell tier. | Entitlement check in `MemoryService` + Router memory intent + Settings → Memory shows "Unlock Recall". (Workstream D) |

## 2. The product at launch

**One app, one login, one subscription.** No API keys, no model pickers, no provider pages.

| Tier | Price (default — Liam to confirm) | Includes | Enforced by |
|---|---|---|---|
| **Free** | $0, no card | Launch apps, files, calculator, system commands, clipboard — everything local. 20 answers/day, 5 tasks/day so people feel it. | Cloud meter, per-day counters |
| **Pro** | $20/mo or $192/yr | Unlimited answers (fair use), 300 agent tasks/mo, voice control, priority routing. | Cloud meter, per-month counters |
| **Pro + Recall** | $30/mo or $288/yr | Everything in Pro plus screen memory: capture, local OCR, digest, Obsidian vault, "what was I doing yesterday". | `recall` entitlement flag; digest/triage calls metered under it |

7-day Pro trial on sign-up, card required at trial end (Stripe handles the dunning).
Hard caps return a typed `NaviError.quotaExceeded(tier, resetsAt)` that the panel renders
as one clear line with an "Upgrade" button — never a stack trace.

Costs sanity check (from `UsageView` rates): Jev ≈ $0.042 / 1M in; Opus $5/$25;
Haiku $1/$5. A heavy Pro user doing 300 tasks/mo at ~40 Jev calls + ~2 Haiku calls a
task is well under $2/mo; answers on Opus are the cost driver — cap output at ~600
tokens for spoken/short answers and route long ones to Sonnet.

## 3. Launch architecture

```
Navi.app ──(Bearer <navi session>)──▶ api.navi.app  (Next.js on Vercel)
   │                                     ├─ /v1/jev       → api.typesafe.ai (server key), metered
   │                                     ├─ /v1/claude    → api.anthropic.com (server key), metered, SSE passthrough
   │                                     ├─ /v1/digest    → Gemini or Haiku, requires `recall`
   │                                     ├─ /v1/me        → tier, entitlements, quotas, resetsAt
   │                                     ├─ /auth/*       → Supabase Auth (magic link + Google), navi:// callback
   │                                     └─ /billing/*    → Stripe Checkout, Portal, webhooks → entitlements
   └─ navi://auth/callback?code=…  (app already owns the navi:// scheme)

navi.app  (Next.js on Vercel) — marketing site, waitlist (Supabase table), pricing, download
```

Stack (chosen for zero-ops and because the Vercel AI Gateway path already exists):
**Next.js App Router on Vercel · Supabase (Auth + Postgres) · Stripe Billing.**
Two separate apps in the repo, `web/` and `cloud/`, so they can be built in parallel and
deployed independently. Vendor keys live only in Vercel env vars.

### 3.1 Cloud API contract v1 (both the backend and the Swift client build to this)

Auth: `Authorization: Bearer <access_token>` (Supabase JWT, 1 h) + refresh token in Keychain
(`Keychain.Key.naviRefresh`). 401 → refresh once → sign-in sheet.

```
GET  /v1/me
  200 { user:{id,email}, tier:"free"|"pro"|"pro_recall", trialEndsAt?,
        entitlements:{answers:bool, tasks:bool, voice:bool, recall:bool},
        quotas:{answersPerDay?, tasksPerDay?, tasksPerMonth?},
        usage:{answersToday, tasksToday, tasksThisMonth, resetsAt} }

POST /v1/jev            body = exact TypeSafe /v1/systemone body     → passthrough JSON
POST /v1/claude         body = exact Anthropic /v1/messages body     → passthrough (SSE when stream:true)
POST /v1/digest         body = { model?, ...anthropic-or-gemini body } → passthrough; 403 without `recall`
  Headers the app adds:  X-Navi-Feature: route|answer|task|voice|recall_triage|recall_digest
                          X-Navi-Run: <uuid per task/answer>   (usage is counted once per run, not per call)
  Errors: 401 unauthenticated · 402 {error:"quota_exceeded", feature, tier, resetsAt}
          403 {error:"not_entitled", feature, tier} · 429 rate-limited (per-IP + per-user) · 5xx

GET  /auth/start?redirect=navi   → hosted sign-in (magic link / Google)
GET  /auth/callback              → issues one-time code → 302 navi://auth/callback?code=…
POST /auth/exchange { code }     → { accessToken, refreshToken, expiresAt }
POST /auth/refresh  { refreshToken } → same shape
POST /billing/checkout { plan:"pro"|"pro_recall", interval:"month"|"year" } → { url }   (Stripe Checkout)
POST /billing/portal → { url }
POST /billing/webhook  (Stripe → entitlements table)
POST /waitlist { email, source? } → 201   (also used by web/)
```

Postgres tables: `profiles(user_id, tier, stripe_customer_id, trial_ends_at)`,
`entitlements(user_id, key, granted_by, expires_at)`, `usage(user_id, feature, run_id, day, month, cost_usd)`,
`waitlist(email, source, created_at)`. Row-level security on all four.

## 4. Workstreams

Each runs as its own agent in its own worktree on branch `claude/launch-<name>`, builds with a
private derived-data dir (`scripts/build.sh Debug build/DerivedData-<name>`), commits small, pushes,
and opens a PR against `main` (never merges — see the merge-via-PRs rule). File ownership is
strict so PRs don't collide.

### A. Website + waitlist — `claude/launch-site` — owns `web/`
- Next.js 15 + Tailwind, dark, the current AI-tool look: big hero with the real Navi panel
  rendered in HTML/CSS (680 pt glass bar, cycling placeholder), "Press ⌘Space" moment, three
  feature blocks (Instant · Answers · Does it for you), Recall block, voice block, pricing from §2,
  FAQ, footer. OG image. Lighthouse ≥ 95.
- Waitlist form → `POST /api/waitlist` → Supabase `waitlist` (env `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`);
  when env is absent, falls back to appending to `web/.waitlist.local.jsonl` so it works in dev.
- Copy: never mentions Jev/Claude/TypeSafe/Anthropic. "Navi decides in under a second."
- Done when `npm run build` passes, the page renders at 375 / 1440 px, and a waitlist submit lands in the fallback file.

### B. Navi-branded UI + result polish — `claude/launch-branding` — owns `Navi/Panel/**`, `Navi/Router/AppIndex.swift`, `Navi/Router/FileSearch.swift`, `Navi/Settings/{About,Usage,Agent,Voice,BrowserRuntime,Providers,General}View.swift`, `NaviTests/**` for those
- Every user-visible string: Navi, not the vendor. "Ask Navi", "Navi is thinking…", "Navi · answering".
  Remove the Jev % + ms pill and model IDs from the panel footer. Keep the risk shield (it's a
  safety affordance) but word it "Navi will ask before anything irreversible".
- Result subtitles: never a path. App → "App" / "Running"; file → the kind ("PDF", "Folder",
  "Swift source", from `UTType.localizedDescription`) and optionally "· Modified 2 days ago". Unit tests.
- Settings: `ProvidersView` becomes a hidden **Developer** section (shown only when
  `defaults write com.liamcarlin.navi developerMode -bool YES`); Usage shows "answers / tasks used
  this month" against the plan, not tokens and dollars; Agent/Voice/Browser pages lose the
  Jev/Claude explanations and the confidence-threshold slider moves under Developer.
- Panel declutter: nothing visible the user didn't ask for — no latency, no transport, no model.
- Done when `grep -rniE 'claude|anthropic|jev|typesafe|gemini|opus|sonnet|haiku' Navi/Panel Navi/Settings`
  returns only Developer-section, `Log.` and comment lines, and `scripts/test.sh` passes.

### C. Navi Cloud backend — `claude/launch-cloud` — owns `cloud/`
- Next.js App Router, TypeScript, Supabase JS, Stripe SDK. Implements §3.1 exactly: auth
  start/callback/exchange/refresh, `/v1/me`, `/v1/jev`, `/v1/claude` (SSE streamed through,
  `anthropic-version` header preserved), `/v1/digest`, billing checkout/portal/webhook, `/waitlist`.
- Metering: one `usage` row per `X-Navi-Run`; quota check before proxying; per-IP + per-user rate limit.
- Local dev with `supabase start` or a `.env.local` against a hosted project; `cloud/README.md`
  lists every env var and the Stripe products/prices to create (`price_pro_month`, `price_pro_year`,
  `price_pro_recall_month`, `price_pro_recall_year`).
- Tests: vitest for the quota/entitlement logic and the Stripe webhook → entitlements mapping.
- Done when `npm test` and `npm run build` pass and a scripted curl session (README) can sign
  in, hit `/v1/me`, and get a 402 after exceeding a free quota.

### D. Account + entitlements in the app — `claude/launch-account` — owns `Navi/Core/{NaviAccount,CloudTransport,Entitlements}.swift` (new), `Navi/Settings/{AccountView,HomeView,MemoryView,OnboardingView,SettingsRootView}.swift`, `Navi/Core/Keychain.swift` (add keys), `Navi/Providers/*` (transport hook only), `Navi/Memory/MemoryService.swift` (gate only), `Navi/Router/QueryRouter.swift` (memory-intent gate only)
- `CloudTransport`: `JevClient`/`ClaudeClient`/`GeminiClient` gain a `.navi` transport — base URL
  from `NaviSettings.cloudBaseURL` (default `https://api.navi.app`), bearer = account token, adds
  `X-Navi-Feature` / `X-Navi-Run`. BYOK transports stay for Developer mode. 402/403 map to
  `NaviError.quotaExceeded` / `.notEntitled`.
- Sign-in: `navi://auth/callback` handled in `AppDelegate`; tokens in Keychain; `NaviAccount`
  (`@MainActor`, observable) exposes `tier`, `entitlements`, `usage`, refreshes `/v1/me` on wake and every 10 min.
- Onboarding step 1 becomes "Sign in to Navi" (button opens the browser). Home shows the plan
  card and usage; Settings gets an **Account** section (plan, usage bars, Manage billing → portal, Sign out).
- Recall gating: `MemoryService.start()` refuses without `recall`; Settings → Memory and the
  Router's `wants_memory` path show an "Unlock Recall" card that opens checkout for `pro_recall`.
- Panel: quota/entitlement errors render as one line + "Upgrade" (calls checkout). 
- Done when the app builds, signs in against a mock server (`cloud/` running locally or a tiny
  Swift `MockCloud` in tests), Recall is refused on Free, and `scripts/test.sh` passes.

### E. Distribution — `claude/launch-dist` — owns `scripts/**`, `project.yml` (signing + Info.plist keys), `Navi/Agent/UltrafastBridge.swift` (bundle lookup only), `Navi/App/Updater.swift` (new), `docs/RELEASE.md`
- `scripts/bundle-runtime.sh`: downloads python-build-standalone (arm64 + x86_64), installs
  `vendor/jev-ultrafast` deps into `Navi.app/Contents/Resources/browser-runtime`, strips, re-signs.
  `UltrafastBridge` looks there first. Browser-use's Chromium is *not* bundled — Navi drives the user's Chrome.
- `scripts/release.sh`: Release build → Developer ID sign (identity from env `NAVI_SIGN_IDENTITY`)
  → `notarytool submit --wait` → staple → DMG (`create-dmg` via hdiutil, no Homebrew dep) →
  `appcast.json` with version, URL, SHA-256, ed25519 signature.
- `Updater.swift`: dependency-free — fetches `appcast.json` daily, verifies signature, downloads
  DMG, replaces the bundle, relaunches. "Check for updates…" in the menu bar.
- `project.yml`: `CODE_SIGN_IDENTITY: "Developer ID Application"`, hardened runtime, entitlements
  file with the needed exceptions; `LSApplicationCategoryType`, `NSHumanReadableCopyright`, usage strings.
- Done when `scripts/release.sh --dry-run` produces a DMG from an unsigned build, the updater's
  signature check has unit tests, and the bundled runtime runs a browser step from `/Applications`.

### F. Reliability pass ("no failures") — after A–E land
- Smoke matrix: 60 queries × 3 categories (launch / answer / task) run nightly via
  `navi://voice?file=` and a new `navi://query?text=` debug entry; failures logged to `agent-runs.log`.
- Every `NaviError` has a one-line user message and a recovery action; no error shows a raw string.
- Cold-start budget: panel visible < 120 ms, first result < 50 ms, Jev warm-up on launch.
- Permissions: every capability degrades gracefully when denied and links to System Settings.

### G. Brand — Liam + one agent, when A is up
- Name, wordmark, app icon (the ✦ already in the menu bar), colour (the glass tint), one-line
  positioning: "Navi. Press ⌘Space and say what you want." Apply to `scripts/make-icon.swift`,
  the site, the DMG background, the About page.

## 5. Sequence

```
week 1  A site+waitlist ──┐   B branding+results ──┐   C cloud ──┐   E dist ──┐
        (ship waitlist)   │                          │   D account ┤ (needs C's contract, not C's code)
week 2                    └── merge A,B ─────────────┘            └── merge C,D,E; deploy cloud to Vercel
week 3  F reliability pass · G brand · TestFlight-style beta to the waitlist (notarized DMG)
week 4  Stripe live mode · pricing page live · open the download
```

## 6. Things only Liam can do (do these in parallel with the agents)

1. **Domain** — register or pick one (`navi.app`? check availability). Set `NEXT_PUBLIC_SITE_URL` / `cloudBaseURL`.
2. **Supabase project** — create it, paste `SUPABASE_URL`, anon key, service key into Vercel env for both apps.
3. **Stripe account** — create the four prices in §4-C, set the webhook secret, enable Customer Portal.
4. **Apple Developer ID** — the team `M8ZP994J4T` exists; create a *Developer ID Application*
   certificate and an app-specific password for `notarytool` (`xcrun notarytool store-credentials navi`).
5. **Vendor keys in Vercel only** — `TYPESAFE_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`. Rotate the
   ones currently in your local Keychain once the proxy is live.
6. **Confirm pricing** (§2) and the Free tier limits.
7. **Privacy policy + terms** — Recall captures the screen; the policy must say frames never leave the
   Mac except digests, and that sensitive frames are dropped before anything is sent.

## 7. Decisions made here (defaults; override by editing this file)

- Backend on Vercel + Supabase + Stripe, not a Swift server, not Firebase — smallest ops surface, matches the existing Vercel AI Gateway path.
- Two Next apps (`web/`, `cloud/`) rather than one, so the site can ship this week without waiting on billing.
- Browser runtime bundled in the app rather than ported to Swift — porting the DOM driver is a month; bundling is a day.
- Custom updater rather than Sparkle, honouring the no-dependency rule; revisit if it bites.
- Recall is a separate tier, not an add-on toggle — one decision on the pricing page.
- Free tier exists (local features are free to run) so the download has no wall; conversion happens at the first "Ask Navi" that hits the daily cap.
