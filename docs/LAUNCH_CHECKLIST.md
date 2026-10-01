# Navi go-live checklist

_The one list between "works on Liam's Mac" and "a stranger downloads a DMG, signs in, and
everything works — no API keys, no repo, no vendor names". Written 2026-10-01 from the
launch-readiness pass; details live in `docs/LAUNCH_ROADMAP.md`, `docs/RELEASE.md` and
`cloud/README.md`. Tick a line only when its **Verify** step passed._

Owners: **Liam** = needs your accounts, money, signature or judgment. **Agent** = a Claude
Code session can do it from the repo (open a PR; Liam merges).

## 0. Decisions (Liam, first — everything below depends on them)

| ☐ | Item | Owner | Verify |
|---|---|---|---|
| ☐ | Pricing + Free limits (roadmap §2: Free 20 answers/5 tasks a day, Pro $20, Pro+Recall $30, 7-day trial) | Liam | `cloud/lib/plans.ts` and the site's pricing section show the same numbers |
| ☐ | Domain for the site and the API: `buildnavi.com` (bought 2026-10-01 at GoDaddy, attached to Vercel `navi-site`) + `api.buildnavi.com` (not yet attached to `navi-cloud`) | Liam | `dig +short api.<domain>` returns Vercel's address |
| ☐ | Apple Developer Program membership ($99/yr, team `M8ZP994J4T`) — needed for Developer ID + notarization; nothing ships to strangers without it | Liam | developer.apple.com → Membership shows "Active" |

## 1. Navi Cloud (`cloud/`) on Vercel

| ☐ | Item | Owner | Verify |
|---|---|---|---|
| ☐ | Create the Vercel project with root `cloud/`; attach `api.<domain>` | Liam | `curl -s https://api.<domain>/healthz` → `{"ok":true,"db":"supabase",…}` |
| ☐ | Production env vars per `cloud/README.md` § 3 (`NAVI_CLOUD_BASE_URL`, Supabase, Stripe, vendor keys); **no** `DEV_LOGIN_SECRET` / `MOCK_UPSTREAM` / `DB_DRIVER` | Liam | `/healthz` shows `"mockUpstream":false`, `"devLogin":false`, all three vendors `true` |
| ☐ | Vendor keys (TypeSafe, Anthropic, Gemini, optional AI Gateway) pasted into `/admin` → **Keys** (stored AES-256-GCM-encrypted with `NAVI_KEYS_SECRET`; Vercel env vars are only the fallback) — never in the app, the repo or a DMG | Liam | each key's **Test** button is green; `/healthz` reports every vendor's source as `database`; `grep -rn 'sk-ant\|tsk_' build/release/Navi.app` finds nothing |
| ☐ | Rotate the vendor keys that sit in your local Keychain/env once the proxy is live | Liam | old keys revoked in each vendor console |
| ☑ | Shared rate limiter: done in #47 — `cloud/lib/ratelimit.ts` uses the Postgres `rate_limit_hit()` RPC (migration 0003) when Supabase is configured, so every Vercel instance shares one counter. Keep Vercel's function region next to Supabase's (one DB round trip per `/v1/*` call) | Agent | two parallel instances of `scripts/smoke.sh` see one shared counter |
| ☐ | Re-check the 120 req/min per-user cap against a busy browser task (one Jev call per step + text helper) | Agent | a 40-step browser task never hits 429 |
| ☐ | Vercel **Pro** plan if `/v1/claude`'s `maxDuration = 300` is kept (Hobby caps functions at 60 s; long streamed agent turns would be cut) | Liam | a 2-minute streamed answer completes |
| ☐ | Smoke against production: `NAVI_CLOUD_URL=https://api.<domain> DEV_LOGIN_SECRET=… cloud/scripts/smoke.sh` (temporarily set the secret, then remove it) | Agent + Liam | all steps pass; secret removed afterwards |

## 2. Supabase

| ☐ | Item | Owner | Verify |
|---|---|---|---|
| ☑ | Migrations `0001_init` → `0002_admin` → `0003_account` applied to the waitlist project `oqvuejmxkkfaogelwraz` (2026-10-01, dashboard SQL editor; the existing waitlist row kept) | Agent | done: 10 public tables (`admin_audit`, `admins`, `app_config`, `auth_codes`, `entitlements`, `profiles`, `rate_limits`, `usage`, `vendor_keys`, `waitlist`), RLS on for all; `on_auth_user_created` trigger present |
| ☐ | Auth → URL configuration: Site URL `https://api.<domain>`, redirect `https://api.<domain>/auth/callback` | Liam | magic-link sign-in from the app lands back in Navi signed in |
| ☐ | Auth email: custom SMTP — Supabase's built-in sender only delivers to the project's team members, so strangers get no sign-in mail without it — plus the Navi template (link + 6-digit code) from `cloud/DEPLOY.md` §3 in both "Magic Link" and "Confirm signup" | Liam | 10 sign-ups in an hour from outside addresses all receive the mail |
| ☐ | Optional Google sign-in (`GOOGLE_CLIENT_ID/SECRET`) | Liam | "Continue with Google" appears on `/auth/start` and works |
| ☐ | Daily purge: Vercel Cron (`cloud/vercel.json`, 04:17 UTC) → `GET /auth/purge` → `navi_purge()` (expired sign-in codes + old rate-limit windows). Needs `CRON_SECRET` set in Vercel | Liam (env) | the cron's run log in Vercel shows 200; `auth_codes` holds nothing older than a day |

## 3. Stripe

| ☐ | Item | Owner | Verify |
|---|---|---|---|
| ☐ | Products + four prices (`STRIPE_PRICE_PRO_{MONTH,YEAR}`, `STRIPE_PRICE_PRO_RECALL_{MONTH,YEAR}`) in **test** mode first | Liam | Upgrade in the app → Checkout shows the right price |
| ☐ | Webhook `https://api.<domain>/billing/webhook` with the five events → `STRIPE_WEBHOOK_SECRET` | Liam | Stripe dashboard → webhook → recent deliveries all 200 |
| ☐ | Customer Portal enabled | Liam | Account → Manage billing opens the portal |
| ☐ | Switch to **live** mode (live keys + live price ids + live webhook secret) | Liam | a real $20 purchase on your own card, then refund it |

## 4. The app's build configuration

| ☐ | Item | Owner | Verify |
|---|---|---|---|
| ☑ | `NaviCloudBaseURL` in `project.yml` = the deployed API — `https://navi-cloud.vercel.app` since 2026-10-01 (read by `CloudTransport.defaultBaseURL`; `https://api.buildnavi.com` is only the code fallback). Change it again when the custom domain is attached | Agent | a fresh user account (no `cloudBaseURL` default) signs in against production |
| ☐ | `NaviUpdateFeedURL` in `project.yml` = where `appcast.json` is served (default: the latest GitHub Release — works as is) | Agent | `curl -sL <url> \| python3 -m json.tool` |
| ☐ | Privacy/terms/support links (`AboutView`: `https://buildnavi.com/privacy`, `/terms`, `support@buildnavi.com`) point at pages and a mailbox that exist | Liam (pages) + Agent (URLs) | each link opens; a test mail to support arrives |
| ☑ | Version bump: 1.0.0 (build 2) in `project.yml` + `Info.plist`. Bump the build number for every later release | Agent | About shows "1.0.0 (2)" |
| ☐ | No vendor names anywhere a user looks (re-check after every UI PR) | Agent | `grep -rniE 'claude\|anthropic\|jev\|typesafe\|gemini' Navi/Settings Navi/Panel` hits only Developer/Providers views, `Log.` and comments |

## 5. Signing, notarization, distribution

| ☐ | Item | Owner | Verify |
|---|---|---|---|
| ☐ | Developer ID Application certificate in the login keychain | Liam | `security find-identity -v -p codesigning \| grep "Developer ID Application"` |
| ☐ | Notary profile: app-specific password → `xcrun notarytool store-credentials navi --apple-id … --team-id M8ZP994J4T` | Liam | `xcrun notarytool history --keychain-profile navi` runs without error |
| ☐ | Back up the update key `~/.config/navi-release/update-key.pem` (1Password / secure note) — losing it means no shipped copy accepts another update | Liam | restore test on another machine: `openssl pkey -in … -pubout` matches `UpdateVerifier.publicKeyBase64` |
| ☐ | `scripts/release.sh --notes RELEASE_NOTES.txt` ends with **"Shippable."** | Liam (runs it; needs the cert) | the script's last lines; `spctl --assess --type execute -vv build/release/Navi.app` → `Notarized Developer ID` |
| ☐ | `scripts/publish-release.sh` → draft `v<version>` on GitHub with `Navi-<v>.dmg`, `Navi.dmg`, `appcast.json`; review, **Publish** | Liam | `curl -sIL https://github.com/LiamCarlin/Navi/releases/latest/download/Navi.dmg` ends in `200` |
| ☑ | `buildnavi.com/download` (`web/app/download/route.ts`): goes to the waitlist while the site is in waitlist mode, and to `releases/latest/download/Navi.dmg` once `NEXT_PUBLIC_SIGNUPS_OPEN=1` | Agent | `curl -sI https://buildnavi.com/download` → 307 to `/#waitlist` now, to the DMG after sign-ups open |
| ☐ | `--universal` build if Intel Macs are supported at launch (macOS 26 still runs on some) | Liam (decide) | `lipo -archs Navi.app/Contents/MacOS/Navi` lists both; `browser-runtime/python-x86_64` exists |

## 6. Smoke tests — on a Mac (or a new macOS user account) that has never seen Navi

Do these with the **published** DMG, signed in as a brand-new account, Developer mode off.

| ☐ | Test | Owner | Pass when |
|---|---|---|---|
| ☐ | Download in Safari, open DMG, drag to Applications, open | Liam | only the standard "downloaded from the internet" dialog; no "cannot be opened" |
| ☐ | Onboarding → Sign in → magic link → back in Navi | Liam | Account shows the email and "Pro trial · 7 days left" |
| ☐ | Each permission prompt reads in plain words (Accessibility, Screen Recording, Microphone, Speech, Calendar, Reminders, Contacts, Automation, Desktop/Documents/Downloads) and denying one degrades with a "Grant in System Settings" button | Liam | no prompt mentions a vendor; nothing crashes when denied |
| ☐ | ⌘Space → "maps" opens Maps; "2+2*3" answers 8; a file name finds the file | Liam | instant, no network needed |
| ☐ | A question streams an answer | Liam | Account → usage shows 1 answer |
| ☐ | "open notes and write hello" (native task) | Liam | done; usage shows 1 task |
| ☐ | **Browser task in Chrome** ("search google for the weather in boston") — first run asks Chrome's "Allow remote debugging?", Navi presses Allow | Liam | the task finishes in Chrome; usage still counts **one** task for it (the bundled runner goes through Navi Cloud — `~/Library/Logs/Navi/ultrafast-last-run.jsonl` has decisions, no vendor key exists on the Mac) |
| ☐ | Same in Safari (native browser path) | Liam | done |
| ☐ | Voice: click the sparkle, say "open calculator" | Liam | Calculator opens; island never shows an engine name |
| ☐ | Free tier: after the trial (or a Free test account) exceed 5 tasks | Liam | one plain line saying the limit was reached and when it resets, an Upgrade button, no stack trace |
| ☐ | Upgrade → Checkout (test card 4242…) → back in Navi | Liam | toast "Welcome to Pro", tier updates without relaunch |
| ☐ | Recall on Free/Pro is refused with "Unlock Recall"; on Pro+Recall capture starts and "what was I doing an hour ago" answers | Liam | as described |
| ☐ | Update: install version N, publish N+1, menu bar → Check for Updates… → Install | Liam | relaunches as N+1; settings and sign-in kept |
| ☐ | Sign out → every paid feature asks to sign in; local features keep working | Liam | as described |

Developer shortcut for the browser-runner path, without a Mac reset: `docs/RELEASE.md` §
Dry run (`scripts/dev/runtime-smoke.sh --cloud … --token …`).

## 7. Legal + support

| ☐ | Item | Owner | Verify |
|---|---|---|---|
| ☐ | Privacy policy (`web/app/privacy/page.tsx`, drafted in #45 from `docs/PRIVACY.md`): what leaves the Mac — queries/answers and task steps (incl. a window screenshot when a task stops for review) to Navi Cloud and its model providers; Recall sends each moment's screen text for triage and, for important ones, the text plus up to two thumbnails for the summary (frames and thumbnails themselves stay on the Mac); sensitive frames and blocked personal details are dropped locally first — retention, deletion. Confirm the flagged claims: providers don't train on the data (Gemini only on the paid tier), the contact address, 30-day account deletion, minimum age 13, GDPR/CCPA wording | Liam (approve) + Agent (draft done) | published at the URL the app links; every claim matches `docs/PRIVACY.md` |
| ☐ | Terms of service + refund policy (Stripe requires a refund/cancellation policy on the site) | Liam | published, linked from pricing and Checkout |
| ☐ | Support email that someone reads | Liam | test mail answered |
| ☑ | Third-party notices: About → Acknowledgements (`Navi/Settings/AcknowledgementsView.swift`) lists typesafe-computer-use, jev-ultrafast, Python + python-build-standalone, every Python package the browser runtime bundles, and the CC0 typing sound, with each license's text. Update it when `scripts/bundle-runtime.sh` adds a package | Agent | About → Acknowledgements lists them |

## 8. Known open issues from the 2026-10-01 pass

- Browser runs that fail keep their tab open by design; local test runs leave background tabs.
