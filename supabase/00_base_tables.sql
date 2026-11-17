-- ============================================================================
-- BASE TABLES — products, categories, warehouses, warehouse_stock
--
-- These tables were originally created by hand in the Supabase dashboard, so
-- no migration creates them, yet every migration after this one assumes they
-- exist. Rebuilt here from how the app reads and writes them. Every statement
-- is "if not exists", so on a database that already has them this does nothing.
-- ============================================================================

-- ── Website catalogue ──────────────────────────────────────────────────────
create table if not exists public.categories (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  slug        text not null,
  parent_id   uuid references public.categories(id) on delete cascade,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now()
);
alter table public.categories enable row level security;
drop policy if exists categories_public_read on public.categories;
create policy categories_public_read on public.categories for select using (true);

create table if not exists public.products (
  id             uuid primary key default gen_random_uuid(),
  title          text not null,
  model_number   text,
  description    text,
  price          numeric(12,2),
  brand          text,
  category       text,
  category_id    text,
  slug           text,
  images         text[]  not null default '{}',
  specifications jsonb   not null default '{}',
  in_stock       boolean not null default true,
  featured       boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
-- RLS + policies for products are set by 20260807_superboss.sql.

-- ── Main-shop stock ────────────────────────────────────────────────────────
create table if not exists public.warehouses (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  color        text not null default '#38bdf8',
  date_columns text[] not null default '{}',
  created_at   timestamptz not null default now()
);

create table if not exists public.warehouse_stock (
  id            uuid primary key default gen_random_uuid(),
  warehouse     text not null,
  model         text not null,
  opening_stock integer not null default 0,
  daily_taken   jsonb   not null default '{}',
  total_taken   integer not null default 0,
  closing_stock integer not null default 0,
  min_level     integer,
  stock_status  text not null default '',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- The locations the app and later migrations expect to find. Same names and
-- colours the Stock tab seeds on first load (src/components/StockTab.tsx).
insert into public.warehouses (name, color, date_columns)
select v.name, v.color, '{}'
  from (values ('BACK WAREHOUSE', '#4f7cff'),
               ('FISHPONG-1',     '#38bdf8'),
               ('FISHPONG-2',     '#a78bfa'),
               ('ABLEKUMA1',      '#34d399'),
               ('ABLEKUMA2',      '#f472b6')) as v(name, color)
 where not exists (select 1 from public.warehouses w where w.name = v.name);
