-- Escape Room Charts: price alerts table, one row per alert, private to each account.
create table if not exists public.alerts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  pair text not null check (pair ~ '^[A-Z0-9]{1,15}-USD$'),
  direction text not null check (direction in ('above', 'below')),
  price numeric not null check (price > 0),
  created_at timestamptz not null default now(),
  hit_at timestamptz,
  hit_price numeric
);
create index if not exists alerts_user_id_idx on public.alerts (user_id);

-- Row-level security: people can only see and change their own alerts.
alter table public.alerts enable row level security;
create policy "Read own alerts"   on public.alerts for select to authenticated using ((select auth.uid()) = user_id);
create policy "Add own alerts"    on public.alerts for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Update own alerts" on public.alerts for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "Delete own alerts" on public.alerts for delete to authenticated using ((select auth.uid()) = user_id);

-- Cap each account at 100 alerts so nobody can flood the free database.
create or replace function public.limit_alerts() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.alerts where user_id = new.user_id) >= 100 then
    raise exception 'Alert limit reached (100 per account)';
  end if;
  return new;
end $$;
drop trigger if exists limit_alerts on public.alerts;
create trigger limit_alerts before insert on public.alerts for each row execute function public.limit_alerts();

-- ===== Part 2: alerts that fire while the site is closed =====
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

-- Devices that turned on push notifications. Written only through the functions below.
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;
create policy "Read own devices" on public.push_subscriptions for select to authenticated using ((select auth.uid()) = user_id);

-- Per-person notification choices (email on by default once email is set up).
create table if not exists public.notify_prefs (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  email boolean not null default true
);
alter table public.notify_prefs enable row level security;
create policy "Read own prefs" on public.notify_prefs for select to authenticated using ((select auth.uid()) = user_id);
create policy "Add own prefs" on public.notify_prefs for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Change own prefs" on public.notify_prefs for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- Server-only keys (push signing keys). Row-level security on with no policies = no public access.
create table if not exists public.app_keys (name text primary key, value jsonb not null);
alter table public.app_keys enable row level security;

-- Save this device's push subscription to the signed-in account (moves it if another account had it).
create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  delete from public.push_subscriptions where endpoint = p_endpoint;
  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth) values (auth.uid(), p_endpoint, p_p256dh, p_auth);
  delete from public.push_subscriptions where user_id = auth.uid() and id not in
    (select id from public.push_subscriptions where user_id = auth.uid() order by created_at desc limit 10);
end $$;
create or replace function public.remove_push_subscription(p_endpoint text) returns void
language sql security definer set search_path = '' as $$
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
$$;
revoke execute on function public.save_push_subscription(text, text, text), public.remove_push_subscription(text) from public, anon;
grant execute on function public.save_push_subscription(text, text, text), public.remove_push_subscription(text) to authenticated;

-- The public half of the push key, which browsers need to subscribe.
create or replace function public.get_vapid_public_key() returns jsonb
language sql security definer set search_path = '' stable as $$
  select value -> 'publicKey' from public.app_keys where name = 'vapid';
$$;
grant execute on function public.get_vapid_public_key() to anon, authenticated;

-- A random secret that only the scheduler and the checker know, so nobody else can trigger the checker.
select vault.create_secret(gen_random_uuid()::text || gen_random_uuid()::text, 'cron_secret')
  where not exists (select 1 from vault.secrets where name = 'cron_secret');
create or replace function public.get_cron_secret() returns text
language sql security definer set search_path = '' stable as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret';
$$;
revoke execute on function public.get_cron_secret() from public, anon, authenticated;
grant execute on function public.get_cron_secret() to service_role;

-- ===== Part 3 (after the check-alerts function is deployed): run it every minute =====
-- select cron.schedule('check-alerts', '* * * * *', $$ select net.http_post(
--   url := 'https://busnludymltxjigvwcnf.supabase.co/functions/v1/check-alerts',
--   headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
--   body := '{}'::jsonb, timeout_milliseconds := 25000) $$);
