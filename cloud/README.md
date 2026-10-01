# Navi Cloud

The backend that lets Navi be sold as one subscription with no user-supplied API keys.
It owns the vendor keys (TypeSafe Jev, Anthropic, Gemini), authenticates the app with a
Navi account, meters every call and enforces the tier. Next.js 15 App Router on Vercel ·
Supabase (Auth + Postgres) · Stripe Billing. Contract: `docs/LAUNCH_ROADMAP.md` §3.1.

```
Navi.app ──(Bearer <navi session>)──▶ Navi Cloud
   │   POST /v1/jev       → api.typesafe.ai/v1/systemone      (server key, metered, JSON passthrough)
   │   POST /v1/claude    → api.anthropic.com/v1/messages      (server key, metered, SSE streamed through)
   │   POST /v1/digest    → Claude or Gemini                   (requires `recall`)
   │   GET  /v1/me        → tier, entitlements, quotas, usage, resetsAt, config (switches, notice, versions)
   │   /auth/*            → Supabase Auth (email link + 6-digit code, Google, Apple) → navi://auth/callback?code=…
   │   /account           → web portal: plan, usage, billing, download, devices, export, delete
   │   /v1/account*       → GET export · DELETE account (Bearer or the /account cookie)
   │   /billing/*         → Stripe Checkout / Portal / webhook → profiles.tier
   └── POST /waitlist     → waitlist table (also used by web/)

Liam ──(browser)──▶ /admin  → admin console: users, vendor keys, product config, waitlist, audit
```

## Quick start (no services needed)

```bash
cd cloud
npm install
npm test                       # vitest: plans, metering, webhook mapping
npm run build

# Terminal 1 — memory DB, canned vendor responses, dev login enabled
MOCK_UPSTREAM=1 DEV_LOGIN_SECRET=dev npm run dev          # http://localhost:3100

# Terminal 2 — the scripted curl walkthrough
scripts/smoke.sh
```

With no `SUPABASE_URL` the server uses an **in-memory DB driver** (`DB_DRIVER=memory`):
profiles, usage, auth codes and the waitlist live in the process. `MOCK_UPSTREAM=1` makes
`/v1/jev`, `/v1/claude` and `/v1/digest` return canned responses in the real wire shapes
(including a Claude SSE stream), so the Swift client can be exercised end to end without
vendor keys. `POST /auth/dev-login` only exists while `DEV_LOGIN_SECRET` is set.

## Endpoints

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/v1/me` | Bearer | `{ user, tier, trialEndsAt?, entitlements, quotas, usage, config }` — `config` below. Never 426 (an old app must still learn it is old); 403 `account_disabled` when disabled. |
| POST | `/v1/jev` | Bearer | Body = exact TypeSafe `/v1/systemone` body. JSON passthrough. |
| POST | `/v1/claude` | Bearer | Body = exact Anthropic `/v1/messages` body. `stream:true` → SSE piped through unbuffered. Client `anthropic-version` / `anthropic-beta` headers are forwarded. |
| POST | `/v1/digest` | Bearer | Same as `/v1/claude`, needs the `recall` entitlement (403 `not_entitled`). With `GEMINI_API_KEY` set and body `provider:"gemini"`, forwards `{model?, ...generateContent body}` to Gemini instead. |
| GET | `/auth/start?redirect=navi\|account` | – | Hosted sign-in page: one email with a link and a 6-digit code; Google / Apple when enabled in Supabase. Failures come back as `?error=<kind>` with an explanation (and, for the app flow, a "Back to Navi" link to `navi://auth/callback?error=sign_in_failed&message=…`). |
| POST | `/auth/otp` | – | `{ email, redirect }` → sends the email (5 per address / 15 min). |
| POST | `/auth/verify` | – | `{ email, code, redirect }` → `{ redirect }`: `navi://auth/callback?code=…` or `/account` + cookie (10 tries per address / 15 min). |
| GET | `/auth/oauth?provider=google\|apple&redirect=` | – | → the provider's consent page. |
| GET | `/auth/callback` | – | Link / OAuth return (`?code=` PKCE or `?token_hash=`); app flow → single-use 5-min code → `302 navi://auth/callback?code=…`; web flow → cookie → `/account`; failures → `/auth/start?error=…`. |
| POST | `/auth/exchange` | – | `{ code }` → `{ accessToken, refreshToken, expiresAt }` |
| POST | `/auth/refresh` | – | `{ refreshToken }` → same shape |
| POST | `/auth/dev-login` | secret | `{ email, trial?: false, redirect? }` + header `x-dev-login-secret`. Dev only; 404 on production deployments. |
| GET | `/auth/purge` | cron secret | Daily (vercel.json): expired sign-in codes, old rate-limit rows. |
| GET | `/v1/account/export` | Bearer or cookie | Everything the cloud holds about the user (profile, plan + usage, grants, usage rows, waitlist row, devices). `?download=1` → attachment. 401 after deletion. |
| DELETE | `/v1/account` | Bearer or cookie | → 204. Cancels Stripe (fail-closed), deletes usage, grants, pending codes, waitlist row, profile, then the auth user. |
| GET | `/account` | cookie | The web portal (`/account/billing`, `/account/signout`, `/account/refresh` back it). |
| POST | `/billing/checkout` | Bearer | `{ plan: "pro"\|"pro_recall", interval: "month"\|"year" }` → `{ url }` |
| POST | `/billing/portal` | Bearer | → `{ url }` (400 `no_customer` before the first purchase) |
| POST | `/billing/webhook` | Stripe sig | `checkout.session.completed`, `customer.subscription.{created,updated,deleted}`, `invoice.payment_failed` |
| GET | `/billing/return?status=` | – | Bridge page → `navi://billing/success` or `navi://billing/cancel` |
| POST | `/waitlist` | – | `{ email, source?, note? }` → 201 new / 200 already listed |
| GET | `/healthz` | – | Which driver / vendors / mock mode are active (vendors = env vars only) |
| GET | `/admin` … | admin cookie | The admin console (see below). 404 for anyone who isn't a signed-in admin. |

### Headers the app sends on `/v1/*`

- `Authorization: Bearer <accessToken>` — Supabase JWT (1 h). Verified locally with the JWT
  secret (or a cached JWKS); no network call per request. 401 → refresh once → sign-in.
- `X-Navi-Feature: route | answer | task | voice | recall_triage | recall_digest`
  (default per route: jev→`route`, claude→`answer`, digest→`recall_digest`).
- `X-Navi-Run: <uuid>` — one usage unit per distinct run per feature, however many calls the
  run makes. Missing → each call is its own run.
- `X-Navi-Version: <short version>` (e.g. `1.2.0`) — on every request. Below the console's
  `minAppVersion` → 426 on `/v1/jev|claude|digest` (never on `/v1/me`). A missing or non-numeric
  header is let through (curl, scripts, builds from before the header).

### `GET /v1/me` → `config`

```json
"config": {
  "features": { "answers": true, "tasks": true, "voice": true, "recall": true },
  "notice": { "id": "1bd17969122e", "message": "…", "level": "info|warning|critical", "url": "https://…" },
  "minAppVersion": "1.2.0",
  "latestVersion": "1.3.0",
  "downloadURL": "https://navi.app/download"
}
```

`features` is always present; the other keys only when set. `notice.id` is a content hash —
it changes whenever the text, level or link changes, so the app can remember dismissals.
`quotas` in `/v1/me` already include the console's per-tier overrides.

Responses carry `X-Navi-Tier`, `X-Navi-Feature`, `X-Navi-Run` for debugging.

### Errors (§3.1)

| Status | Body |
|---|---|
| 401 | `{ error: "unauthenticated" }` |
| 402 | `{ error: "quota_exceeded", feature, tier, resetsAt }` |
| 403 | `{ error: "not_entitled", feature, tier }` |
| 403 | `{ error: "account_disabled", message }` — admin disabled the account (all `/v1/*`, including `/v1/me`) |
| 426 | `{ error: "upgrade_required", minAppVersion, downloadURL?, message }` — `X-Navi-Version` below `minAppVersion` |
| 429 | `{ error: "rate_limited", retryAfterSeconds }` + `Retry-After` |
| 503 | `{ error: "feature_disabled", feature: "answers"\|"tasks"\|"voice"\|"recall", message }` — kill switch off |
| 503 | `{ error: "upstream_unconfigured" \| "billing_unconfigured" }` |
| 4xx/5xx from the vendor | passed through with the vendor's status and body |

Order on a metered call: 401 → 429 → 403 `account_disabled` → 426 → 503 `feature_disabled` →
403 `not_entitled` → 402. Kill switches map `answer`→answers, `task`→tasks, `voice`→voice,
`recall_*`→recall; `route` (typing-time Jev routing) has no switch.

## Tiers, entitlements, quotas — `lib/plans.ts`

| Tier | Entitlements | Quotas |
|---|---|---|
| `free` | answers, tasks | 20 answers/day, 5 tasks/day |
| `pro` | + voice | 500 answers/day (fair use), 300 tasks/month |
| `pro_recall` | + recall | same as pro |

- New users get a **7-day Pro trial** (`profiles.trial_ends_at`). `/v1/me` reports the tier the
  user is *served at* (`pro` during the trial) plus `trialEndsAt` while it is running.
- Feature → bucket: `answer` spends `answers`; `task` **and `voice`** spend `tasks`; `route`
  and `recall_*` are never capped (recorded for cost only).
- A run that already holds a unit is never cut off mid-way: the quota is spent when the run starts.
- Daily windows reset at the next UTC midnight; monthly on the 1st 00:00 UTC. `usage.resetsAt`
  is the soonest of the tier's active windows.
- `cost_usd` per run is approximated from response usage (Jev flat $0.00005; Anthropic/Gemini
  tokens × `lib/pricing.ts`), including streamed responses (the SSE is tallied in passing).

Manual grants (comps, beta testers) go in the `entitlements` table and are OR-ed with the tier.
An admin **tier override** (`profiles.tier_override`) wins over the paid tier and the trial; the
console's **per-tier quota overrides** (`app_config`) replace the numbers above.

## Tables — `supabase/migrations/0001_init.sql`

| Table | Purpose |
|---|---|
| `profiles(user_id, email, tier, trial_ends_at, stripe_customer_id, stripe_subscription_id, subscription_status)` | Created by trigger on `auth.users` insert (trial starts) — the API also upserts on first sight. |
| `entitlements(user_id, key, granted_by, expires_at)` | Manual grants on top of the tier. |
| `usage(user_id, feature, run_id, day, month, cost_usd)` | PK `(user_id, feature, run_id)` — one row per run. |
| `waitlist(email, source, note, created_at)` | Deduped on email. |
| `auth_codes(code, user_id, access_token, refresh_token, token_expires_at, expires_at)` | Single-use, 5-min TTL; purged daily by `navi_purge()`. |
| `rate_limits(bucket, window_start, window_end, count)` | `0003_account.sql`; one row per limiter key per window. |

RLS is on for all five; users can `select` their own profile/entitlements/usage; everything
else is service-role only. `add_usage_cost()` is a `security definer` RPC.

`supabase/migrations/0002_admin.sql` (admin console; re-runnable — `if not exists` / `or replace`):

| Table / change | Purpose |
|---|---|
| `profiles` + `tier_override, disabled_at, disabled_reason, quota_reset` | Override, disable (403), "reset today's quota" offsets (usage rows — the cost history — are never deleted). |
| `waitlist` + `invited_at` | Invites from the console. |
| `admins(email, added_by)` | Admins besides `ADMIN_EMAILS`. |
| `vendor_keys(provider, ciphertext, last4, rotated_at/by, last_used_at, last_test_*)` | AES-256-GCM ciphertext; `ciphertext` null = metadata for an env-var key. |
| `app_config(key, value jsonb)` | Row `product` = the product config (`lib/config.ts`). |
| `admin_audit(actor, action, target, details jsonb, at)` | Every admin action. |
| `admin_usage_daily()`, `admin_active_users()`, `admin_usage_by_feature()`, `admin_sign_out_user()` | Service-role-only SQL functions so the console never pulls raw usage rows. |

All new tables: RLS on, no policies (service role only).

## Setting up for real

### 1. Supabase

1. Create a project. Copy **Project URL**, **anon key**, **service_role key** and
   (Settings → API) the **JWT Secret** into the env vars below.
2. Apply the schema: `supabase link --project-ref <ref> && supabase db push`
   (or paste `supabase/migrations/0001_init.sql`, then `0002_admin.sql`, into the SQL editor).
3. Auth → URL configuration: **Site URL** = `https://api.navi.app`, add
   `https://api.navi.app/auth/callback` and `https://api.navi.app/admin/auth/callback`
   (and the `http://localhost:3100/…` twins) to **Redirect URLs**.
4. Auth → Providers → Email: enabled. The default magic-link template works with the PKCE flow
   used by `/auth/start`. Optionally Google: paste the OAuth client id/secret there, and set
   `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET` here so the button shows.
5. Projects on asymmetric signing keys: set `SUPABASE_JWKS_URL` instead of the JWT secret.

### 2. Stripe

Create two products with four recurring prices and put the ids in env:

| Env var | Product | Interval | Default price (§2) |
|---|---|---|---|
| `STRIPE_PRICE_PRO_MONTH` | Navi Pro | monthly | $20 |
| `STRIPE_PRICE_PRO_YEAR` | Navi Pro | yearly | $192 |
| `STRIPE_PRICE_PRO_RECALL_MONTH` | Navi Pro + Recall | monthly | $30 |
| `STRIPE_PRICE_PRO_RECALL_YEAR` | Navi Pro + Recall | yearly | $288 |

Then: Developers → Webhooks → add `https://api.navi.app/billing/webhook` with events
`checkout.session.completed`, `customer.subscription.created`, `customer.subscription.updated`,
`customer.subscription.deleted`, `invoice.payment_failed` → `STRIPE_WEBHOOK_SECRET`.
Enable the Customer Portal (Settings → Billing → Customer portal). Locally:
`stripe listen --forward-to localhost:3100/billing/webhook`.

Checkout sessions carry `client_reference_id` = user id and `metadata.plan` on both the
session and the subscription, so the webhook can set `profiles.tier` even before the
`subscription.updated` event arrives. Status → tier: `active|trialing|past_due` keep the plan;
`canceled|unpaid|…` → free; `invoice.payment_failed` only marks `subscription_status = past_due`.

### 3. Vercel

Project root `cloud/`. Environment variables (see `.env.example` for all of them):

```
NAVI_CLOUD_BASE_URL=https://api.navi.app
SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_JWT_SECRET
TYPESAFE_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY   (or store them in /admin → Keys)
AI_GATEWAY_API_KEY                                (optional: Jev via Vercel AI Gateway)
ADMIN_EMAILS=liam@…                               (who may open /admin)
NAVI_KEYS_SECRET=$(openssl rand -base64 48)        (encrypts keys stored from /admin; ≥ 32 chars)
STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, STRIPE_PRICE_PRO_MONTH, STRIPE_PRICE_PRO_YEAR,
STRIPE_PRICE_PRO_RECALL_MONTH, STRIPE_PRICE_PRO_RECALL_YEAR
GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET            (optional)
```

Do **not** set `DEV_LOGIN_SECRET`, `MOCK_UPSTREAM` or `DB_DRIVER` on production.
`/v1/claude` declares `maxDuration = 300` for long streamed agent turns (Vercel Pro).

**Rate limits** (`lib/ratelimit.ts`): 120 req/min per user on `/v1/*`, 30/min per IP on `/auth/*`,
10/min on `/waitlist`, 5 sign-in emails + 10 code tries per address per 15 min. With Supabase
configured they are global (a `rate_limits` row per window, incremented by the atomic
`rate_limit_hit` RPC from `0003_account.sql`); without it, in process memory. The Postgres path
fails open onto memory if the database errors.

**The full go-live runbook — every env var, Supabase auth + email template, Google/Apple, Stripe,
domain, smoke, data inventory — is [`DEPLOY.md`](DEPLOY.md).**

## Admin console — `/admin`

Where Liam runs Navi as a product. Server-rendered (Next.js server components + server
actions), no client JS beyond the sign-in form and confirm prompts; dark, dense.

**Sign in.** `/admin/login` → Supabase magic link or Google (lands on `/admin/auth/callback`),
or in development the `DEV_LOGIN_SECRET` dev login. An **admin** is an email in `ADMIN_EMAILS`
or a row in `admins` (manage it on *Product config*). The console then sets its own cookie
`navi_admin` (HS256, audience `navi-admin`, 12 h, `HttpOnly; SameSite=Lax; Path=/admin`), signed
with a key derived from `ADMIN_SESSION_SECRET` (or `NAVI_KEYS_SECRET` / the Supabase secrets).
Admin status is re-checked on every request; every page, server action and route handler checks
it server-side and answers **404** to anyone else.

| Page | What it does |
|---|---|
| Overview | Signups today/7d/30d, active users today/7d, tier mix (as served), trials running, paying subs + MRR estimate (paying = `active`/`past_due` × monthly list price), vendor cost per day vs revenue run-rate (inline SVG), waitlist size. |
| Users | Search by email/id. Detail: profile, served tier, trial, Stripe customer (dashboard link) + status, entitlement grants, quota now, usage by feature with cost to date. Actions: tier override, grant/revoke entitlement with expiry, extend trial, reset today's quota / this month's tasks, disable/enable (→ 403 `account_disabled`), sign out all sessions (revokes refresh tokens; access tokens live out ≤ 1 h), delete (retype the email; cascades). |
| Keys | TypeSafe, Anthropic, Gemini, AI Gateway: source (database / env / none), masked last 4, last rotated, last used, last test. **Test** makes the cheapest real call (Anthropic/Gemini model list, one Jev noul) and shows OK/latency/error. **Store/Rotate** encrypts with AES-256-GCM (`NAVI_KEYS_SECRET`; refuses without it). **Remove** falls back to the env var. `lib/keys.ts` `getVendorKey()` = database key (60 s in-process cache) then env — what the proxy uses. |
| Product config | Kill switches (answers, tasks, voice, recall), in-app notice, `minAppVersion` / `latestVersion` / `downloadURL`, per-tier quota overrides, model per feature (answer / task / digest; empty = pass the app's `model` through), admins. `app_config` row `product`, cached 30 s per instance. |
| Waitlist | Search, CSV export (formula-safe), Invite (Supabase invite email → `downloadURL`) / Mark invited. |
| Audit log | Every admin action: actor, action, target, metadata (`admin_audit`). |

**Privacy.** The console shows metadata only. Navi Cloud never stores request or response
bodies; usage rows are (user, feature, run id, day, cost). Keys never reach the browser (only
`••••last4`), are never logged, and vendor error text is scrubbed of the key before display.

Locally: `MOCK_UPSTREAM=1 DEV_LOGIN_SECRET=dev ADMIN_EMAILS=you@example.com NAVI_KEYS_SECRET=$(openssl rand -base64 48) npm run dev`
→ http://localhost:3100/admin/login.

## Smoke walkthrough — `scripts/smoke.sh`

Against `MOCK_UPSTREAM=1 DEV_LOGIN_SECRET=dev npm run dev` it:

1. `GET /healthz`
2. `POST /auth/dev-login {email, trial:false}` → session tokens (Free tier, no trial)
3. `GET /v1/me` (and confirms a token-less call is 401)
4. `POST /v1/jev` with a real routing body (`route` — never capped)
5. `POST /v1/claude` streaming (prints the first SSE events) and non-streaming
6. `POST /v1/digest` → 403 `not_entitled`; `voice` on Free → 403
7. Runs 7 tasks, 3 calls each with the same `X-Navi-Run` → tasks 1–5 are 200s, 6–7 are 402s;
   the first (in-flight) run still gets 200 after the cap
8. Posts an unsigned `checkout.session.completed` to `/billing/webhook` (accepted only in mock
   dev mode) → `/v1/me` shows `pro`, tasks allowed again
9. `POST /auth/refresh`, a bogus `/auth/exchange` → 400, `/waitlist` → 201 then 200

Point it at any deployment with `NAVI_CLOUD_URL=https://… DEV_LOGIN_SECRET=… scripts/smoke.sh`
(with a real Supabase project, dev-login creates the user via the admin API and signs in
through a generated magic-link token).

## Notes for the Swift client

- All timestamps are ISO-8601 strings (`expiresAt`, `trialEndsAt`, `resetsAt`).
- `tier` in `/v1/me` is the effective tier: a trialing user sees `pro` + `trialEndsAt`.
- Stripe return: the app receives `navi://billing/success` / `navi://billing/cancel` exactly as
  in §3.1, via the `/billing/return` bridge page (Stripe requires http(s) return URLs).
- Sign-in failure lands on `navi://auth/callback?error=sign_in_failed&message=…`.
- Vendor errors (e.g. Anthropic 400/529) are passed through with their own status and body;
  Navi's own errors are the JSON shapes in the table above.

## Layout

```
app/            route handlers (paths match §3.1 exactly) + the /auth/start page
lib/plans.ts    tiers → entitlements → quotas, windows, resets  (pure, tested)
lib/metering.ts one unit per run, 402/403, cost, /v1/me body    (pure over Db, tested)
lib/billing.ts  price ids, Stripe event → profile mapping        (pure, tested) + SDK
lib/proxy.ts    auth → rate limit → meter → upstream/mock → cost; SSE passthrough
lib/db.ts       Db interface + memory driver; lib/db-supabase.ts the Postgres driver
lib/auth.ts     JWT verify (HS256 secret or cached JWKS); lib/sessions.ts issue/refresh
lib/mock.ts     canned Jev / Claude (JSON + SSE) / Gemini responses
lib/keys.ts     vendor keys: AES-256-GCM at rest, DB first then env, masked status, Test
lib/config.ts   product config: kill switches, notice, version gate, quota + model overrides
lib/admin/      console auth (cookie, guard), ops (+ audit), overview stats, Jev-via-gateway
app/admin/      the console (pages, server actions, /admin/auth/*)
supabase/migrations/0001_init.sql   schema + RLS + trigger + RPCs
supabase/migrations/0002_admin.sql  admin console tables + aggregates
scripts/smoke.sh                    the curl walkthrough
tests/                              vitest
```
