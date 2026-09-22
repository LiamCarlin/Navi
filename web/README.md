# navi.app — marketing site + waitlist

Next.js 15 (App Router) · TypeScript · Tailwind 4 · framer-motion. No CMS, no auth.

```bash
cd web
npm install
npm run dev        # http://localhost:3000
npm run build      # type-checks and builds
npm run lint
```

## What's here

| Path | What |
|---|---|
| `app/page.tsx` | The single landing page: nav, hero (animated panel), features, Recall, voice, pricing, FAQ, waitlist, footer |
| `components/PanelDemo.tsx` | HTML/CSS recreation of the ⌘Space panel: cycling placeholder that types itself, results fade in |
| `app/api/waitlist/route.ts` | `POST { email, note?, source? }` → 201 created · 200 already on the list · 400 bad email · 500 storage error |
| `lib/waitlist.ts` | Storage: Supabase when configured, else `web/.waitlist.local.jsonl` (gitignored) |
| `app/opengraph-image.tsx` | OG image (the panel on dark), generated at build time |
| `app/icon.tsx`, `app/apple-icon.tsx` | Favicon / touch icon with the ✦ glyph |
| `app/privacy`, `app/terms` | Placeholder legal pages |

Copy rule: the site never names a model or an AI vendor. It is all "Navi".

## Environment

Copy `.env.example` to `.env.local`:

| Var | Purpose |
|---|---|
| `NEXT_PUBLIC_SITE_URL` | Canonical URL for metadata / OG (`https://navi.app`) |
| `SUPABASE_URL` | Supabase project URL |
| `SUPABASE_SERVICE_KEY` | Supabase **service role** key — server-only, never exposed to the client |

When `SUPABASE_URL` / `SUPABASE_SERVICE_KEY` are absent the waitlist route appends a JSON line
per signup to `web/.waitlist.local.jsonl` so the form works in dev with no setup.

### Supabase table

```sql
create table public.waitlist (
  email       text primary key,
  source      text not null default 'site',
  note        text,
  created_at  timestamptz not null default now()
);
alter table public.waitlist enable row level security;
-- No policies: only the service role (used by the API route) can read or write.
```

The route dedupes on `email` (the primary key; a `23505` unique violation is returned as 200).

## Deploy (Vercel)

1. `vercel link` from `web/` (or import the repo in the Vercel dashboard and set **Root Directory** to `web`).
2. Add the three env vars above in Project → Settings → Environment Variables (Production + Preview).
3. `vercel --prod` (or push to `main` with the Git integration).

Framework preset: Next.js. No extra build settings. `app/opengraph-image.tsx` and the icons run on the
edge runtime, so they render on Vercel without any extra config.

## Checks

- `npm run build` must pass with no type errors.
- Page renders at 375 px and 1440 px with no horizontal scroll.
- Submitting the waitlist form in dev lands a line in `.waitlist.local.jsonl`.
