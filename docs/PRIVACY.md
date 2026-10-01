# Navi — data inventory (engineering)

_The source of truth for what Navi stores and sends. Written 2026-10-01 from the code on
`main` + branch `claude/launch2-privacy`, checked against a real install (shapes and sizes
only). The public policy (`web/app/privacy/page.tsx`) and Settings → Privacy & Data
(`Navi/Settings/PrivacyView.swift`) must agree with this file — change all three together._

Code map: `Navi/Core/DataInventory.swift` (measures it), `Navi/Core/PrivacyData.swift`
(`PrivacyData.deleteAllLocalData()`, `PrivacyMaintenance`), `Navi/Core/TaskLogs.swift`,
`Navi/Memory/CaptureExclusions.swift`, `Navi/Memory/VaultCleanup.swift`.

## 1. On this Mac

All paths are inside the user's home folder (`~/Library` is `0700`); the memory folder is
`0700` and the database `0600`.

| Store | Path | What's in it | Retention | Deleted by "Delete everything" |
|---|---|---|---|---|
| Screen memory DB | `~/Library/Application Support/Navi/memory.sqlite` (+ `-wal`, `-shm`) | **frames**: time, app, bundle ID, window title, page URL (browsers, with Automation consent), **full OCR text (≤ 6,000 chars)**, thumbnail path, perceptual hash, Jev activity/importance. Sensitive frames are stubs: app + time only (no title/URL/text/thumbnail — verified on a real DB: 114/114 stubs empty). **sessions**: title, summary, topics, entities (people, projects…), key facts, app, URL, note path. FTS5 indexes over both. **actions** (`ActionJournal`, toggle `memoryRecordActions`): time, app, window title, page URL, the clicked control's role + label (a text field's label, never its value), menu path + shortcut, and ⌘/⌃ shortcuts pressed — never typed text, secure fields, excluded/paused/sensitive apps or Navi's own input. **procedures**: per digested session, goal, steps, habits. | `memoryRetentionDays`, default **30** (7/30/90/forever), daily; actions at least 90 days, procedures at least 365. `secure_delete=ON`; FTS optimize + WAL truncate after a purge. | yes (rows, index, `VACUUM`; the file stays open so Recall keeps working) |
| Thumbnails | `…/Navi/frames/YYYY/MM/DD/<ts>.jpg` | ≤ 1024 px JPEG of the whole display (excluded apps' windows and Navi cut out), when "Keep screenshots" is on (default on). Never for sensitive frames. | with their frame | yes |
| Journal (Obsidian vault) | `~/Navi Vault` (user-choosable) | `Sessions/` (summary, key facts, links, one screenshot in `attachments/`), `Daily/`, `Apps/`, `Topics/`, `Entities/` (people, companies…), `Navi/README.md`, `Navi/How you work.md` (people/projects/apps the agent learned). Personal identifiers redacted per the user's personal-data choices. | Notes Navi wrote (tagged `navi/*`) follow the memory retention unless "Also remove journal notes" is off; hub lines for expired sessions are removed; the user's own notes are never touched. | Navi-tagged notes + the screenshots they embed + generated notes; user notes and `.obsidian/` stay |
| Agent experience | `…/Navi/agent-experience.json` | ≤ 300 entries: app, **task text (≤ 200 chars)**, ≤ 12 action labels (element names, sometimes URLs; never typed text). | capped at 300, no time limit | yes |
| Task logs | `~/Library/Logs/Navi/runs/<ts>/` (goal, every step's Jev state incl. AX text/OCR lines/user context, answers, the writer's review incl. conversation, a window **screenshot**), `agent-last-run.log`, `agent-runs.log` (+`.1`, 2 MB rotation; task text, steps incl. typed text ≤ 48 chars, answers), `ultrafast-last-run.jsonl` (browser runner events incl. fill text, page text) | **Off for users** unless Settings → Privacy & Data → "Keep task logs" (or Developer mode, or a Debug build that never chose). Everything kept passes `PersonalData` strict redaction; runner screenshots are never logged. | 7 days; run folders ≤ 200 MB and ≤ 30 runs | yes |
| `debug.log` | `~/Library/Logs/Navi/debug.log` | voice transcripts, panel queries (`DebugTrace`) | **Debug builds only** (compiled out of Release); 7-day purge | yes |
| Legacy | `…/Navi/history.json` | written by builds before 2026-09-21 | — | yes |
| UserDefaults | `~/Library/Preferences/com.liamcarlin.navi.plist` | preferences; plus content: `navi.recentQueries` (last 50 queries), `navi.launchCounts` (per-app launch counts), `naviAccountInfo` (email, plan), `schedulerVideoLink`, vault path, exclusions | — | `navi.recentQueries`, `navi.launchCounts` cleared; settings + account kept |
| Keychain | Navi's items | Navi session (`naviAccess`, `naviRefresh`); developer-mode vendor keys | until sign-out | **no** (sign-out / account deletion handle it) |
| Voice | — | audio is never written; transcripts live in memory only (`VoiceCommandExecutor.recent`, last 5) | — | n/a |
| In-memory caches | — | `UserHabits` / `UserKnowledge` (from screen memory, 10-min cache), `UserMoves` (actions + procedures, 5-min cache) | — | invalidated |
| Browser runner (dev only) | `~/.config/browser-harness/tmp/*.log` | browser-harness daemon logs (shared with dev tools) | not managed by Navi | no |

Never captured (`CaptureScheduler.tick`): Recall off / paused, locked screen, display asleep,
screen saver, **another user's session on the console**, built-in apps (Passwords, Keychain
Access, System Settings, auth/Touch ID prompts, 1Password, Bitwarden, LastPass, KeePassXC,
Enpass, Proton Pass, Dashlane) and user-excluded apps (also cut out of every frame), **private
windows** (title: Firefox/Edge/…; Apple Events: Chrome/Brave/Edge/Vivaldi `mode`, Arc
`incognito` — *Safari private windows are not detected*), **excluded sites** (default: password-
manager web vaults; needs the URL, i.e. Automation consent), a **focused password field**
(`AXSecureTextField`), Navi itself.

## 2. What leaves the Mac

Default transport for signed-in users is **Navi Cloud** (`CloudTransport`, `useCloud = true`,
`https://api.navi.app`): the app sends exact vendor request bodies to `/v1/jev`, `/v1/claude`,
`/v1/digest`; the cloud forwards them byte-for-byte and stores none of them. Developer mode
with own keys talks to the vendors directly.

| Feature | Sent | To |
|---|---|---|
| Routing (every ⌘Space query) | query, frontmost app, window title, last 5 queries | Jev (TypeSafe) |
| Answers | query, context (selected text / clipboard when the query refers to it), conversation, up to 8 screen-memory hits (titles, URLs, ≤ 400-char snippets) | Claude (Anthropic) |
| Agent, native | per step: the app's AX text (controls + static text), OCR lines where AX is thin, URL, user context from screen memory (people/projects/where they live; the user's own click counts, shortcuts, procedures and habits for this app — `how_this_user_works`; in the browser runner, the labels and counts of what they click on that site — `this_user`), history incl. typed text → Jev. Text fills, review on a stop: **a window screenshot** + the step packet → Claude. Claude-only driver: full screenshots every step. | Jev, Claude |
| Agent, browser runner | page DOM elements → Jev; fills/coach (may attach a JPEG) → Claude. **Bypasses Navi Cloud** (needs own keys; refuses with the cloud transport only) — effectively dev-only today. | Jev, Claude, directly |
| Recall triage (each captured frame) | app, title, URL, previous context, form-signal *kinds*, **≤ 3,000 chars of OCR**. Frames the local guard blocks (DOB, cards, SSN, IDs, identity/checkout/patient forms per the user's choices) are never sent. | Jev (`X-Navi-Feature: recall_triage`) |
| Recall digest (important sessions, ~every 10 min) | redacted titles, URLs, ≤ 4 redacted OCR blocks (≤ 8,000 chars), **≤ 2 thumbnails** (none for a session that needed scrubbing) | Gemini Flash-Lite, else Claude Haiku (`/v1/digest`) |
| Voice | audio: never (on-device `SpeechAnalyzer`). The clause text + frontmost app/title/URL → Jev; then like a typed query/task | Jev, Claude |
| Third-party telemetry | none in the app. Runner/helpers run with `BH_TELEMETRY=0`, `ANONYMIZED_TELEMETRY=false` (browser-harness had PostHog on by default). | — |

## 3. What Navi Cloud keeps (`cloud/`, read-only review)

- Postgres: `profiles` (user id, email, tier, trial end, Stripe customer/subscription id + status),
  `entitlements`, `usage` (**metadata only**: user, feature, run id, day, month, cost), `waitlist`
  (email, source, note ≤ 500 chars, created_at), `auth_codes` (5-min one-time codes).
  Supabase `auth.users` (email, sign-in provider data).
- Logging: method + path + error object on 5xx (`lib/http.ts:44`); cost-record failures; Stripe
  webhook ids. No request bodies. Vercel platform request logs (IP, path, time) exist on top.
- Rate limiting: in-process map keyed by user id or IP, never persisted.
- **Gaps** (cloud workstream): no account-deletion endpoint (deleting the auth user cascades
  profiles/entitlements/usage; the Stripe customer remains); no retention on `usage`/`waitlist`;
  `purge_expired_auth_codes()` is not scheduled; a 5xx log could include fragments of an
  upstream error message.

## 4. Deletion

- **Settings → Privacy & Data → Delete everything** = `PrivacyData.deleteAllLocalData()`
  (also the hook for the account-deletion flow). Navi keeps working; Recall restarts empty.
- Retention runs daily for every user (`PrivacyMaintenance`, from
  `NaviServices.startBackgroundServices`), not only while capture runs; never in hosted test runs.
- Old builds' redaction: `scripts/memscrub` / "Remove blocked details already saved…".
