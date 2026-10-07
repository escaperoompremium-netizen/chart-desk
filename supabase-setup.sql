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

-- ===== Part 4: watchlist, public settings, account deletion =====
create table if not exists public.watchlist (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  pair text not null check (pair ~ '^[A-Z0-9]{1,15}-USD$'),
  created_at timestamptz not null default now(),
  primary key (user_id, pair)
);
alter table public.watchlist enable row level security;
create policy "Read own watchlist" on public.watchlist for select to authenticated using ((select auth.uid()) = user_id);
create policy "Add to own watchlist" on public.watchlist for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Remove from own watchlist" on public.watchlist for delete to authenticated using ((select auth.uid()) = user_id);
create or replace function public.limit_watchlist() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.watchlist where user_id = new.user_id) >= 100 then raise exception 'Watchlist limit reached (100 coins)'; end if;
  return new;
end $$;
drop trigger if exists limit_watchlist on public.watchlist;
create trigger limit_watchlist before insert on public.watchlist for each row execute function public.limit_watchlist();

-- Settings the website may read (for example whether email alerts are switched on).
create table if not exists public.public_settings (key text primary key, value jsonb not null);
alter table public.public_settings enable row level security;
create policy "Anyone can read settings" on public.public_settings for select to anon, authenticated using (true);
insert into public.public_settings (key, value) values ('email_enabled', 'false') on conflict (key) do nothing;

-- Let signed-in people delete their own account (alerts, watchlist, devices and prefs cascade).
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  delete from auth.users where id = auth.uid();
end $$;
revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- ===== Part 5: smarter alerts, portfolio, admin =====
-- Alert types: price (level), pct (24h move %), rsi (RSI level), cross (EMA 20/50 crossover). Repeat = fire every time.
alter table public.alerts
  add column if not exists kind text not null default 'price' check (kind in ('price', 'pct', 'rsi', 'cross')),
  add column if not exists repeat boolean not null default false,
  add column if not exists tf integer not null default 3600 check (tf in (900, 3600, 21600, 86400)),
  add column if not exists last_state boolean,
  add column if not exists last_hit_at timestamptz;
alter table public.alerts add constraint alerts_rsi_range check (kind <> 'rsi' or price < 100);

-- Portfolio holdings: one row per coin per person.
create table if not exists public.holdings (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  pair text not null check (pair ~ '^[A-Z0-9]{1,15}-USD$'),
  amount numeric not null check (amount > 0),
  avg_cost numeric check (avg_cost is null or avg_cost >= 0),
  updated_at timestamptz not null default now(),
  primary key (user_id, pair)
);
alter table public.holdings enable row level security;
create policy "Read own holdings" on public.holdings for select to authenticated using ((select auth.uid()) = user_id);
create policy "Add own holdings" on public.holdings for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Change own holdings" on public.holdings for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "Remove own holdings" on public.holdings for delete to authenticated using ((select auth.uid()) = user_id);
create or replace function public.limit_holdings() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.holdings where user_id = new.user_id) >= 200 then raise exception 'Portfolio limit reached (200 coins)'; end if;
  return new;
end $$;
drop trigger if exists limit_holdings on public.holdings;
create trigger limit_holdings before insert on public.holdings for each row execute function public.limit_holdings();

-- A log of every alert that fired (written by the checker), for the admin page and future history views.
create table if not exists public.alert_events (
  id bigserial primary key,
  alert_id uuid,
  user_id uuid references auth.users (id) on delete cascade,
  pair text, kind text, title text,
  pushed integer not null default 0,
  emailed boolean not null default false,
  at timestamptz not null default now()
);
alter table public.alert_events enable row level security;
create policy "Read own alert events" on public.alert_events for select to authenticated using ((select auth.uid()) = user_id);

-- Admins (the site owner). No policies = invisible to everyone; checked by the functions below.
create table if not exists public.admins (user_id uuid primary key references auth.users (id) on delete cascade);
alter table public.admins enable row level security;
insert into public.admins (user_id) select id from auth.users where email = 'jaidenwest001@yahoo.com' on conflict do nothing;

create or replace function public.is_admin() returns boolean language sql security definer set search_path = '' stable as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;
create or replace function public.admin_stats() returns jsonb language plpgsql security definer set search_path = '' stable as $$
begin
  if not exists (select 1 from public.admins where user_id = auth.uid()) then raise exception 'not_admin'; end if;
  return jsonb_build_object(
    'users', (select count(*) from auth.users),
    'users_7d', (select count(*) from auth.users where created_at > now() - interval '7 days'),
    'users_today', (select count(*) from auth.users where created_at > date_trunc('day', now())),
    'alerts', (select count(*) from public.alerts),
    'alerts_armed', (select count(*) from public.alerts where hit_at is null),
    'alerts_by_kind', (select coalesce(jsonb_object_agg(kind, c), '{}'::jsonb) from (select kind, count(*) c from public.alerts group by kind) t),
    'watchlist_rows', (select count(*) from public.watchlist),
    'holdings_rows', (select count(*) from public.holdings),
    'push_devices', (select count(*) from public.push_subscriptions),
    'email_off', (select count(*) from public.notify_prefs where email = false),
    'fired_7d', (select count(*) from public.alert_events where at > now() - interval '7 days'),
    'pushes_7d', (select coalesce(sum(pushed), 0) from public.alert_events where at > now() - interval '7 days'),
    'emails_7d', (select count(*) from public.alert_events where emailed and at > now() - interval '7 days'),
    'by_day', (select coalesce(jsonb_agg(jsonb_build_object('day', d, 'fired', c, 'pushes', p, 'emails', e) order by d), '[]'::jsonb) from (
      select date_trunc('day', at)::date d, count(*) c, coalesce(sum(pushed), 0) p, count(*) filter (where emailed) e
      from public.alert_events where at > now() - interval '14 days' group by 1) t),
    'recent_users', (select coalesce(jsonb_agg(jsonb_build_object('email', email, 'created', created_at, 'last_sign_in', last_sign_in_at) order by created_at desc), '[]'::jsonb) from (
      select email, created_at, last_sign_in_at from auth.users order by created_at desc limit 15) t),
    'top_coins', (select coalesce(jsonb_agg(jsonb_build_object('pair', pair, 'count', c) order by c desc), '[]'::jsonb) from (
      select pair, count(*) c from (select pair from public.alerts union all select pair from public.watchlist union all select pair from public.holdings) x
      group by pair order by c desc limit 10) t)
  );
end $$;
revoke execute on function public.is_admin(), public.admin_stats() from public, anon;
grant execute on function public.is_admin(), public.admin_stats() to authenticated;
