-- Sistema Gestão | frigorífico e açougue
create extension if not exists pgcrypto;

create table if not exists public.stores (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.store_memberships (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'operator' check (role in ('admin','manager','operator')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(store_id, user_id)
);

alter table public.stores enable row level security;
alter table public.store_memberships enable row level security;
drop policy if exists stores_member_read on public.stores;
create policy stores_member_read on public.stores for select to authenticated using (id in (select store_id from public.store_memberships where user_id = (select auth.uid()) and active));
drop policy if exists memberships_self_read on public.store_memberships;
create policy memberships_self_read on public.store_memberships for select to authenticated using (user_id = (select auth.uid()));

insert into public.stores (name, slug) values ('Loja principal', 'loja-principal') on conflict (slug) do nothing;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  role text not null default 'operator' check (role in ('admin','manager','operator')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated using (true);
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, role)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)), 'operator')
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();
insert into public.profiles (id, full_name, role)
select id, 'Administrador', 'admin' from auth.users where lower(email) = lower('dvdinho@hotmail.com')
on conflict (id) do update set role = 'admin', full_name = 'Administrador';

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin' and active);
$$;
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated
using (id = (select auth.uid()) or public.is_admin())
with check (id = (select auth.uid()) or public.is_admin());

create table if not exists public.sectors (
  id uuid primary key default gen_random_uuid(),
  store_id uuid references public.stores(id) on delete cascade,
  name text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.equipment (
  id uuid primary key default gen_random_uuid(),
  store_id uuid references public.stores(id) on delete cascade,
  sector_id uuid not null references public.sectors(id) on delete restrict,
  name text not null,
  kind text not null default 'refrigerator',
  min_temperature numeric(5,2),
  max_temperature numeric(5,2),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.temperature_readings (
  id uuid primary key default gen_random_uuid(),
  store_id uuid references public.stores(id) on delete cascade,
  equipment_id uuid not null references public.equipment(id) on delete restrict,
  value numeric(5,2) not null,
  measured_at timestamptz not null default now(),
  notes text,
  recorded_by uuid references auth.users(id) on delete set null,
  within_parameter boolean not null default true
);

create or replace function public.set_reading_parameter_status()
returns trigger language plpgsql as $$
declare min_temp numeric; max_temp numeric;
begin
  select min_temperature, max_temperature into min_temp, max_temp
    from public.equipment where id = new.equipment_id;
  new.within_parameter := (min_temp is null or new.value >= min_temp)
    and (max_temp is null or new.value <= max_temp);
  return new;
end;
$$;

drop trigger if exists temperature_parameter_status on public.temperature_readings;
create trigger temperature_parameter_status before insert or update of equipment_id, value
  on public.temperature_readings for each row execute function public.set_reading_parameter_status();

create table if not exists public.checklists (
  id uuid primary key default gen_random_uuid(),
  store_id uuid references public.stores(id) on delete cascade,
  sector_id uuid references public.sectors(id) on delete set null,
  name text not null,
  description text,
  frequency text not null default 'daily',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.checklist_items (
  id uuid primary key default gen_random_uuid(),
  checklist_id uuid not null references public.checklists(id) on delete cascade,
  label text not null,
  position integer not null default 0,
  required boolean not null default true
);

create table if not exists public.checklist_runs (
  id uuid primary key default gen_random_uuid(),
  store_id uuid references public.stores(id) on delete cascade,
  checklist_id uuid not null references public.checklists(id) on delete restrict,
  status text not null default 'pending' check (status in ('pending','in_progress','completed','failed')),
  started_at timestamptz,
  completed_at timestamptz,
  completed_by uuid references auth.users(id) on delete set null,
  notes text
);

create table if not exists public.occurrences (
  id uuid primary key default gen_random_uuid(),
  store_id uuid references public.stores(id) on delete cascade,
  sector_id uuid references public.sectors(id) on delete set null,
  equipment_id uuid references public.equipment(id) on delete set null,
  title text not null,
  description text,
  severity text not null default 'medium' check (severity in ('low','medium','high','critical')),
  status text not null default 'open' check (status in ('open','in_treatment','resolved')),
  corrective_action text,
  created_by uuid references auth.users(id) on delete set null,
  resolved_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

alter table public.sectors enable row level security;
alter table public.equipment enable row level security;
alter table public.temperature_readings enable row level security;
alter table public.checklists enable row level security;
alter table public.checklist_items enable row level security;
alter table public.checklist_runs enable row level security;
alter table public.occurrences enable row level security;

drop policy if exists "authenticated users can manage sectors" on public.sectors;
create policy "authenticated users can manage sectors" on public.sectors for all to authenticated using (true) with check (true);
drop policy if exists "authenticated users can manage equipment" on public.equipment;
create policy "authenticated users can manage equipment" on public.equipment for all to authenticated using (true) with check (true);
drop policy if exists "authenticated users can manage readings" on public.temperature_readings;
create policy "authenticated users can manage readings" on public.temperature_readings for all to authenticated using (true) with check (true);
drop policy if exists "authenticated users can manage checklists" on public.checklists;
create policy "authenticated users can manage checklists" on public.checklists for all to authenticated using (true) with check (true);
drop policy if exists "authenticated users can manage checklist items" on public.checklist_items;
create policy "authenticated users can manage checklist items" on public.checklist_items for all to authenticated using (true) with check (true);
drop policy if exists "authenticated users can manage checklist runs" on public.checklist_runs;
create policy "authenticated users can manage checklist runs" on public.checklist_runs for all to authenticated using (true) with check (true);
drop policy if exists "authenticated users can manage occurrences" on public.occurrences;
create policy "authenticated users can manage occurrences" on public.occurrences for all to authenticated using (true) with check (true);

insert into public.sectors (name) values ('Frios'), ('Açougue') on conflict (name) do nothing;
