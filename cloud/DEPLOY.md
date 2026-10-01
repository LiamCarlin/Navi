# Deploying Navi Cloud

The exact runbook to take `cloud/` live on Vercel against the existing Supabase project
**`oqvuejmxkkfaogelwraz`** (the one the marketing site's waitlist already writes to). Do the steps
in order; each ends with a check. Nothing here needs a code change.

```
Navi.app ─┐                          ┌─ Supabase oqvuejmxkkfaogelwraz (Auth + Postgres)
Browser ──┼─▶ Vercel project ────────┼─ Stripe (Checkout, Portal, webhook)
web/ ─────┘   navi-cloud (cloud/)    └─ vendor APIs (server-side keys only)
```

**Order of operations:** 1 Supabase schema → 2 Supabase auth → 3 email → 4 Google / Apple
(optional) → 5 Stripe (test mode first) → 6 Vercel project + env → 7 deploy a preview → 8 smoke
→ 9 production + domain → 10 post-launch checks. §11 is the data inventory (what is stored, where,
for how long), §12 day-two operations.

---

## 1. Supabase — schema

The project already has `public.waitlist(email, source, note, created_at)` with real signups.
Every migration here is guarded (`if not exists`, `create or replace`, `drop … if exists`) so it
applies on top of that table without touching its rows, and can be re-run safely.

1. Supabase dashboard → project `oqvuejmxkkfaogelwraz` → **SQL Editor** → New query.
2. Paste and run each file **in order**, one at a time:
   1. `supabase/migrations/0001_init.sql` — profiles (+ 7-day trial trigger on `auth.users`),
      entitlements, usage, auth_codes; guards the existing waitlist.
   2. `supabase/migrations/0002_*.sql` — the admin back end's migration (if present on `main`).
   3. `supabase/migrations/0003_account.sql` — `rate_limits` + `rate_limit_hit()`,
      `auth_codes.user_id`, `account_sessions()`, `navi_purge()`.

   (Alternative: `supabase link --project-ref oqvuejmxkkfaogelwraz && supabase db push` from
   `cloud/`. Either works; don't mix them on the same day.)
3. **Check** (SQL Editor):
   ```sql
   select count(*) from public.waitlist;                         -- unchanged
   select tablename, rowsecurity from pg_tables where schemaname = 'public' order by 1;  -- all true
   select public.rate_limit_hit('deploy-check', date_trunc('minute', now()), 60);         -- 1, then 2…
   select public.navi_purge();                                    -- {"auth_codes":0,"rate_limits":…}
   ```

Verified before merge on Postgres seeded like this project (existing waitlist row): 0001 and 0003
each applied twice, the trigger starts a trial, 10 concurrent `rate_limit_hit` calls count to 10,
RPCs are executable by `service_role` only, RLS is on for every table, deleting an auth user
cascades to its rows.

## 2. Supabase — keys and auth settings

**Settings → API Keys** (copy into Vercel in §6):

| Value | Vercel env var |
|---|---|
| Project URL `https://oqvuejmxkkfaogelwraz.supabase.co` | `SUPABASE_URL` |
| `anon` key (or the new `sb_publishable_…`) | `SUPABASE_ANON_KEY` |
| `service_role` key (or the new `sb_secret_…`) — **secret** | `SUPABASE_SERVICE_ROLE_KEY` |

**Settings → JWT Keys** — decides how bearer tokens are verified (no network call per request):

- **"JWT Signing Keys" shows a current ECC (P-256) / RSA key** (the default for projects created
  in 2025+): leave `SUPABASE_JWT_SECRET` **unset**. The API verifies against
  `https://oqvuejmxkkfaogelwraz.supabase.co/auth/v1/.well-known/jwks.json` automatically (set
  `SUPABASE_JWKS_URL` only to override). Tested: `tests/auth.test.ts` "asymmetric keys".
- **Only the legacy HS256 "JWT Secret" exists:** set `SUPABASE_JWT_SECRET` to it.
- **Migrating from legacy to signing keys:** set both. Each token's own `alg` picks the path, so
  sessions issued before the switch keep working until they expire.

**Authentication → URL Configuration**

- **Site URL:** the cloud's public URL — `https://api.navi.app` once the domain exists (§9), the
  `*.vercel.app` production URL until then. (Redirects to the Site URL's host are always allowed.)
- **Redirect URLs** (add all):
  - `https://api.navi.app/**`
  - `https://navi-cloud-*-liam-carlins-projects.vercel.app/**` (preview deployments)
  - `http://localhost:3100/**` (local dev against the real project)

**Authentication → Sign In / Providers → Email**

- Enable Email provider: **on**. Confirm email: **on**. Secure email change: on.
- **Email OTP Length: 6.** **Email OTP Expiration: 3600** seconds.
- "Allow new users to sign up": **on** at launch (off ⇒ the page says "Sign-ups are closed").

**Authentication → Rate Limits:** raise "Emails sent per hour" once custom SMTP is in (§3) —
e.g. 100. Navi Cloud already limits each address to 5 emails / 15 min and each IP to 30 auth
requests / min, so this is only a global ceiling.

## 3. Email — SMTP and templates

Supabase's built-in mailer only delivers to the project's team members, a few per hour. Real users
need custom SMTP:

1. Create an SMTP sender (Resend, Postmark or SES), verify the sending domain (`navi.app`: the
   SPF/DKIM records they give you, plus a DMARC record).
2. Supabase → **Authentication → Emails → SMTP Settings**: enable custom SMTP, sender
   `hello@navi.app`, sender name `Navi`, host/port/user/password from the provider.

**Templates** (Authentication → Emails → Templates). One email carries both a link and a 6-digit
code. The link uses `token_hash`, so it works in *any* browser — the default `{{ .ConfirmationURL }}`
only works in the browser that asked for it. Paste the same body into **both "Magic Link" and
"Confirm signup"** (a first-time address gets "Confirm signup"):

Subject: `Your Navi sign-in code: {{ .Token }}`

```html
<div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:440px;margin:0 auto;padding:32px 24px;color:#111">
  <div style="font-size:15px;font-weight:600;letter-spacing:-0.01em">✦ Navi</div>
  <h1 style="font-size:22px;font-weight:600;margin:24px 0 8px">Sign in to Navi</h1>
  <p style="color:#555;margin:0 0 24px;line-height:1.5">Click the button on the Mac you’re signing in on, or type this code where you asked for it.</p>
  <p style="margin:0 0 24px">
    <a href="{{ .SiteURL }}/auth/callback?token_hash={{ .TokenHash }}&type=email&next={{ .RedirectTo }}"
       style="display:inline-block;background:#111;color:#fff;text-decoration:none;padding:12px 22px;border-radius:999px;font-weight:500">Sign in</a>
  </p>
  <div style="font-size:30px;font-weight:600;letter-spacing:0.3em;font-variant-numeric:tabular-nums;margin:0 0 24px">{{ .Token }}</div>
  <p style="color:#888;font-size:13px;line-height:1.5;margin:0">The link and code work once and expire in an hour. If you didn’t ask to sign in, ignore this email — nothing happens without it.</p>
</div>
```

`next={{ .RedirectTo }}` carries whether the sign-in was started by the app or by the account
page; `/auth/callback` reads it. The button always opens the **Site URL**'s host, so when testing
on a preview deployment, type the code instead of clicking the button. **Check:** after §7, ask for a code on the preview's
`/auth/start`, and confirm both the button and the typed code sign you in.

## 4. Google and Apple (optional)

The buttons on `/auth/start` appear on their own once a provider is enabled in Supabase (read
from `/auth/v1/settings`, cached 5 min). `AUTH_PROVIDERS=google,apple` (or empty) overrides that.

**Google**
1. Google Cloud console → APIs & Services → OAuth consent screen: app name **Navi**, support email,
   logo, `navi.app` as authorized domain, scopes `openid email profile`. Publish (External).
2. Credentials → Create OAuth client ID → Web application. Authorized redirect URI:
   `https://oqvuejmxkkfaogelwraz.supabase.co/auth/v1/callback`.
3. Supabase → Authentication → Providers → Google: enable, paste client ID + secret.
4. The consent screen shows the `supabase.co` domain until a Supabase custom domain is set up
   (paid add-on; optional).

**Apple** (needs the Apple Developer Program)
1. developer.apple.com → Identifiers → **Services ID** (e.g. `app.navi.signin`) → enable Sign in
   with Apple → domain `oqvuejmxkkfaogelwraz.supabase.co`, return URL
   `https://oqvuejmxkkfaogelwraz.supabase.co/auth/v1/callback`.
2. Keys → new key with Sign in with Apple → download the `.p8` (once).
3. Supabase → Authentication → Providers → Apple: enable, Services ID as client ID, generate the
   client secret from Team ID + Key ID + `.p8` (the dashboard links a generator).
4. **Calendar reminder:** Apple client secrets expire after 6 months — regenerate before then or
   Apple sign-in stops working.

## 5. Stripe

Start in **test mode**; repeat in live mode at launch.

1. Products → **Navi Pro** with prices $20/month and $192/year; **Navi Pro + Recall** with $30/month
   and $288/year. Copy the four price IDs into `STRIPE_PRICE_PRO_MONTH`, `STRIPE_PRICE_PRO_YEAR`,
   `STRIPE_PRICE_PRO_RECALL_MONTH`, `STRIPE_PRICE_PRO_RECALL_YEAR`.
2. Developers → API keys → secret key → `STRIPE_SECRET_KEY` (a restricted key works: write on
   Checkout Sessions, Customers, Subscriptions, Customer portal).
3. Developers → Webhooks → Add endpoint `https://<cloud>/billing/webhook`, events
   `checkout.session.completed`, `customer.subscription.created`, `customer.subscription.updated`,
   `customer.subscription.deleted`, `invoice.payment_failed` → signing secret →
   `STRIPE_WEBHOOK_SECRET`.
4. Settings → Billing → **Customer portal**: activate; allow switching between the two products,
   updating payment methods, viewing invoices, cancelling (at period end). Business name Navi,
   privacy + terms links to the site.
5. Settings → Branding: name Navi, icon, accent `#8b8cf8`.

`/account` hides Upgrade / Manage billing until `STRIPE_SECRET_KEY` is set and shows "Paid plans
open soon" — so the cloud can launch before billing. Deleting an account cancels its
subscriptions immediately and deletes the Stripe customer (card details); invoices stay in Stripe
for tax records.

## 6. Vercel — project and environment

1. Vercel → Add New → Project → name **`navi-cloud`**, team `liam-carlins-projects`, framework
   Next.js, **root directory `cloud`**, Node.js 20+. (Connecting the GitHub repo is the permanent fix
   for the commit-author block; until then use `scripts/deploy.sh`, §7.)
2. Settings → Functions → **Region:** the region of the Supabase project (Supabase → Settings →
   General). Every request makes a few database round trips; same region keeps them ~1 ms.
3. Plan: **Pro** is needed for `/v1/claude`'s `maxDuration = 300` (long streamed agent turns).
4. Settings → Environment Variables:

| Variable | Prod | Preview | Where it comes from |
|---|---|---|---|
| `NAVI_CLOUD_BASE_URL` | ✓ | – | The public URL, e.g. `https://api.navi.app`. Previews fall back to `VERCEL_URL`. |
| `SUPABASE_URL` | ✓ | ✓ | §2 |
| `SUPABASE_ANON_KEY` | ✓ | ✓ | §2 |
| `SUPABASE_SERVICE_ROLE_KEY` | ✓ | ✓ | §2 — secret |
| `SUPABASE_JWT_SECRET` | only if legacy | same | §2 — leave unset on signing-key projects |
| `SUPABASE_JWKS_URL` | optional | optional | §2 — only to override the derived URL |
| `TYPESAFE_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY` | ✓ | optional | The vendor dashboards. Server-side only; rotate the ones in your local Keychain afterwards. |
| `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` | ✓ live | ✓ test | §5 — a separate webhook endpoint per environment |
| `STRIPE_PRICE_PRO_MONTH`, `…_PRO_YEAR`, `…_PRO_RECALL_MONTH`, `…_PRO_RECALL_YEAR` | ✓ live | ✓ test | §5 |
| `CRON_SECRET` | ✓ | – | `openssl rand -hex 32`. Vercel Cron sends it to `/auth/purge`. |
| `NAVI_DOWNLOAD_URL` | ✓ | ✓ | The latest notarized DMG (`scripts/release.sh` output). Unset → "download opens soon". |
| `NAVI_SITE_URL` | ✓ | ✓ | `https://navi.app` (Privacy/Terms links on the hosted pages). |
| `AUTH_PROVIDERS` | optional | optional | `google,apple` to force the buttons; unset = whatever Supabase has enabled. |
| `MOCK_UPSTREAM`, `DEV_LOGIN_SECRET` | **never** | for smoke only | Preview-only, to run `scripts/smoke.sh` without vendor cost (§8). Dev login is refused on production deployments regardless. |
| `DB_DRIVER`, `DEV_JWT_SECRET` | **never** | **never** | Local development only. |

Admin back-end variables are documented with the admin routes (see `README.md`).

**Check:** `curl https://<deployment>/healthz` → `"db":"supabase"`, `"mockUpstream":false`,
`"devLogin":false` on production.

## 7. Deploy

`vercel deploy` from inside this git repo is blocked by the commit-author check. `scripts/deploy.sh`
copies `cloud/` to `~/.cache/navi-cloud-deploy` (outside any repo), runs the tests and typecheck
first, links the copy to the `navi-cloud` project once, and deploys from there. No `.env*` file is
uploaded; all configuration comes from §6.

```bash
cd cloud
scripts/deploy.sh            # preview → prints the URL
scripts/deploy.sh --prod     # production (refuses uncommitted changes unless --force)
```

`vercel.json` registers the daily cron (`GET /auth/purge` at 04:17 UTC).

## 8. Smoke test

**On a preview** (with `MOCK_UPSTREAM=1` and a random `DEV_LOGIN_SECRET` set for *Preview* only):

```bash
NAVI_CLOUD_URL=https://navi-cloud-<hash>-liam-carlins-projects.vercel.app \
DEV_LOGIN_SECRET=<preview secret> \
VERCEL_BYPASS=<Settings → Deployment Protection → Protection Bypass for Automation> \
scripts/smoke.sh
```

It signs a fresh `smoke+<ts>@navi.local` user in through the real Supabase (admin API + magic-link
token), walks `/v1/me`, `/v1/jev`, `/v1/claude` (streamed and not), the 403/402 gates, the webhook
(skipped when the signature is enforced), refresh, exchange, waitlist, then **exports and deletes
the account** (its waitlist row included) and checks export → 401 and refresh → 401 afterwards.
Nothing is left behind except Supabase's auth audit-log lines.

**On production** (no dev login there), by hand:

1. `curl -sI https://api.navi.app/auth/start | grep -iE 'content-security|strict-transport|x-frame'`.
2. Open `https://api.navi.app/auth/start?redirect=account`, sign in with your email: once with
   the link, once with the typed code (sign out between). Land on `/account`.
3. In Navi on the Mac: Settings → Account → Sign in → the browser → "Open Navi" → signed in.
4. Stripe **test** mode: Upgrade → card `4242 4242 4242 4242` → back on `/account?billing=success`,
   plan Pro; Manage billing opens the portal.
5. Export my data → the JSON has your profile, usage and (if you signed up there) waitlist row.
6. Vercel → Settings → Cron Jobs → `/auth/purge` → Run → logs show `purge: N auth codes, M rate-limit rows`.
7. Delete a throwaway account from `/account` → `/account/deleted`; its sign-in on the Mac stops at
   the next refresh.

## 9. Custom domain

1. Vercel → `navi-cloud` → Settings → Domains → add `api.navi.app` → at the DNS host:
   `CNAME api → cname.vercel-dns.com`.
2. Then update, in this order: `NAVI_CLOUD_BASE_URL`; Supabase Site URL (+ Redirect URLs); the
   Stripe webhook endpoint URL; the app's default `cloudBaseURL`; `web/`'s
   `NEXT_PUBLIC_NAVI_CLOUD_URL`. Redeploy `cloud/` and `web/`.
3. `web/` launch switches (Vercel project `navi-site`): `NEXT_PUBLIC_NAVI_CLOUD_URL=https://api.navi.app`
   adds "Sign in" and "Account" links; `NEXT_PUBLIC_SIGNUPS_OPEN=1` turns the waitlist buttons into
   "Get Navi" / "Start free trial" and adds "Download".

## 10. Security posture (what is already in the code)

- **Headers** on every response (`next.config.ts`): CSP `default-src 'self'; connect-src 'self';
  frame-ancestors 'none'; object-src 'none'; base-uri 'none'; form-action 'self'`, HSTS (2 years,
  subdomains), `X-Frame-Options: DENY`, `nosniff`, `Referrer-Policy: no-referrer`, COOP, a
  Permissions-Policy that denies camera/mic/location. The sign-in page never talks to Supabase from
  the browser — every auth call is server-side — so `connect-src 'self'` holds.
- **Rate limits** (shared across instances through Postgres, fail-open to per-instance memory if
  the database blips): 120 req/min per user on `/v1/*` and account routes, 30/min per IP on
  `/auth/*`, 10/min per IP on `/waitlist`, 5 sign-in emails and 10 code attempts per address per
  15 min.
- **Sessions:** the app gets tokens only through a single-use, 5-minute code
  (`navi://auth/callback?code=` → `POST /auth/exchange`). The web portal uses an `HttpOnly`,
  `SameSite=Lax`, `Secure` cookie; cookie-authenticated writes also require a same-origin `Origin`.
  Supabase's own `sb-*` cookies are cleared after every sign-in.
- **Tokens** are verified locally (JWKS or secret), with `aud = authenticated` and the user role
  required; the project's anon/service keys (also JWTs) are rejected.
- "Sign out everywhere" revokes every refresh token at once; access tokens already issued stay
  valid for at most an hour (they are verified without a network call).

## 11. Data inventory — what Navi Cloud stores

**Never stored, anywhere in the cloud:** what the user typed or said, prompts, answers, model
responses, screenshots, OCR text, anything Recall captures. `/v1/jev`, `/v1/claude` and
`/v1/digest` pass bodies straight through to the vendor and back (`lib/proxy.ts`); the only thing
read from a response is the token count, to price the run. No log line in `app/` or `lib/`
contains a request or response body, a token or an OCR string (they log error messages, route
paths and counts). Recall's memory never leaves the Mac except as the digest requests it makes,
which are passed through, not kept.

| Data | Where | Contents | Kept for | Deleted by DELETE /v1/account |
|---|---|---|---|---|
| Account | Supabase `auth.users` | email, sign-in provider, timestamps | until deleted | ✓ |
| Sessions | Supabase `auth.sessions` / refresh tokens | per device: created/refreshed time, IP, user agent (Supabase's) | until signed out / expired | ✓ |
| Profile | `public.profiles` | email, plan, trial end, Stripe customer/subscription id + status | until deleted | ✓ |
| Grants | `public.entitlements` | manual feature grants (comps, beta) | until deleted | ✓ |
| Usage | `public.usage` | per run: feature, run id, day, month, cost in USD | until deleted | ✓ |
| Waitlist | `public.waitlist` | email, signup source, optional note | until deleted | ✓ |
| Sign-in codes | `public.auth_codes` | session tokens for ≤ 5 min until the app swaps them | single use; expired rows purged daily | ✓ |
| Rate limits | `public.rate_limits` | user id or IP + a counter per minute | purged daily after 1 day | expires |
| Auth audit log | Supabase `auth.audit_log_entries` | sign-in / sign-out events (email, IP) | Supabase's retention | ✗ — purge by hand if asked |
| Billing | Stripe | customer email, card (at Stripe), invoices | Stripe / tax law | customer deleted; invoices kept |
| Request logs | Vercel | method, path, status, IP, timing (no bodies) | plan's log retention (1–30 days) | expires |
| Emails | SMTP provider | recipient + delivery status of sign-in mails | provider retention | expires |

Users get all of the above that belongs to them from **Export my data** (`GET /v1/account/export`),
and remove it with **Delete account** (`DELETE /v1/account`: Stripe first — if cancelling fails
nothing is deleted — then the rows, then the auth user).

## 12. Day two

- **Rotate a vendor key:** change it in Vercel → redeploy (no app update needed).
- **Close sign-ups:** Supabase → Authentication → "Allow new users to sign up" off.
- **Revoke someone:** Supabase → Authentication → Users → the user → "Sign out" (or delete); they
  lose access within the hour.
- **Rate limiter health:** if logs show `rate limiter "…" fell back to memory`, the RPC is failing
  (check that 0003 was applied); requests keep flowing meanwhile.
- **Apple client secret** expires every 6 months (§4).
- **Rollback:** Vercel → Deployments → the previous production deployment → Promote. The schema is
  additive, so older builds keep working against it.
