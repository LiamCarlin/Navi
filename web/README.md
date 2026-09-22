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
| `app/page.tsx` | The single landing page: nav, hero (MacBook + island loop), "Spotlight finds. Navi does.", "decides, not chats", voice, background mode, Recall, pricing, FAQ, waitlist, footer |
| `components/MacBook.tsx` | CSS/SVG 14" MacBook Pro in perspective with pointer tilt. The screen is a container; everything on it is sized in `--u` (see `.screen` in `globals.css`) |
| `components/HeroLoop.tsx` | The ~12 s hero loop as a pure function of time: island drops from the notch and ticks steps, then the ⌘Space bar shows task / calculator / app |
| `components/Island.tsx`, `components/Panel.tsx`, `components/Windows.tsx` | The voice island, the ⌘Space bar, and the mini macOS windows/notifications the demos use; all presentational and themed via CSS variables |
| `components/useLoop.ts` | Drives every looping demo as a pure function of elapsed time: starts in view, pauses off-screen, long rest so it plays once then loops slowly, one static frame under reduced motion, `seek()` for the chips |
| `components/Does.tsx`, `Decides.tsx`, `Talk.tsx`, `Background.tsx`, `Recall.tsx` | The five numbered story sections, each with its own timeline |
| `components/Section.tsx` | The 12-column story layout (narrow text column, wide visual, alternating) |
| `components/SeenOn.tsx`, `lib/seenOn.ts` | The "As seen on" press strip. Every entry ships `enabled: false`, so it renders nothing. **Flip `enabled: true` once Navi is actually posted there.** Logos are Simple Icons (CC0). |
| `components/WaitlistForm.tsx`, `StickyCTA.tsx`, `MidCTA.tsx`, `WaitlistCount.tsx`, `lib/source.ts` | The signup funnel: one form used in the hero, the sticky bar, the mid-page lines and the waitlist section; every CTA sends a `source` (`hero`, `sticky`, `mid-02`, `pricing-pro`, …, plus `.ref-<id>` from a `?ref=` link). After signup: place in line and share buttons. |
| `app/api/waitlist/count/route.ts` | `GET` → `{ count }`, cached 60 s; the page shows it only from 25 up |
| `components/Photo.tsx`, `public/img/`, `CREDITS.md` | The one photograph on the page and where it came from |
| `components/Nav.tsx` | Nav with the sun/moon theme toggle; `app/layout.tsx` sets `data-theme` on `<html>` before first paint (stored choice, else `prefers-color-scheme`) |
| `app/api/waitlist/route.ts` | `POST { email, note?, source?, ref? }` → 201 created · 200 already on the list · 400 bad email · 500 storage error; the body also carries `position` (list size) and `ref` (share id) |
| `lib/waitlist.ts` | Storage: Supabase when configured, else `web/.waitlist.local.jsonl` (gitignored) |
| `app/opengraph-image.tsx` | OG image (the MacBook with the island down), generated at build time |
| `app/icon.tsx`, `app/apple-icon.tsx` | Favicon / touch icon with the ✦ glyph |
| `app/privacy`, `app/terms` | Placeholder legal pages |

Copy rule: the site never names a model or an AI vendor. It is all "Navi".

Theme: dark and light are two real palettes in `app/globals.css` (`:root` and `[data-theme="light"]`, with a
`prefers-color-scheme` fallback for no-JS). The MacBook's wallpaper, the bar and the mini windows follow via
`--wall`, `--panel-*` and `--win-*`; the island stays black because it is the notch.

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
