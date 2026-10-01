-- Navi Cloud — read-only billing tokens for the admin Overview (Vercel spend, Supabase plan and
-- add-ons) live in vendor_keys next to the AI vendor keys, encrypted the same way. Idempotent.

alter table public.vendor_keys drop constraint if exists vendor_keys_provider_check;
alter table public.vendor_keys add constraint vendor_keys_provider_check
  check (provider in ('typesafe', 'anthropic', 'gemini', 'ai_gateway', 'vercel', 'supabase'));
