-- Navi Cloud — initial schema.
-- Apply with `supabase db push` (or paste into the SQL editor). Every table has RLS on;
-- the API writes with the service role (bypasses RLS), users may read their own rows.

create extension if not exists pgcrypto;

-- MARK: - profiles ---------------------------------------------------------------

create type public.navi_tier as enum ('free', 'pro', 'pro_recall');

create table public.profiles (
  user_id                uuid primary key references auth.users (id) on delete cascade,
  email                  text not null,
  tier                   public.navi_tier not null default 'free',
  trial_ends_at          timestamptz,
  stripe_customer_id     text unique,
  stripe_subscription_id text,
  subscription_status    text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

create index profiles_stripe_customer_idx on public.profiles (stripe_customer_id);

alter table public.profiles enable row level security;

create policy "profiles: users read their own"
  on public.profiles for select
  using (auth.uid() = user_id);

-- Keep updated_at honest.
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

create trigger profiles_touch_updated_at
  before update on public.profiles
  for each row execute function public.touch_updated_at();

-- New sign-ups get a profile with a 7-day Pro trial the moment auth.users gets the row.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (user_id, email, tier, trial_ends_at)
  values (new.id, coalesce(new.email, ''), 'free', now() + interval '7 days')
  on conflict (user_id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- MARK: - entitlements -----------------------------------------------------------
-- Manual grants on top of the tier (comps, beta testers). Tier entitlements are
-- computed in code (lib/plans.ts); this table only ever adds.

create table public.entitlements (
  user_id    uuid not null references auth.users (id) on delete cascade,
  key        text not null check (key in ('answers', 'tasks', 'voice', 'recall')),
  granted_by text not null default 'admin',
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (user_id, key)
);

alter table public.entitlements enable row level security;

create policy "entitlements: users read their own"
  on public.entitlements for select
  using (auth.uid() = user_id);

-- MARK: - usage ------------------------------------------------------------------
-- One row per (user, feature, run). A task that makes 40 calls is one row.

create table public.usage (
  user_id    uuid not null references auth.users (id) on delete cascade,
  feature    text not null check (feature in ('route', 'answer', 'task', 'voice', 'recall_triage', 'recall_digest')),
  run_id     text not null,
  day        text not null,   -- 'YYYY-MM-DD' UTC
  month      text not null,   -- 'YYYY-MM'    UTC
  cost_usd   numeric(12, 8) not null default 0,
  created_at timestamptz not null default now(),
  primary key (user_id, feature, run_id)
);

create index usage_user_day_idx   on public.usage (user_id, day, feature);
create index usage_user_month_idx on public.usage (user_id, month, feature);

alter table public.usage enable row level security;

create policy "usage: users read their own"
  on public.usage for select
  using (auth.uid() = user_id);

-- Atomic cost accumulation after a proxied call.
create or replace function public.add_usage_cost(p_user_id uuid, p_feature text, p_run_id text, p_cost numeric)
returns void language sql security definer set search_path = public as $$
  update public.usage
     set cost_usd = cost_usd + coalesce(p_cost, 0)
   where user_id = p_user_id and feature = p_feature and run_id = p_run_id;
$$;

revoke all on function public.add_usage_cost(uuid, text, text, numeric) from public, anon, authenticated;

-- MARK: - waitlist ---------------------------------------------------------------

create table public.waitlist (
  email      text primary key,
  source     text,
  note       text,
  created_at timestamptz not null default now()
);

alter table public.waitlist enable row level security;
-- No policies: only the service role reads or writes the waitlist.

-- MARK: - auth_codes -------------------------------------------------------------
-- Single-use codes handed to the app via navi://auth/callback?code=…, 5-minute TTL.

create table public.auth_codes (
  code             text primary key,
  access_token     text not null,
  refresh_token    text not null,
  token_expires_at timestamptz not null,
  expires_at       timestamptz not null,
  created_at       timestamptz not null default now()
);

create index auth_codes_expires_idx on public.auth_codes (expires_at);

alter table public.auth_codes enable row level security;
-- No policies: service role only.

-- Housekeeping: run from a cron (pg_cron / Supabase scheduled function) or ad hoc.
create or replace function public.purge_expired_auth_codes()
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  delete from public.auth_codes where expires_at < now();
  get diagnostics n = row_count;
  return n;
end $$;
