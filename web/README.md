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
| `app/page.tsx` | The single landing page, in order: hero (typeable ⌘Space bar), the real recording, "One bar, seven kinds of answer", "What happens after you press ⏎", voice, background mode, app playbooks, Recall, privacy, pricing, FAQ, waitlist |
| `lib/motion.ts`, `components/motion/*` | The motion system: one curve (`EASE`), three durations, one entrance (`Reveal`: rise + unblur), masked headline lines (`Lines`), Lenis smooth scrolling (`SmoothScroll`, off under reduced motion), the gradient read-progress hairline |
| `components/bar/Bar.tsx` | The ⌘Space bar drawn from the app's `PanelStyle` (680 pt, 28 pt corners, 64 pt bar, 52 pt rows, key-hint footer) plus its bodies: rows, answer, calculator, task steps + approval, scheduler card, reminder card, Recall answer. Sized in `--u` inside a `.stage` |
| `components/bar/LiveBar.tsx`, `lib/demo.ts` | The hero bar: types scripted examples and routes on every keystroke; click it and a toy router in `lib/demo.ts` decides what Navi would do with anything typed. The page says it's a demo |
| `components/Film.tsx` | `public/video/demo.mp4` (a real screen recording) in the CSS MacBook; tilts flat as it scrolls in; chapters seek the video |
| `components/Kinds.tsx` | Pinned scrollytelling: steps scroll on the left, the bar on the right changes to match (phones: a bar per step) |
| `components/Anatomy.tsx` | One task scrubbed by the scroll on three lanes (your Mac / decides / writes); phones get a vertical list |
| `components/Voice.tsx` | Dark stage (`.stage-dark`) that opens to full bleed, then pins while the island hears a sentence and splits it into three jobs. The nav and sticky bar switch palette over it (`lib/useOverDark.ts`) |
| `components/Background.tsx`, `Apps.tsx`, `Recall.tsx`, `Privacy.tsx` | Background mode + what it asks before; the playbook marquee and habits/people/browser cards; the notes graph, pipeline and personal-data switches; what stays on the Mac vs. what's sent |
| `components/MacBook.tsx`, `components/Windows.tsx` | CSS 14" MacBook Pro and mini macOS windows |
| `components/SeenOn.tsx`, `lib/seenOn.ts` | The "As seen on" press strip. Every entry ships `enabled: false`, so it renders nothing. **Flip `enabled: true` once Navi is actually posted there.** |
| `components/WaitlistForm.tsx`, `StickyCTA.tsx`, `WaitlistCount.tsx`, `lib/source.ts` | The signup funnel: one form used in the hero, the sticky bar (a button on phones) and the waitlist section; every CTA sends a `source` (`hero`, `sticky`, `pricing-pro`, …, plus `.ref-<id>` from a `?ref=` link). After signup: place in line and share buttons |
| `app/api/waitlist/route.ts`, `app/api/waitlist/count/route.ts`, `lib/waitlist.ts` | Signup + count; Supabase when configured, else `web/.waitlist.local.jsonl` |
| `components/Nav.tsx` | Nav with the active-section underline and the sun/moon theme toggle; `app/layout.tsx` sets `data-theme` before first paint |
| `app/opengraph-image.tsx`, `app/icon.tsx`, `app/apple-icon.tsx` | OG image and icons |

Copy rules: the site never names a model or an AI vendor; it is all "Navi". Claims about what is sent off the Mac
must match the app (typed queries are routed by the server; local rows don't wait for it). Type: Newsreader for
headlines, Geist for interface, Geist Mono for timings and footnotes.

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
