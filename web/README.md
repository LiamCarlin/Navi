# buildnavi.com — marketing site + waitlist

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
| `app/page.tsx` | The single landing page, in order: hero (sky + real recording), app strip, "How Navi helps" (type / say), "One bar, seven kinds of answer", stats, "What happens after you press ⏎", voice, background mode, habits, Recall, privacy, pricing, FAQ, waitlist band |
| `app/globals.css` | One light palette: white page, ink→slate gradient titles, blue pill buttons, pale blue-grey cards (`.card`), a bright blue card (`.card-blue`), light and dark glass, the sunset wallpaper (`--wall`) in Navi's colours |
| `lib/motion.ts`, `components/motion/*` | The motion system: one curve (`EASE`), three durations, one entrance (`Reveal`: rise + unblur), masked title lines (`Lines`) and the centred section header (`Head`), Lenis smooth scrolling (`SmoothScroll`, off under reduced motion), the read-progress hairline |
| `components/Sky.tsx`, `components/Hero.tsx` | The hero sky: gradient, sun, drifting clouds, three seeded SVG mountain ranges that part on scroll. `public/video/demo.mp4` (a real screen recording) rises out of it; chips seek the video |
| `components/bar/Bar.tsx` | The ⌘Space bar drawn from the app's `PanelStyle` plus its bodies: rows, answer, calculator, task steps + approval, scheduler card, reminder card, Recall answer. Sized in `--u` inside a `.stage` |
| `components/bar/LiveBar.tsx`, `lib/demo.ts` | The typeable bar on the blue card: scripted examples routed on every keystroke; click it and a toy router decides what Navi would do with anything typed. The page says it's a demo |
| `components/TypeTalk.tsx`, `Kinds.tsx`, `Stats.tsx`, `Anatomy.tsx`, `Voice.tsx`, `Background.tsx`, `Apps.tsx`, `Recall.tsx`, `Privacy.tsx` | The story sections. `Kinds`, `Anatomy` and `Voice` pin and are driven by the scroll; phones get stacked versions where pinning doesn't fit |
| `components/SeenOn.tsx`, `lib/seenOn.ts` | The "As seen on" press strip. Every entry ships `enabled: false`, so it renders nothing. **Flip `enabled: true` once Navi is actually posted there.** |
| `components/WaitlistForm.tsx`, `Waitlist.tsx`, `WaitlistCount.tsx`, `lib/source.ts` | The signup funnel: the glass pill in the hero and the full form in the closing band; every CTA sends a `source` (`hero`, `waitlist`, `pricing-pro`, …, plus `.ref-<id>` from a `?ref=` link). After signup: place in line and share buttons |
| `app/api/waitlist/route.ts`, `app/api/waitlist/count/route.ts`, `lib/waitlist.ts` | Signup + count; Supabase when configured, else `web/.waitlist.local.jsonl` |
| `components/Nav.tsx` | Fixed nav: white over the sky, white glass once the hero is behind you |
| `app/opengraph-image.tsx`, `app/icon.tsx`, `app/apple-icon.tsx` | OG image and icons |

Copy rules: the site never names a model or an AI vendor; it is all "Navi". Claims about what is sent off the Mac
must match `app/privacy/page.tsx`. Type: EB Garamond for the hero headline only, Geist for everything else, Geist
Mono for timings.

## Environment

Copy `.env.example` to `.env.local`:

| Var | Purpose |
|---|---|
| `NEXT_PUBLIC_SITE_URL` | Canonical URL for metadata / OG (`https://buildnavi.com`) |
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
