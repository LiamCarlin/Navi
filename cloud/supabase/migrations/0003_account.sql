-- Navi Cloud — accounts: shared rate limits, sign-in codes tied to a user, the device list,
-- and the purge job. Idempotent (safe to re-run). Everything here is service-role only.

-- MARK: - rate_limits ------------------------------------------------------------
-- One row per (bucket, fixed window). `bucket` is "<limiter>:<key>", e.g. "user:<uuid>" or
-- "auth-ip:203.0.113.7". Windows are epoch-aligned, so every Vercel instance agrees.

create table if not exists public.rate_limits (
  bucket       text        not null,
  window_start timestamptz not null,
  window_end   timestamptz not null,
  count        integer     not null default 0,
  primary key (bucket, window_start)
);

create index if not exists rate_limits_window_end_idx on public.rate_limits (window_end);

alter table public.rate_limits enable row level security;
-- No policies: service role only.

-- Atomic hit: insert-or-increment in one statement and return the new count. Concurrent hits on
-- the same bucket serialize on the row lock, so the count is exact across instances.
create or replace function public.rate_limit_hit(p_bucket text, p_window_start timestamptz, p_window_seconds integer)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if p_window_seconds is null or p_window_seconds <= 0 then
    raise exception 'p_window_seconds must be positive';
  end if;
  insert into public.rate_limits as r (bucket, window_start, window_end, count)
  values (p_bucket, p_window_start, p_window_start + make_interval(secs => p_window_seconds), 1)
  on conflict (bucket, window_start) do update set count = r.count + 1
  returning r.count into n;
  return n;
end $$;

revoke all on function public.rate_limit_hit(text, timestamptz, integer) from public, anon, authenticated;
grant execute on function public.rate_limit_hit(text, timestamptz, integer) to service_role;

-- MARK: - auth_codes.user_id -----------------------------------------------------
-- So DELETE /v1/account can remove a code that was minted but never exchanged.

alter table public.auth_codes add column if not exists user_id uuid;
create index if not exists auth_codes_user_idx on public.auth_codes (user_id);

-- MARK: - devices ----------------------------------------------------------------
-- auth.sessions is not exposed over the API. /account lists a user's sessions (one per
-- signed-in Mac or browser) through this RPC: ids and timestamps only.

-- plpgsql (not sql) so the body is only checked when called: if a future auth schema renames a
-- column, the migration still applies and /account just shows no device list.
create or replace function public.account_sessions(p_user_id uuid)
returns table (id uuid, created_at timestamptz, last_active_at timestamptz)
language plpgsql stable security definer set search_path = auth, public as $$
begin
  return query
    select s.id,
           s.created_at,
           greatest(s.created_at, s.updated_at, s.refreshed_at::timestamptz) as last_active_at
      from auth.sessions s
     where s.user_id = p_user_id
       and (s.not_after is null or s.not_after > now())
     order by 3 desc nulls last;
end $$;

revoke all on function public.account_sessions(uuid) from public, anon, authenticated;
grant execute on function public.account_sessions(uuid) to service_role;

-- MARK: - purge ------------------------------------------------------------------
-- Called daily by Vercel Cron → GET /auth/purge. Expired sign-in codes, and rate-limit
-- windows that ended more than a day ago.

create or replace function public.navi_purge()
returns json language plpgsql security definer set search_path = public as $$
declare codes integer; limits integer;
begin
  delete from public.auth_codes where expires_at < now();
  get diagnostics codes = row_count;
  delete from public.rate_limits where window_end < now() - interval '1 day';
  get diagnostics limits = row_count;
  return json_build_object('auth_codes', codes, 'rate_limits', limits);
end $$;

revoke all on function public.navi_purge() from public, anon, authenticated;
grant execute on function public.navi_purge() to service_role;
