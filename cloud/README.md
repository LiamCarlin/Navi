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
   │   GET  /v1/me        → tier, entitlements, quotas, usage, resetsAt
   │   /auth/*            → Supabase Auth (magic link + Google) → navi://auth/callback?code=…
   │   /billing/*         → Stripe Checkout / Portal / webhook → profiles.tier
   └── POST /waitlist     → waitlist table (also used by web/)
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
| GET | `/v1/me` | Bearer | `{ user, tier, trialEndsAt?, entitlements, quotas, usage }` |
| POST | `/v1/jev` | Bearer | Body = exact TypeSafe `/v1/systemone` body. JSON passthrough. |
| POST | `/v1/claude` | Bearer | Body = exact Anthropic `/v1/messages` body. `stream:true` → SSE piped through unbuffered. Client `anthropic-version` / `anthropic-beta` headers are forwarded. |
| POST | `/v1/digest` | Bearer | Same as `/v1/claude`, needs the `recall` entitlement (403 `not_entitled`). With `GEMINI_API_KEY` set and body `provider:"gemini"`, forwards `{model?, ...generateContent body}` to Gemini instead. |
| GET | `/auth/start?redirect=navi` | – | Hosted sign-in page (magic link, "Continue with Google" when `GOOGLE_*` set). |
| GET | `/auth/callback` | – | Supabase lands here; mints a single-use 5-min code → `302 navi://auth/callback?code=…` (or `?error=sign_in_failed&message=…`). |
| POST | `/auth/exchange` | – | `{ code }` → `{ accessToken, refreshToken, expiresAt }` |
| POST | `/auth/refresh` | – | `{ refreshToken }` → same shape |
| POST | `/auth/dev-login` | secret | `{ email, trial?: false }` + header `x-dev-login-secret`. Dev only. |
| POST | `/billing/checkout` | Bearer | `{ plan: "pro"\|"pro_recall", interval: "month"\|"year" }` → `{ url }` |
| POST | `/billing/portal` | Bearer | → `{ url }` (400 `no_customer` before the first purchase) |
| POST | `/billing/webhook` | Stripe sig | `checkout.session.completed`, `customer.subscription.{created,updated,deleted}`, `invoice.payment_failed` |
| GET | `/billing/return?status=` | – | Bridge page → `navi://billing/success` or `navi://billing/cancel` |
| POST | `/waitlist` | – | `{ email, source?, note? }` → 201 new / 200 already listed |
| GET | `/healthz` | – | Which driver / vendors / mock mode are active |

### Headers the app sends on `/v1/*`

- `Authorization: Bearer <accessToken>` — Supabase JWT (1 h). Verified locally with the JWT
  secret (or a cached JWKS); no network call per request. 401 → refresh once → sign-in.
- `X-Navi-Feature: route | answer | task | voice | recall_triage | recall_digest`
  (default per route: jev→`route`, claude→`answer`, digest→`recall_digest`).
- `X-Navi-Run: <uuid>` — one usage unit per distinct run per feature, however many calls the
  run makes. Missing → each call is its own run.

Responses carry `X-Navi-Tier`, `X-Navi-Feature`, `X-Navi-Run` for debugging.

### Errors (§3.1)

| Status | Body |
|---|---|
| 401 | `{ error: "unauthenticated" }` |
| 402 | `{ error: "quota_exceeded", feature, tier, resetsAt }` |
| 403 | `{ error: "not_entitled", feature, tier }` |
| 429 | `{ error: "rate_limited", retryAfterSeconds }` + `Retry-After` |
| 503 | `{ error: "upstream_unconfigured" \| "billing_unconfigured" }` |
| 4xx/5xx from the vendor | passed through with the vendor's status and body |

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

## Tables — `supabase/migrations/0001_init.sql`

| Table | Purpose |
|---|---|
| `profiles(user_id, email, tier, trial_ends_at, stripe_customer_id, stripe_subscription_id, subscription_status)` | Created by trigger on `auth.users` insert (trial starts) — the API also upserts on first sight. |
| `entitlements(user_id, key, granted_by, expires_at)` | Manual grants on top of the tier. |
| `usage(user_id, feature, run_id, day, month, cost_usd)` | PK `(user_id, feature, run_id)` — one row per run. |
| `waitlist(email, source, note, created_at)` | Deduped on email. |
| `auth_codes(code, access_token, refresh_token, token_expires_at, expires_at)` | Single-use, 5-min TTL; `purge_expired_auth_codes()` for cron. |

RLS is on for all five; users can `select` their own profile/entitlements/usage; everything
else is service-role only. `add_usage_cost()` is a `security definer` RPC.

## Setting up for real

### 1. Supabase

1. Create a project. Copy **Project URL**, **anon key**, **service_role key** and
   (Settings → API) the **JWT Secret** into the env vars below.
2. Apply the schema: `supabase link --project-ref <ref> && supabase db push`
   (or paste `supabase/migrations/0001_init.sql` into the SQL editor).
3. Auth → URL configuration: **Site URL** = `https://api.navi.app`, add
   `https://api.navi.app/auth/callback` (and `http://localhost:3100/auth/callback`) to
   **Redirect URLs**.
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
TYPESAFE_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY
STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, STRIPE_PRICE_PRO_MONTH, STRIPE_PRICE_PRO_YEAR,
STRIPE_PRICE_PRO_RECALL_MONTH, STRIPE_PRICE_PRO_RECALL_YEAR
GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET            (optional)
```

Do **not** set `DEV_LOGIN_SECRET`, `MOCK_UPSTREAM` or `DB_DRIVER` on production.
`/v1/claude` declares `maxDuration = 300` for long streamed agent turns (Vercel Pro).

**Production swap before launch:** `lib/ratelimit.ts` is an in-process fixed window
(120 req/min per user on `/v1/*`, 30/min per IP on `/auth/*`, 10/min on `/waitlist`). On Vercel
each instance has its own memory, so replace `hit()` with Vercel KV / Upstash `INCR`+`EXPIRE`;
the call sites do not change.

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
supabase/migrations/0001_init.sql   schema + RLS + trigger + RPCs
scripts/smoke.sh                    the curl walkthrough
tests/                              vitest
```
