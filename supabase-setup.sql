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
