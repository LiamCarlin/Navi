-- Navi Cloud — admin console (/admin).
-- Apply after 0001_init.sql: `supabase db push` (or paste into the SQL editor).
-- Every new table has RLS on and NO policies: only the service role (the API) reads or
-- writes them. Nothing here stores request or response bodies — metadata only.

-- MARK: - profiles: override, disable, quota reset ---------------------------------

alter table public.profiles
  add column if not exists tier_override   public.navi_tier,
  add column if not exists disabled_at     timestamptz,
  add column if not exists disabled_reason text,
  add column if not exists quota_reset     jsonb;

comment on column public.profiles.tier_override   is 'Admin override; wins over the paid tier and the trial.';
comment on column public.profiles.disabled_at     is 'Set ⇒ every /v1/* call is 403 account_disabled.';
comment on column public.profiles.disabled_reason is 'Internal note; never sent to the user.';
comment on column public.profiles.quota_reset     is 'Units already spent when an admin reset the quota: {day, answersDay, tasksDay, month, tasksMonth}.';

-- MARK: - waitlist: invites -----------------------------------------------------------

alter table public.waitlist add column if not exists invited_at timestamptz;

-- MARK: - admins ------------------------------------------------------------------------
-- Admin = email in ADMIN_EMAILS (env) OR a row here.

create table if not exists public.admins (
  email      text primary key check (email = lower(email)),
  added_by   text not null default 'sql',
  created_at timestamptz not null default now()
);

alter table public.admins enable row level security;

-- MARK: - vendor_keys -----------------------------------------------------------------------
-- AES-256-GCM ciphertext (key derived from NAVI_KEYS_SECRET, never stored here).
-- ciphertext null ⇒ metadata-only row (last used / last test) for a key that lives in env.

create table if not exists public.vendor_keys (
  provider             text primary key check (provider in ('typesafe', 'anthropic', 'gemini', 'ai_gateway')),
  ciphertext           text,
  last4                text,
  rotated_at           timestamptz,
  rotated_by           text,
  last_used_at         timestamptz,
  last_test_at         timestamptz,
  last_test_ok         boolean,
  last_test_latency_ms integer,
  last_test_error      text
);

alter table public.vendor_keys enable row level security;

-- MARK: - app_config --------------------------------------------------------------------------
-- One JSON document per key; the console uses key 'product' (lib/config.ts).

create table if not exists public.app_config (
  key        text primary key,
  value      jsonb not null,
  updated_by text,
  updated_at timestamptz not null default now()
);

alter table public.app_config enable row level security;

-- MARK: - admin_audit -------------------------------------------------------------------------

create table if not exists public.admin_audit (
  id      bigint generated always as identity primary key,
  actor   text not null,
  action  text not null,
  target  text,
  details jsonb not null default '{}'::jsonb,
  at      timestamptz not null default now()
);

create index if not exists admin_audit_at_idx on public.admin_audit (at desc);

alter table public.admin_audit enable row level security;

-- MARK: - usage aggregates (so the console never pulls raw usage rows) --------------------

create index if not exists usage_day_idx on public.usage (day);

create or replace function public.admin_usage_daily(p_since text)
returns table (day text, active_users bigint, runs bigint, cost_usd numeric)
language sql stable security definer set search_path = public as $$
  select u.day, count(distinct u.user_id), count(*), coalesce(sum(u.cost_usd), 0)
    from public.usage u
   where u.day >= p_since
   group by u.day
   order by u.day;
$$;

create or replace function public.admin_active_users(p_since text)
returns bigint
language sql stable security definer set search_path = public as $$
  select count(distinct u.user_id) from public.usage u where u.day >= p_since;
$$;

create or replace function public.admin_usage_by_feature(p_user_id uuid)
returns table (feature text, runs bigint, cost_usd numeric, last_day text)
language sql stable security definer set search_path = public as $$
  select u.feature, count(*), coalesce(sum(u.cost_usd), 0), max(u.day)
    from public.usage u
   where u.user_id = p_user_id
   group by u.feature
   order by count(*) desc;
$$;

-- "Sign out all sessions": deleting auth.sessions revokes every refresh token
-- (auth.refresh_tokens cascades). Access tokens already issued live out their ≤ 1 h.
create or replace function public.admin_sign_out_user(p_user_id uuid)
returns integer
language plpgsql security definer set search_path = public, auth as $$
declare n integer;
begin
  delete from auth.sessions where user_id = p_user_id;
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.admin_usage_daily(text)       from public, anon, authenticated;
revoke all on function public.admin_active_users(text)      from public, anon, authenticated;
revoke all on function public.admin_usage_by_feature(uuid)  from public, anon, authenticated;
revoke all on function public.admin_sign_out_user(uuid)     from public, anon, authenticated;
grant execute on function public.admin_usage_daily(text)      to service_role;
grant execute on function public.admin_active_users(text)     to service_role;
grant execute on function public.admin_usage_by_feature(uuid) to service_role;
grant execute on function public.admin_sign_out_user(uuid)    to service_role;
