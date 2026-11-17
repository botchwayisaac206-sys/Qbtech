-- ============================================================================
-- QBNET TECH — ALL MIGRATIONS IN ONE FILE (generated, do not edit by hand)
-- Built by scripts/build-all-migrations.mjs from 61 files.
-- For a FRESH Supabase project: paste into SQL Editor and run once.
-- ============================================================================


-- ############################################################################
-- ## 00_base_tables.sql
-- ############################################################################

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


-- ############################################################################
-- ## 20260417_sales_system.sql
-- ############################################################################

-- ============================================================================
-- QBNET TECH — Sales & Invoice Management System
-- Run this in the Supabase SQL editor (one-time, idempotent).
-- ============================================================================

-- ──────────────────────────────────────────────────────────────────────────
-- 1. USER ROLES
-- ──────────────────────────────────────────────────────────────────────────
create table if not exists public.user_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role    text not null check (role in ('boss','admin','cashier')),
  created_at timestamptz not null default now()
);

create or replace function public.current_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.user_roles where user_id = auth.uid()
$$;

create or replace function public.is_boss() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.current_role() in ('boss','admin'), false)
$$;

-- ──────────────────────────────────────────────────────────────────────────
-- 2. INVOICES & LINE ITEMS
-- ──────────────────────────────────────────────────────────────────────────
create table if not exists public.invoices (
  id              uuid primary key default gen_random_uuid(),
  invoice_number  text not null unique,
  customer_name   text not null,
  customer_loc    text,
  customer_num    text,
  order_no        text,
  rep             text,
  fob             text,
  payment_method  text default 'Cash',
  subtotal        numeric(12,2) not null default 0,
  vat_rate        numeric(5,2)  not null default 0,
  vat_amount      numeric(12,2) not null default 0,
  total           numeric(12,2) not null default 0,
  issued_at       timestamptz not null default now(),
  created_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now()
);

create index if not exists invoices_issued_at_idx on public.invoices (issued_at desc);
create index if not exists invoices_created_by_idx on public.invoices (created_by);

create table if not exists public.invoice_items (
  id          uuid primary key default gen_random_uuid(),
  invoice_id  uuid not null references public.invoices(id) on delete cascade,
  product_id  uuid references public.products(id) on delete set null,
  description text not null,
  quantity    numeric(10,2) not null default 1,
  unit_price  numeric(12,2) not null default 0,
  line_total  numeric(12,2) not null default 0,
  position    int not null default 0
);
create index if not exists invoice_items_invoice_idx on public.invoice_items (invoice_id);

-- Invoice number auto-gen (per-year seq: INV-2026-0001)
create or replace function public.next_invoice_number() returns text
language plpgsql security definer set search_path = public as $$
declare
  yr  text := to_char(now(), 'YYYY');
  cnt int;
begin
  select count(*) + 1 into cnt from public.invoices
    where to_char(issued_at, 'YYYY') = yr;
  return 'INV-' || yr || '-' || lpad(cnt::text, 4, '0');
end $$;

-- ──────────────────────────────────────────────────────────────────────────
-- 3. PRODUCT WATCHES (Boss alerts)
-- ──────────────────────────────────────────────────────────────────────────
create table if not exists public.product_watches (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid not null references public.products(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  unique (product_id, user_id)
);

create table if not exists public.watch_alerts (
  id          uuid primary key default gen_random_uuid(),
  watch_id    uuid not null references public.product_watches(id) on delete cascade,
  invoice_id  uuid references public.invoices(id) on delete set null,
  product_id  uuid not null references public.products(id) on delete cascade,
  quantity    numeric(10,2) not null,
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists watch_alerts_unread_idx on public.watch_alerts (read_at) where read_at is null;

-- Trigger: after invoice item inserted, if its product is watched, create alert
create or replace function public.fn_create_watch_alerts() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.product_id is null then return new; end if;
  insert into public.watch_alerts (watch_id, invoice_id, product_id, quantity)
    select w.id, new.invoice_id, new.product_id, new.quantity
    from public.product_watches w where w.product_id = new.product_id;
  return new;
end $$;

drop trigger if exists trg_watch_alerts on public.invoice_items;
create trigger trg_watch_alerts after insert on public.invoice_items
  for each row execute function public.fn_create_watch_alerts();

-- ──────────────────────────────────────────────────────────────────────────
-- 4. EXPENSES (for income vs expense breakdown)
-- ──────────────────────────────────────────────────────────────────────────
create table if not exists public.expenses (
  id          uuid primary key default gen_random_uuid(),
  category    text not null,
  description text,
  amount      numeric(12,2) not null,
  incurred_at timestamptz not null default now(),
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists expenses_incurred_idx on public.expenses (incurred_at desc);

-- ──────────────────────────────────────────────────────────────────────────
-- 5. AUDIT LOG
-- ──────────────────────────────────────────────────────────────────────────
create table if not exists public.audit_log (
  id         uuid primary key default gen_random_uuid(),
  actor_id   uuid references auth.users(id) on delete set null,
  actor_role text,
  action     text not null,        -- insert | update | delete
  table_name text not null,
  row_id     text,
  diff       jsonb,
  created_at timestamptz not null default now()
);
create index if not exists audit_created_idx on public.audit_log (created_at desc);

create or replace function public.fn_audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  rid text;
  d   jsonb;
begin
  if tg_op = 'DELETE' then
    rid := old.id::text;
    d   := to_jsonb(old);
  else
    rid := new.id::text;
    d   := to_jsonb(new);
  end if;
  insert into public.audit_log (actor_id, actor_role, action, table_name, row_id, diff)
    values (auth.uid(), public.current_role(), lower(tg_op), tg_table_name, rid, d);
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

drop trigger if exists trg_audit_invoices on public.invoices;
create trigger trg_audit_invoices after insert or update or delete on public.invoices
  for each row execute function public.fn_audit();

drop trigger if exists trg_audit_expenses on public.expenses;
create trigger trg_audit_expenses after insert or update or delete on public.expenses
  for each row execute function public.fn_audit();

-- ──────────────────────────────────────────────────────────────────────────
-- 6. ROW-LEVEL SECURITY
-- ──────────────────────────────────────────────────────────────────────────
alter table public.user_roles      enable row level security;
alter table public.invoices        enable row level security;
alter table public.invoice_items   enable row level security;
alter table public.product_watches enable row level security;
alter table public.watch_alerts    enable row level security;
alter table public.expenses        enable row level security;
alter table public.audit_log       enable row level security;

-- user_roles: each user reads own row; only boss can write
drop policy if exists ur_self_read on public.user_roles;
drop policy if exists ur_self_read on public.user_roles;

create policy ur_self_read on public.user_roles for select
  using (auth.uid() = user_id or public.is_boss());

drop policy if exists ur_boss_write on public.user_roles;
drop policy if exists ur_boss_write on public.user_roles;

create policy ur_boss_write on public.user_roles for all
  using (public.is_boss()) with check (public.is_boss());

-- invoices: boss sees all, cashier sees own
drop policy if exists inv_read on public.invoices;
drop policy if exists inv_read on public.invoices;

create policy inv_read on public.invoices for select
  using (public.is_boss() or created_by = auth.uid());

drop policy if exists inv_insert on public.invoices;
drop policy if exists inv_insert on public.invoices;

create policy inv_insert on public.invoices for insert
  with check (auth.uid() is not null and (public.is_boss() or created_by = auth.uid()));

drop policy if exists inv_update on public.invoices;
drop policy if exists inv_update on public.invoices;

create policy inv_update on public.invoices for update
  using (public.is_boss()) with check (public.is_boss());

drop policy if exists inv_delete on public.invoices;
drop policy if exists inv_delete on public.invoices;

create policy inv_delete on public.invoices for delete
  using (public.is_boss());

-- invoice_items: follow parent invoice
drop policy if exists inv_items_read on public.invoice_items;
drop policy if exists inv_items_read on public.invoice_items;

create policy inv_items_read on public.invoice_items for select
  using (exists (select 1 from public.invoices i
    where i.id = invoice_id and (public.is_boss() or i.created_by = auth.uid())));

drop policy if exists inv_items_write on public.invoice_items;
drop policy if exists inv_items_write on public.invoice_items;

create policy inv_items_write on public.invoice_items for all
  using (exists (select 1 from public.invoices i
    where i.id = invoice_id and (public.is_boss() or i.created_by = auth.uid())))
  with check (exists (select 1 from public.invoices i
    where i.id = invoice_id and (public.is_boss() or i.created_by = auth.uid())));

-- product_watches: only boss
drop policy if exists pw_boss on public.product_watches;
drop policy if exists pw_boss on public.product_watches;

create policy pw_boss on public.product_watches for all
  using (public.is_boss()) with check (public.is_boss());

-- watch_alerts: boss-only
drop policy if exists wa_boss on public.watch_alerts;
drop policy if exists wa_boss on public.watch_alerts;

create policy wa_boss on public.watch_alerts for all
  using (public.is_boss()) with check (public.is_boss());

-- expenses: boss-only
drop policy if exists exp_boss on public.expenses;
drop policy if exists exp_boss on public.expenses;

create policy exp_boss on public.expenses for all
  using (public.is_boss()) with check (public.is_boss());

-- audit_log: boss read-only
drop policy if exists audit_boss_read on public.audit_log;
drop policy if exists audit_boss_read on public.audit_log;

create policy audit_boss_read on public.audit_log for select
  using (public.is_boss());

-- ──────────────────────────────────────────────────────────────────────────
-- 7. REPORTING VIEW (lightweight aggregate for charts)
-- ──────────────────────────────────────────────────────────────────────────
create or replace view public.sales_by_day as
  select date_trunc('day', issued_at)::date as day,
         sum(total) as total,
         count(*)   as invoice_count
  from public.invoices group by 1;

-- Grant read of view through existing policies
grant select on public.sales_by_day to anon, authenticated;


-- ############################################################################
-- ## 20260417_seed_ablekuma_stock.sql
-- ############################################################################

-- ============================================================================
-- Seed ABLEKUMA1, ABLEKUMA2 & FISHPONG-1 warehouse stock (62 items, ~15,642 pcs).
-- Idempotent: each row is inserted only if (warehouse, model) doesn't exist.
-- ============================================================================

insert into public.warehouse_stock
  (warehouse, model, opening_stock, daily_taken, total_taken, closing_stock, min_level, stock_status)
select v.warehouse, v.model, v.qty, '{}'::jsonb, 0, v.qty, null, ''
from (
  values
  -- ── ABLEKUMA2 ──────────────────────────────────────────────────────
  ('ABLEKUMA2', 'Waste 520*350*180 2U',                            870),
  ('ABLEKUMA2', 'Waste 3U 520*350*210',                            840),
  ('ABLEKUMA2', 'Waste 9U 520*400*450',                              4),
  ('ABLEKUMA2', 'Waste 4U 530*400*240',                            621),
  ('ABLEKUMA2', 'Hik view 4U 520*400*240',                         155),
  ('ABLEKUMA2', 'Axiom cat6 SFTP outdoor PVC+PE 100m',             120),
  ('ABLEKUMA2', 'Axiom cat6 UTP black',                             90),
  ('ABLEKUMA2', 'Axiom cat6 UTP 100m',                             376),
  ('ABLEKUMA2', 'Waste cat6 indoor pure copper FC001',              38),
  ('ABLEKUMA2', 'Waste cat6 SFTP outdoor AG004',                    24),
  ('ABLEKUMA2', 'Round junction box B001',                         600),
  ('ABLEKUMA2', 'Small junction box 100F',                        1000),
  ('ABLEKUMA2', 'Junction box octagon shape medium',              1300),
  ('ABLEKUMA2', 'HD wireless extender 200m KVM',                     3),
  ('ABLEKUMA2', 'Network kit LKT-300110Y',                          40),
  ('ABLEKUMA2', 'Metal camera mount PFA152-E unbranded',           135),
  ('ABLEKUMA2', 'Metal camera mount PFA152-E branded',              30),
  ('ABLEKUMA2', 'Metal camera mount 1258ZJ-120',                    30),
  ('ABLEKUMA2', 'Metal camera wall mount PFD203W',                  22),
  ('ABLEKUMA2', 'Metal camera mount 1602ZJ',                        24),
  ('ABLEKUMA2', 'Video balun C1 8PM',                             5000),
  ('ABLEKUMA2', 'HDMI 60m KVM extender',                             3),
  ('ABLEKUMA2', 'HDMI 2x2 video wall controller',                    1),
  ('ABLEKUMA2', 'Fiber optic 4K 8K UHD 30m',                         8),
  ('ABLEKUMA2', 'Westa cat6 SFTP 305m outdoor AG003',              404),
  ('ABLEKUMA2', 'Wireless intercom HY626',                          40),
  ('ABLEKUMA2', 'Wireless intercom HY636',                          40),
  ('ABLEKUMA2', 'Motor rag',                                       100),
  ('ABLEKUMA2', 'ST-558-6M-4G-12X',                                  4),
  ('ABLEKUMA2', 'BNC connector copper',                            130),
  ('ABLEKUMA2', 'Single cat6',                                     500),
  ('ABLEKUMA2', 'Siren 30W',                                        24),
  ('ABLEKUMA2', 'Cable manager',                                    36),
  ('ABLEKUMA2', 'Solar fan',                                         2),
  ('ABLEKUMA2', 'Hikvision cat6 DS-1LN6U-W/CCA',                     6),
  ('ABLEKUMA2', 'DS-TMG035 trigger radar',                           1),

  -- ── ABLEKUMA1 ──────────────────────────────────────────────────────
  ('ABLEKUMA1', 'Magnetic lock DS-K4H255S',                        200),
  ('ABLEKUMA1', 'Solid SD-UTP 320m cable',                         380),
  ('ABLEKUMA1', 'Solid SD-UTP 120m cable',                         138),
  ('ABLEKUMA1', 'Solid SD-SFTP 305m',                              158),
  ('ABLEKUMA1', 'Solid SD-FTP 305m cable',                          10),
  ('ABLEKUMA1', 'AK 305m cat6 cable',                               38),
  ('ABLEKUMA1', 'Westa cat6 UTP 305m indoor AG001',                558),
  ('ABLEKUMA1', 'Westa cat6 UTP 305m outdoor AG002',                50),
  ('ABLEKUMA1', 'Westa cat6 UTP 100m indoor',                      174),
  ('ABLEKUMA1', 'Axiom UTP cat6 gray 305m',                        486),
  ('ABLEKUMA1', 'Axiom UTP cat6 orange 305m',                      246),
  ('ABLEKUMA1', 'Hilook cat6 305m NC-1LN6UU/CCA/M',                 24),
  ('ABLEKUMA1', 'Dahua cat6 cable 305m DH-PFM922I-6UN-C',          154),
  ('ABLEKUMA1', 'D-Link cat6 cable 305m',                            8),
  ('ABLEKUMA1', '1U rug',                                           24),
  ('ABLEKUMA1', 'DS-D5C98RB/B',                                      1),
  ('ABLEKUMA1', 'DS-D5ABKY2-B',                                      1),
  ('ABLEKUMA1', '42U 800x1000x2000',                                 1),
  ('ABLEKUMA1', '15U 800HX600WX450D',                                1),

  -- ── FISHPONG-1 ─────────────────────────────────────────────────────
  ('FISHPONG-1', 'HILOOK-THC-B127-LPS 2MP',                        192),
  ('FISHPONG-1', 'HILOOK-DVR-116G-M1-16-1U 2MP',                    10),
  ('FISHPONG-1', 'HILOOK-NVR-104H-D/4P NVR',                        13),
  ('FISHPONG-1', 'HILOOK-NVR-216MH-C/16P 4K NVR',                   16),
  ('FISHPONG-1', 'HILOOK-NVR-108H-D/8P',                            27),
  ('FISHPONG-1', 'THC-T140-P 4MP',                                  53),
  ('FISHPONG-1', 'HILOOK-THC-T127-LPC 2MP',                         58)
) as v(warehouse, model, qty)
where not exists (
  select 1 from public.warehouse_stock ws
  where ws.warehouse = v.warehouse and ws.model = v.model
);

-- Quick verification
select warehouse, count(*) as items, sum(opening_stock) as total_pcs
from public.warehouse_stock
where warehouse in ('ABLEKUMA1','ABLEKUMA2','FISHPONG-1')
group by warehouse
order by warehouse;


-- ############################################################################
-- ## 20260421_staff_and_vat.sql
-- ############################################################################

-- ============================================================================
-- Extensions for staff management + VAT toggle on invoices.
-- Safe to run multiple times.
-- ============================================================================

-- 1. Staff name (shown on the Staff Manager list)
alter table public.user_roles
  add column if not exists full_name text;

-- 2. Optional VAT toggle — invoices already store vat_rate & vat_amount as numeric,
--    so "VAT off" simply means vat_rate = 0 and vat_amount = 0. No new columns needed,
--    but we loosen the constraint on vat_rate just in case:
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='invoices' and column_name='vat_rate'
  ) then
    execute 'alter table public.invoices alter column vat_rate set default 15';
  end if;
end $$;

-- 3. RLS policy: cashier can read own user_roles row already; also allow them
--    to insert expenses they create (boss can read all via existing exp_boss policy).
drop policy if exists exp_cashier_insert on public.expenses;
drop policy if exists exp_cashier_insert on public.expenses;

create policy exp_cashier_insert on public.expenses for insert
  with check (auth.uid() is not null and auth.uid() = created_by);

drop policy if exists exp_cashier_select_own on public.expenses;
drop policy if exists exp_cashier_select_own on public.expenses;

create policy exp_cashier_select_own on public.expenses for select
  using (public.is_boss() or created_by = auth.uid());


-- ############################################################################
-- ## 20260422_order_number_daily.sql
-- ############################################################################

-- ============================================================================
-- Per-day auto-incrementing order number for invoices.
-- Format: ORD-YYYYMMDD-NNN  (NNN resets to 001 each new day)
-- Safe to run multiple times.
-- ============================================================================

create or replace function public.next_order_number() returns text
language plpgsql security definer set search_path = public as $$
declare
  d   text := to_char((now() at time zone 'UTC')::date, 'YYYYMMDD');
  cnt int;
begin
  select count(*) + 1 into cnt
    from public.invoices
    where to_char((issued_at at time zone 'UTC')::date, 'YYYYMMDD') = d;
  return 'ORD-' || d || '-' || lpad(cnt::text, 3, '0');
end $$;

grant execute on function public.next_order_number() to authenticated;


-- ############################################################################
-- ## 20260423_staff_id_email.sql
-- ############################################################################

-- ============================================================================
-- Store the staff's login email (= their staff ID) on user_roles so the
-- boss can see/search it without querying auth.users.
-- Format going forward: <handle>@qbnettech.com (e.g. isha@qbnettech.com).
-- Safe to run multiple times.
-- ============================================================================

alter table public.user_roles
  add column if not exists staff_id text;

-- Backfill staff_id for any existing staff from auth.users.email (service role only).
do $$
begin
  update public.user_roles ur
     set staff_id = u.email
    from auth.users u
   where u.id = ur.user_id
     and ur.staff_id is null;
end $$;


-- ############################################################################
-- ## 20260515_pricelist.sql
-- ############################################################################

-- Price list tables
-- pricelist_categories: each category has its own GH₵/$ rate and duty toggle
-- pricelist_items: boss types name/model/USD price; GH₵ is always calculated live

create table if not exists pricelist_categories (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  rate_ghs_per_usd numeric(10,4) not null default 15,
  duty_rate_pct    numeric(6,2)  not null default 0,
  duties_enabled   boolean       not null default false,
  created_at       timestamptz   not null default now()
);

create table if not exists pricelist_items (
  id          uuid primary key default gen_random_uuid(),
  category_id uuid not null references pricelist_categories(id) on delete cascade,
  name        text not null,
  model       text not null default '',
  usd_price   numeric(12,2) not null default 0,
  created_at  timestamptz not null default now()
);

alter table pricelist_categories enable row level security;
alter table pricelist_items      enable row level security;

-- All authenticated users can read
drop policy if exists "read pricelist_categories" on pricelist_categories;

create policy "read pricelist_categories" on pricelist_categories for select to authenticated using (true);
drop policy if exists "read pricelist_items" on pricelist_items;

create policy "read pricelist_items"      on pricelist_items      for select to authenticated using (true);

-- Only boss/admin can write
drop policy if exists "write pricelist_categories" on pricelist_categories;

create policy "write pricelist_categories" on pricelist_categories for all to authenticated using (
  exists (select 1 from user_roles where user_id = auth.uid() and role in ('boss','admin'))
);
drop policy if exists "write pricelist_items" on pricelist_items;

create policy "write pricelist_items" on pricelist_items for all to authenticated using (
  exists (select 1 from user_roles where user_id = auth.uid() and role in ('boss','admin'))
);


-- ############################################################################
-- ## 20260521_dahua_stock.sql
-- ############################################################################

-- Dahua stock management + invoicing
-- Separate from main warehouse_stock / invoices tables
-- Stock deduction happens automatically when a dahua invoice is saved

-- ── Warehouses ────────────────────────────────────────────────
create table if not exists dahua_warehouses (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  color        text not null default '#38bdf8',
  date_columns text[] not null default '{}',
  created_at   timestamptz not null default now()
);

-- ── Stock items ───────────────────────────────────────────────
create table if not exists dahua_stock (
  id            uuid primary key default gen_random_uuid(),
  warehouse     text not null,
  model         text not null,
  opening_stock integer not null default 0,
  daily_taken   jsonb   not null default '{}',
  total_taken   integer not null default 0,
  invoice_taken integer not null default 0,
  closing_stock integer not null default 0,
  min_level     integer,
  stock_status  text not null default '',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- ── Invoices ──────────────────────────────────────────────────
create table if not exists dahua_invoices (
  id             uuid primary key default gen_random_uuid(),
  invoice_number text not null unique,
  customer_name  text not null,
  customer_loc   text,
  customer_num   text,
  order_no       text,
  payment_method text not null default 'Cash',
  subtotal       numeric(12,2) not null default 0,
  vat_rate       numeric(5,2)  not null default 0,
  vat_amount     numeric(12,2) not null default 0,
  total          numeric(12,2) not null default 0,
  issued_at      timestamptz   not null default now(),
  created_by     uuid references auth.users(id),
  created_at     timestamptz   not null default now()
);

-- ── Invoice line items ────────────────────────────────────────
create table if not exists dahua_invoice_items (
  id          uuid primary key default gen_random_uuid(),
  invoice_id  uuid not null references dahua_invoices(id) on delete cascade,
  stock_id    uuid references dahua_stock(id),
  description text not null,
  quantity    integer       not null default 1,
  unit_price  numeric(12,2) not null default 0,
  line_total  numeric(12,2) not null default 0,
  position    integer not null default 1,
  created_at  timestamptz not null default now()
);

-- ── RLS ───────────────────────────────────────────────────────
alter table dahua_warehouses     enable row level security;
alter table dahua_stock          enable row level security;
alter table dahua_invoices       enable row level security;
alter table dahua_invoice_items  enable row level security;

-- ── dahua_warehouses ─────────────────────────────────────────
-- All authenticated users can read
drop policy if exists "read dahua_warehouses" on dahua_warehouses;

create policy "read dahua_warehouses" on dahua_warehouses
  for select to authenticated using (true);

-- Only boss/admin can add, edit, delete warehouses
drop policy if exists "boss write dahua_warehouses" on dahua_warehouses;

create policy "boss write dahua_warehouses" on dahua_warehouses
  for all to authenticated
  using (exists (
    select 1 from user_roles
    where user_id = auth.uid() and role in ('boss','admin')
  ));

-- ── dahua_stock ───────────────────────────────────────────────
-- All authenticated users can read
drop policy if exists "read dahua_stock" on dahua_stock;

create policy "read dahua_stock" on dahua_stock
  for select to authenticated using (true);

-- Only boss/admin can INSERT new items or DELETE items
drop policy if exists "boss insert dahua_stock" on dahua_stock;

create policy "boss insert dahua_stock" on dahua_stock
  for insert to authenticated
  with check (exists (
    select 1 from user_roles
    where user_id = auth.uid() and role in ('boss','admin')
  ));

drop policy if exists "boss delete dahua_stock" on dahua_stock;


create policy "boss delete dahua_stock" on dahua_stock
  for delete to authenticated
  using (exists (
    select 1 from user_roles
    where user_id = auth.uid() and role in ('boss','admin')
  ));

-- Any authenticated user can UPDATE dahua_stock.
-- This is required so that cashiers can save a Dahua invoice and have the
-- stock quantities deducted automatically. Without this, the UPDATE in
-- DahuaInvoiceForm would be blocked by RLS for non-boss roles.
drop policy if exists "staff update dahua_stock" on dahua_stock;

create policy "staff update dahua_stock" on dahua_stock
  for update to authenticated
  using (true)
  with check (true);

-- ── dahua_invoices ────────────────────────────────────────────
-- All authenticated users can read
drop policy if exists "read dahua_invoices" on dahua_invoices;

create policy "read dahua_invoices" on dahua_invoices
  for select to authenticated using (true);

-- All authenticated users can create invoices (boss + cashier)
drop policy if exists "write dahua_invoices" on dahua_invoices;

create policy "write dahua_invoices" on dahua_invoices
  for insert to authenticated
  with check (true);

-- Only boss/admin can edit or delete invoices
drop policy if exists "boss update dahua_invoices" on dahua_invoices;

create policy "boss update dahua_invoices" on dahua_invoices
  for update to authenticated
  using (exists (
    select 1 from user_roles
    where user_id = auth.uid() and role in ('boss','admin')
  ));

drop policy if exists "boss delete dahua_invoices" on dahua_invoices;


create policy "boss delete dahua_invoices" on dahua_invoices
  for delete to authenticated
  using (exists (
    select 1 from user_roles
    where user_id = auth.uid() and role in ('boss','admin')
  ));

-- ── dahua_invoice_items ───────────────────────────────────────
-- All authenticated users can read
drop policy if exists "read dahua_invoice_items" on dahua_invoice_items;

create policy "read dahua_invoice_items" on dahua_invoice_items
  for select to authenticated using (true);

-- All authenticated users can insert line items (part of creating an invoice)
drop policy if exists "write dahua_invoice_items" on dahua_invoice_items;

create policy "write dahua_invoice_items" on dahua_invoice_items
  for insert to authenticated
  with check (true);

-- Only boss/admin can edit or delete invoice line items
drop policy if exists "boss update dahua_invoice_items" on dahua_invoice_items;

create policy "boss update dahua_invoice_items" on dahua_invoice_items
  for update to authenticated
  using (exists (
    select 1 from user_roles
    where user_id = auth.uid() and role in ('boss','admin')
  ));

drop policy if exists "boss delete dahua_invoice_items" on dahua_invoice_items;


create policy "boss delete dahua_invoice_items" on dahua_invoice_items
  for delete to authenticated
  using (exists (
    select 1 from user_roles
    where user_id = auth.uid() and role in ('boss','admin')
  ));


-- ############################################################################
-- ## 20260522_pricelist_revamp.sql
-- ############################################################################

-- Pricelist revamp: drop FX rate / duty workflow, store price directly in GH₵,
-- add specifications and image fields.
--
-- Old columns (usd_price, name, rate_ghs_per_usd, duty_rate_pct, duties_enabled)
-- are kept for safety so any external readers don't break; the UI no longer
-- writes to them.

alter table pricelist_items
  add column if not exists specifications text          not null default '',
  add column if not exists image_url       text,
  add column if not exists ghs_price       numeric(12,2) not null default 0;

-- Back-fill ghs_price from the old usd_price * rate * (1+duty) formula so
-- existing rows keep the price they showed before this migration.
update pricelist_items pi
set ghs_price = round(
  pi.usd_price * pc.rate_ghs_per_usd
  * (case when pc.duties_enabled then 1 + pc.duty_rate_pct / 100 else 1 end),
  2
)
from pricelist_categories pc
where pi.category_id = pc.id
  and pi.ghs_price = 0
  and pi.usd_price > 0;


-- ############################################################################
-- ## 20260528_warehouse_sections.sql
-- ############################################################################

-- Add section_labels to warehouses so each warehouse can define
-- named daily-quantity groups shown in the stock item edit form.
alter table warehouses
  add column if not exists section_labels text[] not null default '{}';


-- ############################################################################
-- ## 20260603_deliveries.sql
-- ############################################################################

-- ============================================================================
-- Deliveries: staff log a delivery (customer, amount, location, payment method);
-- the boss sees all of them, and the amounts roll into the sales dashboard.
--
-- RLS mirrors invoices/expenses: a cashier may insert and read only their own
-- rows; boss/admin read everything and may edit/delete.
--
-- Safe to run multiple times.
-- ============================================================================

-- Ensure the role helpers exist (they live in the base sales-system migration,
-- but this makes the deliveries migration self-contained / runnable standalone).
create or replace function public.current_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.user_roles where user_id = auth.uid()
$$;

create or replace function public.is_boss() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.current_role() in ('boss','admin'), false)
$$;

create table if not exists public.deliveries (
  id             uuid primary key default gen_random_uuid(),
  customer_name  text,
  location       text,
  amount         numeric not null default 0,
  payment_method text   not null default 'Cash',   -- 'Cash' | 'Mobile Money'
  note           text,
  delivered_at   timestamptz not null default now(),
  created_by     uuid references auth.users(id) on delete set null,
  created_at     timestamptz not null default now()
);

create index if not exists deliveries_delivered_at_idx on public.deliveries (delivered_at desc);
create index if not exists deliveries_created_by_idx    on public.deliveries (created_by);

alter table public.deliveries enable row level security;

drop policy if exists del_read on public.deliveries;
drop policy if exists del_read on public.deliveries;

create policy del_read on public.deliveries for select
  using (public.is_boss() or created_by = auth.uid());

drop policy if exists del_insert on public.deliveries;
drop policy if exists del_insert on public.deliveries;

create policy del_insert on public.deliveries for insert
  with check (auth.uid() is not null and (public.is_boss() or created_by = auth.uid()));

drop policy if exists del_update on public.deliveries;
drop policy if exists del_update on public.deliveries;

create policy del_update on public.deliveries for update
  using (public.is_boss()) with check (public.is_boss());

drop policy if exists del_delete on public.deliveries;
drop policy if exists del_delete on public.deliveries;

create policy del_delete on public.deliveries for delete
  using (public.is_boss());


-- ############################################################################
-- ## 20260603_server_invoice_numbers.sql
-- ############################################################################

-- ============================================================================
-- Server-side, RLS-proof invoice number + order number assignment.
--
-- Bug: cashiers can only SELECT their own invoices (inv_read policy:
--   "public.is_boss() or created_by = auth.uid()"). The old client generated
--   the invoice number in the browser from max(invoice_number)+1, but that
--   query only saw the cashier's own rows -> it kept reusing numbers that
--   already exist (created by other staff, invisible to them) -> 23505
--   duplicate -> "Could not assign invoice number after 5 attempts".
--   The boss (e.g. AISHA) sees all rows, so it worked only for her.
--
-- Fix: assign both numbers in a BEFORE INSERT trigger using SECURITY DEFINER
-- functions, which run as the function owner and bypass RLS (so they see ALL
-- invoices). An advisory lock serializes concurrent inserts so two cashiers
-- can't grab the same number at the same instant.
--
-- Safe to run multiple times.
-- ============================================================================

create or replace function public.next_invoice_number() returns text
language plpgsql security definer set search_path = public as $$
declare
  yr  text := to_char(now(), 'YYYY');
  seq int;
begin
  select coalesce(max((regexp_replace(invoice_number, '^.*-', ''))::int), 0) + 1
    into seq
    from public.invoices
    where invoice_number like 'INV-' || yr || '-%'
      and invoice_number ~ ('^INV-' || yr || '-\d+$');  -- ignore demo / odd formats
  return 'INV-' || yr || '-' || lpad(seq::text, 4, '0');
end $$;

grant execute on function public.next_invoice_number() to authenticated;

create or replace function public.fn_assign_invoice_numbers() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  yr text := to_char(now(), 'YYYY');
begin
  -- Serialize concurrent inserts for this year so numbers never collide.
  perform pg_advisory_xact_lock(hashtext('invoice_seq_' || yr));

  if new.invoice_number is null or new.invoice_number = '' then
    new.invoice_number := public.next_invoice_number();
  end if;

  if new.order_no is null or new.order_no = '' then
    new.order_no := public.next_order_number();
  end if;

  return new;
end $$;

-- Must run BEFORE the existing audit trigger; trigger order is alphabetical,
-- and 'trg_assign...' sorts before 'trg_audit...', so this is fine.
drop trigger if exists trg_assign_invoice_numbers on public.invoices;
create trigger trg_assign_invoice_numbers before insert on public.invoices
  for each row execute function public.fn_assign_invoice_numbers();


-- ############################################################################
-- ## 20260604_dahua_section_labels.sql
-- ############################################################################

-- ============================================================================
-- Add daily-quantity "sections" to Dahua warehouses, mirroring the main
-- warehouse stock tab. Each section (e.g. a new month) keeps its own day
-- values; in dahua_stock.daily_taken the keys are namespaced as
-- "sectionIdx:day" (legacy bare keys = section 0), so months don't collide.
--
-- Safe to run multiple times.
-- ============================================================================

alter table public.dahua_warehouses
  add column if not exists section_labels text[] not null default '{}';


-- ############################################################################
-- ## 20260707_product_codes.sql
-- ############################################################################

-- Barcode / material-code → model lookup for scan-based stock taking & pricelist.
--
-- Each physical CCTV box carries a manufacturer "material code" (Hikvision's
-- internal part number). Unlike the serial number, the material code is SHARED
-- by every unit of the same model, so it maps cleanly to our product `model`
-- string (the shared identity used by both warehouse_stock and pricelist_items).
--
-- Populated "learn as you scan": the first time an unknown code is scanned the
-- operator links it to a model; every future scan of that model resolves instantly.

create table if not exists product_codes (
  id            uuid primary key default gen_random_uuid(),
  material_code text not null,
  model         text not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- One model per code. Scanning the same code again updates the mapping in place.
create unique index if not exists product_codes_material_code_key
  on product_codes (material_code);

alter table product_codes enable row level security;

-- All authenticated staff can read (scanning needs lookups) and link codes,
-- since stock-taking is done by cashiers/staff, not just the boss.
drop policy if exists "read product_codes" on product_codes;

create policy "read product_codes"  on product_codes for select to authenticated using (true);
drop policy if exists "write product_codes" on product_codes;

create policy "write product_codes"  on product_codes for all    to authenticated using (true) with check (true);


-- ############################################################################
-- ## 20260708_scan_staff_access.sql
-- ############################################################################

-- Give staff (cashiers) the ability to record stock via the Scan tab, and log
-- every stock change to the audit trail.
--
-- 1. Audit logging: reuse the existing security-definer fn_audit() trigger
--    (already used on invoices/expenses). Attaching it to warehouse_stock and
--    product_codes records actor_id + actor_role + a row snapshot on every
--    insert/update/delete — so we can see WHO changed stock and WHEN, whether
--    the change came from scanning or manual editing.
--
-- 2. Write access: a permissive policy so any signed-in staff member can save
--    stock counts (previously stock writes were effectively boss-only). This
--    policy is OR'd with any existing policy, so it only widens access and does
--    NOT change whether RLS is enabled on the table.

drop trigger if exists trg_audit_warehouse_stock on public.warehouse_stock;
create trigger trg_audit_warehouse_stock
  after insert or update or delete on public.warehouse_stock
  for each row execute function public.fn_audit();

drop trigger if exists trg_audit_product_codes on public.product_codes;
create trigger trg_audit_product_codes
  after insert or update or delete on public.product_codes
  for each row execute function public.fn_audit();

-- Allow signed-in staff to UPDATE stock (record counts) via scanning. Scoped to
-- UPDATE only — scanning never creates or deletes stock rows (that stays with
-- the boss-only Stock tab), so staff can't accidentally add/remove products.
drop policy if exists warehouse_stock_staff_update on public.warehouse_stock;
drop policy if exists warehouse_stock_staff_update on public.warehouse_stock;

create policy warehouse_stock_staff_update on public.warehouse_stock
  for update to authenticated using (true) with check (true);


-- ############################################################################
-- ## 20260720_audit_deliveries.sql
-- ############################################################################

-- Close an audit gap: deliveries count toward Total Sales on the dashboard
-- (see SalesDashboard.tsx income = invoiceIncome + deliveryIncome) but never
-- had an audit trigger, so a deleted delivery silently changed the sales
-- total with no trace. Reuses the existing fn_audit() used by invoices/
-- expenses/warehouse_stock/product_codes — same audit_log table, same shape.

drop trigger if exists trg_audit_deliveries on public.deliveries;
create trigger trg_audit_deliveries
  after insert or update or delete on public.deliveries
  for each row execute function public.fn_audit();


-- ############################################################################
-- ## 20260807_superboss.sql
-- ############################################################################

-- ============================================================================
-- QBNET TECH — "Big Boss" (superboss) role
--
-- Introduces a tier ABOVE the existing boss/admin:
--
--   superboss      Big Boss. Everything boss/admin could do before this
--                  migration, unrestricted.
--   boss / admin   Same tabs and same UI as before, but read-only and clamped
--                  to a rolling 24-hour window. No invoice list, no staff
--                  creation, no writes of any kind.
--   cashier        Unchanged.
--
-- Enforcement lives here, in RLS — not just in the React gates. A restricted
-- boss with the anon key and a REST client gets exactly the same answers the
-- UI shows them.
--
-- Idempotent: safe to re-run.
--
-- PERFORMANCE NOTE — why every predicate below reads `(select public.is_x())`
-- rather than `public.is_x()`:
--
-- These are SECURITY DEFINER functions, so Postgres will not inline them. Called
-- bare in a policy they are re-evaluated ONCE PER ROW — across invoice_items
-- (9,029 rows) that is 9,029 extra function calls, each doing its own lookup
-- against user_roles, on every single query. Wrapping the call in a scalar
-- subquery lets the planner hoist it into an InitPlan that runs exactly once per
-- query and is then reused. Same reason auth.uid() is wrapped. This is the
-- documented Supabase RLS pattern and the difference is large at these row
-- counts — do not "simplify" the parentheses away.
-- ============================================================================

-- ──────────────────────────────────────────────────────────────────────────
-- 1. ROLE VOCABULARY
-- ──────────────────────────────────────────────────────────────────────────
alter table public.user_roles drop constraint if exists user_roles_role_check;
alter table public.user_roles add  constraint user_roles_role_check
  check (role in ('superboss','boss','admin','cashier'));

-- is_boss() keeps its original meaning — "has boss-level reach" — and now
-- includes superboss. Every pre-existing policy that calls it therefore grants
-- the Big Boss at least what the old boss had. Restrictions are applied by
-- explicitly REPLACING the sensitive policies further down.
create or replace function public.is_boss() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.current_role() in ('superboss','boss','admin'), false)
$$;

-- Unrestricted top tier.
create or replace function public.is_superboss() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.current_role() = 'superboss', false)
$$;

-- Demoted boss/admin: boss-shaped UI, read-only, 24-hour window.
create or replace function public.is_restricted_boss() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.current_role() in ('boss','admin'), false)
$$;

create or replace function public.is_cashier() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.current_role() = 'cashier', false)
$$;

-- The rolling visibility window for a restricted boss.
create or replace function public.window_start() returns timestamptz
language sql stable set search_path = public as $$
  select now() - interval '24 hours'
$$;

-- ──────────────────────────────────────────────────────────────────────────
-- 2. USER ROLES — only the Big Boss may write
--
-- This is the keystone. Left as is_boss(), a restricted boss could simply
-- UPDATE their own row to 'superboss' and undo everything below.
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists ur_self_read  on public.user_roles;
drop policy if exists ur_self_read on public.user_roles;
create policy ur_self_read on public.user_roles for select
  using ((select auth.uid()) = user_id or (select public.is_boss()));

drop policy if exists ur_boss_write on public.user_roles;
drop policy if exists ur_superboss_write on public.user_roles;
drop policy if exists ur_superboss_write on public.user_roles;
create policy ur_superboss_write on public.user_roles for all
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

-- ──────────────────────────────────────────────────────────────────────────
-- 3. INVOICES
--   read   superboss: all · restricted boss: last 24h only · cashier: own
--   write  superboss, plus cashier inserting their own
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists inv_read on public.invoices;
drop policy if exists inv_read on public.invoices;
create policy inv_read on public.invoices for select
  using (
    (select public.is_superboss())
    or ((select public.is_restricted_boss()) and issued_at >= (select public.window_start()))
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists inv_insert on public.invoices;
drop policy if exists inv_insert on public.invoices;
create policy inv_insert on public.invoices for insert
  with check (
    (select public.is_superboss())
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists inv_update on public.invoices;
drop policy if exists inv_update on public.invoices;
create policy inv_update on public.invoices for update
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists inv_delete on public.invoices;
drop policy if exists inv_delete on public.invoices;
create policy inv_delete on public.invoices for delete
  using ((select public.is_superboss()));

-- invoice_items follow their parent invoice's visibility exactly.
drop policy if exists inv_items_read on public.invoice_items;
drop policy if exists inv_items_read on public.invoice_items;
create policy inv_items_read on public.invoice_items for select
  using (exists (
    select 1 from public.invoices i
    where i.id = invoice_id and (
      (select public.is_superboss())
      or ((select public.is_restricted_boss()) and i.issued_at >= (select public.window_start()))
      or ((select public.is_cashier()) and i.created_by = (select auth.uid()))
    )));

drop policy if exists inv_items_write on public.invoice_items;
drop policy if exists inv_items_write on public.invoice_items;
create policy inv_items_write on public.invoice_items for all
  using (exists (
    select 1 from public.invoices i
    where i.id = invoice_id
      and ((select public.is_superboss()) or ((select public.is_cashier()) and i.created_by = (select auth.uid())))))
  with check (exists (
    select 1 from public.invoices i
    where i.id = invoice_id
      and ((select public.is_superboss()) or ((select public.is_cashier()) and i.created_by = (select auth.uid())))));

-- ──────────────────────────────────────────────────────────────────────────
-- 4. EXPENSES — replaces exp_boss / exp_cashier_* (policies OR together, so
--    the old permissive ones must be dropped, not merely shadowed)
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists exp_boss              on public.expenses;
drop policy if exists exp_cashier_insert    on public.expenses;
drop policy if exists exp_cashier_select_own on public.expenses;

drop policy if exists exp_read on public.expenses;
drop policy if exists exp_read on public.expenses;
create policy exp_read on public.expenses for select
  using (
    (select public.is_superboss())
    or ((select public.is_restricted_boss()) and incurred_at >= (select public.window_start()))
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists exp_insert on public.expenses;
drop policy if exists exp_insert on public.expenses;
create policy exp_insert on public.expenses for insert
  with check (
    (select public.is_superboss())
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists exp_modify on public.expenses;
drop policy if exists exp_modify on public.expenses;
create policy exp_modify on public.expenses for update
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists exp_delete on public.expenses;
drop policy if exists exp_delete on public.expenses;
create policy exp_delete on public.expenses for delete
  using ((select public.is_superboss()));

-- ──────────────────────────────────────────────────────────────────────────
-- 5. DELIVERIES
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists del_read on public.deliveries;
drop policy if exists del_read on public.deliveries;
create policy del_read on public.deliveries for select
  using (
    (select public.is_superboss())
    or ((select public.is_restricted_boss()) and delivered_at >= (select public.window_start()))
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists del_insert on public.deliveries;
drop policy if exists del_insert on public.deliveries;
create policy del_insert on public.deliveries for insert
  with check (
    (select public.is_superboss())
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists del_update on public.deliveries;
drop policy if exists del_update on public.deliveries;
create policy del_update on public.deliveries for update
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists del_delete on public.deliveries;
drop policy if exists del_delete on public.deliveries;
create policy del_delete on public.deliveries for delete
  using ((select public.is_superboss()));

-- ──────────────────────────────────────────────────────────────────────────
-- 6. AUDIT LOG — Big Boss only. The restricted boss must not be able to read
--    the trail that would show the role change itself.
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists audit_boss_read on public.audit_log;
drop policy if exists audit_superboss_read on public.audit_log;
drop policy if exists audit_superboss_read on public.audit_log;
create policy audit_superboss_read on public.audit_log for select
  using ((select public.is_superboss()));

-- ──────────────────────────────────────────────────────────────────────────
-- 7. WATCHES
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists pw_boss on public.product_watches;
drop policy if exists pw_superboss on public.product_watches;
drop policy if exists pw_superboss on public.product_watches;
create policy pw_superboss on public.product_watches for all
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists wa_boss on public.watch_alerts;
drop policy if exists wa_superboss on public.watch_alerts;
drop policy if exists wa_superboss on public.watch_alerts;
create policy wa_superboss on public.watch_alerts for all
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

-- ──────────────────────────────────────────────────────────────────────────
-- 8. PRICELIST — these inlined role lists would otherwise LOCK OUT the
--    superboss, since 'superboss' is not in ('boss','admin').
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists "write pricelist_categories" on public.pricelist_categories;
drop policy if exists "write pricelist_categories" on public.pricelist_categories;
create policy "write pricelist_categories" on public.pricelist_categories
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists "write pricelist_items" on public.pricelist_items;
drop policy if exists "write pricelist_items" on public.pricelist_items;
create policy "write pricelist_items" on public.pricelist_items
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

-- ──────────────────────────────────────────────────────────────────────────
-- 9. DAHUA — same inlined-role-list problem, plus the restricted boss must
--    lose write access and lose invoice visibility beyond the window.
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists "boss write dahua_warehouses" on public.dahua_warehouses;
drop policy if exists "boss write dahua_warehouses" on public.dahua_warehouses;
create policy "boss write dahua_warehouses" on public.dahua_warehouses
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists "boss insert dahua_stock" on public.dahua_stock;
drop policy if exists "boss insert dahua_stock" on public.dahua_stock;
create policy "boss insert dahua_stock" on public.dahua_stock
  for insert to authenticated with check ((select public.is_superboss()));

drop policy if exists "boss delete dahua_stock" on public.dahua_stock;
drop policy if exists "boss delete dahua_stock" on public.dahua_stock;
create policy "boss delete dahua_stock" on public.dahua_stock
  for delete to authenticated using ((select public.is_superboss()));

-- Stock UPDATE stays open to cashiers (invoice save deducts quantities), but
-- the restricted boss is excluded so their view is genuinely read-only.
drop policy if exists "staff update dahua_stock" on public.dahua_stock;
drop policy if exists "staff update dahua_stock" on public.dahua_stock;
create policy "staff update dahua_stock" on public.dahua_stock
  for update to authenticated
  using ((select public.is_superboss()) or (select public.is_cashier()))
  with check ((select public.is_superboss()) or (select public.is_cashier()));

drop policy if exists "read dahua_invoices" on public.dahua_invoices;
drop policy if exists "read dahua_invoices" on public.dahua_invoices;
create policy "read dahua_invoices" on public.dahua_invoices
  for select to authenticated
  using (
    (select public.is_superboss())
    or ((select public.is_restricted_boss()) and issued_at >= (select public.window_start()))
    or (select public.is_cashier())
  );

drop policy if exists "write dahua_invoices" on public.dahua_invoices;
drop policy if exists "write dahua_invoices" on public.dahua_invoices;
create policy "write dahua_invoices" on public.dahua_invoices
  for insert to authenticated
  with check ((select public.is_superboss()) or (select public.is_cashier()));

drop policy if exists "boss update dahua_invoices" on public.dahua_invoices;
drop policy if exists "boss update dahua_invoices" on public.dahua_invoices;
create policy "boss update dahua_invoices" on public.dahua_invoices
  for update to authenticated using ((select public.is_superboss()));

drop policy if exists "boss delete dahua_invoices" on public.dahua_invoices;
drop policy if exists "boss delete dahua_invoices" on public.dahua_invoices;
create policy "boss delete dahua_invoices" on public.dahua_invoices
  for delete to authenticated using ((select public.is_superboss()));

drop policy if exists "read dahua_invoice_items" on public.dahua_invoice_items;
drop policy if exists "read dahua_invoice_items" on public.dahua_invoice_items;
create policy "read dahua_invoice_items" on public.dahua_invoice_items
  for select to authenticated
  using (exists (
    select 1 from public.dahua_invoices di
    where di.id = invoice_id and (
      (select public.is_superboss())
      or ((select public.is_restricted_boss()) and di.issued_at >= (select public.window_start()))
      or (select public.is_cashier())
    )));

drop policy if exists "write dahua_invoice_items" on public.dahua_invoice_items;
drop policy if exists "write dahua_invoice_items" on public.dahua_invoice_items;
create policy "write dahua_invoice_items" on public.dahua_invoice_items
  for insert to authenticated
  with check ((select public.is_superboss()) or (select public.is_cashier()));

drop policy if exists "boss update dahua_invoice_items" on public.dahua_invoice_items;
drop policy if exists "boss update dahua_invoice_items" on public.dahua_invoice_items;
create policy "boss update dahua_invoice_items" on public.dahua_invoice_items
  for update to authenticated using ((select public.is_superboss()));

drop policy if exists "boss delete dahua_invoice_items" on public.dahua_invoice_items;
drop policy if exists "boss delete dahua_invoice_items" on public.dahua_invoice_items;
create policy "boss delete dahua_invoice_items" on public.dahua_invoice_items
  for delete to authenticated using ((select public.is_superboss()));

-- ──────────────────────────────────────────────────────────────────────────
-- 10. WAREHOUSE STOCK & PRODUCT CODES — read stays open, writes exclude the
--     restricted boss. (Scanning by cashiers is preserved.)
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists warehouse_stock_staff_update on public.warehouse_stock;
drop policy if exists warehouse_stock_staff_update on public.warehouse_stock;
create policy warehouse_stock_staff_update on public.warehouse_stock
  for update to authenticated
  using ((select public.is_superboss()) or (select public.is_cashier()))
  with check ((select public.is_superboss()) or (select public.is_cashier()));

drop policy if exists "write product_codes" on public.product_codes;
drop policy if exists "write product_codes" on public.product_codes;
create policy "write product_codes" on public.product_codes
  for all to authenticated
  using ((select public.is_superboss()) or (select public.is_cashier()))
  with check ((select public.is_superboss()) or (select public.is_cashier()));

-- ──────────────────────────────────────────────────────────────────────────
-- 11. PRODUCTS — catalogue writes are Big-Boss-only.
-- ──────────────────────────────────────────────────────────────────────────
alter table public.products enable row level security;

drop policy if exists products_public_read on public.products;
drop policy if exists products_public_read on public.products;
create policy products_public_read on public.products for select using (true);

drop policy if exists products_superboss_write on public.products;
drop policy if exists products_superboss_write on public.products;
create policy products_superboss_write on public.products for all
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

-- ──────────────────────────────────────────────────────────────────────────
-- 12. REPORTING VIEW — a plain view runs with the OWNER's rights, which would
--     hand the restricted boss all-time totals straight past inv_read.
--     security_invoker makes it respect the caller's RLS.
-- ──────────────────────────────────────────────────────────────────────────
alter view public.sales_by_day set (security_invoker = on);

-- ──────────────────────────────────────────────────────────────────────────
-- 13. CREATE THE BIG BOSS  ← REQUIRED, DO NOT SKIP
--
-- Until a superboss exists, NOBODY can manage staff or write anything: the
-- restricted boss has lost those rights and no account has gained them yet.
-- Run this in the Supabase SQL editor, which connects as the table owner and
-- so is not blocked by the ur_superboss_write policy above.
--
-- Step 1 — create the login. Supabase Dashboard → Authentication → Users →
--          "Add user", email `bigboss@qbnettech.com`, set a password, and tick
--          "Auto Confirm User". (Any email works; the sign-in form on
--          /teamqtech accepts a bare handle and appends @qbnettech.com, so
--          `bigboss` + password is enough to sign in.)
--
-- Step 2 — grant the role. Uncomment, set the email to match, and run:
--
-- insert into public.user_roles (user_id, role, full_name, staff_id)
-- select id, 'superboss', 'Big Boss', email
--   from auth.users where email = 'bigboss@qbnettech.com'
-- on conflict (user_id) do update set role = 'superboss';
--
-- Step 3 — confirm exactly one superboss exists before signing out:
--
-- select u.email, r.role from public.user_roles r
--   join auth.users u on u.id = r.user_id order by r.role;
--
-- To hand the top tier to an EXISTING account instead of a new one:
-- update public.user_roles set role = 'superboss'
--   where user_id = (select id from auth.users where email = 'you@example.com');


-- ############################################################################
-- ## 20260807_perf_last_sold.sql
-- ############################################################################

-- ============================================================================
-- Performance: collapse the last-sold-price lookup into the database.
--
-- fetchLastSoldPrices() was pulling every invoice_items row (9,029 at the time
-- of writing) WITH an embedded invoices(issued_at) join, purely to reduce them
-- client-side to "most recent unit price per description". That is a second
-- full scan of the largest table on every sign-in, on top of the one
-- fetchInvoiceItems() already does.
--
-- There are only 2,383 distinct descriptions behind those 9,029 rows, so doing
-- the reduction in Postgres cuts the payload ~3.8x and drops the request from
-- 10 sequential pages to 3.
--
-- security_invoker keeps row-level security applying to the CALLER — without
-- it the view would run with the owner's rights and hand every role the full
-- price history regardless of the invoice policies.
-- ============================================================================

create or replace view public.last_sold_prices
with (security_invoker = on) as
select distinct on (lower(btrim(ii.description)))
       lower(btrim(ii.description)) as key,
       btrim(ii.description)        as description,
       ii.unit_price                as price,
       i.issued_at                  as issued_at
  from public.invoice_items ii
  join public.invoices i on i.id = ii.invoice_id
 where ii.description is not null
   and btrim(ii.description) <> ''
 order by lower(btrim(ii.description)), i.issued_at desc, ii.id desc;

-- Supports both the DISTINCT ON ordering above and the invoice_items -> invoices
-- join that every dashboard query drives through.
create index if not exists invoice_items_desc_idx
  on public.invoice_items (lower(btrim(description)));
create index if not exists invoice_items_invoice_id_idx
  on public.invoice_items (invoice_id);
create index if not exists invoices_issued_at_idx
  on public.invoices (issued_at desc);

-- The 24-hour window predicates added in 20260807_superboss.sql filter on these.
create index if not exists expenses_incurred_at_idx
  on public.expenses (incurred_at desc);
create index if not exists deliveries_delivered_at_idx
  on public.deliveries (delivered_at desc);


-- ############################################################################
-- ## 20260810_dahua_stock_recount.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Dahua stock recount — 2026-08-10
--
-- Sets opening_stock from a physical count sheet, inserts models that
-- were not previously tracked, then recomputes the derived columns.
--
-- SCOPE: warehouse 'DAHUA-SHOWROOM' only. This is the sole warehouse
-- present in dahua_stock; the four section headings on the count sheet
-- (MAIN / OTHER ACCESSORIES / INTERCOM / SHOP MINI) were pooled into it,
-- and a model appearing in more than one section had its counts summed.
--
--    78 rows updated  (opening_stock overwritten, not added to)
--    10 rows inserted (models not previously in the table)
--    39 rows untouched (not on the count sheet — keep current values)
--
-- daily_taken and invoice_taken are PRESERVED on updated rows, so units
-- already issued via invoices or daily entries are not lost. Rows 1-19 of
-- the count sheet's main section were not supplied and are not covered.
--
-- Run once, in the Supabase SQL editor. Wrapped in a transaction.
-- ─────────────────────────────────────────────────────────────

begin;

-- ── 1. Update opening_stock for models already tracked ────────
with incoming(model, opening_stock) as (
  values
    ('DH-SD3E405DB-GNY-A-PV1',                            1),
    ('DH-SD3C405DB-GNY-A-PV',                             7),
    ('DH-H5D-5F 10MP',                                   11),
    ('DH-H5B 5MP',                                        9),
    ('DH-H5A 5MP',                                       11),
    ('DH-C3A 3MP',                                        1),
    ('DH-HAC-PTS1500CP-E2-IL-A 5MP',                      5),
    ('DH-T4A-PV 4MP',                                     8),
    ('DH-P5AE-PV 5MP',                                    1),
    ('DH-SD2A500NB-GNY-A-PV 5MP',                         1),
    ('DH-HAC-PT1509AP-A-LED 5MP',                         2),
    ('DH-SD2C400NA-B-PV-PRO 4MP',                         1),
    ('DH-HAC-ME1239THP-A-PV',                             5),
    ('DH-HAC-ME1239HP-A-PV',                              5),
    ('DH-IPC-HDW2249T-S-PV',                              5),
    ('DH-IPC-HFW1230S1-S5 2MP',                           1),
    ('DH-IPC-HFW2249TL-S-PV 2MP',                         5),
    ('DH-IPC-PDW3849-A180-AS-PV 8MP',                     1),
    ('DH-IPC-HFW1239DT-4G-ST-IL-EU-B 2MP',                1),
    ('DH-HAC-T2A21P 2MP',                                 5),
    ('DH-IPC-HDW1230T1-S5',                               2),
    ('DH-IPC-HFW1239TL1-PV 2MP',                         41),
    ('DH-IPC-HFW1431S1P-S4 4MP',                          5),
    ('DH-HAC-HFW1200TLMP-IL-T 2MP',                      16),
    ('DH-HAC-T2A51P 5MP',                                 4),
    ('DHI-NVR1108HS-8P-S3/H NETWORK VIDEO RECORDER',     25),
    ('DH-KIT/XVR1B08-1/8-HFW1200CLP-IL-A0360B',           2),
    ('DHI-NVR5464-EL 64CH',                               1),
    ('DH-IPC-HFW2439MP-AS-LED-B-S2 FULL COLOR',           2),
    ('DH-HAC-T1A21P-U 2MP',                             117),
    ('DH-HAC-HDW1509CLQP-A-LED 5MP ',                    71),
    ('DH-HAC-HFW1509CLP-A-LED 5MP',                      22),
    ('DH-HAC-HFW1500RLP-IL-T 5MP',                       22),
    ('DH-HAC-B1A21P-U 2MP ',                             85),
    ('DH-HAC-HFW1500CLP-IL-A   5MP',                    231),
    ('DH-IPC-HFW1439S-A-LED-S4 4MP',                     39),
    ('DH-IPC-HFW2549S-S-IL 5MP',                         20),
    ('DH-IPC-HDW1439V-PV 4MP',                           41),
    ('DH-IPC-HDW1239V-A-IL 2MP',                         48),
    ('DH-IPC-HDW2549T-S-IL 5MP',                         30),
    ('DH-IPC-HFW2649S-S-IL 6MP',                         20),
    ('DH-IPC-HDW1239T1-LED-S5 2MP',                       9),
    ('DH-IPC-HDW1239T1-A-LED 2MP',                       13),
    ('DH-IPC-HDW2649T-S-IL 6MP',                         30),
    ('DH-IPC-HFW2439SP-SA-LED-S2 4MP ',                   4),
    ('DH-IPC-HFW2449S-S-IL 4MP',                         54),
    ('DH-HAC-HDW1500TQP-IL-T 5MP',                       17),
    ('DH-HAC-HFW1200RLP-IL-T 2MP',                       11),
    ('DH-HAC-T1A21P-U-IL-A 2MP',                         26),
    ('DH-HAC-B1A21P-U-IL-A 2MP',                          1),
    ('DH-IPC-HDW1239V-PV 2MP',                           20),
    ('DH-HAC-HDW1209CLQP-A-LED 2MP',                      7),
    ('DH-IPC-HFW2849T-AS-IL SMART DUAL LIGHT',            4),
    ('DH-IPC-HDW2449T-S-PRO WIZ COLOR',                   1),
    ('DHI-NVR1104HS-P-S3/H NETWORK VIDEO RECORDER',      15),
    ('DH-XVR5232AN-I3 HDCVI DIGITAL',                     2),
    ('DH-XVR4232AN-I DIGITAL VIDEO RECORDER',             2),
    ('DHI-NVR2216-4KS3 16CH NVR',                         4),
    ('DHI-NVR4232-16P-4KS3 32CH WITH POE',                5),
    ('DHI-NVR5464-16P-EL',                                1),
    ('DHI-NVR4432-4KS3 32CH',                             3),
    ('DH-CS4226-24ET-375 POE SWITCH',                    26),
    ('DH-CS4218-16ET-240 POE SWITCH',                     6),
    ('DH-CS4010-ET-110 SWITCH',                          10),
    ('DH-CS4010-8ET2GT-110 SWITCH',                       8),
    ('DH-CS4006-4ET2GT-60  SWITCH',                      11),
    ('DH-PFM976-631-PT RJ45 CONNECTOR',               50000),
    ('DH-PFM976-631 RJ45 CONNECTOR',                  50000),
    ('DH-PFM800-N',                                      90),
    ('DH-PFM914 CRIMPING TOOL',                         499),
    ('DH-PFM979-DCP POWER PIN',                       15500),
    ('DH-PFA12A JUNCTION BOX',                          160),
    ('DH-PFM344D-8CH-BS POWER SUPPLY',                   42),
    ('DHI-KTH01',                                        12),
    ('DHI-KTA02 VIDEO INTERCOM KIT',                     30),
    ('DHI-ASA1222GL ACCESS CONTROL',                      1),
    ('DH-IPC-HFW1239TL1-A-IL 2MP',                       61),
    ('DH-IPC-HDW1439V-A-IL 4MP INDOOR',                  30)
)
update dahua_stock s
   set opening_stock = i.opening_stock,
       updated_at    = now()
  from incoming i
 where s.warehouse = 'DAHUA-SHOWROOM'
   and s.model     = i.model;

-- ── 2. Insert models not previously tracked ───────────────────
insert into dahua_stock (warehouse, model, opening_stock, daily_taken, invoice_taken, min_level)
select 'DAHUA-SHOWROOM', v.model, v.opening_stock, '{}'::jsonb, 0, null
  from (values
    ('DH-BP3EW-4G',                    32),
    ('DH-IPC-EB5541P-AS',               2),
    ('DH-H3B',                          3),
    ('DH-P5B-PV',                       5),
    ('DH-HAC-PT1500AP-IL-A',            3),
    ('DH-IPC-PTS2649C-3E3Z-4GB20',     17),
    ('DH-IPC-HDW1200TQP-IL-T',         20),
    ('DH-CS4010-8ET2GT-60',             6),
    ('DH-PFM344D-4CH-BS',              93),
    ('DHI-KTW03',                       2)
       ) as v(model, opening_stock)
 where not exists (
         select 1 from dahua_stock s
          where s.warehouse = 'DAHUA-SHOWROOM'
            and s.model     = v.model
       );

-- ── 3. Recompute derived columns ──────────────────────────────
-- total_taken   = manual daily entries + invoice deductions
-- closing_stock = opening_stock - total_taken
-- stock_status  = '' when no min_level, else LOW / OK
-- Mirrors computeTotals() / computeStatus() in DahuaStockTab.tsx.
update dahua_stock s
   set total_taken   = t.taken,
       closing_stock = s.opening_stock - t.taken,
       stock_status  = case
                         when coalesce(s.min_level, 0) = 0 then ''
                         when s.opening_stock - t.taken < s.min_level then 'LOW'
                         else 'OK'
                       end,
       updated_at    = now()
  from (
         select id,
                coalesce((select sum(value::int)
                            from jsonb_each_text(daily_taken)), 0)
              + coalesce(invoice_taken, 0) as taken
           from dahua_stock
          where warehouse = 'DAHUA-SHOWROOM'
       ) t
 where t.id = s.id;

commit;

-- ── Verification (run after committing) ───────────────────────
-- select count(*)                              as total_rows,
--        count(*) filter (where closing_stock < 0) as negative_closing
--   from dahua_stock where warehouse = 'DAHUA-SHOWROOM';


-- ############################################################################
-- ## 20260810_ezviz_pricelist.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- EZVIZ price list — 22 products
--
-- Creates the 'EZVIZ' category (matching the existing brand-per-category
-- convention: HIKVISION-PRODUCTS, TP-LINK, Tenda Networking) and adds the
-- product list to it.
--
-- COLUMN MAPPING (see addItem() in src/components/admin/PriceList.tsx)
--   Code        -> model
--   Description -> specifications
--   Price       -> ghs_price      (Ghana cedis; the UI reads this directly)
--   name        -> mirrors model  (legacy not-null column, unused by the UI)
--   usd_price   -> 0              (legacy; the FX/duty workflow was dropped in
--                                  20260522_pricelist_revamp.sql)
--
-- Safe to re-run: the category and every item are guarded by NOT EXISTS,
-- so a second run inserts nothing.
-- ─────────────────────────────────────────────────────────────

begin;

-- ── 1. Category ───────────────────────────────────────────────
insert into pricelist_categories (name)
select 'EZVIZ'
 where not exists (
         select 1 from pricelist_categories where name = 'EZVIZ'
       );

-- ── 2. Products ───────────────────────────────────────────────
insert into pricelist_items (category_id, model, name, specifications, ghs_price, usd_price)
select (select id from pricelist_categories where name = 'EZVIZ' limit 1),
       v.model, v.model, v.specifications, v.ghs_price, 0
  from (values
    ('CS-C7-44WF',             'EZVIZ IDual-Lens Pan & Tilt Wi-Fi Camera',                        750),
    ('CS-CB1',                 'Ezviz CB1 Wi-Fi Smart Home Battery Camera-1080p 2MP Resoluti',    550),
    ('CS-CB2-B',               'Ezviz Bullet 2.0Mp Smart Wifi Camera With Battery - Black',       800),
    ('CS-CB2-W',               'Ezviz Bullet 2.0Mp Smart Wifi Camera With Battery - White',       800),
    ('CS-CB3/SP-2K',           'Ezviz Outdoor Smart Home Battery Camera|2Mp Resolution|Recha',    950),
    ('CS-E4P-6MP',             'Smart Wi-Fi Panoramic Fisheye Camera',                           1000),
    ('CS-EB3/SP-2K',           'Ezviz EB3 4G Smart Home Battery Camera',                         1000),
    ('CS-EB8/SP-4KW4GA',       'Ezviz Pt 4K Pan/Tilt Camera 4G With Battery And Solar Panel',    1850),
    ('CS-EP3x/SD7-KIT',        'Ezviz Battery-Powered Video Doorbell Kit',                       1800),
    ('CS-H1C',                 'EZVIZ H1C 1080p Smart Home Wi-Fi Camera',                         350),
    ('CS-H3C-3MP/Colored',     'Ezviz Bullet 3.0MP WiFi Camera Colored',                          550),
    ('CS-H5-4G',               'EZVIZ 3mp 4G Smart Home Camera',                                  665),
    ('CS-H6-5WF-3K',           'Ezviz H6 Smart Home Camera 3K',                                   450),
    ('CS-H7C-44WFW2',          'Ezviz Dual-Lens Pan & Tilt Wi-Fi Camera',                         650),
    ('CS-H80X-8MP+2MP4M',      'EZVIZ 8mp+2mp Dual-Lens Pan & Tilt Wi-Fi Camera',                 950),
    ('CS-H90-4MP+4MP',         'EZVIZ 4mp+4mp Dual-Lens Pan & Tilt Wi-Fi Camera',                 950),
    ('CS-H9C-3MP',             'Ezviz Pan/Tilt 3MP+3MP Dual Lence WiFi Camera',                   750),
    ('CS-HB8/SP-4k',           'Ezviz PT 8.0MP Wifi Camera With Battery With Solar',             1565),
    ('CS-HB8C/SP-4MPW4G',      'Ezviz PT 4.0MP WiFi Camera With Battery 4G',                     1250),
    ('CS-HB90/SP-4MP+4MP',     'Ezviz 4+4mp Dual-Lens All-Day Recording Wi-Fi Camera + Solar',   1750),
    ('CS-HB90X/SP-4MP+4M-4G',  'Ezviz 4+4mp Dual-Lens All-Day Recording Wi-Fi Camera + Solar',   2200),
    ('CS-SD7',                 'Ezviz Smart Screen',                                             1000)
       ) as v(model, specifications, ghs_price)
 where not exists (
         select 1 from pricelist_items pi where pi.model = v.model
       );

commit;

-- ── Verification ──────────────────────────────────────────────
-- select pi.model, pi.specifications, pi.ghs_price
--   from pricelist_items pi
--   join pricelist_categories pc on pc.id = pi.category_id
--  where pc.name = 'EZVIZ'
--  order by pi.model;


-- ############################################################################
-- ## 20260906_dahua_pricing.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Dahua fixed pricing — 2026-09-06
--
-- Gives every Dahua product ONE selling price, held on the product itself,
-- and makes that price the price an invoice line is written with.
--
-- Before this migration the cashier typed a unit price by hand on every
-- Dahua invoice line. Nothing tied the number to the product, so the same
-- model went out at different prices and dahua_invoices.total could not be
-- read as "what this product sells for" — which is what broke sales
-- tracking. dahua_stock now carries unit_price, and three triggers keep it
-- honest:
--
--   1. dahua_stock_lock_price      only the Big Boss may change a price.
--   2. dahua_item_apply_price      an invoice line linked to a product is
--                                  written at that product's price, whoever
--                                  saves it; line_total is always derived.
--   3. dahua_invoice_resync_totals the invoice header (subtotal / VAT /
--                                  total) is recomputed from its own lines,
--                                  so a snapped price can never leave the
--                                  header disagreeing with the items.
--
-- Enforcement is in the database, not only in the React gates. Cashiers hold
-- UPDATE on dahua_stock (invoice save deducts quantities) and INSERT on
-- dahua_invoice_items, so a REST client with the anon key could otherwise
-- rewrite prices freely. RLS cannot express "every column but this one", so
-- the column-level rule is a trigger.
--
-- Unpriced products (unit_price = 0) are deliberately left alone by trigger 2
-- so the shop is not blocked before the price list is entered — the cashier
-- can still type a price on those, and the admin UI flags them.
--
-- Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────

begin;

-- ── 1. The price column ───────────────────────────────────────
alter table public.dahua_stock
  add column if not exists unit_price numeric(12,2) not null default 0;

comment on column public.dahua_stock.unit_price is
  'Fixed selling price in GH¢. Big Boss only. Auto-fills and locks the unit '
  'price on any invoice line linked to this product. 0 = not yet priced.';

-- ── 2. Only the Big Boss may change a price ───────────────────
-- Cashiers legitimately UPDATE this table on every invoice save (stock
-- deduction). Those updates leave unit_price untouched, so they pass; an
-- attempt to alter the price itself is rejected.
--
-- The auth.uid() test is what lets a migration run. A session with no JWT is
-- not an app user at all — it is the Supabase SQL editor, psql, or the
-- service-role key. Those already bypass RLS entirely, so refusing them here
-- buys no safety and only blocks the very migrations that set prices in bulk.
-- The lock still binds every request that arrives through the app, which is
-- where cashiers actually are.
create or replace function public.dahua_stock_lock_price()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.unit_price is distinct from old.unit_price
     and (select auth.uid()) is not null
     and not (select public.is_superboss()) then
    raise exception
      'Only the Big Boss may change a Dahua selling price (%)', old.model
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_dahua_stock_lock_price on public.dahua_stock;
create trigger trg_dahua_stock_lock_price
  before update on public.dahua_stock
  for each row execute function public.dahua_stock_lock_price();

-- ── 3. Invoice lines are written at the product's price ───────
-- The Big Boss keeps the ability to override a line (a negotiated sale).
-- Everyone else gets the fixed price regardless of what the client sent.
-- line_total is always derived, never trusted from the client.
create or replace function public.dahua_item_apply_price()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  fixed numeric(12,2);
begin
  if new.stock_id is not null then
    select unit_price into fixed
      from public.dahua_stock
     where id = new.stock_id;

    -- unit_price = 0 means the product has not been priced yet; leave the
    -- typed price alone rather than zeroing out the sale. As above, a session
    -- with no JWT is a console or the service role, not a cashier — it writes
    -- the price it states.
    if fixed is not null and fixed > 0
       and (select auth.uid()) is not null
       and not (select public.is_superboss()) then
      new.unit_price := fixed;
    end if;
  end if;

  new.line_total := round(new.quantity * new.unit_price, 2);
  return new;
end;
$$;

drop trigger if exists trg_dahua_item_apply_price on public.dahua_invoice_items;
create trigger trg_dahua_item_apply_price
  before insert or update on public.dahua_invoice_items
  for each row execute function public.dahua_item_apply_price();

-- ── 4. Header totals always match the lines ───────────────────
-- Runs as definer because a cashier has no UPDATE on dahua_invoices.
create or replace function public.dahua_invoice_resync_totals()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  inv  uuid;
  sub  numeric(12,2);
  rate numeric(5,2);
  vat  numeric(12,2);
begin
  inv := coalesce(new.invoice_id, old.invoice_id);

  select vat_rate into rate from public.dahua_invoices where id = inv;
  if rate is null then
    return null;  -- invoice already gone (cascade delete)
  end if;

  select coalesce(sum(line_total), 0) into sub
    from public.dahua_invoice_items
   where invoice_id = inv;

  vat := round(sub * rate / 100, 2);

  update public.dahua_invoices
     set subtotal   = sub,
         vat_amount = vat,
         total      = round(sub + vat, 2)
   where id = inv;

  return null;
end;
$$;

drop trigger if exists trg_dahua_invoice_resync_totals on public.dahua_invoice_items;
create trigger trg_dahua_invoice_resync_totals
  after insert or update or delete on public.dahua_invoice_items
  for each row execute function public.dahua_invoice_resync_totals();

-- ── 5. Sales-tracking index ───────────────────────────────────
-- The dashboard and invoice list both scan by date.
create index if not exists dahua_invoices_issued_at_idx
  on public.dahua_invoices (issued_at desc);
create index if not exists dahua_invoice_items_invoice_id_idx
  on public.dahua_invoice_items (invoice_id);

commit;

-- ── Optional: seed prices from the existing pricelist ─────────
-- Copies ghs_price onto any Dahua product whose model matches a pricelist
-- code exactly. Most Dahua models are not in pricelist_items, so this only
-- saves a little typing — the rest are entered in Admin → Dahua Stock →
-- 💰 Prices. Run it as the Big Boss, or the price-lock trigger will reject it.
--
-- update public.dahua_stock s
--    set unit_price = pi.ghs_price
--   from public.pricelist_items pi
--  where upper(trim(s.model)) = upper(trim(pi.model))
--    and s.unit_price = 0
--    and pi.ghs_price > 0;

-- ── Verification ──────────────────────────────────────────────
-- select count(*) filter (where unit_price > 0) as priced,
--        count(*) filter (where unit_price = 0) as unpriced
--   from public.dahua_stock;


-- ############################################################################
-- ## 20260906_dahua_price_list.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Dahua price list — 2026-09-06
--
-- Sets dahua_stock.unit_price from the shop's price sheet. Requires
-- 20260906_dahua_pricing.sql (the unit_price column and its triggers).
--
-- Run it in the Supabase SQL editor. The SQL editor connects as postgres with
-- no JWT, which trg_dahua_stock_lock_price treats as a privileged console
-- session and lets through; the lock still binds every price change that
-- arrives through the app. (If the trigger rejects this file, the database is
-- still on the first version of 20260906_dahua_pricing.sql — re-run that file,
-- it is idempotent, then come back to this one.)
--
-- MATCHING
--   The sheet writes bare model codes ("DH-H5B") while dahua_stock stores the
--   code plus a descriptor ("DH-H5B 5MP"), so codes were matched on the model
--   with that trailing descriptor removed, ignoring case and punctuation.
--   68 matched outright. 9 were accepted as character misreads where the
--   intent is unambiguous (I read as 1, S as 5, EI for EL); each is marked
--   inline with the code as it appears on the sheet.
--
--   Lookalikes were NOT auto-matched. A digit that changes the megapixel class
--   (1239 vs 1439) or the series letters (HFW vs HDW) is a different camera,
--   so those are left for a decision rather than guessed at — see the notes at
--   the foot of this file.
--
-- Prices are in GH¢. Re-running is safe: it simply reasserts the same values.
-- ─────────────────────────────────────────────────────────────

begin;

with incoming(model, price) as (
  values
    ('DH-BP3EW-4G'                            ,     750),
    ('DH-C3A 3MP'                             ,     350),
    ('DH-CS4006-4ET2GT-60  SWITCH'            ,     400),
    ('DH-CS4010-8ET2GT-110 SWITCH'            ,     600),  -- sheet reads "DHI-CS410-8ET2GT---110"
    ('DH-CS4010-8ET2GT-60'                    ,     500),
    ('DH-CS4218-16ET-240 POE SWITCH'          ,    1600),
    ('DH-H3B'                                 ,     700),
    ('DH-H5A 5MP'                             ,     500),
    ('DH-H5B 5MP'                             ,     600),
    ('DH-H5D-5F 10MP'                         ,     650),
    ('DH-HAC-B1A21P-U 2MP '                   ,     150),  -- sheet reads "DH-HAC-BIA21P-U"
    ('DH-HAC-B1A21P-U-IL-A 2MP'               ,     180),  -- sheet reads "DH-HAC-BIA21P-U-IL-A"
    ('DH-HAC-HDW1209CLQP-A-LED 2MP'           ,     190),
    ('DH-HAC-HDW1500TQP-IL-T 5MP'             ,     320),
    ('DH-HAC-HDW1509CLQP-A-LED 5MP '          ,     295),
    ('DH-HAC-HFW1200TLMP-IL-T 2MP'            ,     300),
    ('DH-HAC-HFW1500CLP-IL-A   5MP'           ,     200),
    ('DH-HAC-HFW1500RLP-IL-T 5MP'             ,     320),
    ('DH-HAC-HFW1509CLP-A-LED 5MP'            ,     295),
    ('DH-HAC-ME1239HP-A-PV'                   ,     450),
    ('DH-HAC-ME1239THP-A-PV'                  ,     450),
    ('DH-HAC-PT1500AP-IL-A'                   ,     550),
    ('DH-HAC-PT1509AP-A-LED 5MP'              ,     550),
    ('DH-HAC-PTS1500CP-E2-IL-A 5MP'           ,     700),
    ('DH-HAC-T1A21P-U-IL-A 2MP'               ,     180),
    ('DH-HAC-T2A21P 2MP'                      ,     150),
    ('DH-IPC-EB5541P-AS'                      ,    2000),
    ('DH-IPC-HDW1200TQP-IL-T'                 ,     250),
    ('DH-IPC-HDW1239T1-A-LED 2MP'             ,     350),
    ('DH-IPC-HDW1239T1-LED-S5 2MP'            ,     350),
    ('DH-IPC-HDW1239V-PV 2MP'                 ,     450),
    ('DH-IPC-HDW1439V-A-IL 4MP INDOOR'        ,     555),
    ('DH-IPC-HDW1439V-PV 4MP'                 ,     550),
    ('DH-IPC-HDW2249T-S-PV'                   ,     650),
    ('DH-IPC-HDW2449T-S-PRO WIZ COLOR'        ,     950),
    ('DH-IPC-HDW2549T-S-IL 5MP'               ,     750),  -- sheet reads "DH-IPC-HDW2549T-5-IL"
    ('DH-IPC-HDW2649T-S-IL 6MP'               ,     750),
    ('DH-IPC-HFW1230S1-S5 2MP'                ,     300),
    ('DH-IPC-HFW1239DT-4G-ST-IL-EU-B 2MP'     ,     800),
    ('DH-IPC-HFW1239TL1-A-IL 2MP'             ,     410),
    ('DH-IPC-HFW1239TL1-PV 2MP'               ,     420),
    ('DH-IPC-HFW1431S1P-S4 4MP'               ,     300),
    ('DH-IPC-HFW1439S-A-LED-S4 4MP'           ,     500),
    ('DH-IPC-HFW2249TL-S-PV 2MP'              ,     650),
    ('DH-IPC-HFW2439MP-AS-LED-B-S2 FULL COLOR',     700),
    ('DH-IPC-HFW2439SP-SA-LED-S2 4MP '        ,     500),
    ('DH-IPC-HFW2449S-S-IL 4MP'               ,     650),
    ('DH-IPC-HFW2549S-S-IL 5MP'               ,     750),
    ('DH-IPC-HFW2649S-S-IL 6MP'               ,     750),
    ('DH-IPC-HFW2849T-AS-IL SMART DUAL LIGHT' ,    1300),
    ('DH-IPC-PDW3849-A180-AS-PV 8MP'          ,    2700),
    ('DH-IPC-PTS2649C-3E3Z-4GB20'             ,    1850),
    ('DH-KIT/XVR1B08-1/8-HFW1200CLP-IL-A0360B',    2450),  -- sheet reads "DH-KIT/XVR1B08-I/8-HFW1200CLP-IL-A-0360B"
    ('DH-P5B-PV'                              ,     650),
    ('DH-PFA12A JUNCTION BOX'                 ,      35),
    ('DH-PFM344D-4CH-BS'                      ,     100),
    ('DH-PFM344D-8CH-BS POWER SUPPLY'         ,     130),
    ('DH-PFM800-N'                            ,      25),
    ('DH-PFM914 CRIMPING TOOL'                ,     130),
    ('DH-PFM976-631 RJ45 CONNECTOR'           ,     0.5),
    ('DH-PFM976-631-PT RJ45 CONNECTOR'        ,     0.5),
    ('DH-PFM979-DCP POWER PIN'                ,       3),
    ('DH-SD2A500NB-GNY-A-PV 5MP'              ,     650),
    ('DH-SD3C405DB-GNY-A-PV'                  ,    1650),
    ('DH-SD3E405DB-GNY-A-PV1'                 ,    2000),
    ('DH-T4A-PV 4MP'                          ,     550),
    ('DH-XVR4232AN-I DIGITAL VIDEO RECORDER'  ,    2200),  -- sheet reads "DH-XVR4232AN-1"
    ('DH-XVR5232AN-I3 HDCVI DIGITAL'          ,    3200),  -- sheet reads "DH-XVR5232AN-13"
    ('DHI-ASA1222GL ACCESS CONTROL'           ,     700),
    ('DHI-KTA02 VIDEO INTERCOM KIT'           ,     750),
    ('DHI-KTH01'                              ,    1100),
    ('DHI-KTW03'                              ,    1650),
    ('DHI-NVR2216-4KS3 16CH NVR'              ,    1000),
    ('DHI-NVR4232-16P-4KS3 32CH WITH POE'     ,    2650),
    ('DHI-NVR4432-4KS3 32CH'                  ,    2500),  -- sheet reads "DHI-NVR4432-4K53"
    ('DHI-NVR5464-16P-EL'                     ,    7500),
    ('DHI-NVR5464-EL 64CH'                    ,    6800)  -- sheet reads "DHI-NVR5464-EI"
)
update public.dahua_stock s
   set unit_price = i.price,
       updated_at = now()
  from incoming i
 where s.model = i.model
   and s.unit_price is distinct from i.price;

commit;

-- ── Verification ──────────────────────────────────────────────
-- select count(*) filter (where unit_price > 0) as priced,
--        count(*) filter (where unit_price = 0) as unpriced
--   from public.dahua_stock;
--
-- select model from public.dahua_stock where unit_price = 0 order by model;

-- ═════════════════════════════════════════════════════════════
-- NOT APPLIED — needs a decision
-- ═════════════════════════════════════════════════════════════
--
-- 1. CONTRADICTORY PRICES — the sheet lists these twice, at two prices.
--    Neither was applied; pick one in Admin → Dahua Stock → 💰 Prices.
--      DH-HAC-T1A21P-U 2MP
--        "DH-HAC-T1A21P-U" = GH¢180  vs  "DH-HAC-TIA21P-U" = GH¢150
--      DHI-NVR1108HS-8P-S3/H NETWORK VIDEO RECORDER
--        "DHI-NVR1108HS-8P-S3/H" = GH¢900  vs  "DHI-NVR1108HS-8P-S3/H" = GH¢950
--      DH-IPC-HDW1239V-A-IL 2MP
--        "DH-IPC-HDW1239V-A-IL" = GH¢450  vs  "DH-IPC-HDW1239V-A-IL" = GH¢420
--
-- 2. PROBABLE MISREADS — likely the same product, but the change is not
--    self-evident, so they were left alone rather than guessed:
--      sheet "DH-P5AF-PV"  ->  db "DH-P5AE-PV 5MP"  @ GH¢650
--      sheet "DHI-NVR1104HS-4P-S3/H"  ->  db "DHI-NVR1104HS-P-S3/H NETWORK VIDEO RECORDER"  @ GH¢650
--      sheet "DH-CS4225-24ET-375"  ->  db "DH-CS4226-24ET-375 POE SWITCH"  @ GH¢1950
--      sheet "DH-CS4010-8ET-110"  ->  db "DH-CS4010-ET-110 SWITCH"  @ GH¢600
--
-- 3. NOT IN dahua_stock — on the sheet but no such product in the table.
--    HANDLED: 20260906_dahua_new_products.sql creates and prices these, with
--    opening stock 0. Run it after this file; each still needs a real
--    opening count entering on the Dahua Stock tab.
--      DH-IPC-HFW1439TL1-A-IL                       GH¢585   (near, but NOT the same as "DH-IPC-HFW1239TL1-A-IL 2MP")
--      DH-IPC-HFW1439TL1-PV                         GH¢510   (near, but NOT the same as "DH-IPC-HFW1239TL1-PV 2MP")
--      DH-IPC-HDW2449T-S-IL                         GH¢620   (near, but NOT the same as "DH-IPC-HDW2549T-S-IL 5MP")
--      DH-IPC-HFW1239S1-A-LED                       GH¢400   (near, but NOT the same as "DH-IPC-HDW1239T1-A-LED 2MP")
--      DH-IPC-HFW1439S1-A-LED                       GH¢500   (near, but NOT the same as "DH-IPC-HFW1439S-A-LED-S4 4MP")
--      DH-IPC-HDW1439T1-A-LED                       GH¢500   (near, but NOT the same as "DH-IPC-HDW1239T1-A-LED 2MP")
--      DHI-KTP01L                                   GH¢2200   (near, but NOT the same as "DHI-KTH01")
--      DHI-KTP10                                    GH¢2200   (near, but NOT the same as "DHI-KTH01")
--      DHI-KTP02                                    GH¢1900   (near, but NOT the same as "DHI-KTA02 VIDEO INTERCOM KIT")
--      DH-HAC-HDW1200TQP-IL-T ANALOG                GH¢235
--      DH-XVR1B16-I/T                               GH¢900
--      DH-XVR1B04H-I/T                              GH¢550
--      DH-XVR1B08H-I                                GH¢750
--      DH-XVR1B08H-I/T                              GH¢750
--      DH-XVR1B16H-I                                GH¢900
--      DH-XVR1B08-I/T                               GH¢450
--      DH-SD4E425GB-HNR-A-PV1                       GH¢4300
--      DH-SDT4E425-8P-GB-APV1                       GH¢5300
--      DH-SD3D416NB-GNY                             GH¢2350
--      DH-SDT3E410-8P-MB-A-PV1                      GH¢3400


-- ############################################################################
-- ## 20260906_dahua_new_products.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Dahua — products on the price sheet but not yet in stock — 2026-09-06
--
-- Adds the 20 models that 20260906_dahua_price_list.sql could not price
-- because no such row existed in dahua_stock, and prices them at the same
-- time. Run it after that migration, in the Supabase SQL editor — which
-- connects as postgres and so bypasses the superboss-only INSERT policy on
-- dahua_stock.
--
-- OPENING STOCK IS 0 for every row. A price sheet says what a product sells
-- for, not how many are on the shelf, so these are created as priced but
-- uncounted: they appear in the invoice autocomplete showing "0 in stock",
-- and the Dahua Stock tab lists them as EMPTY until someone edits each one
-- and enters a real opening count. Selling one before that will drive its
-- closing stock negative, which the tab shows in red.
--
-- DUPLICATE GUARD
--   Only 88 of the models in dahua_stock are known from the count sheet in
--   20260810_dahua_stock_recount.sql; the table holds others besides. So each
--   insert is guarded by a NOT EXISTS that compares models with case and
--   punctuation stripped and allows the trailing descriptor the table adds
--   ("DH-H5B" matching "DH-H5B 5MP"). If anything resembling the code is
--   already present, the row is skipped rather than duplicated.
--
--   Check what was skipped by comparing the reported row count to 20.
--
-- These are NOT near-misses of existing products. Where a code merely looks
-- like one already in the table, the difference is a real one — a digit that
-- changes the megapixel class (1239 vs 1439) or the series letters (HFW vs
-- HDW) — and the existing model is named in a comment beside it.
--
-- Safe to re-run: the guard makes a second run insert nothing.
-- ─────────────────────────────────────────────────────────────

begin;

with incoming(model, price) as (
  values
    ('DH-IPC-HFW1439TL1-A-IL'       ,     585),  -- distinct from "DH-IPC-HFW1239TL1-A-IL 2MP"
    ('DH-IPC-HFW1439TL1-PV'         ,     510),  -- distinct from "DH-IPC-HFW1239TL1-PV 2MP"
    ('DH-IPC-HDW2449T-S-IL'         ,     620),  -- distinct from "DH-IPC-HDW2549T-S-IL 5MP"
    ('DH-IPC-HFW1239S1-A-LED'       ,     400),  -- distinct from "DH-IPC-HDW1239T1-A-LED 2MP"
    ('DH-IPC-HFW1439S1-A-LED'       ,     500),  -- distinct from "DH-IPC-HFW1439S-A-LED-S4 4MP"
    ('DH-IPC-HDW1439T1-A-LED'       ,     500),  -- distinct from "DH-IPC-HDW1239T1-A-LED 2MP"
    ('DHI-KTP01L'                   ,    2200),  -- distinct from "DHI-KTH01"
    ('DHI-KTP10'                    ,    2200),  -- distinct from "DHI-KTH01"
    ('DHI-KTP02'                    ,    1900),  -- distinct from "DHI-KTA02 VIDEO INTERCOM KIT"
    ('DH-HAC-HDW1200TQP-IL-T ANALOG',     235),
    ('DH-XVR1B16-I/T'               ,     900),
    ('DH-XVR1B04H-I/T'              ,     550),
    ('DH-XVR1B08H-I'                ,     750),
    ('DH-XVR1B08H-I/T'              ,     750),
    ('DH-XVR1B16H-I'                ,     900),
    ('DH-XVR1B08-I/T'               ,     450),
    ('DH-SD4E425GB-HNR-A-PV1'       ,    4300),
    ('DH-SDT4E425-8P-GB-APV1'       ,    5300),
    ('DH-SD3D416NB-GNY'             ,    2350),
    ('DH-SDT3E410-8P-MB-A-PV1'      ,    3400)
)
insert into public.dahua_stock
       (warehouse, model, opening_stock, daily_taken, total_taken,
        invoice_taken, closing_stock, min_level, stock_status, unit_price)
select 'DAHUA-SHOWROOM', i.model, 0, '{}'::jsonb, 0,
       0, 0, null, '', i.price
  from incoming i
 where not exists (
         select 1
           from public.dahua_stock s
          where regexp_replace(upper(s.model), '[^A-Z0-9]', '', 'g')
                like regexp_replace(upper(i.model), '[^A-Z0-9]', '', 'g') || '%'
       );

commit;

-- ── Verification ──────────────────────────────────────────────
-- Should list 20 rows, each priced, each with 0 opening stock:
--
-- select model, unit_price, opening_stock
--   from public.dahua_stock
--  where opening_stock = 0 and unit_price > 0
--  order by model;
--
-- Anything still unpriced (expect only the four the sheet left blank):
--
-- select model from public.dahua_stock where unit_price = 0 order by model;


-- ############################################################################
-- ## 20260906_dahua_price_override.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Dahua — staff may override a fixed price, but every override is logged
-- 2026-09-06
--
-- Replaces the hard lock added in 20260906_dahua_pricing.sql. A cashier at
-- the counter can now sell at a negotiated price; what changes is that the
-- invoice line remembers what the price SHOULD have been, and the override
-- is written to public.audit_log where the boss already reads it.
--
-- Requires 20260906_dahua_pricing.sql. Run in the Supabase SQL editor.
--
-- WHAT IS AND IS NOT UNLOCKED
--   Overriding one line of one invoice is not the same as repricing a
--   product. dahua_stock.unit_price stays Big-Boss-only
--   (trg_dahua_stock_lock_price is untouched), so a cashier can discount a
--   sale but cannot quietly move the shop's price and hide the discount.
--
-- WHY list_price IS A STORED COLUMN
--   An override is only detectable against the price that applied at the
--   time of sale. Reading dahua_stock.unit_price later gives today's price,
--   so a repricing would silently turn old sales into overrides, or hide
--   real ones. The line therefore carries its own copy.
--
-- Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────

begin;

-- ── 1. Remember the price that applied when the line was written ──
alter table public.dahua_invoice_items
  add column if not exists list_price numeric(12,2) not null default 0;

comment on column public.dahua_invoice_items.list_price is
  'The product''s fixed price at the moment this line was saved. 0 = the '
  'product had no fixed price (or the line is free text). An override is '
  'list_price > 0 and unit_price <> list_price.';

-- Back-fill: every line written before this migration was forced to the
-- product price, so its list_price is its unit_price. Marking them 0 would
-- read as "never had a fixed price", which is the opposite of what happened.
update public.dahua_invoice_items
   set list_price = unit_price
 where list_price = 0
   and stock_id is not null;

-- ── 2. Record the fixed price; allow the sale price to differ ─────
-- Supersedes the version in 20260906_dahua_pricing.sql, which forced
-- new.unit_price to the product price for anyone but the Big Boss.
create or replace function public.dahua_item_apply_price()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  fixed numeric(12,2);
begin
  if new.stock_id is not null then
    select unit_price into fixed
      from public.dahua_stock
     where id = new.stock_id;

    new.list_price := coalesce(fixed, 0);

    -- A line saved with no price at all takes the fixed price. This is what
    -- makes the price "automatic" in the ordinary case: the cashier picks a
    -- product and does nothing else. Typing a different figure is an
    -- override, and step 3 logs it.
    if coalesce(new.unit_price, 0) = 0 and coalesce(fixed, 0) > 0 then
      new.unit_price := fixed;
    end if;
  else
    new.list_price := 0;
  end if;

  -- Never trusted from the client.
  new.line_total := round(new.quantity * new.unit_price, 2);
  return new;
end;
$$;

-- ── 3. Log every override to audit_log ────────────────────────────
-- Definer because a cashier has no INSERT on audit_log — the same pattern
-- fn_audit() uses for invoices and expenses.
create or replace function public.dahua_log_price_override()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  inv  record;
  mdl  text;
begin
  -- Nothing to compare against when the product has no fixed price.
  if coalesce(new.list_price, 0) <= 0 then return null; end if;
  if new.unit_price = new.list_price   then return null; end if;

  select invoice_number, customer_name, issued_at
    into inv
    from public.dahua_invoices
   where id = new.invoice_id;

  select model into mdl from public.dahua_stock where id = new.stock_id;

  insert into public.audit_log (actor_id, actor_role, action, table_name, row_id, diff)
  values (
    auth.uid(),
    public.current_role(),
    'override',
    'dahua_price_override',
    new.id::text,
    jsonb_build_object(
      'model',          coalesce(mdl, new.description),
      'description',    new.description,
      'invoice_id',     new.invoice_id,
      'invoice_number', inv.invoice_number,
      'customer_name',  inv.customer_name,
      'quantity',       new.quantity,
      'list_price',     new.list_price,
      'unit_price',     new.unit_price,
      'difference',     round(new.unit_price - new.list_price, 2),
      'total_effect',   round((new.unit_price - new.list_price) * new.quantity, 2)
    )
  );
  return null;
end;
$$;

drop trigger if exists trg_dahua_log_price_override on public.dahua_invoice_items;
create trigger trg_dahua_log_price_override
  after insert or update on public.dahua_invoice_items
  for each row execute function public.dahua_log_price_override();

commit;

-- ── Verification ──────────────────────────────────────────────
-- Overrides so far, newest first:
--
-- select created_at,
--        diff->>'invoice_number' as invoice,
--        diff->>'model'          as model,
--        diff->>'list_price'     as should_be,
--        diff->>'unit_price'     as sold_at,
--        diff->>'total_effect'   as effect
--   from public.audit_log
--  where table_name = 'dahua_price_override'
--  order by created_at desc;
--
-- Total given away (or gained) this month:
--
-- select sum((diff->>'total_effect')::numeric)
--   from public.audit_log
--  where table_name = 'dahua_price_override'
--    and created_at >= date_trunc('month', now());


-- ############################################################################
-- ## 20260913_dahua_expenses_deliveries_codes.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Dahua — expenses, deliveries, barcodes and activity logging
-- 2026-09-13
--
-- Gives the Dahua business line the same back-office the main shop has:
--
--   dahua_expenses       mirror of public.expenses
--   dahua_deliveries     mirror of public.deliveries
--   dahua_product_codes  mirror of public.product_codes (barcode → Dahua model)
--
-- They are separate tables, not a "line" column on the shared ones, for the
-- same reason dahua_invoices is: the main dashboard's totals must not move.
--
-- ACCESS — copied from 20260807_superboss.sql, table for table:
--   read    superboss: all · restricted boss: last 24h · cashier: own rows
--   insert  superboss, or a cashier writing their own row
--   update/delete  superboss only
--   codes   read: any signed-in user · write: superboss or cashier
--           (scanning is done by cashiers; restricted boss stays read-only)
--
-- LOGGING — fn_audit() (20260417_sales_system.sql) is attached to every
-- Dahua table that moves money or stock, so the Log tab covers both sides.
--
-- Requires 20260807_superboss.sql (is_superboss / is_restricted_boss /
-- is_cashier / window_start). Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────

begin;

-- ── 1. Expenses ───────────────────────────────────────────────
create table if not exists public.dahua_expenses (
  id          uuid primary key default gen_random_uuid(),
  category    text not null default 'General',
  description text,
  amount      numeric(12,2) not null,
  incurred_at timestamptz not null default now(),
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists dahua_expenses_incurred_idx   on public.dahua_expenses (incurred_at desc);
create index if not exists dahua_expenses_created_by_idx on public.dahua_expenses (created_by);

alter table public.dahua_expenses enable row level security;

drop policy if exists dexp_read on public.dahua_expenses;
drop policy if exists dexp_read on public.dahua_expenses;

create policy dexp_read on public.dahua_expenses for select
  using (
    (select public.is_superboss())
    or ((select public.is_restricted_boss()) and incurred_at >= (select public.window_start()))
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists dexp_insert on public.dahua_expenses;
drop policy if exists dexp_insert on public.dahua_expenses;

create policy dexp_insert on public.dahua_expenses for insert
  with check (
    (select public.is_superboss())
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists dexp_update on public.dahua_expenses;
drop policy if exists dexp_update on public.dahua_expenses;

create policy dexp_update on public.dahua_expenses for update
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists dexp_delete on public.dahua_expenses;
drop policy if exists dexp_delete on public.dahua_expenses;

create policy dexp_delete on public.dahua_expenses for delete
  using ((select public.is_superboss()));

-- ── 2. Deliveries ─────────────────────────────────────────────
create table if not exists public.dahua_deliveries (
  id             uuid primary key default gen_random_uuid(),
  customer_name  text,
  location       text,
  amount         numeric not null default 0,
  payment_method text   not null default 'Cash',   -- 'Cash' | 'Mobile Money'
  note           text,
  delivered_at   timestamptz not null default now(),
  created_by     uuid references auth.users(id) on delete set null,
  created_at     timestamptz not null default now()
);
create index if not exists dahua_deliveries_delivered_at_idx on public.dahua_deliveries (delivered_at desc);
create index if not exists dahua_deliveries_created_by_idx   on public.dahua_deliveries (created_by);

alter table public.dahua_deliveries enable row level security;

drop policy if exists ddel_read on public.dahua_deliveries;
drop policy if exists ddel_read on public.dahua_deliveries;

create policy ddel_read on public.dahua_deliveries for select
  using (
    (select public.is_superboss())
    or ((select public.is_restricted_boss()) and delivered_at >= (select public.window_start()))
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists ddel_insert on public.dahua_deliveries;
drop policy if exists ddel_insert on public.dahua_deliveries;

create policy ddel_insert on public.dahua_deliveries for insert
  with check (
    (select public.is_superboss())
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists ddel_update on public.dahua_deliveries;
drop policy if exists ddel_update on public.dahua_deliveries;

create policy ddel_update on public.dahua_deliveries for update
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists ddel_delete on public.dahua_deliveries;
drop policy if exists ddel_delete on public.dahua_deliveries;

create policy ddel_delete on public.dahua_deliveries for delete
  using ((select public.is_superboss()));

-- ── 3. Barcodes ───────────────────────────────────────────────
-- One model per code; re-linking a code overwrites the mapping (upsert on
-- material_code), exactly like product_codes. `model` is a dahua_stock.model.
create table if not exists public.dahua_product_codes (
  id            uuid primary key default gen_random_uuid(),
  material_code text not null,
  model         text not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create unique index if not exists dahua_product_codes_material_code_key
  on public.dahua_product_codes (material_code);

alter table public.dahua_product_codes enable row level security;

drop policy if exists "read dahua_product_codes" on public.dahua_product_codes;
drop policy if exists "read dahua_product_codes" on public.dahua_product_codes;

create policy "read dahua_product_codes" on public.dahua_product_codes
  for select to authenticated using (true);

drop policy if exists "write dahua_product_codes" on public.dahua_product_codes;
drop policy if exists "write dahua_product_codes" on public.dahua_product_codes;

create policy "write dahua_product_codes" on public.dahua_product_codes
  for all to authenticated
  using ((select public.is_superboss()) or (select public.is_cashier()))
  with check ((select public.is_superboss()) or (select public.is_cashier()));

-- ── 4. Activity logging ───────────────────────────────────────
drop trigger if exists trg_audit_dahua_expenses on public.dahua_expenses;
create trigger trg_audit_dahua_expenses
  after insert or update or delete on public.dahua_expenses
  for each row execute function public.fn_audit();

drop trigger if exists trg_audit_dahua_deliveries on public.dahua_deliveries;
create trigger trg_audit_dahua_deliveries
  after insert or update or delete on public.dahua_deliveries
  for each row execute function public.fn_audit();

drop trigger if exists trg_audit_dahua_product_codes on public.dahua_product_codes;
create trigger trg_audit_dahua_product_codes
  after insert or update or delete on public.dahua_product_codes
  for each row execute function public.fn_audit();

drop trigger if exists trg_audit_dahua_stock on public.dahua_stock;
create trigger trg_audit_dahua_stock
  after insert or update or delete on public.dahua_stock
  for each row execute function public.fn_audit();

-- dahua_invoices gets its UPDATE logged only when something actually changed.
-- trg_dahua_invoice_resync_totals rewrites the header after every line item
-- is saved; on a normal save the figures come out identical, and without the
-- WHEN clause each invoice would log one empty "update" per line.
drop trigger if exists trg_audit_dahua_invoices     on public.dahua_invoices;
drop trigger if exists trg_audit_dahua_invoices_upd on public.dahua_invoices;
create trigger trg_audit_dahua_invoices
  after insert or delete on public.dahua_invoices
  for each row execute function public.fn_audit();
create trigger trg_audit_dahua_invoices_upd
  after update on public.dahua_invoices
  for each row when (old.* is distinct from new.*)
  execute function public.fn_audit();

commit;

-- ── Verification ──────────────────────────────────────────────
-- select tablename, policyname, cmd from pg_policies
--  where tablename in ('dahua_expenses','dahua_deliveries','dahua_product_codes')
--  order by tablename, cmd;
--
-- select event_object_table, trigger_name from information_schema.triggers
--  where trigger_name like 'trg_audit_dahua%' order by 1;


-- ############################################################################
-- ## 20260920_store_stock_transfers.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- STORE STOCK + STOCK TRANSFERS — 2026-09-20
--
-- Introduces the shop floor as a stock location of its own.
--
--   • STORE STOCK is a normal warehouse row. It is NOT a roll-up of the
--     other warehouses — it holds its own quantities, counted separately.
--     Units only reach it when somebody transfers them in.
--   • Transfers move units between any two locations and are recorded, so
--     "where did those 20 cameras go" has an answer.
--   • Main-shop invoices now deduct from STORE STOCK. A line that asks for
--     more than the store holds still saves (a customer must never be
--     blocked by a bad count) and simply drives the figure negative.
--
-- Dahua is deliberately untouched — dahua_stock keeps its own pool and its
-- own invoice_taken flow.
--
-- Run once, in the Supabase SQL editor. Idempotent.
-- ─────────────────────────────────────────────────────────────

begin;

-- ── 1. Movement columns on warehouse_stock ────────────────────
-- Until now closing_stock was only ever `opening_stock - sum(daily_taken)`.
-- Three more ways for a unit to move now exist, and each gets its own
-- column so the Stock tab can show WHY a figure changed rather than just
-- that it did. daily_taken stays what it has always been: units booked out
-- by hand on the day sheet.
alter table public.warehouse_stock
  add column if not exists invoice_taken integer not null default 0,  -- sold on a main invoice
  add column if not exists transfer_in   integer not null default 0,  -- received from another location
  add column if not exists transfer_out  integer not null default 0;  -- sent to another location

-- ── 2. Derived columns are computed by the database ───────────
-- Four separate clients (Stock tab, Scan, the invoice form, and transfers)
-- write to this table. Having each of them recompute total_taken and
-- closing_stock in TypeScript is how the numbers drift apart, so the
-- database now has the last word on every derived column.
--
--   total_taken   = hand-entered + invoiced + transferred away
--   closing_stock = opening + transferred in - total_taken
--   stock_status  = '' when no min_level is set, else LOW / OK
--
-- Mirrors computeTotals()/computeStatus() in StockTab.tsx.
create or replace function public.fn_warehouse_stock_derive() returns trigger
language plpgsql set search_path = public as $$
declare
  manual integer;
begin
  select coalesce(sum(value::integer), 0) into manual
    from jsonb_each_text(coalesce(new.daily_taken, '{}'::jsonb));

  new.total_taken   := manual
                     + coalesce(new.invoice_taken, 0)
                     + coalesce(new.transfer_out, 0);
  new.closing_stock := coalesce(new.opening_stock, 0)
                     + coalesce(new.transfer_in, 0)
                     - new.total_taken;
  new.stock_status  := case
                         when coalesce(new.min_level, 0) = 0 then ''
                         when new.closing_stock < new.min_level then 'LOW'
                         else 'OK'
                       end;
  new.updated_at    := now();
  return new;
end $$;

drop trigger if exists trg_warehouse_stock_derive on public.warehouse_stock;
create trigger trg_warehouse_stock_derive
  before insert or update on public.warehouse_stock
  for each row execute function public.fn_warehouse_stock_derive();

-- Re-derive every existing row. With the three new columns all at 0 this
-- reproduces exactly what is already stored — it is a no-op on the numbers,
-- run only so nothing is left over from a client that computed differently.
-- The audit trigger is lifted for the sweep: this is a schema migration, not
-- staff activity, and logging a diff for every stock row would bury the log.
alter table public.warehouse_stock disable trigger trg_audit_warehouse_stock;
update public.warehouse_stock set opening_stock = opening_stock;
alter table public.warehouse_stock enable trigger trg_audit_warehouse_stock;

-- ── 3. The STORE STOCK location ───────────────────────────────
-- date_columns is left empty: the store is not counted on a day sheet, its
-- movements come from transfers in and invoices out.
insert into public.warehouses (name, color, date_columns, section_labels)
select 'STORE STOCK', '#f59e0b', '{}', '{}'
 where not exists (select 1 from public.warehouses where name = 'STORE STOCK');

-- ── 4. Transfer records ───────────────────────────────────────
-- Locations are stored as names, not ids, to match warehouse_stock.warehouse
-- (the whole schema keys stock on the warehouse NAME). A renamed warehouse
-- would orphan old transfers either way; the name at least stays readable.
create table if not exists public.stock_transfers (
  id              uuid primary key default gen_random_uuid(),
  transfer_number text not null unique,
  from_warehouse  text not null,
  to_warehouse    text not null,
  note            text,
  transferred_at  timestamptz not null default now(),
  created_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  constraint stock_transfers_distinct_ends check (from_warehouse <> to_warehouse)
);
create index if not exists stock_transfers_when_idx on public.stock_transfers (transferred_at desc);

create table if not exists public.stock_transfer_items (
  id          uuid primary key default gen_random_uuid(),
  transfer_id uuid not null references public.stock_transfers(id) on delete cascade,
  model       text not null,
  quantity    integer not null check (quantity > 0),
  -- What the source had on hand the moment the transfer was applied. Kept
  -- so a later shortfall can be explained without replaying every movement.
  from_before integer,
  position    integer not null default 1
);
create index if not exists stock_transfer_items_parent_idx on public.stock_transfer_items (transfer_id);

-- Per-year sequence, matching the invoice numbering style: TRF-2026-0001.
create or replace function public.next_transfer_number() returns text
language plpgsql security definer set search_path = public as $$
declare
  yr  text := to_char(now(), 'YYYY');
  cnt integer;
begin
  select count(*) + 1 into cnt from public.stock_transfers
   where to_char(transferred_at, 'YYYY') = yr;
  return 'TRF-' || yr || '-' || lpad(cnt::text, 4, '0');
end $$;

-- ── 5. Applying a transfer ────────────────────────────────────
-- One round trip, one transaction. Doing this client-side would leave a
-- half-moved transfer behind the moment the phone drops its connection
-- between the source update and the destination update.
--
-- p_items: [{"model": "DS-7208HGHI-M1", "quantity": 5}, ...]
--
-- A model missing from the destination is CREATED there with opening_stock 0
-- and transfer_in set, so receiving something new needs no prior setup.
-- A model missing from the SOURCE is rejected: you cannot send what the
-- source has never held, and silently inventing it would corrupt the count.
create or replace function public.transfer_stock(
  p_from  text,
  p_to    text,
  p_items jsonb,
  p_note  text default null,
  p_when  timestamptz default now()
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_transfer public.stock_transfers;
  v_item     jsonb;
  v_model    text;
  v_qty      integer;
  v_before   integer;
  v_pos      integer := 0;
  v_try      integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to transfer stock';
  end if;
  if p_from is null or p_to is null or p_from = p_to then
    raise exception 'A transfer needs two different locations';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A transfer needs at least one item';
  end if;

  -- next_transfer_number() counts existing rows, so two staff transferring at
  -- the same moment can both be handed TRF-2026-0007. The unique constraint
  -- catches it; retrying just picks up the number the winner did not take.
  for v_try in 1..8 loop
    begin
      insert into public.stock_transfers
        (transfer_number, from_warehouse, to_warehouse, note, transferred_at, created_by)
      values
        (public.next_transfer_number(), p_from, p_to, nullif(btrim(coalesce(p_note, '')), ''),
         coalesce(p_when, now()), auth.uid())
      returning * into v_transfer;
      exit;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    -- Source: book the units out. Locked so two staff transferring the same
    -- model at once cannot both read the same "before" figure.
    select closing_stock into v_before
      from public.warehouse_stock
     where warehouse = p_from and model = v_model
     for update;
    if not found then
      raise exception '% does not hold %', p_from, v_model;
    end if;

    update public.warehouse_stock
       set transfer_out = coalesce(transfer_out, 0) + v_qty
     where warehouse = p_from and model = v_model;

    -- Destination: book them in, creating the row if this location has
    -- never carried the model before.
    update public.warehouse_stock
       set transfer_in = coalesce(transfer_in, 0) + v_qty
     where warehouse = p_to and model = v_model;
    if not found then
      insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, transfer_in)
      values (p_to, v_model, 0, '{}'::jsonb, v_qty);
    end if;

    v_pos := v_pos + 1;
    insert into public.stock_transfer_items (transfer_id, model, quantity, from_before, position)
    values (v_transfer.id, v_model, v_qty, v_before, v_pos);
  end loop;

  return v_transfer;
end $$;

-- ── 6. Invoice deduction from STORE STOCK ─────────────────────
-- Called by InvoiceForm right after the line items are saved.
--
-- p_items: [{"model": "DS-7208HGHI-M1", "quantity": 2}, ...]
--
-- Returns one row per line that could not be covered, so the form can tell
-- the cashier what the store is short of. The deduction happens either way —
-- the sale is never blocked by the count, per the shop's rule. A model the
-- store has no row for is reported as missing and left alone (inventing a
-- negative row for a one-off, untracked item would be noise, not accuracy).
create or replace function public.deduct_store_stock(
  p_items jsonb,
  p_store text default 'STORE STOCK'
) returns table (model text, requested integer, available integer, tracked boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_item  jsonb;
  v_model text;
  v_qty   integer;
  v_have  integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to adjust stock';
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_model := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    select closing_stock into v_have
      from public.warehouse_stock
     where warehouse = p_store and warehouse_stock.model = v_model
     for update;

    if not found then
      model := v_model; requested := v_qty; available := 0; tracked := false;
      return next;
      continue;
    end if;

    update public.warehouse_stock
       set invoice_taken = coalesce(invoice_taken, 0) + v_qty
     where warehouse = p_store and warehouse_stock.model = v_model;

    if v_have < v_qty then
      model := v_model; requested := v_qty; available := v_have; tracked := true;
      return next;
    end if;
  end loop;
end $$;

-- ── 7. RLS ────────────────────────────────────────────────────
alter table public.stock_transfers      enable row level security;
alter table public.stock_transfer_items enable row level security;

-- Everyone signed in can see the movement history; it is the record staff
-- check when a count looks wrong.
drop policy if exists stock_transfers_read on public.stock_transfers;
drop policy if exists stock_transfers_read on public.stock_transfers;

create policy stock_transfers_read on public.stock_transfers
  for select to authenticated using (true);

drop policy if exists stock_transfer_items_read on public.stock_transfer_items;
drop policy if exists stock_transfer_items_read on public.stock_transfer_items;

create policy stock_transfer_items_read on public.stock_transfer_items
  for select to authenticated using (true);

-- Writes go exclusively through transfer_stock(), which is SECURITY DEFINER.
-- No direct-write policy is granted, so a transfer cannot be forged without
-- the matching stock movement.
drop policy if exists stock_transfers_superboss_write on public.stock_transfers;
drop policy if exists stock_transfers_superboss_write on public.stock_transfers;

create policy stock_transfers_superboss_write on public.stock_transfers
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists stock_transfer_items_superboss_write on public.stock_transfer_items;
drop policy if exists stock_transfer_items_superboss_write on public.stock_transfer_items;

create policy stock_transfer_items_superboss_write on public.stock_transfer_items
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

grant execute on function public.transfer_stock(text, text, jsonb, text, timestamptz) to authenticated;
grant execute on function public.deduct_store_stock(jsonb, text) to authenticated;

-- ── 8. Audit ──────────────────────────────────────────────────
-- warehouse_stock is already audited (20260708_scan_staff_access.sql); the
-- transfer header gets the same treatment so the log shows who moved what.
drop trigger if exists trg_audit_stock_transfers on public.stock_transfers;
create trigger trg_audit_stock_transfers
  after insert or update or delete on public.stock_transfers
  for each row execute function public.fn_audit();

commit;

-- ── Verification (run after committing) ───────────────────────
-- select name from public.warehouses where name = 'STORE STOCK';
-- select count(*) filter (where closing_stock
--          <> opening_stock + transfer_in - total_taken) as drifted
--   from public.warehouse_stock;   -- expect 0


-- ############################################################################
-- ## 20260921_deduct_store_stock_match.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Make the invoice deduction match a model the way everything else does
-- 2026-09-21
--
-- deduct_store_stock() matched the invoice line against the stock row with
-- a plain `=`, so the match was case- and spacing-sensitive. Every other
-- lookup in the system is not: price_for_model() resolves on
-- upper(btrim(model)), and the Prices screen keys on the same. A line could
-- therefore be priced correctly and still fail to come off the shelf, and
-- the failure is quiet — the model is simply reported as untracked, which
-- reads as "the store does not carry this" rather than "the spelling did
-- not line up".
--
-- The barcode path makes this more than theoretical: a scanned line takes
-- its model from product_codes, which is populated by hand as staff link
-- codes, so its spelling need not match warehouse_stock exactly.
--
-- The shortfall now also names the model AS STORED rather than as typed, so
-- a warning points at the row the cashier will actually go and look at.
--
-- Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────

-- Every invoice save runs one lookup per line against this.
create index if not exists warehouse_stock_warehouse_model_upper_idx
  on public.warehouse_stock (warehouse, upper(btrim(model)));

create or replace function public.deduct_store_stock(
  p_items jsonb,
  p_store text default 'STORE STOCK'
) returns table (model text, requested integer, available integer, tracked boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item  jsonb;
  v_typed text;
  v_qty   integer;
  v_id    uuid;
  v_model text;
  v_have  integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to adjust stock';
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_typed := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_typed = '' or v_qty <= 0 then
      continue;
    end if;

    -- Locked so two tills invoicing the same model cannot both read the
    -- same "before" figure. Nothing stops two rows in one location
    -- differing only by case, so the oldest wins — deterministic, and the
    -- same row every time rather than whichever the planner returned.
    select s.id, s.model, s.closing_stock
      into v_id, v_model, v_have
      from public.warehouse_stock s
     where s.warehouse = p_store
       and upper(btrim(s.model)) = upper(v_typed)
     order by s.created_at, s.id::text
     limit 1
     for update;

    if not found then
      -- Reported, not invented. A line typed free-hand, or an item the shop
      -- genuinely does not stock, should not create a negative row out of
      -- nothing; the form decides whether this is worth mentioning.
      model := v_typed; requested := v_qty; available := 0; tracked := false;
      return next;
      continue;
    end if;

    update public.warehouse_stock
       set invoice_taken = coalesce(invoice_taken, 0) + v_qty
     where id = v_id;

    -- The sale is never blocked by the count; a shortfall is reported and
    -- the closing figure simply goes negative.
    if v_have < v_qty then
      model := v_model; requested := v_qty; available := v_have; tracked := true;
      return next;
    end if;
  end loop;
end $$;

grant execute on function public.deduct_store_stock(jsonb, text) to authenticated;

-- ── Verification ──────────────────────────────────────────────
-- What the store holds for a model, however it was typed:
--
-- select model, opening_stock, transfer_in, invoice_taken, closing_stock
--   from public.warehouse_stock
--  where warehouse = 'STORE STOCK'
--    and upper(btrim(model)) = upper(btrim('ds-2ce16d0t-lpfs'));
--
-- Everything the shop floor has sold so far:
--
-- select model, invoice_taken, closing_stock
--   from public.warehouse_stock
--  where warehouse = 'STORE STOCK' and invoice_taken > 0
--  order by invoice_taken desc;


-- ############################################################################
-- ## 20260921_store_stock_opening_count.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- STORE STOCK opening count — 2026-09-21
--
-- The first physical count of the shop floor: 145 models, 4298 units.
--
-- These land as opening_stock, the counted baseline, exactly as the Dahua
-- recount did. They are NOT booked in as transfer_in — nothing was moved
-- from a back warehouse to put them there, they were already on the floor.
-- Units moved in from a warehouse later will add to transfer_in on top of
-- this, and invoices will take them off again.
--
-- Idempotent: a model already present in STORE STOCK is left alone, so
-- re-running this cannot double a count. To correct a figure afterwards,
-- edit the row in the Stock tab rather than re-running.
--
-- NOTE — DS-PWA64-KIT-WB appeared twice on the count sheet at 1 pc each and
-- is recorded here as 2. If those were the same unit written down twice,
-- set it back to 1 in the Stock tab.
--
-- Two models are spelled here as the back warehouses already spell them,
-- not as the count sheet wrote them. Stock is keyed on (warehouse, model),
-- so a store row named differently from the warehouse row for the same item
-- could never be transferred between the two:
--
--   count sheet                   stored as
--   DS-2FA1208-C16                DS-2FA1208-C16 16CH POWER SUPPLY
--   DIGITAL MULTIMETER DT9201A    DIGITAL MULTIMETER DT920SA
--
-- The warehouse rows were left alone deliberately: they are live, and
-- product_codes and past invoice lines are matched on those exact strings.
--
-- Requires 20260920_store_stock_transfers.sql (the STORE STOCK location and
-- the derive trigger). Run once, in the Supabase SQL editor.
-- ─────────────────────────────────────────────────────────────

begin;

-- The location must exist, or every row below would be orphaned under a
-- warehouse name nothing else recognises.
insert into public.warehouses (name, color, date_columns, section_labels)
select 'STORE STOCK', '#f59e0b', '{}', '{}'
 where not exists (select 1 from public.warehouses where name = 'STORE STOCK');

-- total_taken, closing_stock and stock_status are left to
-- trg_warehouse_stock_derive — it overwrites them on insert anyway.
insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, min_level)
select 'STORE STOCK', v.model, v.qty, '{}'::jsonb, null
  from (values
    ('MK120 CORDED KEYBOARD AND MOUSE',                13),
    ('POE-43IP MINI DC UPS 8800MAH',                   27),
    ('P0E-432EM MINI DC UPS 10400MAH',                  9),
    ('Mk270 WIRELESS KEYBOARD AND MOUSE',               2),
    ('MK540 WIRELESS KEYBOARD AND MOUSE',               5),
    ('RJ45 CONNECTORS NORMAL',                        972),
    ('ALFAMAX C-1005',                                  5),
    ('SYS-WS O1',                                       3),
    ('POWER SWITCH 13.5MHZ',                           47),
    ('C922 PRO HD STREAM WEBCAM',                       4),
    ('Z05 WEBCAM',                                      3),
    ('DS-K7P08',                                       32),
    ('DS-K7P07',                                        8),
    ('EXIT BUTTON WITH REMOTE',                         5),
    ('EXIT BUTTON WITHOUT REMOTE',                     30),
    ('RE450',                                           3),
    ('TL-WA850RE',                                     30),
    ('ELECTRIC BOLT LOCK',                              5),
    ('RF CARD',                                       978),
    ('MIFI CARD',                                      15),
    ('104JF 4 PORT POE REPEATER',                      20),
    ('DS-K1F100-D8E',                                   2),
    ('DS-K1F820-F',                                     2),
    ('HF-CSS1',                                         1),
    ('ARCHER T2U NANO',                                 1),
    ('MAGNETIC LOCK 280KG UNBRANDED',                   6),
    ('RJ45 LAN JOINER',                                90),
    ('EP-280ZL',                                        9),
    ('U BRACKET',                                       9),
    ('DS-KAH255-LZ',                                    1),
    ('1280ZJ-XS',                                      19),
    ('DS-K4DC103',                                      4),
    ('DOME META MOUNT',                                 3),
    ('YD/T926.3-2009 PATCH PANEL 48PORT',               5),
    ('4WAY POWER SPLITTER',                           205),
    ('8WAY POWER SPLITTER',                             9),
    ('RB3011UIAS-RM MIKROTIK ROUTER BAND',              1),
    ('CABINET PDU 3 WAY HP-403',                        4),
    ('PROJECTOR CELLING MOUNT NCTS-ACM5080',            1),
    ('PROJECTOR WALL MOUNT 430-650',                    3),
    ('CABLE MANAGER',                                  16),
    ('CABINET PDU WAY',                                 1),
    ('MINI PROJECTOR',                                  3),
    ('CABINET PDU 6WAY',                                1),
    ('6WAY POWER SPLITTER',                            53),
    ('NCTS-12V9A',                                     11),
    ('RACK FAN',                                        1),
    ('HDTV TO VGA/AV ADAPTER',                          5),
    ('MINI DP TO HDTV ADAPTER',                         2),
    ('HDMI TO VGA MINI DISPLAY PORT ADAPTER',           3),
    ('HDMI TO TYPE-C ADAPTER',                          1),
    ('HDMI TO HDMI DISPLAY PORT ADAPTER',               2),
    ('1.8M DISPLAY PORT ADAPTER',                       4),
    ('USB EXTENSION CABLE 1.5M',                       12),
    ('USB RJ45 EXTENSION ADAPTER',                     47),
    ('OTG USB FLASH DRIVE',                             6),
    ('USB HUB 4 PORT 303',                              4),
    ('USB 3.0/3.1 ETHERNET ADAPTER',                   20),
    ('USB SOUND ADAPTER 7.1 CHANNEL',                   6),
    ('RJ45 CONNECTORS PASSTHROUGH',                  1119),
    ('RJ45 PASSTHROUGH CRIMPING TOOL WESTA',            1),
    ('RJ45 CRIMPING TOOL NORMAL 8P6P W-318',           16),
    ('BNC TO BNC CABLE 2M',                             4),
    ('HP M10 WIRED MOUSE',                             46),
    ('30M HDTV TO CAT 6 EXTENDER',                      6),
    ('NETWORK ADAPTER TYPE C',                          6),
    ('CABLE TRACKER',                                   3),
    ('DIGITAL MULTIMETER DT920SA',                     10),
    ('HIGH QUALITY AUTOMOTIVE EMERGENCY POWER BANK',    2),
    ('K9 WIRELESS MICROPHONE',                          4),
    ('RF433-DIY SMART SWITCH',                         14),
    ('DS-PDMCS-EG2-WE',                                 7),
    ('DS-PDC10AM-EG2-WE',                               1),
    ('DS-PDWL-E-WE',                                    1),
    ('DS-PDTPH-E-WE',                                   1),
    ('DS-PDPG12P-EG2-WE',                               2),
    ('WIRELESS PANIC BUTTON',                           4),
    ('DS-PDP18-EG2',                                    2),
    ('DS-PDMC-EG2-WE(B)',                               4),
    ('IDS-E04HQHI-D',                                   1),
    ('TC-R3104',                                        1),
    ('NCTS-NB2D6 BARCODE SCANNER',                      5),
    ('NCTS-NL10 BARCODE SCANNER',                       3),
    ('NCTS-NB2D2W BARCODE SCANNER',                     3),
    ('DS-PKF1-WB',                                      1),
    ('USB-C CHARGE CABLE 2M',                           1),
    ('M185 LOGITECH MOUSE',                             1),
    ('M90 LOGITECH MOUSE',                              1),
    ('48V-EU POE ADAPTER',                              9),
    ('UNIVERSAL FOAM CLEANING AGENT',                  19),
    ('DS-PK1-LT-WE',                                    5),
    ('F11-2 WIRELESS MICROPHONE',                       5),
    ('BOAFENG UV-5RH',                                  3),
    ('SX21 WIRELESS MICROPHONE',                        4),
    ('DS-PDP15P-EG2-WE(B)',                             5),
    ('DS-PC2002-WECKV',                                 1),
    ('V380 SMART AI CAMERA',                            8),
    ('T01 DETECTOR',                                    2),
    ('S-120-12 POWER SUPPLY',                          12),
    ('FF-Q2421B LINK FF 24PORT POE SWITCH',             5),
    ('JVS-S18-16P-240W',                                1),
    ('JVS-ND6610-HD NVR',                               1),
    ('S-240W-12 POWER SUPPLY',                          2),
    ('JVS-S10-8P-120W',                                 1),
    ('PATCH CORD 3M',                                   7),
    ('10M PATCH CORD',                                 19),
    ('15M PATCH CORD',                                  9),
    ('20M PATCH CORD',                                  3),
    ('5M PATCH CORD',                                  17),
    ('1.5M PATCH CORD',                                 2),
    ('NAP-9000-4K 360 HD CAMERA',                       1),
    ('FF-Q&A 8PORT SWITCH',                             1),
    ('60M HDMI TO CAT 6 EXTENDER',                      1),
    ('NOTEBOOK POWER ADAPTER 12V4.5A',                  1),
    ('PROFESSIONAL DOOR CLOSER 072',                    4),
    ('2420GF-24 PORT GIGABIT POE SWITCH',               8),
    ('16F22GB-16PORT AI ENHANCED POE SWITCH',           1),
    ('1018G-16PORT GIGABIT NETWORK SWITCH',             1),
    ('DS-PWA64-KIT-WB',                                 2),
    ('1006B-J-4PORT STANDARD POE SWITCH',               1),
    ('X16F20GB-16PORT UPLINK GIGABIT POE SWITCH',       2),
    ('D50 ULTRA SMART 3 GLASSES',                       5),
    ('XP-E200L PRINTER',                                4),
    ('XP-Q80A PRINTER',                                 1),
    ('XP-365B PRINTER',                                 1),
    ('12V10A POWER ADAPTER',                            3),
    ('POE424G',                                         5),
    ('DS-K1201AMF',                                     2),
    ('AK-ACS80 ACCESS CONTROL POWER SUPPLY',            3),
    ('HF-CABLE FIRE ALARM BELL',                        4),
    ('POSO PROFESSIONAL TOOLS BAG',                     2),
    ('NETWORKING TOOL KIT 200',                         2),
    ('NETWORKING TOOL KIT 250',                         1),
    ('HAMMER TOOL PE-HD',                               1),
    ('DRILLING MACHINE',                                4),
    ('KX-TS500FX',                                     18),
    ('DS-3E0116R-O',                                    5),
    ('DS-3E11326P-EI/M',                                1),
    ('DS-3E1318P-EI/M',                                 2),
    ('DS-3E0526P-E/M',                                  1),
    ('DS-3E0326P-E/M(C)',                               1),
    ('DS-2FA1208-C16 16CH POWER SUPPLY',              7),
    ('GXP2200EXT',                                      1),
    ('DS-PR1-WE(B)',                                    1),
    ('DS-KH9510-WTE(B)',                                1)
       ) as v(model, qty)
 where not exists (
         select 1 from public.warehouse_stock s
          where s.warehouse = 'STORE STOCK'
            and s.model     = v.model
       );

commit;

-- ── Verification (run after committing) ───────────────────────
-- select count(*) as models, sum(opening_stock) as units
--   from public.warehouse_stock where warehouse = 'STORE STOCK';
--   -- expect 145 models, 4298 units on a first run


-- ############################################################################
-- ## 20260921_store_stock_second_count.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- STORE STOCK — second count, 2026-09-21
--
-- 65 more models, 397 units, added to the shop floor alongside the 145
-- models from 20260921_store_stock_opening_count.sql. None of these were in
-- that first count, so nothing here overlaps it.
--
-- Recorded as opening_stock, the counted baseline, for the same reason as
-- the first batch: these were already on the floor, not moved in from a
-- back warehouse. Transfers in and invoices out apply on top.
--
-- NOTES ON THE COUNT SHEET
--   DS-2CD1147G3-LIU was written twice, as "5" in the free list and as
--   "5+3" in the camera table. The table restates that same 5 and adds 3,
--   so it is recorded once, as 8 — not 13.
--
--   Quantities written as sums ("23+1", "16+3", "4+12") are stored added up.
--
--   Two rows are filed under their model code rather than the description
--   they were written with, so they sort and scan with everything else:
--     "Magnetic Contact — DS-PD1-MC-MS"   -> DS-PD1-MC-MS MAGNETIC CONTACT
--     "Fibre optic transceivers — DS-3D501T" -> DS-3D501T FIBRE OPTIC TRANSCEIVER
--
--   Everything else keeps the wording of the sheet, including entries that
--   are terse ("PV", "AG003", "12V 7AH"). Renaming them on a guess would be
--   worse than leaving them recognisable to whoever wrote them down.
--
-- Ten of these models are already stocked in a back warehouse under exactly
-- this spelling, so stock can be transferred between the two:
--   DS-2CD1027G2-L, DS-2CD1027G3-LIU/SRB, DS-2CD1047G3-LIU,
--   DS-2CD1083G2-LIU, DS-2CD1123G2-LIU, DS-2CD1143G2-LIU,
--   DS-2CD1147G2H-LIU, DS-2CD1327G2H-LIUF/SRB, DS-2CD1347G3-LIU,
--   DS-7216HGHI-M1/T
--
-- Idempotent: a model already present in STORE STOCK is left alone, so
-- re-running cannot double a count. To correct a figure afterwards, edit
-- the row in the Stock tab rather than re-running.
--
-- Requires 20260920_store_stock_transfers.sql. Run once, in the Supabase
-- SQL editor.
-- ─────────────────────────────────────────────────────────────

-- The location must exist, or every row below would be orphaned under a
-- warehouse name nothing else recognises.
insert into public.warehouses (name, color, date_columns, section_labels)
select 'STORE STOCK', '#f59e0b', '{}', '{}'
 where not exists (select 1 from public.warehouses where name = 'STORE STOCK');

-- total_taken, closing_stock and stock_status are left to
-- trg_warehouse_stock_derive — it overwrites them on insert anyway.
insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, min_level)
select 'STORE STOCK', v.model, v.qty, '{}'::jsonb, null
  from (values
    ('AX3000 WiFi 6 ceiling access point',    1),
    ('10 HDMI Cable',                        11),
    ('VGA 10M',                               1),
    ('HDMI 1.5 m',                            2),
    ('DS-PD1-MC-MS MAGNETIC CONTACT',        14),
    ('Paper roll',                           50),
    ('Grand Stream GWN7660ELR',               3),
    ('Westa ZT550LED',                        1),
    ('DS-2CD1023G2H-LIU',                     4),
    ('THC-B127-LPS',                          1),
    ('SP4 Solar Camera',                      2),
    ('Ecotank-L3252',                         1),
    ('DS-7216HGHI-M1/T',                      7),
    ('HUAWEI-B660',                           1),
    ('12V 7AH',                               3),
    ('AG003',                                 2),
    ('PV',                                    2),
    ('DS-2CE72DF0T-LPFS',                     2),
    ('West 100M Indoor',                      1),
    ('DS-2CD1047G3-LIU/SRB',                 11),
    ('120 m KVM',                             1),
    ('DS-3D501T FIBRE OPTIC TRANSCEIVER',     3),
    ('NCTS Qstrom Pro 1500VA',                1),
    ('DS-2CD1123G2-LIU',                     24),
    ('DS-2CD1147G3-LIU',                      8),
    ('DS-2CD1143G2-LIU',                     24),
    ('DS-2CD1367G2H-LIUF/SRB',               12),
    ('DS-2CD1327G2H-LIUF/SRB',                9),
    ('DS-2CD1127G3-LIU',                     13),
    ('DS-2CD1163G2-LIU',                      4),
    ('DS-2CD1167G3-LIU',                     14),
    ('DS-2CD1347G3-LIU',                     19),
    ('DS-2CD1147G2H-LIU',                     3),
    ('DS-2CD1347G3-LIU/SRB',                 11),
    ('DS-2CD1067G3-LIU',                      8),
    ('DS-2CD1083G2-LIU',                     14),
    ('DS-2CD1063G2-LIU',                      2),
    ('DS-2CD1027G2-L',                       16),
    ('DS-2CD1027G3-LIU',                     15),
    ('DS-2CD1047G3-LIU',                     12),
    ('DS-2CD1027G3-LIU/SRB',                  6),
    ('CS-H90',                                5),
    ('CS-HB90/SP',                            3),
    ('CS-C7',                                 5),
    ('CS-HB8/SP',                             1),
    ('CS-HB8c/SP',                            1),
    ('CS-HB90x/SP',                           1),
    ('CS-H7c',                                5),
    ('CS-CB3/SP',                             3),
    ('CS-EB3/SP',                             3),
    ('CS-H8c',                                1),
    ('CS-H80x',                               2),
    ('CS-H5',                                 1),
    ('CS-H3c',                                6),
    ('CS-CB2',                                1),
    ('CS-CB1',                                6),
    ('CS-HP4',                                1),
    ('CS-E4P',                                1),
    ('CS-CB2/PB',                             1),
    ('CS-H9C',                                1),
    ('CS-X5s (4K)',                           2),
    ('CS-CMT-Solarpanel-E',                   1),
    ('CS-EB8',                                1),
    ('CS-HP7',                                5),
    ('CS-HB8',                                1)
       ) as v(model, qty)
 where not exists (
         select 1 from public.warehouse_stock s
          where s.warehouse = 'STORE STOCK'
            and s.model     = v.model
       );

-- ── Verification (run after the statements above) ─────────────
-- select count(*) as models, sum(opening_stock) as units
--   from public.warehouse_stock where warehouse = 'STORE STOCK';
--   -- expect 210 models, 4695 units once both counts are in


-- ############################################################################
-- ## 20260921_store_stock_third_count.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- STORE STOCK — third count, 2026-09-21
--
-- IP cameras, analogue cameras and TP-Link networking: 46 new models and
-- 578 units on the shop floor, plus two revised figures.
--
-- Recorded as opening_stock, like the two counts before it — these were
-- already on the floor, not moved in from a back warehouse.
--
-- HOW THE COUNT SHEET WAS READ
--   DS-2CE76K0T-LPFS appeared twice in the analogue table, as 7 and as 24.
--   Two separate piles, so it is stored as 31.
--
--   "DS-2CE70D0T-PTLS [?]" carried a question mark. It is the camera BACK
--   WAREHOUSE already stocks as DS-2CE70D0T-PTLTS, and is spelled that way
--   here so stock can be transferred between the two.
--
--   Sums ("5+6", "3+7", "14+1") are stored added up.
--
--   EAP225 appeared three times: the outdoor unit, the ceiling-mount
--   access point, and a bare "EAP225" of 1. TP-Link sells the outdoor and
--   the ceiling-mount units as different products, so those stay separate;
--   the bare line is the ceiling mount, and its 1 is folded in, giving 3.
--
-- TWO REVISED FIGURES
--   DS-2CD1167G3-LIU and THC-B127-LPS were already counted, so a plain
--   insert would have been skipped by the guard below and this sheet's
--   numbers would have vanished without a word. They are set to an
--   ABSOLUTE total instead:
--
--     DS-2CD1167G3-LIU   14 already + 4 here (a separate pile) = 18
--     THC-B127-LPS       "14+1" includes the 1 already counted = 15
--
--   Setting an absolute figure is still safe to re-run, and it only touches
--   opening_stock — anything since sold or transferred lives in its own
--   column, so the closing figure stays correct.
--
-- Idempotent. Requires 20260920_store_stock_transfers.sql; run after the
-- first and second counts.
-- ─────────────────────────────────────────────────────────────

insert into public.warehouses (name, color, date_columns, section_labels)
select 'STORE STOCK', '#f59e0b', '{}', '{}'
 where not exists (select 1 from public.warehouses where name = 'STORE STOCK');

-- New models. The two revised ones carry their final figure here too, so
-- this lands correctly even if the earlier counts were never run.
insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, min_level)
select 'STORE STOCK', v.model, v.qty, '{}'::jsonb, null
  from (values
    ('DS-2CD1027G2H-LIU',                    2),
    ('IPC-B149HA-LU',                       12),
    ('DS-2CD1023G2-LIU',                     3),
    ('IPC-D149HA-LU',                       12),
    ('DS-2CD1167G3-LIU',                    18),
    ('DS-2CD1147G3-LIU/SRB',                11),
    ('DS-2CD2743G2-LIZS2',                   3),
    ('DS-2CD1147G2-L',                       2),
    ('DS-2CD2763G2-LIZS2U',                  3),
    ('DS-2CD1367G2HP-LIUF/SRB',              5),
    ('DS-2CD2043G2-LI2U',                    2),
    ('DS-2CD1743G2-LIZU',                    1),
    ('AE-DC2328-C200S',                      1),
    ('IPC-T221H-C',                          2),
    ('DS-2CE16D0T-EXIPF',                   10),
    ('DS-2CE16D0T-LPFS',                   103),
    ('DS-2CE10DF0T-LPFS',                   23),
    ('DS-2CE10KF0T-LPFS',                   63),
    ('DS-2CE72DF0T-LPTS',                    8),
    ('DS-2CE10DF0T-LPTS',                   34),
    ('DS-2CE16K0T-LPTS',                     3),
    ('DS-2CE16D0T-LPTS',                    16),
    ('DS-2CE70D0T-PTLTS',                   10),
    ('DS-2CE76U0T-LPF',                      4),
    ('DS-2CE16U0T-LPF',                      1),
    ('DS-2CE76K0T-LPFS',                    31),
    ('THC-B127-LPS',                        15),
    ('THC-P127-LPT',                         2),
    ('DS-2CE16K0T-LPFS',                    31),
    ('DS-2CE70KF0T-LPFS',                   38),
    ('DS-2CE70DF0T-LPFS',                   26),
    ('DS-2CE76D0T-LPFS',                    48),
    ('DS-2CE76D0T-EXIPF',                    4),
    ('TL-WR845N WIRELESS ROUTER',            9),
    ('TL-WR940N WIRELESS ROUTER',            3),
    ('CPE510 13DBI OUTDOOR',                 4),
    ('EAP110 OUTDOOR',                       5),
    ('EAP225 OUTDOOR',                       4),
    ('EAP225 CEILING MOUNT ACCESS POINT',    3),
    ('RE235BE WIFI 7 RANGE EXTENDER',        3),
    ('TL-WPA7817 KIT WIFI 6 EXTENDER',       2),
    ('EAP215 BRIDGE KIT',                    5),
    ('LS1008 DESKTOP SWITCH',                3),
    ('CPE710 23DBI OUTDOOR CPE',             1),
    ('EAP113 OUTDOOR',                       1),
    ('CPE210 9DBI OUTDOOR',                  1),
    ('ARCHER NX500 ROUTER',                  1),
    ('ARCHER MR402',                         1)
       ) as v(model, qty)
 where not exists (
         select 1 from public.warehouse_stock s
          where s.warehouse = 'STORE STOCK'
            and s.model     = v.model
       );

-- The revised figures, applied whether or not the row already existed.
update public.warehouse_stock s
   set opening_stock = v.qty
  from (values
    ('DS-2CD1167G3-LIU',                    18),
    ('THC-B127-LPS',                        15)
       ) as v(model, qty)
 where s.warehouse = 'STORE STOCK'
   and s.model     = v.model
   and s.opening_stock is distinct from v.qty;

-- ── Verification (run after the statements above) ─────────────
-- select count(*) as models, sum(opening_stock) as units
--   from public.warehouse_stock where warehouse = 'STORE STOCK';
--   -- expect 256 models, 5273 units once all three counts are in


-- ############################################################################
-- ## 20260921_store_stock_fourth_count.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- STORE STOCK — fourth count, 2026-09-21
--
-- Networking, access control, UPS and AV: 105 new models and 297 units,
-- taking the shop floor to 361 models and 5570 units.
--
-- Recorded as opening_stock, like the counts before it — these were
-- already on the floor, not moved in from a back warehouse.
--
-- HOW THE COUNT SHEET WAS READ
--   Sums are stored added up: "6+7" -> 13, "1+3+1" -> 5, "7+5+1" -> 13,
--   "2+3" -> 5, "3+1" -> 4, and each "1+1" -> 2.
--
--   Three crossed-out lines with no quantity are NOT included: Nano 5AC,
--   Power Beam M5 PBE-M6-400, and Cabinet fan. The un-struck
--   Power Beam M5 PBE-M5-400 is included, at 1.
--
--   Entries written "Model — description" are stored as one string with the
--   dash dropped, keeping the sheet's own wording. Several carried a "[?]"
--   against an uncertain spelling; the marker is dropped and the name kept
--   as written rather than corrected on a guess. Those are ER703WP,
--   ZKT MB360, Grandstream GRP2602W, ZTE MF286R, D-Link DGS1210-28RP,
--   LSUW TLE router MF607, DS-2DE2C400MW-DB and DS-QAE0215G1-V. Fix any of
--   them in the Stock tab and the barcode and price will follow the name.
--
--   The two TV wall mounts were written with inch marks; they are stored as
--   "26-63 inch" and "14-42 inch" so they can be typed and searched.
--
-- ONE REVISED FIGURE
--   HUAWEI-B660 was counted in the second count at 1, and this sheet lists
--   another as "Huawei B660 — 4G router / wireless gateway". They are two
--   units of the same product, so the existing row is set to an ABSOLUTE 2
--   rather than a second row being created under a different spelling —
--   which would have split one product's stock across two names.
--
-- TWO NAMES ALIGNED TO THE BACK WAREHOUSE
--   Stock is keyed on (warehouse, model), so a store row spelled
--   differently from the warehouse row for the same item could never be
--   transferred between them:
--
--     count sheet                        stored as
--     D-Link DWR-M922                    DWR-M922
--     DS-QAE0A60G1-VB Analog amplifier   DS-QAE0A60G1-VB
--
--   The warehouse rows were left alone: they are live, and product_codes
--   and past invoice lines match on those exact strings.
--
-- NOT MERGED, DELIBERATELY
--   Three lines resemble a back-warehouse item but are not clearly the same
--   product, so they are kept as written rather than merged on a guess:
--   "HDMI splitter 4K" (warehouse has HDMI SPLITTER 4K 1X8), "HDMI splitter
--   2-port 4K" (HDMI SPLITTER 2 PORT) and "HDMI fibre optic 50 m"
--   (FIBRE OPTIC 50M). They sit in a different location either way; only
--   transfers between the two are affected.
--
-- Idempotent. Requires 20260920_store_stock_transfers.sql; run after the
-- earlier counts.
-- ─────────────────────────────────────────────────────────────

insert into public.warehouses (name, color, date_columns, section_labels)
select 'STORE STOCK', '#f59e0b', '{}', '{}'
 where not exists (select 1 from public.warehouses where name = 'STORE STOCK');

-- New models. The revised one carries its final figure here too, so this
-- lands correctly even if the earlier counts were never run.
insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, min_level)
select 'STORE STOCK', v.model, v.qty, '{}'::jsonb, null
  from (values
    ('EAP115 Wireless ceiling mount access point',                  2),
    ('EAP610 Outdoor',                                              2),
    ('Agile ES210GP',                                               4),
    ('SG2210P',                                                     7),
    ('ER605 Gigabit VPN gateway',                                   2),
    ('ES205GP',                                                     2),
    ('Archer AX53',                                                 2),
    ('Archer BE220 Dual-band WiFi 7 router',                        1),
    ('EAP725 Outdoor',                                              1),
    ('ER703WP 4G outdoor',                                          1),
    ('LS109P Normal switch',                                        1),
    ('TS-SF1016D',                                                  3),
    ('LS105GP',                                                     2),
    ('LS110P',                                                      3),
    ('POE160S',                                                     4),
    ('EAP610GP Desktop (EU)',                                       5),
    ('ER706W 4G (EU)',                                              1),
    ('EAP610',                                                      1),
    ('EAP653UR Ceiling mount access point',                         1),
    ('MikroTik SXTsq Lite 5',                                       1),
    ('Nano Ebiquity M5',                                            3),
    ('Ebiquity U6 Mesh Pro',                                        1),
    ('U7 Pro',                                                      1),
    ('Nano Beam 5AC',                                               1),
    ('Lite Beam 5AC',                                               2),
    ('Power Beam M5 PBE-M5-400',                                    1),
    ('ZKTCO VDP04-B4 Kit',                                          2),
    ('EAP668 Outdoor HD',                                           2),
    ('Deco M4 AC1200',                                              2),
    ('Deco X20 3-pack',                                             2),
    ('Deco X10',                                                    1),
    ('Deco X50',                                                    1),
    ('EAP235 Wall',                                                 2),
    ('WiFi 6 router 8 stream',                                      1),
    ('4G LTE router',                                               3),
    ('DWR-M922',                                                    2),
    ('ZKT F16',                                                     1),
    ('ZKT MB10-VL',                                                 1),
    ('U7 Lite',                                                     1),
    ('MikroTik hAP Lite',                                           1),
    ('MikroTik RB951Ui-2HND',                                       1),
    ('MikroTik L009 series',                                        1),
    ('ZKT MA500',                                                   1),
    ('ZKT X8-BT',                                                   1),
    ('ZKT F22',                                                     4),
    ('ZKT MB420',                                                   1),
    ('ZKT MB360',                                                   1),
    ('ZKT Multibio600',                                             1),
    ('ZKT K40 Pro',                                                 1),
    ('Grandstream GXP1625',                                        13),
    ('Grandstream GRP2602W',                                        5),
    ('Grandstream UCM6302A',                                        2),
    ('Ruijie RG-RAP72 Pro',                                         1),
    ('Telenet MF286N Router',                                       8),
    ('ZTE MF286R 4G',                                              12),
    ('ZTE MF286 4G router',                                         5),
    ('TP-Link 4G+ AI Cube',                                         2),
    ('Huawei B315S-22 4G router',                                   4),
    ('D-Link DES-1024D 24-port switch',                             7),
    ('D-Link DGS-1024C 24-port Gigabit switch',                     4),
    ('D-Link DGS-1100-18PV2 16-port switch',                        1),
    ('D-Link DGS1210-28RP 24-port Gigabit smart managed switch',    1),
    ('TP-Link SG2218',                                              3),
    ('102G 24-port full Gigabit smart network switch',              2),
    ('Tenda TEG1024D 24-port Gigabit Ethernet switch',              2),
    ('Fibre optic 100 m',                                           2),
    ('UCom L600D Gamepad',                                          2),
    ('UCom L600S',                                                  4),
    ('TV-8108HD 8-channel passive HD video balun',                  2),
    ('Starlink adjustable mount',                                   4),
    ('NCTS Qstrom Pro Qpr 2000VA Stepdown UPS',                     2),
    ('Tenda TX2 Pro Wireless router',                               1),
    ('D-Link DGS-1100-08PV2',                                       2),
    ('Sealead UPS battery 12V 17Ah',                                1),
    ('Gamister UPS battery 12V 17Ah',                               1),
    ('Voltage regulator',                                           2),
    ('1602ZJ PTZ pole mount',                                       1),
    ('ZKT MK-U/MK-H',                                               1),
    ('HDMI KVM extender 200 m',                                     5),
    ('HDMI KVM extender with audio 60 m',                           5),
    ('HDMI splitter 4K',                                            2),
    ('HDMI splitter 2-port 4K',                                     4),
    ('Hikvision DS-3E0105-O Ethernet switch',                      22),
    ('HDMI fibre optic 30 m',                                       1),
    ('HDMI fibre optic 10 m',                                       4),
    ('Q16S-1 Bulb camera',                                         13),
    ('HDMI fibre optic 50 m',                                       2),
    ('HDMI 4K 30 m',                                                1),
    ('TV wall mount 26-63 inch',                                    5),
    ('TV wall mount 14-42 inch',                                    1),
    ('Wireless intercom without screen',                            7),
    ('Wireless HDMI 100 m',                                         2),
    ('Wireless HDMI 50 m',                                          3),
    ('Wireless HDMI 150 m',                                         3),
    ('Huawei F316 4G SIM phone',                                    7),
    ('GRP2650',                                                     1),
    ('MS108GP 8-port Gigabit desktop switch',                       2),
    ('4-channel passive HD video balun',                            1),
    ('LSUW TLE router MF607',                                       1),
    ('DS-QAE0A60G1-VB',                                             2),
    ('DS-QAE1A80G1-VB Network amplifier',                           1),
    ('DS-2DE2C400MW-DB Mini PT network camera',                     1),
    ('NKS42W0H',                                                    1),
    ('DS-QAE0215G1-V Analogue ceiling speaker 45W',                 4),
    ('DS-QAE0210G1-Y Analogue ceiling speaker 10W',                 9),
    ('HUAWEI-B660',                                                 2)
       ) as v(model, qty)
 where not exists (
         select 1 from public.warehouse_stock s
          where s.warehouse = 'STORE STOCK'
            and s.model     = v.model
       );

-- The revised figure, applied whether or not the row already existed.
update public.warehouse_stock s
   set opening_stock = v.qty
  from (values
    ('HUAWEI-B660',                                                 2)
       ) as v(model, qty)
 where s.warehouse = 'STORE STOCK'
   and s.model     = v.model
   and s.opening_stock is distinct from v.qty;

-- ── Verification (run after the statements above) ─────────────
-- select count(*) as models, sum(opening_stock) as units
--   from public.warehouse_stock where warehouse = 'STORE STOCK';
--   -- expect 361 models, 5570 units once all four counts are in


-- ############################################################################
-- ## 20260921_resync_store_invoice_taken.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Rebuild STORE STOCK's sold figures from the invoices — 2026-09-21
--
-- Sales were made that never came off the shelf. Three ways that happened,
-- all of them quiet:
--
--   * the line was picked from the product catalogue, so its description
--     read "Title — MODEL" and matched no stock row at all;
--   * the spelling differed in case or spacing from the stock row, because
--     the deduction matched with a plain `=` (fixed in
--     20260921_deduct_store_stock_match.sql);
--   * the model had not been counted into STORE STOCK yet, so there was no
--     row to take it off.
--
-- WHY THIS RECOMPUTES RATHER THAN ADDS
--   Some sales DID deduct. Adding the missing ones would mean knowing
--   exactly which, and nothing on invoice_items records whether stock was
--   taken — so any "add the difference" approach risks double-counting the
--   ones that worked. Instead invoice_taken is derived from scratch: it is
--   simply what the invoices say was sold. That is idempotent, self-
--   correcting, and safe to run again whenever a figure looks wrong.
--
-- WHICH SALES COUNT
--   Only invoices issued AFTER a model's row was created — that is, after
--   it was physically counted. opening_stock is a count taken at a moment
--   in time, so anything sold before that moment is already reflected in
--   the number on the shelf. Counting it again would deduct it twice.
--   This is per model, so a model added in the second or third count uses
--   its own date, not the store's.
--
-- WHAT IT DOES NOT TOUCH
--   opening_stock, transfer_in, transfer_out and daily_taken are left
--   alone. Only invoice_taken is rebuilt, and the derive trigger then
--   recomputes closing_stock from it.
--
-- HOW TO RUN IT
--   Preview first — this writes nothing:
--     select * from public.resync_store_invoice_taken();
--   Then apply:
--     select * from public.resync_store_invoice_taken(true);
--   Both return the same rows, so what you previewed is what you get.
--
-- Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────

create or replace function public.resync_store_invoice_taken(
  p_apply boolean default false,
  p_store text default 'STORE STOCK'
) returns table (
  model      text,
  counted_at timestamptz,
  was        integer,
  should_be  integer,
  difference integer
)
language plpgsql
security definer
set search_path = public
as $$
begin
  -- A session with no JWT is the SQL editor, psql or the service role, not
  -- an app user — those bypass RLS anyway, and refusing them here would
  -- block the very console this is meant to be run from. The check still
  -- binds every request arriving through the app.
  if (select auth.uid()) is not null and not (select public.is_superboss()) then
    raise exception 'Only the Big Boss may rebuild stock figures'
      using errcode = '42501';
  end if;

  return query
  with figures as (
    select
      s.id,
      s.model,
      s.created_at,
      coalesce(s.invoice_taken, 0) as was,
      coalesce((
        select sum(ii.quantity)::integer
          from public.invoice_items ii
          join public.invoices i on i.id = ii.invoice_id
         where i.issued_at > s.created_at
           and (
             -- Typed, autocompleted or scanned: the description IS the model.
             upper(btrim(ii.description)) = upper(btrim(s.model))
             -- Picked from the catalogue: "Title — MODEL". Compared from the
             -- right rather than with LIKE, so a model containing % or _
             -- cannot turn into a wildcard.
             or right(upper(btrim(ii.description)),
                      length(' — ' || upper(btrim(s.model))))
                = ' — ' || upper(btrim(s.model))
           )
      ), 0) as should_be
    from public.warehouse_stock s
    where s.warehouse = p_store
  ),
  changed as (
    select * from figures f where f.was is distinct from f.should_be
  ),
  -- A data-modifying CTE always runs to completion, whether or not the
  -- outer query reads it.
  applied as (
    update public.warehouse_stock w
       set invoice_taken = c.should_be
      from changed c
     where w.id = c.id
       and p_apply
    returning w.id
  )
  select c.model, c.created_at, c.was, c.should_be, c.should_be - c.was
    from changed c
   order by abs(c.should_be - c.was) desc, c.model;
end $$;

grant execute on function public.resync_store_invoice_taken(boolean, text) to authenticated;

-- ── After applying ────────────────────────────────────────────
-- What the shop floor has sold, and what is left:
--
-- select model, opening_stock, transfer_in, invoice_taken, closing_stock
--   from public.warehouse_stock
--  where warehouse = 'STORE STOCK' and invoice_taken > 0
--  order by invoice_taken desc;
--
-- Anything now showing negative — sold more than was ever counted in, which
-- means the count missed some or the sale was of a model spelled differently:
--
-- select model, opening_stock, transfer_in, invoice_taken, closing_stock
--   from public.warehouse_stock
--  where warehouse = 'STORE STOCK' and closing_stock < 0
--  order by closing_stock;
--
-- Invoiced lines that STILL match no store row, i.e. sales the shop floor
-- has no record of stocking at all:
--
-- select upper(btrim(ii.description)) as description, sum(ii.quantity) as units
--   from public.invoice_items ii
--   join public.invoices i on i.id = ii.invoice_id
--  where i.issued_at > (select min(created_at) from public.warehouse_stock
--                        where warehouse = 'STORE STOCK')
--    and not exists (
--          select 1 from public.warehouse_stock s
--           where s.warehouse = 'STORE STOCK'
--             and (upper(btrim(s.model)) = upper(btrim(ii.description))
--               or right(upper(btrim(ii.description)),
--                        length(' — ' || upper(btrim(s.model))))
--                  = ' — ' || upper(btrim(s.model))))
--  group by 1 order by units desc;


-- ############################################################################
-- ## 20260921_merge_digital_multimeter.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Fold "DIGITAL MULTIMETER" into "DIGITAL MULTIMETER DT920SA" — 2026-09-21
--
-- FISHPONG-2 carried a bare "DIGITAL MULTIMETER" while FISHPONG-1 carried
-- "DIGITAL MULTIMETER DT920SA". They are the same meter, so they were two
-- names for one product — which meant the two piles could never be
-- transferred between each other, and neither count was the real one.
--
-- Stock is keyed on (warehouse, model), so this is a rename, except where a
-- warehouse holds BOTH names: there the rows are added together and only
-- one kept, or the location would list the same meter twice.
--
-- The model string is also the identity used by product_codes (scanned
-- barcodes) and pricelist_items, so those are renamed in step. Past invoice
-- lines are deliberately NOT touched: they record what was printed on a
-- customer's invoice, and the History tab matches on a substring anyway, so
-- a search for "multimeter" still finds them.
--
-- Run once, in the Supabase SQL editor. Idempotent — after the first run no
-- row named exactly "DIGITAL MULTIMETER" is left for it to act on. Order
-- against the STORE STOCK opening count does not matter; they touch
-- different locations.
--
-- NOTE ON STRUCTURE — the merge is ONE statement, built from CTEs, rather
-- than a temp table filled by one statement and read by the next. The
-- Supabase SQL editor does not honour an explicit `begin`, so each statement
-- commits on its own and a temp table declared `on commit drop` is gone
-- before the next statement can read it. Every step below therefore stands
-- on its own and is safe to re-run.
-- ─────────────────────────────────────────────────────────────

-- ── 1. Merge and rename, in a single atomic statement ─────────
-- The UPDATE and the DELETE must share one snapshot of the table. Split
-- apart, the DELETE would re-evaluate "which warehouses hold the old name"
-- AFTER the UPDATE had already renamed the surviving row, find nothing, and
-- leave the absorbed duplicate sitting there.
with involved as (
  -- Every row under either name, but only in warehouses that actually hold
  -- the old one — a location already using DT920SA alone is left untouched.
  -- Written as a set rather than a pair so that a warehouse holding two rows
  -- of the same name, which nothing prevents at the database level, is still
  -- added up correctly instead of one of them being silently dropped.
  select s.id, s.warehouse, s.opening_stock, s.invoice_taken,
         s.transfer_in, s.transfer_out, s.min_level, s.daily_taken,
         -- The surviving row: the one on the books longest. Ranked on
         -- created_at rather than id, because gen_random_uuid() is random
         -- and says nothing about age. id breaks a tie.
         row_number() over (
           partition by s.warehouse order by s.created_at, s.id::text
         ) as rn
    from public.warehouse_stock s
   where s.model in ('DIGITAL MULTIMETER', 'DIGITAL MULTIMETER DT920SA')
     and s.warehouse in (
           select warehouse from public.warehouse_stock
            where model = 'DIGITAL MULTIMETER'
         )
),
merged as (
  select
    i.warehouse,
    (select k.id from involved k where k.warehouse = i.warehouse and k.rn = 1) as keeper_id,
    sum(i.opening_stock)              as opening_stock,
    sum(coalesce(i.invoice_taken, 0)) as invoice_taken,
    sum(coalesce(i.transfer_in,   0)) as transfer_in,
    sum(coalesce(i.transfer_out,  0)) as transfer_out,
    -- The lower of the reorder points, the more cautious one. MIN skips
    -- nulls, so a row without one does not erase the other's.
    min(i.min_level)                  as min_level,
    -- daily_taken is a day→qty map. Overlapping days are added, not
    -- overwritten, or a day booked out in both piles would lose one of them.
    (
      select coalesce(jsonb_object_agg(d.day, d.qty), '{}'::jsonb)
        from (
          select e.key as day, sum(e.value::integer) as qty
            from involved j
           cross join lateral jsonb_each_text(coalesce(j.daily_taken, '{}'::jsonb)) e
           where j.warehouse = i.warehouse
           group by e.key
        ) d
    )                                 as daily_taken
  from involved i
  group by i.warehouse
),
-- Write the combined figures onto the surviving row. total_taken,
-- closing_stock and stock_status are left to trg_warehouse_stock_derive,
-- which recomputes them from these columns.
upd as (
  update public.warehouse_stock s
     set model         = 'DIGITAL MULTIMETER DT920SA',
         opening_stock = m.opening_stock,
         invoice_taken = m.invoice_taken,
         transfer_in   = m.transfer_in,
         transfer_out  = m.transfer_out,
         min_level     = m.min_level,
         daily_taken   = m.daily_taken
    from merged m
   where s.id = m.keeper_id
  returning s.id
)
-- Drop the rows that were absorbed. `upd` runs even though nothing selects
-- from it: a data-modifying CTE is always executed.
delete from public.warehouse_stock s
 using merged m
 where s.warehouse = m.warehouse
   and s.id       <> m.keeper_id
   and s.model in ('DIGITAL MULTIMETER', 'DIGITAL MULTIMETER DT920SA');

-- ── 2. Any warehouse that only ever held the old name ─────────
-- Nothing to merge it with, so a plain rename is the whole job. This also
-- catches anything step 1 left behind, which keeps the file safe to re-run.
update public.warehouse_stock
   set model = 'DIGITAL MULTIMETER DT920SA'
 where model = 'DIGITAL MULTIMETER';

-- ── 3. The other tables keyed on the model string ─────────────
-- A barcode linked to the old name must keep resolving, or the next scan of
-- that box would come up as an unknown code needing to be linked again.
update public.product_codes
   set model = 'DIGITAL MULTIMETER DT920SA', updated_at = now()
 where model = 'DIGITAL MULTIMETER';

update public.pricelist_items
   set model = 'DIGITAL MULTIMETER DT920SA'
 where model = 'DIGITAL MULTIMETER';

-- ── Verification (run after the statements above) ─────────────
-- select warehouse, model, opening_stock, closing_stock
--   from public.warehouse_stock where model ilike '%MULTIMETER%'
--  order by warehouse;
--   -- expect no row named exactly 'DIGITAL MULTIMETER', and exactly one
--   -- 'DIGITAL MULTIMETER DT920SA' per warehouse that held either name.
--   -- On the seeded data: FISHPONG-1 15, FISHPONG-2 10, STORE STOCK 10.


-- ############################################################################
-- ## 20260921_main_fixed_pricing.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Main-shop fixed pricing — 2026-09-21
--
-- Gives every main-shop product ONE selling price and makes that price the
-- price an invoice line is written with — the same treatment Dahua got in
-- 20260906_dahua_pricing.sql / _price_override.sql.
--
-- WHERE THE PRICE LIVES
--   pricelist_items.ghs_price, keyed on the model string, NOT a column on
--   warehouse_stock. Dahua could put the price on the stock row because it
--   has a single warehouse; here the same model sits in BACK WAREHOUSE,
--   FISHPONG-1 and STORE STOCK at once, and three rows would mean three
--   prices to keep in step by hand. pricelist_items is also already what
--   the invoice form reads, so nothing has to be migrated onto a new table.
--
-- WHO MAY REPRICE
--   Already settled: "write pricelist_items" is superboss-only RLS
--   (20260807_superboss.sql), so the Big-Boss lock Dahua needed a trigger
--   for is enforced here by the policy. No lock trigger is added.
--
-- WHAT THE TRIGGERS DO
--   1. invoice_item_apply_price     a line with no price typed takes the
--                                   model's price; line_total is always
--                                   derived, never trusted from the client.
--   2. invoice_log_price_override   selling at anything other than the list
--                                   price is written to audit_log.
--   3. invoice_resync_totals        the header (subtotal / VAT / total) is
--                                   recomputed from its own lines.
--
-- A line typed free-hand, or picked from the product catalogue (whose
-- description reads "Title — MODEL"), matches no pricelist model. Those are
-- left exactly as the cashier entered them: unpriced, not zeroed.
--
-- Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────

begin;

-- ── 1. Somewhere to file a price entered from the Stock tab ───
-- pricelist_items.category_id is NOT NULL, so a price for a model that has
-- no catalogue entry yet needs a category to land in.
insert into public.pricelist_categories (name)
select 'Stock items'
 where not exists (select 1 from public.pricelist_categories where name = 'Stock items');

-- ── 2. The price of a model ───────────────────────────────────
-- Case- and whitespace-insensitive, because a model typed on an invoice and
-- the same model typed into the price list rarely agree on either.
--
-- Nothing constrains pricelist_items to one row per model, and the shop has
-- been entering rows by hand for months, so a model CAN have several. The
-- most recently entered priced row wins: "the last price I typed is the
-- price" is a rule staff can predict without being taught it.
create or replace function public.price_for_model(p_model text)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select pi.ghs_price
    from public.pricelist_items pi
   where upper(btrim(pi.model)) = upper(btrim(coalesce(p_model, '')))
     and btrim(coalesce(p_model, '')) <> ''
     and pi.ghs_price > 0
   order by pi.created_at desc
   limit 1
$$;

-- The lookup above runs for every invoice line saved.
create index if not exists pricelist_items_model_upper_idx
  on public.pricelist_items (upper(btrim(model)));

-- ── 3. Remember the price that applied at the time of sale ────
-- An override is only detectable against the price that applied WHEN the
-- line was written. Reading the price list later gives today's figure, so a
-- repricing would silently turn old sales into overrides, or hide real ones.
alter table public.invoice_items
  add column if not exists list_price numeric(12,2) not null default 0;

comment on column public.invoice_items.list_price is
  'The model''s fixed price at the moment this line was saved. 0 = the model '
  'had no fixed price (or the line is free text). An override is '
  'list_price > 0 and unit_price <> list_price.';

-- Deliberately NOT back-filled. Lines written before this migration were
-- priced by hand with no list price in force, and setting list_price =
-- unit_price would invent a fixed price that never existed and make every
-- historical sale look like it matched one.

-- ── 4. Apply the price ────────────────────────────────────────
create or replace function public.fn_invoice_item_apply_price()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  fixed numeric(12,2);
begin
  fixed := public.price_for_model(new.description);
  new.list_price := coalesce(fixed, 0);

  -- A line saved with no price takes the model's price. This is what makes
  -- pricing automatic in the ordinary case: the cashier picks the item and
  -- does nothing else. Typing a different figure is an override, and step 5
  -- logs it rather than blocking it — a counter negotiation must not fail.
  if coalesce(new.unit_price, 0) = 0 and coalesce(fixed, 0) > 0 then
    new.unit_price := fixed;
  end if;

  new.line_total := round(coalesce(new.quantity, 0) * coalesce(new.unit_price, 0), 2);
  return new;
end;
$$;

drop trigger if exists trg_invoice_item_apply_price on public.invoice_items;
create trigger trg_invoice_item_apply_price
  before insert or update on public.invoice_items
  for each row execute function public.fn_invoice_item_apply_price();

-- ── 5. Log every override ─────────────────────────────────────
-- Definer because a cashier has no INSERT on audit_log — the same pattern
-- fn_audit() uses for invoices and expenses.
create or replace function public.fn_invoice_log_price_override()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  inv record;
begin
  if coalesce(new.list_price, 0) <= 0     then return null; end if;
  if new.unit_price = new.list_price      then return null; end if;

  select invoice_number, customer_name into inv
    from public.invoices where id = new.invoice_id;

  insert into public.audit_log (actor_id, actor_role, action, table_name, row_id, diff)
  values (
    auth.uid(),
    public.current_role(),
    'override',
    'invoice_price_override',
    new.id::text,
    jsonb_build_object(
      'model',          new.description,
      'description',    new.description,
      'invoice_id',     new.invoice_id,
      'invoice_number', inv.invoice_number,
      'customer_name',  inv.customer_name,
      'quantity',       new.quantity,
      'list_price',     new.list_price,
      'unit_price',     new.unit_price,
      'difference',     round(new.unit_price - new.list_price, 2),
      'total_effect',   round((new.unit_price - new.list_price) * new.quantity, 2)
    )
  );
  return null;
end;
$$;

drop trigger if exists trg_invoice_log_price_override on public.invoice_items;
create trigger trg_invoice_log_price_override
  after insert or update on public.invoice_items
  for each row execute function public.fn_invoice_log_price_override();

-- ── 6. Header totals always match the lines ───────────────────
-- Without this, a line the trigger repriced would leave the header showing
-- the figure the client computed before the price was applied.
create or replace function public.fn_invoice_resync_totals()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  inv  uuid;
  sub  numeric(12,2);
  rate numeric(5,2);
  vat  numeric(12,2);
begin
  inv := coalesce(new.invoice_id, old.invoice_id);

  select vat_rate into rate from public.invoices where id = inv;
  if rate is null then
    return null;  -- invoice already gone (cascade delete)
  end if;

  select coalesce(sum(line_total), 0) into sub
    from public.invoice_items where invoice_id = inv;

  vat := round(sub * rate / 100, 2);

  update public.invoices
     set subtotal   = sub,
         vat_amount = vat,
         total      = round(sub + vat, 2)
   where id = inv;

  return null;
end;
$$;

drop trigger if exists trg_invoice_resync_totals on public.invoice_items;
create trigger trg_invoice_resync_totals
  after insert or update or delete on public.invoice_items
  for each row execute function public.fn_invoice_resync_totals();

-- ── 7. Setting a price from the Stock tab ─────────────────────
-- The Prices screen thinks in models, not in price-list rows: it should not
-- have to know about categories, or whether a row for this model exists.
-- Updates the most recent row for the model, or creates one.
--
-- Definer so the category lookup and insert are not blocked by RLS, but
-- gated to the Big Boss explicitly — otherwise this would be a hole straight
-- through the superboss-only write policy it is standing in front of.
create or replace function public.set_model_price(p_model text, p_price numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_model text := btrim(coalesce(p_model, ''));
  v_id    uuid;
  v_cat   uuid;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss may set a selling price'
      using errcode = '42501';
  end if;
  if v_model = '' then
    raise exception 'A price needs a model';
  end if;
  if p_price is null or p_price < 0 then
    raise exception 'A price cannot be negative';
  end if;

  select id into v_id
    from public.pricelist_items
   where upper(btrim(model)) = upper(v_model)
   order by created_at desc
   limit 1;

  if v_id is not null then
    update public.pricelist_items set ghs_price = p_price where id = v_id;
  else
    select id into v_cat from public.pricelist_categories where name = 'Stock items' limit 1;
    if v_cat is null then
      insert into public.pricelist_categories (name) values ('Stock items') returning id into v_cat;
    end if;
    -- `name` is NOT NULL and is what the Price List tab shows; the model is
    -- the only name this row has.
    insert into public.pricelist_items (category_id, name, model, ghs_price)
    values (v_cat, v_model, v_model, p_price);
  end if;
end;
$$;

grant execute on function public.price_for_model(text)        to authenticated;
grant execute on function public.set_model_price(text, numeric) to authenticated;

commit;

-- ── Verification ──────────────────────────────────────────────
-- How much of STORE STOCK is priced:
--
-- select count(*) filter (where public.price_for_model(model) > 0) as priced,
--        count(*) filter (where coalesce(public.price_for_model(model), 0) = 0) as unpriced
--   from public.warehouse_stock where warehouse = 'STORE STOCK';
--
-- Overrides so far, newest first:
--
-- select created_at,
--        diff->>'invoice_number' as invoice,
--        diff->>'model'          as model,
--        diff->>'list_price'     as should_be,
--        diff->>'unit_price'     as sold_at,
--        diff->>'total_effect'   as effect
--   from public.audit_log
--  where table_name = 'invoice_price_override'
--  order by created_at desc;


-- ############################################################################
-- ## 20260921_receive_stock_and_signatures.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Receiving stock from outside, and signing for it — 2026-09-21
--
-- Until now the only way units could enter the system was a physical count
-- written into opening_stock by a migration. Anything a supplier delivered
-- had to be back-filled by hand, so the moment a delivery arrived the
-- figures were wrong and stayed wrong until someone noticed.
--
-- Receiving is NOT a transfer: nothing is deducted from anywhere, stock
-- enters. It shares the transfer record anyway, because "where did this
-- stock come from" should have one answer in one list rather than two
-- screens to cross-reference. `kind` tells the two apart:
--
--   move     warehouse -> warehouse. Source goes down, destination goes up.
--   receive  outside -> warehouse. Destination goes up, nothing goes down.
--            from_warehouse is null, and `supplier` says who brought it.
--
-- SIGNATURES
--   Both kinds can carry a signature drawn on screen, stored as a PNG data
--   URL. The staff member's name is copied onto the record at the time of
--   signing rather than read back through created_by: a name resolved later
--   would follow a renamed or deleted staff row, and the point of a
--   signature is what was true when it was signed.
--
-- Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────

-- ── 1. Columns ────────────────────────────────────────────────
alter table public.stock_transfers
  add column if not exists kind      text not null default 'move',
  add column if not exists supplier  text,
  add column if not exists signature text,
  add column if not exists signed_by text;

comment on column public.stock_transfers.kind is
  'move = between two locations; receive = in from outside (from_warehouse null).';
comment on column public.stock_transfers.signature is
  'PNG data URL of a signature drawn on screen. Null when unsigned.';
comment on column public.stock_transfers.signed_by is
  'Who signed, copied in at the time — not resolved from created_by later.';

-- A receive has no source, so the column can no longer be mandatory.
alter table public.stock_transfers alter column from_warehouse drop not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'stock_transfers_kind_check') then
    alter table public.stock_transfers
      add constraint stock_transfers_kind_check check (kind in ('move', 'receive'));
  end if;
  -- A receive names no source; a move must name one.
  if not exists (select 1 from pg_constraint where conname = 'stock_transfers_source_check') then
    alter table public.stock_transfers
      add constraint stock_transfers_source_check check (
        (kind = 'receive' and from_warehouse is null)
        or (kind = 'move' and from_warehouse is not null)
      );
  end if;
  -- A drawn signature is a few tens of KB; anything far larger is a bug or
  -- an attempt to use this column as file storage.
  if not exists (select 1 from pg_constraint where conname = 'stock_transfers_signature_len') then
    alter table public.stock_transfers
      add constraint stock_transfers_signature_len check (
        signature is null or length(signature) <= 200000
      );
  end if;
end $$;

create index if not exists stock_transfers_kind_idx on public.stock_transfers (kind, transferred_at desc);

-- ── 2. Numbering ──────────────────────────────────────────────
-- Receipts get their own RCV series so a delivery note and an internal move
-- can never be confused for one another in conversation.
create or replace function public.next_movement_number(p_kind text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  yr     text := to_char(now(), 'YYYY');
  prefix text := case when p_kind = 'receive' then 'RCV' else 'TRF' end;
  cnt    integer;
begin
  select count(*) + 1 into cnt
    from public.stock_transfers
   where to_char(transferred_at, 'YYYY') = yr
     and kind = p_kind;
  return prefix || '-' || yr || '-' || lpad(cnt::text, 4, '0');
end $$;

-- ── 3. Who is signing ─────────────────────────────────────────
create or replace function public.current_staff_name()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(nullif(btrim(full_name), ''), role)
    from public.user_roles where user_id = auth.uid()
$$;

-- ── 4. Receiving ──────────────────────────────────────────────
-- p_items: [{"model": "DS-7208HGHI-M1", "quantity": 5}, ...]
--
-- A model the destination has never carried is created there, because that
-- is the ordinary case for a delivery — new stock arrives before anyone has
-- set up a row for it. Units land in transfer_in, leaving opening_stock as
-- what the last physical count actually found.
create or replace function public.receive_stock(
  p_to        text,
  p_items     jsonb,
  p_supplier  text default null,
  p_note      text default null,
  p_signature text default null,
  p_when      timestamptz default now()
) returns public.stock_transfers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rec   public.stock_transfers;
  v_item  jsonb;
  v_model text;
  v_qty   integer;
  v_pos   integer := 0;
  v_try   integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to receive stock';
  end if;
  if p_to is null or btrim(p_to) = '' then
    raise exception 'Where is this delivery going?';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A delivery needs at least one item';
  end if;

  -- next_movement_number() counts rows, so two staff receiving at the same
  -- moment can both be handed RCV-2026-0007. The unique constraint catches
  -- it; retrying picks up the number the winner did not take.
  for v_try in 1..8 loop
    begin
      insert into public.stock_transfers
        (transfer_number, kind, from_warehouse, to_warehouse, supplier,
         note, signature, signed_by, transferred_at, created_by)
      values
        (public.next_movement_number('receive'), 'receive', null, p_to,
         nullif(btrim(coalesce(p_supplier, '')), ''),
         nullif(btrim(coalesce(p_note, '')), ''),
         nullif(btrim(coalesce(p_signature, '')), ''),
         public.current_staff_name(),
         coalesce(p_when, now()), auth.uid())
      returning * into v_rec;
      exit;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    update public.warehouse_stock
       set transfer_in = coalesce(transfer_in, 0) + v_qty
     where warehouse = p_to and model = v_model;

    if not found then
      insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, transfer_in)
      values (p_to, v_model, 0, '{}'::jsonb, v_qty);
    end if;

    v_pos := v_pos + 1;
    -- from_before is null: there is no source to have held anything.
    insert into public.stock_transfer_items (transfer_id, model, quantity, from_before, position)
    values (v_rec.id, v_model, v_qty, null, v_pos);
  end loop;

  return v_rec;
end $$;

-- ── 5. Moves can be signed too ────────────────────────────────
-- Dropped rather than overloaded: two transfer_stock functions differing
-- only by a trailing argument would make every existing call ambiguous.
drop function if exists public.transfer_stock(text, text, jsonb, text, timestamptz);

create or replace function public.transfer_stock(
  p_from      text,
  p_to        text,
  p_items     jsonb,
  p_note      text default null,
  p_when      timestamptz default now(),
  p_signature text default null
) returns public.stock_transfers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transfer public.stock_transfers;
  v_item     jsonb;
  v_model    text;
  v_qty      integer;
  v_before   integer;
  v_pos      integer := 0;
  v_try      integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to transfer stock';
  end if;
  if p_from is null or p_to is null or p_from = p_to then
    raise exception 'A transfer needs two different locations';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A transfer needs at least one item';
  end if;

  for v_try in 1..8 loop
    begin
      insert into public.stock_transfers
        (transfer_number, kind, from_warehouse, to_warehouse,
         note, signature, signed_by, transferred_at, created_by)
      values
        (public.next_movement_number('move'), 'move', p_from, p_to,
         nullif(btrim(coalesce(p_note, '')), ''),
         nullif(btrim(coalesce(p_signature, '')), ''),
         public.current_staff_name(),
         coalesce(p_when, now()), auth.uid())
      returning * into v_transfer;
      exit;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    select closing_stock into v_before
      from public.warehouse_stock
     where warehouse = p_from and model = v_model
     for update;
    if not found then
      raise exception '% does not hold %', p_from, v_model;
    end if;

    update public.warehouse_stock
       set transfer_out = coalesce(transfer_out, 0) + v_qty
     where warehouse = p_from and model = v_model;

    update public.warehouse_stock
       set transfer_in = coalesce(transfer_in, 0) + v_qty
     where warehouse = p_to and model = v_model;
    if not found then
      insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, transfer_in)
      values (p_to, v_model, 0, '{}'::jsonb, v_qty);
    end if;

    v_pos := v_pos + 1;
    insert into public.stock_transfer_items (transfer_id, model, quantity, from_before, position)
    values (v_transfer.id, v_model, v_qty, v_before, v_pos);
  end loop;

  return v_transfer;
end $$;

grant execute on function public.receive_stock(text, jsonb, text, text, text, timestamptz) to authenticated;
grant execute on function public.transfer_stock(text, text, jsonb, text, timestamptz, text) to authenticated;
grant execute on function public.next_movement_number(text) to authenticated;
grant execute on function public.current_staff_name() to authenticated;

-- ── Verification ──────────────────────────────────────────────
-- Everything received from outside, newest first:
--
-- select transfer_number, to_warehouse, supplier, signed_by, transferred_at,
--        (signature is not null) as signed
--   from public.stock_transfers where kind = 'receive'
--  order by transferred_at desc;
--
-- What a given delivery brought in:
--
-- select i.model, i.quantity
--   from public.stock_transfer_items i
--   join public.stock_transfers t on t.id = i.transfer_id
--  where t.transfer_number = 'RCV-2026-0001'
--  order by i.position;


-- ############################################################################
-- ## 20260922_returns_and_staff_id.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Returns (RNA), and staff ID in place of a drawn signature — 2026-09-22
--
-- Supersedes the signature pad added in
-- 20260921_receive_stock_and_signatures.sql. A drawn squiggle proves less
-- than the login it was drawn under: the staff ID is already unique, it
-- cannot be traced by someone else's hand, and it is what the shop uses to
-- identify people everywhere else. The signature column is dropped.
--
-- RETURNS (RNA)
--   A third kind of movement, alongside moving and receiving. Goods come
--   back from a buyer, and each line is either
--
--     not spoilt  resaleable — the units go back into stock, normally
--                 STORE STOCK, exactly as a delivery would.
--     spoilt      written off. Recorded in full, but NO stock is added:
--                 putting damaged goods back on the shelf as sellable is
--                 how a shop ends up invoicing something it cannot supply.
--
--   Both are logged either way, on the same numbered record, so a return is
--   never a quantity that changed with nothing to explain it.
--
--   Receipts and returns each get their own series — TRF / RCV / RNA — so a
--   delivery note, an internal move and a customer return can never be
--   confused for one another.
--
-- Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────

-- ── 1. Staff ID replaces the signature ────────────────────────
alter table public.stock_transfers
  add column if not exists kind      text not null default 'move',
  add column if not exists supplier  text,
  add column if not exists signed_by text,
  add column if not exists staff_id  text;

alter table public.stock_transfers drop constraint if exists stock_transfers_signature_len;
alter table public.stock_transfers drop column if exists signature;

comment on column public.stock_transfers.staff_id is
  'Login ID of the staff member who recorded this, copied in at the time.';
comment on column public.stock_transfers.signed_by is
  'Their name at the time. Stored alongside the ID so the record still reads '
  'plainly if the staff row is later renamed or removed.';
comment on column public.stock_transfers.supplier is
  'Who the stock came from — the supplier on a receive, the buyer on a return.';

-- ── 2. Returns are a third kind ───────────────────────────────
alter table public.stock_transfers alter column from_warehouse drop not null;
alter table public.stock_transfers drop constraint if exists stock_transfers_kind_check;
alter table public.stock_transfers drop constraint if exists stock_transfers_source_check;

alter table public.stock_transfers
  add constraint stock_transfers_kind_check check (kind in ('move', 'receive', 'return'));

-- Only a move has a source location; a delivery and a return both come
-- from outside the warehouses.
alter table public.stock_transfers
  add constraint stock_transfers_source_check check (
    (kind = 'move' and from_warehouse is not null)
    or (kind in ('receive', 'return') and from_warehouse is null)
  );

-- ── 3. Condition, per returned line ───────────────────────────
-- On a move or a receive every line is simply stock, so 'good' is the
-- default and those paths never set it.
alter table public.stock_transfer_items
  add column if not exists condition text not null default 'good';

alter table public.stock_transfer_items drop constraint if exists stock_transfer_items_condition_check;
alter table public.stock_transfer_items
  add constraint stock_transfer_items_condition_check check (condition in ('good', 'spoilt'));

comment on column public.stock_transfer_items.condition is
  'good = went back into stock; spoilt = written off, recorded but not restocked.';

create index if not exists stock_transfer_items_condition_idx
  on public.stock_transfer_items (condition) where condition = 'spoilt';

-- ── 4. Numbering ──────────────────────────────────────────────
create or replace function public.next_movement_number(p_kind text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  yr     text := to_char(now(), 'YYYY');
  prefix text := case p_kind when 'receive' then 'RCV'
                             when 'return'  then 'RNA'
                             else 'TRF' end;
  cnt    integer;
begin
  select count(*) + 1 into cnt
    from public.stock_transfers
   where to_char(transferred_at, 'YYYY') = yr
     and kind = p_kind;
  return prefix || '-' || yr || '-' || lpad(cnt::text, 4, '0');
end $$;

-- ── 5. Who is recording it ────────────────────────────────────
create or replace function public.current_staff_id()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select staff_id from public.user_roles where user_id = auth.uid()
$$;

create or replace function public.current_staff_name()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(nullif(btrim(full_name), ''), role)
    from public.user_roles where user_id = auth.uid()
$$;

-- ── 6. Rebuild the movement functions without p_signature ─────
-- Dropped rather than overloaded: variants differing only by a trailing
-- argument would make every existing call ambiguous.
drop function if exists public.transfer_stock(text, text, jsonb, text, timestamptz);
drop function if exists public.transfer_stock(text, text, jsonb, text, timestamptz, text);
drop function if exists public.receive_stock(text, jsonb, text, text, text, timestamptz);

create or replace function public.transfer_stock(
  p_from  text,
  p_to    text,
  p_items jsonb,
  p_note  text default null,
  p_when  timestamptz default now()
) returns public.stock_transfers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transfer public.stock_transfers;
  v_item     jsonb;
  v_model    text;
  v_qty      integer;
  v_before   integer;
  v_pos      integer := 0;
  v_try      integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to transfer stock';
  end if;
  if p_from is null or p_to is null or p_from = p_to then
    raise exception 'A transfer needs two different locations';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A transfer needs at least one item';
  end if;

  -- next_movement_number() counts rows, so two staff acting at the same
  -- moment can both be handed the same number. The unique constraint
  -- catches it; retrying picks up the one the winner did not take.
  for v_try in 1..8 loop
    begin
      insert into public.stock_transfers
        (transfer_number, kind, from_warehouse, to_warehouse,
         note, signed_by, staff_id, transferred_at, created_by)
      values
        (public.next_movement_number('move'), 'move', p_from, p_to,
         nullif(btrim(coalesce(p_note, '')), ''),
         public.current_staff_name(), public.current_staff_id(),
         coalesce(p_when, now()), auth.uid())
      returning * into v_transfer;
      exit;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    select closing_stock into v_before
      from public.warehouse_stock
     where warehouse = p_from and model = v_model
     for update;
    if not found then
      raise exception '% does not hold %', p_from, v_model;
    end if;

    update public.warehouse_stock
       set transfer_out = coalesce(transfer_out, 0) + v_qty
     where warehouse = p_from and model = v_model;

    update public.warehouse_stock
       set transfer_in = coalesce(transfer_in, 0) + v_qty
     where warehouse = p_to and model = v_model;
    if not found then
      insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, transfer_in)
      values (p_to, v_model, 0, '{}'::jsonb, v_qty);
    end if;

    v_pos := v_pos + 1;
    insert into public.stock_transfer_items (transfer_id, model, quantity, from_before, position)
    values (v_transfer.id, v_model, v_qty, v_before, v_pos);
  end loop;

  return v_transfer;
end $$;

create or replace function public.receive_stock(
  p_to       text,
  p_items    jsonb,
  p_supplier text default null,
  p_note     text default null,
  p_when     timestamptz default now()
) returns public.stock_transfers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rec   public.stock_transfers;
  v_item  jsonb;
  v_model text;
  v_qty   integer;
  v_pos   integer := 0;
  v_try   integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to receive stock';
  end if;
  if p_to is null or btrim(p_to) = '' then
    raise exception 'Where is this delivery going?';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A delivery needs at least one item';
  end if;

  for v_try in 1..8 loop
    begin
      insert into public.stock_transfers
        (transfer_number, kind, from_warehouse, to_warehouse, supplier,
         note, signed_by, staff_id, transferred_at, created_by)
      values
        (public.next_movement_number('receive'), 'receive', null, p_to,
         nullif(btrim(coalesce(p_supplier, '')), ''),
         nullif(btrim(coalesce(p_note, '')), ''),
         public.current_staff_name(), public.current_staff_id(),
         coalesce(p_when, now()), auth.uid())
      returning * into v_rec;
      exit;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    update public.warehouse_stock
       set transfer_in = coalesce(transfer_in, 0) + v_qty
     where warehouse = p_to and model = v_model;

    if not found then
      insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, transfer_in)
      values (p_to, v_model, 0, '{}'::jsonb, v_qty);
    end if;

    v_pos := v_pos + 1;
    insert into public.stock_transfer_items (transfer_id, model, quantity, from_before, position)
    values (v_rec.id, v_model, v_qty, null, v_pos);
  end loop;

  return v_rec;
end $$;

-- ── 7. Returns ────────────────────────────────────────────────
-- p_items: [{"model": "...", "quantity": 2, "condition": "good"|"spoilt"}, ...]
--
-- A 'good' line goes back into stock at p_to. A 'spoilt' line is recorded
-- and nothing is restocked — that is the whole point of asking.
create or replace function public.return_stock(
  p_to       text,
  p_items    jsonb,
  p_customer text default null,
  p_note     text default null,
  p_when     timestamptz default now()
) returns public.stock_transfers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rec   public.stock_transfers;
  v_item  jsonb;
  v_model text;
  v_qty   integer;
  v_cond  text;
  v_pos   integer := 0;
  v_try   integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record returns';
  end if;
  if p_to is null or btrim(p_to) = '' then
    raise exception 'Where are the good items going back to?';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A return needs at least one item';
  end if;

  for v_try in 1..8 loop
    begin
      insert into public.stock_transfers
        (transfer_number, kind, from_warehouse, to_warehouse, supplier,
         note, signed_by, staff_id, transferred_at, created_by)
      values
        (public.next_movement_number('return'), 'return', null, p_to,
         nullif(btrim(coalesce(p_customer, '')), ''),
         nullif(btrim(coalesce(p_note, '')), ''),
         public.current_staff_name(), public.current_staff_id(),
         coalesce(p_when, now()), auth.uid())
      returning * into v_rec;
      exit;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    -- Anything not explicitly marked spoilt is treated as resaleable, which
    -- matches how the form is filled in: the tick is on the exception.
    v_cond  := case when lower(coalesce(v_item->>'condition', 'good')) = 'spoilt'
                    then 'spoilt' else 'good' end;
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    if v_cond = 'good' then
      update public.warehouse_stock
         set transfer_in = coalesce(transfer_in, 0) + v_qty
       where warehouse = p_to and model = v_model;

      if not found then
        insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, transfer_in)
        values (p_to, v_model, 0, '{}'::jsonb, v_qty);
      end if;
    end if;

    v_pos := v_pos + 1;
    insert into public.stock_transfer_items
      (transfer_id, model, quantity, from_before, position, condition)
    values (v_rec.id, v_model, v_qty, null, v_pos, v_cond);
  end loop;

  return v_rec;
end $$;

grant execute on function public.transfer_stock(text, text, jsonb, text, timestamptz)   to authenticated;
grant execute on function public.receive_stock(text, jsonb, text, text, timestamptz)    to authenticated;
grant execute on function public.return_stock(text, jsonb, text, text, timestamptz)     to authenticated;
grant execute on function public.next_movement_number(text) to authenticated;
grant execute on function public.current_staff_id()         to authenticated;
grant execute on function public.current_staff_name()       to authenticated;

-- ── Verification ──────────────────────────────────────────────
-- Everything returned, and whether it went back on the shelf:
--
-- select t.transfer_number, t.transferred_at, t.supplier as returned_by,
--        t.staff_id, i.model, i.quantity, i.condition
--   from public.stock_transfer_items i
--   join public.stock_transfers t on t.id = i.transfer_id
--  where t.kind = 'return'
--  order by t.transferred_at desc, i.position;
--
-- Written off this month, by model:
--
-- select i.model, sum(i.quantity) as spoilt
--   from public.stock_transfer_items i
--   join public.stock_transfers t on t.id = i.transfer_id
--  where t.kind = 'return' and i.condition = 'spoilt'
--    and t.transferred_at >= date_trunc('month', now())
--  group by 1 order by spoilt desc;


-- ############################################################################
-- ## 20260922_spoilt_location.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Spoilt goods pile up in their own location — 2026-09-22
--
-- Until now a spoilt return was recorded on the RNA record and nowhere
-- else: correct, but it meant the only way to answer "how much have we
-- written off" was to read every return. Write-offs now accumulate in a
-- location of their own, so the Stock tab answers it at a glance.
--
-- WHY A LOCATION RATHER THAN A COLUMN
--   Everything the shop already knows how to do with stock — list it,
--   search it, export it, move it back out — works on a warehouse without
--   another screen being written. A damaged unit is still a physical thing
--   sitting somewhere; SPOILT is where.
--
-- WHAT IT IS NOT
--   Not sellable. Invoices deduct from STORE STOCK alone, so nothing here
--   can be invoiced by accident. The form does not offer SPOILT as a
--   destination either — stock arrives here only by being marked spoilt on
--   a return. It CAN be moved out, which is how a repaired unit goes back
--   into circulation, or a disposal is recorded as leaving.
--
-- Units land in transfer_in, leaving opening_stock at 0: nothing here was
-- ever counted onto a shelf, it arrived by being written off.
--
-- Requires 20260922_returns_and_staff_id.sql. Idempotent.
-- ─────────────────────────────────────────────────────────────

-- ── 0. Refuse to run out of order ─────────────────────────────
-- Without the returns migration there is no `condition` column, no
-- 'return' kind and no staff-id functions, and this file fails partway
-- through with "column i.condition does not exist" — which says nothing
-- about what to do next.
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name   = 'stock_transfer_items'
       and column_name  = 'condition'
  ) then
    raise exception
      'Run 20260922_returns_and_staff_id.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1. The location ───────────────────────────────────────────
-- Red, and no date columns: spoilt goods are not counted on a day sheet.
insert into public.warehouses (name, color, date_columns, section_labels)
select 'SPOILT', '#ef4444', '{}', '{}'
 where not exists (select 1 from public.warehouses where name = 'SPOILT');

-- ── 2. Returns file spoilt lines there ────────────────────────
-- Dropped rather than overloaded: a variant differing only by a trailing
-- argument would make every existing call ambiguous.
drop function if exists public.return_stock(text, jsonb, text, text, timestamptz);

create or replace function public.return_stock(
  p_to       text,
  p_items    jsonb,
  p_customer text default null,
  p_note     text default null,
  p_when     timestamptz default now(),
  p_spoilt   text default 'SPOILT'
) returns public.stock_transfers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rec   public.stock_transfers;
  v_item  jsonb;
  v_model text;
  v_qty   integer;
  v_cond  text;
  v_dest  text;
  v_pos   integer := 0;
  v_try   integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record returns';
  end if;
  if p_to is null or btrim(p_to) = '' then
    raise exception 'Where are the good items going back to?';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A return needs at least one item';
  end if;

  for v_try in 1..8 loop
    begin
      insert into public.stock_transfers
        (transfer_number, kind, from_warehouse, to_warehouse, supplier,
         note, signed_by, staff_id, transferred_at, created_by)
      values
        (public.next_movement_number('return'), 'return', null, p_to,
         nullif(btrim(coalesce(p_customer, '')), ''),
         nullif(btrim(coalesce(p_note, '')), ''),
         public.current_staff_name(), public.current_staff_id(),
         coalesce(p_when, now()), auth.uid())
      returning * into v_rec;
      exit;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    -- Anything not explicitly marked spoilt is treated as resaleable, which
    -- matches how the form is filled in: the tick is on the exception.
    v_cond  := case when lower(coalesce(v_item->>'condition', 'good')) = 'spoilt'
                    then 'spoilt' else 'good' end;
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    -- A good line goes back on the shelf; a spoilt one goes to the
    -- write-off pile. Either way the units land somewhere countable, so a
    -- return never ends as a quantity that vanished.
    v_dest := case when v_cond = 'spoilt' then p_spoilt else p_to end;

    update public.warehouse_stock
       set transfer_in = coalesce(transfer_in, 0) + v_qty
     where warehouse = v_dest and model = v_model;

    if not found then
      insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, transfer_in)
      values (v_dest, v_model, 0, '{}'::jsonb, v_qty);
    end if;

    v_pos := v_pos + 1;
    insert into public.stock_transfer_items
      (transfer_id, model, quantity, from_before, position, condition)
    values (v_rec.id, v_model, v_qty, null, v_pos, v_cond);
  end loop;

  return v_rec;
end $$;

grant execute on function public.return_stock(text, jsonb, text, text, timestamptz, text) to authenticated;

-- ── 3. Back-fill anything already written off ─────────────────
-- Spoilt lines recorded before this migration restocked nothing anywhere,
-- so the pile would start empty and understate the true total. Computed as
-- an absolute figure from the return records rather than added to, so it is
-- safe to run again and cannot double anything.
insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, transfer_in)
select 'SPOILT', x.model, 0, '{}'::jsonb, x.units
  from (
    select i.model, sum(i.quantity)::integer as units
      from public.stock_transfer_items i
      join public.stock_transfers t on t.id = i.transfer_id
     where t.kind = 'return' and i.condition = 'spoilt'
     group by i.model
  ) x
 where not exists (
         select 1 from public.warehouse_stock s
          where s.warehouse = 'SPOILT' and s.model = x.model
       );

update public.warehouse_stock s
   set transfer_in = x.units
  from (
    select i.model, sum(i.quantity)::integer as units
      from public.stock_transfer_items i
      join public.stock_transfers t on t.id = i.transfer_id
     where t.kind = 'return' and i.condition = 'spoilt'
     group by i.model
  ) x
 where s.warehouse = 'SPOILT'
   and s.model = x.model
   and s.transfer_in is distinct from x.units;

-- ── Verification ──────────────────────────────────────────────
-- What has been written off, worst first:
--
-- select model, closing_stock as spoilt
--   from public.warehouse_stock
--  where warehouse = 'SPOILT' and closing_stock > 0
--  order by spoilt desc;
--
-- Total written off, against what it would have sold for:
--
-- select sum(s.closing_stock)                                        as units,
--        sum(s.closing_stock * coalesce(public.price_for_model(s.model), 0)) as at_list_price
--   from public.warehouse_stock s
--  where s.warehouse = 'SPOILT' and s.closing_stock > 0;


-- ############################################################################
-- ## 20260922_movement_history_boss_only.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Movement history is boss-only — 2026-09-22
--
-- 20260920_store_stock_transfers.sql let every signed-in user read the
-- whole transfer history, on the reasoning that it is the record staff
-- check when a count looks wrong. In practice it is a running account of
-- what the shop moves, receives, returns and writes off, and that is not
-- counter staff's to browse.
--
-- Cashiers keep the ability to RECORD movements. transfer_stock,
-- receive_stock and return_stock are all SECURITY DEFINER, so they write
-- and return the new row without the caller needing read access to the
-- table — the tab still confirms "TRF-2026-0007 — 12 units moved ✓" after
-- saving, it just no longer lists everything anyone else has done.
--
-- The Transfers tab hides the history panel for the same audience, but that
-- is presentation. This policy is the boundary: without it the rows are
-- still one API call away.
--
-- Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────

drop policy if exists stock_transfers_read on public.stock_transfers;
drop policy if exists stock_transfers_read on public.stock_transfers;

create policy stock_transfers_read on public.stock_transfers
  for select to authenticated
  using ((select public.is_boss()));

drop policy if exists stock_transfer_items_read on public.stock_transfer_items;
drop policy if exists stock_transfer_items_read on public.stock_transfer_items;

create policy stock_transfer_items_read on public.stock_transfer_items
  for select to authenticated
  using ((select public.is_boss()));

-- ── Verification ──────────────────────────────────────────────
-- As a cashier, this should return nothing; as the boss, the full history:
--
-- select transfer_number, kind, to_warehouse, staff_id, transferred_at
--   from public.stock_transfers order by transferred_at desc limit 10;
--
-- Recording still works for a cashier, because the function is definer:
--
-- select * from public.transfer_stock(
--   'FISHPONG-1', 'STORE STOCK',
--   '[{"model":"DS-2CD1023G2-LIU","quantity":1}]'::jsonb);


-- ############################################################################
-- ## 20260922_store_stock_fifth_count.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- STORE STOCK — fifth count, 2026-09-22
--
-- 153 models on this sheet: 127 never counted before, and 26 that were,
-- whose figures are ADDED to what is already recorded. 672 units in total.
--
-- THE REPEATED ITEMS ARE DELIBERATE
--   The last two dozen lines of this sheet repeat the second count word for
--   word — Paper roll 50, DS-PD1-MC-MS 14, AX3000 1, and so on. That was
--   put to the shop as a question and confirmed: these are further units
--   that arrived on top, not the same ones written down twice. So Paper
--   roll becomes 100, not 50.
--
--   If that turns out to be wrong, every affected model is listed in the
--   UPDATE at the bottom of this file with its new total, and the figures
--   can be halved back in the Stock tab. The list is short and explicit for
--   exactly that reason.
--
-- HOW THE FIGURES ARE WRITTEN
--   As ABSOLUTE totals, not increments. An increment would double again on
--   every re-run, and these migrations have already been run out of order
--   once. Each total is "what the earlier counts set" plus "what this sheet
--   adds", so running this twice leaves the same number.
--
--   For that to hold, THE FOURTH COUNT MUST RUN FIRST — it sets some of
--   these models to absolute figures of its own and would otherwise
--   overwrite the totals here. The guard below refuses to run before it.
--
-- HOW THE SHEET WAS READ
--   Sums are stored added up ("2+2", "4+4+2", "22+200", "9+1", "1+1+1").
--   Repeats within the sheet are two piles of one thing: DS-2CE18D0T-LFS
--   (2 and 1) is 3, and the 7204HGHI ColorVu kit (twice at 1) is 2.
--
--   Three struck-out lines with no quantity are excluded: the second
--   DS-2CD2T83G2-4LI2U, the second DS-J1421/7208HGHI-M1+4+4 CAM, and
--   Power Supply C8. "Patrex box" had no quantity either and is excluded.
--
--   Seven entries carried a "[?]" against an uncertain spelling. The marker
--   is dropped and the name kept as written rather than corrected on a
--   guess: DS-2CD2T46G2P-ISU/SL, DS-2CD2346G2P-ISU/SL, HiLook VI-K13P,
--   DS-3E1318P-E1/M, ST-517C-3M-4G, RBX-830, DS-KH6110-WIE1, Westa
--   ZT550LED, DS-3D501T, NCTS Qstrom Pro 1500VA and HDMI 1.5 m.
--
--   Repeated items are spelled as the database already spells them, so the
--   units land on the existing row instead of opening a second row under
--   different wording for the same product.
--
-- NOT MERGED, DELIBERATELY
--   DS-J1421/7208HGHI/M1+4+4 (slash) and DS-J1421/7208HGHI-M1+4+4 (hyphen)
--   are kept apart, as are the 7204HGHI kits and BACK WAREHOUSE's
--   DS-J1427204HGH1-M1+2+2 CAM. They look like one product written three
--   ways, but merging kit codes on a guess is how a count stops matching
--   the shelf.
--
-- Idempotent. Requires the earlier counts and
-- 20260920_store_stock_transfers.sql.
-- ─────────────────────────────────────────────────────────────

-- ── 0. Refuse to run before the fourth count ──────────────────
do $$
begin
  if not exists (
    select 1 from public.warehouse_stock
     where warehouse = 'STORE STOCK'
       and model = 'EAP115 Wireless ceiling mount access point'
  ) then
    raise exception
      'Run 20260921_store_stock_fourth_count.sql first — the totals here build on it.'
      using errcode = '42P01';
  end if;
end $$;

insert into public.warehouses (name, color, date_columns, section_labels)
select 'STORE STOCK', '#f59e0b', '{}', '{}'
 where not exists (select 1 from public.warehouses where name = 'STORE STOCK');

-- ── 1. Models the shop floor has not carried before ───────────
insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, min_level)
select 'STORE STOCK', v.model, v.qty, '{}'::jsonb, null
  from (values
    ('DS-3WF0BC-2NT(B) Wireless bridge',                   3),
    ('DS-3WAP522-S1 Smart managed access point',           5),
    ('DS-QE0206G1-V Analogue ceiling speaker',             1),
    ('HF-KS2 Smoke alarm kit',                             2),
    ('HF-KS1 Smoke alarm kit',                             2),
    ('DS-K1105EMKB Card reader',                           3),
    ('DS-3WF02C-5AC/O Wireless bridge',                    1),
    ('DS-K1T801M Standalone access control terminal',      2),
    ('DS-2SE7C425MWG-EB/26',                               1),
    ('DS-2SE4C225MWG-E/26',                                1),
    ('DS-2SE2C225MWG-E',                                   1),
    ('DS-2CD2T47G2-LSU/SL',                                1),
    ('DS-2CD2T83G2-2LI2U',                                 2),
    ('DS-2CD2T83G2-4LI2U',                                 4),
    ('DS-2CD2T63G2-4LI2U',                                 1),
    ('DS-2CD2T46G2P-ISU/SL',                               1),
    ('DS-2CD2643G2-LIZS2U',                                1),
    ('DS-2CD2663G2-LIZS2U',                                1),
    ('DS-3WR4G3N-O 4G LTE router',                         2),
    ('DS-QACAM07G1-4LIZSU',                                1),
    ('DS-2CD2T126G3-IS2UY/SRB',                            1),
    ('DS-2CD2T166G3-IS2UY/SRB',                            1),
    ('DS-2CD2T47G3-LIY',                                   1),
    ('DS-2CD2T87G2H-LISU/SL',                              1),
    ('DS-2CD2T43G2-4LI2U',                                 1),
    ('DS-2CD2643G2-IZS',                                   1),
    ('DS-2CD2T47G2P-LSU/SL',                               1),
    ('DS-2CD6825G0/C-IVS',                                 1),
    ('DS-3WAP521-S1 In-wall access point',                 2),
    ('DS-2CD1643G2-LIZU',                                  3),
    ('NK844WDH Dome',                                      1),
    ('DS-KD3003-E6 Outdoor station',                       1),
    ('DS-2CD2083G2-I',                                     1),
    ('DS-2CD2743G2-IZS',                                   6),
    ('DS-2DE2C400IWG-K/4G/C05S10',                         1),
    ('DS-2DE2C200IWG/W',                                   3),
    ('DS-2DE2C400MWG-4G',                                  1),
    ('DS-2CFS04/4G',                                       1),
    ('DS-2DE2C400MWG-E',                                   3),
    ('DS-2CFSP4/4G',                                       3),
    ('NK42E0H/H 2MP bullet kit',                           1),
    ('DS-J1421/7208HGHI/M1+4+4 cameras ColorVu',           1),
    ('DS-J1421/7208HGHI-M1+4+4 CAM',                       1),
    ('DS-J1421/7204HGHI-M1+2+2 cameras ColorVu',           2),
    ('DS-QAE0KA60120-2 Analog audio kit',                  1),
    ('NK844WBH',                                           1),
    ('DS-2CFSP8-D/4G',                                     2),
    ('DS-2CD2187G3-LIS2UY',                               10),
    ('DS-2CD2T43G2-4L',                                    1),
    ('DS-2CD2346G2P-ISU/SL',                               2),
    ('DS-2CD2087G3-LI2UY/SRB',                             5),
    ('DS-2CD2087G2-LU',                                    3),
    ('PS4 gamepad',                                        6),
    ('Logitech H390 Headphone',                            4),
    ('DS-2CD2347G2P-LSU/SL',                               1),
    ('DS-2CD5147G2/V-XS',                                  1),
    ('DS-2CD3641G2-IZS',                                   3),
    ('DS-2CD3343G2/X2-LIZSUY/SL',                          1),
    ('DS-2CD2187G2+LSU',                                   1),
    ('DS-2CD2183G2-IU',                                    1),
    ('DS-KAS808 Fingerprint access control kit',           4),
    ('DS-2DE3A404IW-DE/W Mini PTZ camera',                 1),
    ('DS-2SE3C204MWG-E/12 Mini camera',                    2),
    ('DS-TCG40G-E',                                        1),
    ('DS-2CD2347G2H-LIU',                                  1),
    ('DS-K1T670MX Face recognition terminal',              7),
    ('DS-K1T809MWX Outdoor access control',                6),
    ('DS-K1T673DWFX Face recognition',                     1),
    ('DS-K1T323MBWX-E1 Face recognition',                 10),
    ('DS-K1T808MFWX',                                      6),
    ('DS-K1T321MFWX-B Face recognition',                   2),
    ('DS-K1T807MBFWX-E1',                                  4),
    ('DS-K1A8503MF-B',                                     7),
    ('DS-KV8113-WME1(C)',                                  4),
    ('DS-K1T343MFX',                                       1),
    ('DS-2CE13DF0T-LXTS Sound MAX with speaker',           3),
    ('DS-PS1-EWE AX Pro wireless external sounder',        1),
    ('DS-PK1-LRT-HWE Wired LCD keypad for AX Pro',         1),
    ('DS-PHA64-KIT-WE(B)',                                 4),
    ('DS-2CE12KF3TP-DLS Turbo camera',                     2),
    ('DS-3T1512HP-SI-8P4F Ethernet switch',                1),
    ('Tapo C200',                                          3),
    ('DS-2CV2Q21G1-IDW Network camera',                    1),
    ('Tapo C501GW 4G PTZ outdoor camera',                  1),
    ('Tapo C425 WiFi camera 4-pack',                       1),
    ('Tapo C720 Smart floodlight camera',                  1),
    ('DS-PR1-WE AX Pro wireless repeater',                 1),
    ('HiLook VI-K43P Intercom',                            3),
    ('DS-KIS614-P IP video intercom',                      4),
    ('HiLook VI-K46P Intercom',                            2),
    ('DS-KIS902-S',                                        4),
    ('DS-KH2220 Indoor analogue station',                  4),
    ('HiLook VI-K13P 4-wire video intercom',               1),
    ('HiLook VI-K23P Hybrid intercom',                     5),
    ('DS-KH2230T Analogue intercom screen',                7),
    ('DS-PDTT15AM-LM-WP',                                  2),
    ('DS-2CE18D0T-LFS',                                    3),
    ('DS-KH6320-WTE1 IP video intercom indoor station',    5),
    ('Ultra MT-S3 4G UBox app',                            1),
    ('IOMA IO-SG440 HiEasy app',                           1),
    ('ST-558-6M-12X-4G UBox app',                          4),
    ('ES-SC180UV UBox app',                                2),
    ('ST-698-6M-36X-4G UBox app',                          1),
    ('DS-3E1318P-E1/M Ethernet switch',                    1),
    ('Epson HA86B Projector',                              1),
    ('IOMA IO-WF145',                                      1),
    ('ES30 Ultra Esee Cloud',                              1),
    ('ES30W Ultra Esee Cloud',                             1),
    ('4G (EU) Solar camera iCam+',                         2),
    ('ST-515-6M-12X-4G',                                   1),
    ('ST-517C-3M-4G',                                      1),
    ('RBX-830',                                            2),
    ('IOMA IO-RP42W12A',                                   1),
    ('DS-PC2002-WECKV',                                   28),
    ('DS-QAE0A120G1-VB6',                                  1),
    ('1602ZJ PTZ pole mount',                              3),
    ('DYMO Label Manager DYM160 Printer',                 10),
    ('TMG090-4B Controller box',                           2),
    ('DS-J1421/7108HQHI-K1+8 CAM',                         1),
    ('Panasonic KX-TE82474X',                              2),
    ('DS-2CD1021G0-I',                                     5),
    ('DS-2CD1321G0-I',                                     3),
    ('DS-KH6110-WIE1 IP video intercom station',           1),
    ('DS-1H18-A',                                        222),
    ('DS-K2602T Access controller',                        2),
    ('DS-3WR30X-V Wireless router',                        3),
    ('A30-HD 20x optical zoom UBox',                       1),
    ('Yunteng VCT880 Video tripod',                        2),
    ('VGA 30 m',                                           2),
    ('AX3000 WiFi 6 ceiling access point',                 2),
    ('10 HDMI Cable',                                     22),
    ('VGA 10M',                                            2),
    ('HDMI 1.5 m',                                         4),
    ('DS-PD1-MC-MS MAGNETIC CONTACT',                     28),
    ('Paper roll',                                       100),
    ('Grand Stream GWN7660ELR',                            6),
    ('Westa ZT550LED',                                     2),
    ('DS-2CD1023G2H-LIU',                                  8),
    ('THC-B127-LPS',                                      16),
    ('SP4 Solar Camera',                                   4),
    ('Ecotank-L3252',                                      2),
    ('DS-7216HGHI-M1/T',                                  14),
    ('HUAWEI-B660',                                        3),
    ('12V 7AH',                                            6),
    ('AG003',                                              4),
    ('PV',                                                 4),
    ('DS-2CE72DF0T-LPFS',                                  4),
    ('West 100M Indoor',                                   2),
    ('DS-2CD1047G3-LIU/SRB',                              22),
    ('120 m KVM',                                          2),
    ('DS-2CD1147G3-LIU',                                  13),
    ('DS-3D501T FIBRE OPTIC TRANSCEIVER',                  6),
    ('NCTS Qstrom Pro 1500VA',                             2)
       ) as v(model, qty)
 where not exists (
         select 1 from public.warehouse_stock s
          where s.warehouse = 'STORE STOCK'
            and s.model     = v.model
       );

-- ── 2. Models already counted: the new total ──────────────────
-- Absolute, so a re-run cannot double them. Only opening_stock is touched;
-- anything since sold, transferred or returned lives in its own column and
-- still lands on the right closing figure.
update public.warehouse_stock s
   set opening_stock = v.qty
  from (values
    ('DS-PC2002-WECKV',                                   28),
    ('1602ZJ PTZ pole mount',                              3),
    ('AX3000 WiFi 6 ceiling access point',                 2),
    ('10 HDMI Cable',                                     22),
    ('VGA 10M',                                            2),
    ('HDMI 1.5 m',                                         4),
    ('DS-PD1-MC-MS MAGNETIC CONTACT',                     28),
    ('Paper roll',                                       100),
    ('Grand Stream GWN7660ELR',                            6),
    ('Westa ZT550LED',                                     2),
    ('DS-2CD1023G2H-LIU',                                  8),
    ('THC-B127-LPS',                                      16),
    ('SP4 Solar Camera',                                   4),
    ('Ecotank-L3252',                                      2),
    ('DS-7216HGHI-M1/T',                                  14),
    ('HUAWEI-B660',                                        3),
    ('12V 7AH',                                            6),
    ('AG003',                                              4),
    ('PV',                                                 4),
    ('DS-2CE72DF0T-LPFS',                                  4),
    ('West 100M Indoor',                                   2),
    ('DS-2CD1047G3-LIU/SRB',                              22),
    ('120 m KVM',                                          2),
    ('DS-2CD1147G3-LIU',                                  13),
    ('DS-3D501T FIBRE OPTIC TRANSCEIVER',                  6),
    ('NCTS Qstrom Pro 1500VA',                             2)
       ) as v(model, qty)
 where s.warehouse = 'STORE STOCK'
   and s.model     = v.model
   and s.opening_stock is distinct from v.qty;

-- ── Verification (run after the statements above) ─────────────
-- select count(*) as models, sum(opening_stock) as units
--   from public.warehouse_stock where warehouse = 'STORE STOCK';
--   -- expect 488 models and 6242 units once all five counts are in
--   -- (plus any rows added by hand or created by a transfer)


-- ############################################################################
-- ## 20260922_trace_missed_store_sales.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Trace sales that never came off STORE STOCK — 2026-09-22
--
-- Invoices were written for items the shop floor does hold, but the stock
-- did not move, because the model had not been counted in yet: there was
-- no row to deduct from, so deduct_store_stock() reported it untracked and
-- carried on. Those models exist now, and the sales are still sitting in
-- the invoices with nothing on the stock side to match them.
--
-- WHY THE EXISTING RESYNC DOES NOT CATCH THEM
--   resync_store_invoice_taken() only counts invoices issued AFTER a
--   model's row was created, because opening_stock is a count taken at a
--   moment in time and anything sold before that moment is already
--   reflected on the shelf. That holds for the first count, which was
--   entered the day it was taken. It does NOT hold for the fourth and
--   fifth counts: those sheets were written days before the rows were
--   created, so every sale in between falls in the gap — counted on the
--   sheet as still present, and never deducted afterwards.
--
--   The fix is a cutoff the shop chooses rather than one inferred from
--   created_at. That is what p_since is for, on both functions here.
--
-- This file adds two REPORTS and one option. It changes no stock by
-- itself: trace_store_sales() is read-only, and the resync still only
-- writes when told to.
--
-- Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────

-- ── 1. What does not add up, by model ─────────────────────────
-- p_since null means "every invoice ever". Pass a date to limit it to the
-- period the counts actually describe.
create or replace function public.trace_store_sales(
  p_since timestamptz default null,
  p_store text default 'STORE STOCK'
) returns table (
  model      text,
  counted_at timestamptz,
  invoiced   integer,
  deducted   integer,
  missed     integer,
  first_sale timestamptz,
  last_sale  timestamptz,
  on_hand    integer
)
language sql
stable
security definer
set search_path = public
as $$
  select s.model,
         s.created_at,
         coalesce(x.units, 0)::integer,
         coalesce(s.invoice_taken, 0),
         (coalesce(x.units, 0) - coalesce(s.invoice_taken, 0))::integer,
         x.first_sale,
         x.last_sale,
         s.closing_stock
    from public.warehouse_stock s
    left join lateral (
      select sum(ii.quantity)::integer as units,
             min(i.issued_at)          as first_sale,
             max(i.issued_at)          as last_sale
        from public.invoice_items ii
        join public.invoices i on i.id = ii.invoice_id
       where (p_since is null or i.issued_at >= p_since)
         and (
           -- Typed, autocompleted or scanned: the description IS the model.
           upper(btrim(ii.description)) = upper(btrim(s.model))
           -- Picked from the catalogue: "Title — MODEL". Compared from the
           -- right rather than with LIKE, so a model containing % or _
           -- cannot turn into a wildcard.
           or right(upper(btrim(ii.description)),
                    length(' — ' || upper(btrim(s.model))))
              = ' — ' || upper(btrim(s.model))
         )
    ) x on true
   where s.warehouse = p_store
     and coalesce(x.units, 0) <> coalesce(s.invoice_taken, 0)
   order by (coalesce(x.units, 0) - coalesce(s.invoice_taken, 0)) desc, s.model
$$;

-- ── 2. The actual sales behind one model ──────────────────────
-- For when a number looks wrong and you want the invoices, the dates and
-- the customers rather than a total.
create or replace function public.trace_store_sales_detail(
  p_model text,
  p_since timestamptz default null
) returns table (
  invoice_number text,
  issued_at      timestamptz,
  customer_name  text,
  description    text,
  quantity       numeric,
  unit_price     numeric
)
language sql
stable
security definer
set search_path = public
as $$
  select i.invoice_number, i.issued_at, i.customer_name,
         ii.description, ii.quantity, ii.unit_price
    from public.invoice_items ii
    join public.invoices i on i.id = ii.invoice_id
   where (p_since is null or i.issued_at >= p_since)
     and (
       upper(btrim(ii.description)) = upper(btrim(p_model))
       or right(upper(btrim(ii.description)),
                length(' — ' || upper(btrim(p_model))))
          = ' — ' || upper(btrim(p_model))
     )
   order by i.issued_at desc
$$;

-- ── 3. The resync can be given an explicit cutoff ─────────────
-- Dropped rather than overloaded: a variant differing only by a trailing
-- argument would make every existing call ambiguous.
drop function if exists public.resync_store_invoice_taken(boolean, text);

create or replace function public.resync_store_invoice_taken(
  p_apply boolean default false,
  p_store text default 'STORE STOCK',
  p_since timestamptz default null
) returns table (
  model      text,
  counted_at timestamptz,
  was        integer,
  should_be  integer,
  difference integer
)
language plpgsql
security definer
set search_path = public
as $$
begin
  -- A session with no JWT is the SQL editor, psql or the service role, not
  -- an app user — those bypass RLS anyway, and refusing them here would
  -- block the very console this is meant to be run from.
  if (select auth.uid()) is not null and not (select public.is_superboss()) then
    raise exception 'Only the Big Boss may rebuild stock figures'
      using errcode = '42501';
  end if;

  return query
  with figures as (
    select
      s.id,
      s.model,
      s.created_at,
      coalesce(s.invoice_taken, 0) as was,
      coalesce((
        select sum(ii.quantity)::integer
          from public.invoice_items ii
          join public.invoices i on i.id = ii.invoice_id
         -- With no cutoff given, fall back to the row's own creation date:
         -- a count taken the day it was entered already reflects everything
         -- sold before it. Pass p_since where that is not true.
         where i.issued_at > coalesce(p_since, s.created_at)
           and (
             upper(btrim(ii.description)) = upper(btrim(s.model))
             or right(upper(btrim(ii.description)),
                      length(' — ' || upper(btrim(s.model))))
                = ' — ' || upper(btrim(s.model))
           )
      ), 0) as should_be
    from public.warehouse_stock s
    where s.warehouse = p_store
  ),
  changed as (
    select * from figures f where f.was is distinct from f.should_be
  ),
  -- A data-modifying CTE always runs to completion, whether or not the
  -- outer query reads it.
  applied as (
    update public.warehouse_stock w
       set invoice_taken = c.should_be
      from changed c
     where w.id = c.id
       and p_apply
    returning w.id
  )
  select c.model, c.created_at, c.was, c.should_be, c.should_be - c.was
    from changed c
   order by abs(c.should_be - c.was) desc, c.model;
end $$;

grant execute on function public.trace_store_sales(timestamptz, text)              to authenticated;
grant execute on function public.trace_store_sales_detail(text, timestamptz)       to authenticated;
grant execute on function public.resync_store_invoice_taken(boolean, text, timestamptz) to authenticated;

-- ── How to use this ───────────────────────────────────────────
-- 1. See what does not add up. Read-only:
--
--    select * from public.trace_store_sales();
--
--    `missed` is units invoiced that the stock never lost. A NEGATIVE
--    missed means the opposite — deducted more than the invoices show,
--    which usually means a sale was deleted after the stock came off.
--
-- 2. Look at one of them properly:
--
--    select * from public.trace_store_sales_detail('DS-2CD1123G2-LIU');
--
--    Check the dates against when that stock was physically counted. Sales
--    from BEFORE the count are already reflected in opening_stock and must
--    not be deducted again; sales after it must.
--
-- 3. Once the cutoff is clear, preview the correction:
--
--    select * from public.resync_store_invoice_taken(false, 'STORE STOCK',
--                                                    timestamptz '2026-09-15');
--
-- 4. Apply the same thing:
--
--    select * from public.resync_store_invoice_taken(true, 'STORE STOCK',
--                                                    timestamptz '2026-09-15');
--
--    Absolute, not additive, so it can be re-run and cannot double.


-- ############################################################################
-- ## 20260930_dahua_transfers.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Dahua transfers, receiving, returns (RNA) and SPOILT — 2026-09-30
--
-- Gives the Dahua line the stock movements the main shop has had since
-- 20260920_store_stock_transfers.sql, 20260922_returns_and_staff_id.sql and
-- 20260922_spoilt_location.sql:
--
--   move     units leave one Dahua warehouse and arrive at another, in one
--            transaction.
--   receive  a supplier delivery — units enter the system, nothing is
--            deducted anywhere.
--   return   goods back from a buyer. Good lines go back into stock;
--            spoilt lines go to the Dahua SPOILT location instead.
--
-- Everything lands on one numbered record per movement, in series of its
-- own — DH-TRF / DH-RCV / DH-RNA — so a Dahua movement can never be read as
-- a main-shop one. Who did it is the staff ID of whoever is signed in,
-- recorded by the database rather than typed.
--
-- WHAT IS DIFFERENT FROM THE MAIN SHOP
--   There is no STORE STOCK here. Dahua invoices deduct from whichever
--   stock row the cashier picks, as they always have, so a transfer is just
--   units changing warehouse.
--
--   dahua_stock has no unique (warehouse, model) key, so the functions below
--   always act on the OLDEST matching row — the same one the Stock tab lists
--   first. A row created at a destination copies the model's selling price
--   from its existing rows, so stock moved into a new warehouse does not
--   show up on an invoice as "no price".
--
-- DERIVED COLUMNS
--   Until now total_taken and closing_stock were computed by each client
--   (Stock tab, invoice form, invoice delete, Scan). With transfer_in and
--   transfer_out added, the database takes that over, exactly as
--   fn_warehouse_stock_derive() does for the main shop:
--
--     total_taken   = hand-entered + invoiced + transferred away
--     closing_stock = opening + transferred in - total_taken
--
--   With both new columns at 0 that is the formula every client already
--   uses, so re-deriving existing rows changes nothing that was computed
--   correctly. Run the DRIFT CHECK below first if you want to see whether
--   any row was not.
--
-- Requires 20260906_dahua_pricing.sql (unit_price) and
-- 20260922_returns_and_staff_id.sql (current_staff_id / current_staff_name).
-- Run once, in the Supabase SQL editor. Idempotent.
--
-- DRIFT CHECK (optional, run before this file):
--   select warehouse, model, closing_stock,
--          opening_stock - (invoice_taken + (select coalesce(sum(v::integer), 0)
--                                             from jsonb_each_text(daily_taken) as t(k, v))) as derived
--     from public.dahua_stock
--    where closing_stock <> opening_stock - (invoice_taken + (select coalesce(sum(v::integer), 0)
--                                             from jsonb_each_text(daily_taken) as t(k, v)));
-- ─────────────────────────────────────────────────────────────

-- ── 0. Refuse to run out of order ─────────────────────────────
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'dahua_stock' and column_name = 'unit_price'
  ) then
    raise exception 'Run 20260906_dahua_pricing.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
  if to_regprocedure('public.current_staff_id()') is null then
    raise exception 'Run 20260922_returns_and_staff_id.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

begin;

-- ── 1. Movement columns on dahua_stock ────────────────────────
alter table public.dahua_stock
  add column if not exists transfer_in  integer not null default 0,  -- received, moved in, or returned
  add column if not exists transfer_out integer not null default 0;  -- moved to another Dahua warehouse

-- ── 2. Derived columns are computed by the database ───────────
-- Mirrors computeTotals()/computeStatus() in DahuaStockTab.tsx.
create or replace function public.fn_dahua_stock_derive() returns trigger
language plpgsql set search_path = public as $$
declare
  manual integer;
begin
  select coalesce(sum(value::integer), 0) into manual
    from jsonb_each_text(coalesce(new.daily_taken, '{}'::jsonb));

  new.total_taken   := manual
                     + coalesce(new.invoice_taken, 0)
                     + coalesce(new.transfer_out, 0);
  new.closing_stock := coalesce(new.opening_stock, 0)
                     + coalesce(new.transfer_in, 0)
                     - new.total_taken;
  new.stock_status  := case
                         when coalesce(new.min_level, 0) = 0 then ''
                         when new.closing_stock < new.min_level then 'LOW'
                         else 'OK'
                       end;
  new.updated_at    := now();
  return new;
end $$;

drop trigger if exists trg_dahua_stock_derive on public.dahua_stock;
create trigger trg_dahua_stock_derive
  before insert or update on public.dahua_stock
  for each row execute function public.fn_dahua_stock_derive();

-- Re-derive every existing row. The audit trigger is lifted for the sweep:
-- this is a schema migration, not staff activity.
alter table public.dahua_stock disable trigger trg_audit_dahua_stock;
update public.dahua_stock set opening_stock = opening_stock;
alter table public.dahua_stock enable trigger trg_audit_dahua_stock;

-- ── 3. The Dahua SPOILT location ──────────────────────────────
-- Red, no date columns: spoilt goods are not counted on a day sheet. Filled
-- only by marking a returned line spoilt; the invoice form does not offer it.
insert into public.dahua_warehouses (name, color, date_columns, section_labels)
select 'SPOILT', '#ef4444', '{}', '{}'
 where not exists (select 1 from public.dahua_warehouses where name = 'SPOILT');

-- ── 4. Movement records ───────────────────────────────────────
create table if not exists public.dahua_stock_transfers (
  id              uuid primary key default gen_random_uuid(),
  transfer_number text not null unique,
  kind            text not null default 'move',
  from_warehouse  text,
  to_warehouse    text not null,
  supplier        text,       -- the supplier on a receive, the buyer on a return
  note            text,
  signed_by       text,       -- their name at the time
  staff_id        text,       -- their login ID at the time
  transferred_at  timestamptz not null default now(),
  created_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  constraint dahua_stock_transfers_kind_check check (kind in ('move', 'receive', 'return')),
  constraint dahua_stock_transfers_source_check check (
    (kind = 'move' and from_warehouse is not null and from_warehouse <> to_warehouse)
    or (kind in ('receive', 'return') and from_warehouse is null)
  )
);
create index if not exists dahua_stock_transfers_when_idx
  on public.dahua_stock_transfers (transferred_at desc);

create table if not exists public.dahua_stock_transfer_items (
  id          uuid primary key default gen_random_uuid(),
  transfer_id uuid not null references public.dahua_stock_transfers(id) on delete cascade,
  model       text not null,
  quantity    integer not null check (quantity > 0),
  from_before integer,        -- what the source held when the move applied
  position    integer not null default 1,
  condition   text not null default 'good',
  constraint dahua_stock_transfer_items_condition_check check (condition in ('good', 'spoilt'))
);
create index if not exists dahua_stock_transfer_items_parent_idx
  on public.dahua_stock_transfer_items (transfer_id);

-- ── 5. Numbering: DH-TRF-2026-0001, DH-RCV-…, DH-RNA-… ────────
create or replace function public.next_dahua_movement_number(p_kind text)
returns text
language plpgsql security definer set search_path = public as $$
declare
  yr     text := to_char(now(), 'YYYY');
  prefix text := case p_kind when 'receive' then 'DH-RCV'
                             when 'return'  then 'DH-RNA'
                             else 'DH-TRF' end;
  cnt    integer;
begin
  select count(*) + 1 into cnt
    from public.dahua_stock_transfers
   where to_char(transferred_at, 'YYYY') = yr
     and kind = p_kind;
  return prefix || '-' || yr || '-' || lpad(cnt::text, 4, '0');
end $$;

-- ── 6. Shared steps ───────────────────────────────────────────
-- Writes the header, retrying on a number clash: the number counts rows, so
-- two staff saving at once can both be handed the same one.
create or replace function public.dahua_movement_open(
  p_kind text, p_from text, p_to text, p_party text, p_note text, p_when timestamptz
) returns public.dahua_stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_rec public.dahua_stock_transfers;
  v_try integer;
begin
  for v_try in 1..8 loop
    begin
      insert into public.dahua_stock_transfers
        (transfer_number, kind, from_warehouse, to_warehouse, supplier,
         note, signed_by, staff_id, transferred_at, created_by)
      values
        (public.next_dahua_movement_number(p_kind), p_kind, p_from, p_to,
         nullif(btrim(coalesce(p_party, '')), ''),
         nullif(btrim(coalesce(p_note, '')), ''),
         public.current_staff_name(), public.current_staff_id(),
         coalesce(p_when, now()), auth.uid())
      returning * into v_rec;
      return v_rec;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;
end $$;

-- Books units in at a warehouse, creating the row (at the model's existing
-- price) when that warehouse has never carried it.
create or replace function public.dahua_stock_book_in(p_warehouse text, p_model text, p_qty integer)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_id    uuid;
  v_price numeric(12,2);
begin
  select id into v_id
    from public.dahua_stock
   where warehouse = p_warehouse and model = p_model
   order by created_at, id
   limit 1
   for update;

  if found then
    update public.dahua_stock
       set transfer_in = coalesce(transfer_in, 0) + p_qty
     where id = v_id;
  else
    select max(unit_price) into v_price from public.dahua_stock where model = p_model;
    insert into public.dahua_stock (warehouse, model, opening_stock, daily_taken, invoice_taken, transfer_in, unit_price)
    values (p_warehouse, p_model, 0, '{}'::jsonb, 0, p_qty, coalesce(v_price, 0));
  end if;
end $$;

-- Internal helpers: reachable only through the three functions below.
revoke all on function public.dahua_movement_open(text, text, text, text, text, timestamptz) from public, anon, authenticated;
revoke all on function public.dahua_stock_book_in(text, text, integer) from public, anon, authenticated;

-- ── 7. Moving between warehouses ──────────────────────────────
-- p_items: [{"model": "DH-IPC-HFW1239TL1-A-IL 2MP", "quantity": 5}, ...]
-- A model the source has never held is rejected; one the destination has
-- never held is created there.
create or replace function public.dahua_transfer_stock(
  p_from  text,
  p_to    text,
  p_items jsonb,
  p_note  text default null,
  p_when  timestamptz default now()
) returns public.dahua_stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_rec    public.dahua_stock_transfers;
  v_item   jsonb;
  v_model  text;
  v_qty    integer;
  v_id     uuid;
  v_before integer;
  v_pos    integer := 0;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to transfer stock';
  end if;
  if p_from is null or p_to is null or p_from = p_to then
    raise exception 'A transfer needs two different locations';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A transfer needs at least one item';
  end if;

  v_rec := public.dahua_movement_open('move', p_from, p_to, null, p_note, p_when);

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    select id, closing_stock into v_id, v_before
      from public.dahua_stock
     where warehouse = p_from and model = v_model
     order by created_at, id
     limit 1
     for update;
    if not found then
      raise exception '% does not hold %', p_from, v_model;
    end if;

    update public.dahua_stock
       set transfer_out = coalesce(transfer_out, 0) + v_qty
     where id = v_id;

    perform public.dahua_stock_book_in(p_to, v_model, v_qty);

    v_pos := v_pos + 1;
    insert into public.dahua_stock_transfer_items (transfer_id, model, quantity, from_before, position)
    values (v_rec.id, v_model, v_qty, v_before, v_pos);
  end loop;

  return v_rec;
end $$;

-- ── 8. Receiving from a supplier ──────────────────────────────
create or replace function public.dahua_receive_stock(
  p_to       text,
  p_items    jsonb,
  p_supplier text default null,
  p_note     text default null,
  p_when     timestamptz default now()
) returns public.dahua_stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_rec   public.dahua_stock_transfers;
  v_item  jsonb;
  v_model text;
  v_qty   integer;
  v_pos   integer := 0;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to receive stock';
  end if;
  if p_to is null or btrim(p_to) = '' then
    raise exception 'Where is this delivery going?';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A delivery needs at least one item';
  end if;

  v_rec := public.dahua_movement_open('receive', null, p_to, p_supplier, p_note, p_when);

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    perform public.dahua_stock_book_in(p_to, v_model, v_qty);

    v_pos := v_pos + 1;
    insert into public.dahua_stock_transfer_items (transfer_id, model, quantity, from_before, position)
    values (v_rec.id, v_model, v_qty, null, v_pos);
  end loop;

  return v_rec;
end $$;

-- ── 9. Returns from buyers ────────────────────────────────────
-- p_items: [{"model": "...", "quantity": 2, "condition": "good"|"spoilt"}, ...]
-- Good lines go back into p_to; spoilt lines go to p_spoilt. Both are
-- recorded on the same DH-RNA record.
create or replace function public.dahua_return_stock(
  p_to       text,
  p_items    jsonb,
  p_customer text default null,
  p_note     text default null,
  p_when     timestamptz default now(),
  p_spoilt   text default 'SPOILT'
) returns public.dahua_stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_rec   public.dahua_stock_transfers;
  v_item  jsonb;
  v_model text;
  v_qty   integer;
  v_cond  text;
  v_pos   integer := 0;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record returns';
  end if;
  if p_to is null or btrim(p_to) = '' then
    raise exception 'Where are the good items going back to?';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A return needs at least one item';
  end if;

  v_rec := public.dahua_movement_open('return', null, p_to, p_customer, p_note, p_when);

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    -- The tick is on the exception: anything not marked spoilt is resaleable.
    v_cond  := case when lower(coalesce(v_item->>'condition', 'good')) = 'spoilt'
                    then 'spoilt' else 'good' end;
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    perform public.dahua_stock_book_in(
      case when v_cond = 'spoilt' then p_spoilt else p_to end, v_model, v_qty);

    v_pos := v_pos + 1;
    insert into public.dahua_stock_transfer_items
      (transfer_id, model, quantity, from_before, position, condition)
    values (v_rec.id, v_model, v_qty, null, v_pos, v_cond);
  end loop;

  return v_rec;
end $$;

-- ── 10. RLS ───────────────────────────────────────────────────
-- The history is boss-only, as the main shop's is since
-- 20260922_movement_history_boss_only.sql. Cashiers still RECORD movements:
-- the functions are definer, so they write and return the new row without
-- the caller needing read access.
alter table public.dahua_stock_transfers      enable row level security;
alter table public.dahua_stock_transfer_items enable row level security;

drop policy if exists dahua_stock_transfers_read on public.dahua_stock_transfers;
drop policy if exists dahua_stock_transfers_read on public.dahua_stock_transfers;

create policy dahua_stock_transfers_read on public.dahua_stock_transfers
  for select to authenticated using ((select public.is_boss()));

drop policy if exists dahua_stock_transfer_items_read on public.dahua_stock_transfer_items;
drop policy if exists dahua_stock_transfer_items_read on public.dahua_stock_transfer_items;

create policy dahua_stock_transfer_items_read on public.dahua_stock_transfer_items
  for select to authenticated using ((select public.is_boss()));

-- Writes go through the functions. Only the Big Boss may touch rows directly.
drop policy if exists dahua_stock_transfers_superboss_write on public.dahua_stock_transfers;
drop policy if exists dahua_stock_transfers_superboss_write on public.dahua_stock_transfers;

create policy dahua_stock_transfers_superboss_write on public.dahua_stock_transfers
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists dahua_stock_transfer_items_superboss_write on public.dahua_stock_transfer_items;
drop policy if exists dahua_stock_transfer_items_superboss_write on public.dahua_stock_transfer_items;

create policy dahua_stock_transfer_items_superboss_write on public.dahua_stock_transfer_items
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

grant execute on function public.dahua_transfer_stock(text, text, jsonb, text, timestamptz)      to authenticated;
grant execute on function public.dahua_receive_stock(text, jsonb, text, text, timestamptz)       to authenticated;
grant execute on function public.dahua_return_stock(text, jsonb, text, text, timestamptz, text)  to authenticated;
grant execute on function public.next_dahua_movement_number(text)                                to authenticated;

-- ── 11. Audit ─────────────────────────────────────────────────
drop trigger if exists trg_audit_dahua_stock_transfers on public.dahua_stock_transfers;
create trigger trg_audit_dahua_stock_transfers
  after insert or update or delete on public.dahua_stock_transfers
  for each row execute function public.fn_audit();

commit;

-- ── Verification (run after committing) ───────────────────────
-- select name from public.dahua_warehouses where name = 'SPOILT';
-- select count(*) filter (where closing_stock
--          <> opening_stock + transfer_in - total_taken) as drifted
--   from public.dahua_stock;   -- expect 0
--
-- Recent Dahua movements:
-- select t.transfer_number, t.kind, t.from_warehouse, t.to_warehouse,
--        t.staff_id, i.model, i.quantity, i.condition
--   from public.dahua_stock_transfer_items i
--   join public.dahua_stock_transfers t on t.id = i.transfer_id
--  order by t.transferred_at desc, i.position
--  limit 50;


-- ############################################################################
-- ## 20260930_lock_stock_writes.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Stock can only change the way the app changes it — 2026-09-30
--
-- THE HOLE
--   The app signs in with the public anon key, so anything the app can do,
--   a cashier can also do from a script with their own login. Until now
--   cashiers held a plain UPDATE policy on warehouse_stock and dahua_stock
--   (20260807_superboss.sql) — needed because the Scan tab and the Dahua
--   invoice form wrote stock rows directly. That policy is row-level only,
--   so outside the app a cashier could rewrite ANY column of ANY stock row:
--   opening counts, invoice deductions, transfer figures, all of it.
--
--   deduct_store_stock() had the same shape of problem: it takes a free
--   list of models and quantities, so it could take units off STORE STOCK
--   with no invoice behind them.
--
-- THE FIX
--   Cashiers lose direct write access to the stock tables entirely. Every
--   stock change the app makes as a cashier now goes through a function
--   that can do exactly that one thing and nothing more:
--
--     scan_adjust_stock           Scan tab: add/remove units taken, for one
--                                 day column of one row. Only daily_taken
--                                 moves; the derive triggers recompute the
--                                 rest.
--     scan_add_stock_row          Scan tab: stock a model in a location that
--                                 has never carried it. Refuses a row that
--                                 already exists. Main shop only for
--                                 cashiers, as before (Dahua inserts were
--                                 already Big-Boss-only).
--     deduct_invoice_store_stock  Main invoice save: deducts what the
--                                 INVOICE's saved lines say — read from the
--                                 database, not sent by the client — and
--                                 only once per invoice, only by the
--                                 cashier who made it.
--     dahua_deduct_invoice_stock  The same for a Dahua invoice.
--
--   Transfers, receipts and returns already went through definer functions
--   that record a numbered movement with the staff ID, so they are left as
--   they are.
--
--   The Big Boss keeps full direct access — the Stock tabs edit rows
--   directly and are theirs alone.
--
-- Requires 20260920_store_stock_transfers.sql and 20260930_dahua_transfers.sql
-- (the derive triggers that recompute totals after a scan). Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regprocedure('public.fn_dahua_stock_derive()') is null then
    raise exception 'Run 20260930_dahua_transfers.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
  if to_regprocedure('public.fn_warehouse_stock_derive()') is null then
    raise exception 'Run 20260920_store_stock_transfers.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

begin;

-- ── 1. Reset the stock tables' policies ───────────────────────
-- Dropped by listing what is actually there rather than by name: a policy
-- added by hand in the dashboard at some point would otherwise survive,
-- and policies OR together, so one stray permissive policy reopens the hole.
do $$
declare r record;
begin
  for r in
    select policyname, tablename from pg_policies
     where schemaname = 'public'
       and tablename in ('warehouse_stock', 'dahua_stock', 'warehouses')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

alter table public.warehouse_stock enable row level security;
alter table public.dahua_stock     enable row level security;
alter table public.warehouses      enable row level security;

-- Everyone signed in reads stock: the invoice forms, Scan and Transfers all
-- show on-hand figures.
drop policy if exists warehouse_stock_read on public.warehouse_stock;

create policy warehouse_stock_read on public.warehouse_stock
  for select to authenticated using (true);
drop policy if exists dahua_stock_read on public.dahua_stock;

create policy dahua_stock_read on public.dahua_stock
  for select to authenticated using (true);
drop policy if exists warehouses_read on public.warehouses;

create policy warehouses_read on public.warehouses
  for select to authenticated using (true);

-- Only the Big Boss writes directly.
drop policy if exists warehouse_stock_superboss_write on public.warehouse_stock;

create policy warehouse_stock_superboss_write on public.warehouse_stock
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));
drop policy if exists dahua_stock_superboss_write on public.dahua_stock;

create policy dahua_stock_superboss_write on public.dahua_stock
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));
drop policy if exists warehouses_superboss_write on public.warehouses;

create policy warehouses_superboss_write on public.warehouses
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

-- dahua_warehouses is already read-all / Big-Boss-write (20260807_superboss.sql).

-- ── 2. Scan: units taken, one day column at a time ────────────
-- p_key is the daily_taken key the Scan tab writes: "<day>" for the first
-- section, "<section>:<day>" for the others. It must name a day column and a
-- section the row's warehouse actually has, so a script cannot invent keys.
-- A slot that falls to zero or below is removed, as the tab does.
create or replace function public.scan_adjust_stock(
  p_dahua boolean,
  p_id    uuid,
  p_key   text,
  p_delta integer
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_wh       text;
  v_daily    jsonb;
  v_cols     text[];
  v_labels   text[];
  v_section  integer;
  v_day      text;
  v_next     integer;
  v_row      jsonb;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record stock';
  end if;
  if p_delta is null or p_delta = 0 or abs(p_delta) > 100000 then
    raise exception 'Quantity must be a whole number between -100000 and 100000, not zero';
  end if;
  if p_key is null or p_key !~ '^([0-9]{1,3}:)?[^:]{1,20}$' then
    raise exception 'Not a day column: %', p_key;
  end if;

  if p_key like '%:%' then
    v_section := split_part(p_key, ':', 1)::integer;
    v_day     := split_part(p_key, ':', 2);
  else
    v_section := 0;
    v_day     := p_key;
  end if;

  -- Lock the row, then check the key against its warehouse.
  if p_dahua then
    select warehouse, coalesce(daily_taken, '{}'::jsonb) into v_wh, v_daily
      from public.dahua_stock where id = p_id for update;
    if not found then raise exception 'That stock row no longer exists'; end if;
    select date_columns, section_labels into v_cols, v_labels
      from public.dahua_warehouses where name = v_wh;
  else
    select warehouse, coalesce(daily_taken, '{}'::jsonb) into v_wh, v_daily
      from public.warehouse_stock where id = p_id for update;
    if not found then raise exception 'That stock row no longer exists'; end if;
    select date_columns, section_labels into v_cols, v_labels
      from public.warehouses where name = v_wh;
  end if;

  if v_cols is null or not (v_day = any (v_cols)) then
    raise exception '% has no day column %', v_wh, v_day;
  end if;
  if v_section >= greatest(coalesce(array_length(v_labels, 1), 0), 1) then
    raise exception '% has no section %', v_wh, v_section;
  end if;

  v_next := coalesce((v_daily->>p_key)::integer, 0) + p_delta;
  v_daily := case when v_next <= 0 then v_daily - p_key
                  else jsonb_set(v_daily, array[p_key], to_jsonb(v_next)) end;

  -- Only daily_taken is written; fn_*_stock_derive recomputes the totals.
  if p_dahua then
    update public.dahua_stock set daily_taken = v_daily where id = p_id
      returning to_jsonb(dahua_stock.*) into v_row;
  else
    update public.warehouse_stock set daily_taken = v_daily where id = p_id
      returning to_jsonb(warehouse_stock.*) into v_row;
  end if;
  return v_row;
end $$;

-- ── 3. Scan: stock a model somewhere new ──────────────────────
create or replace function public.scan_add_stock_row(
  p_dahua     boolean,
  p_warehouse text,
  p_model     text,
  p_opening   integer,
  p_min       integer default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_model text := btrim(coalesce(p_model, ''));
  v_row   jsonb;
  v_price numeric(12,2);
begin
  -- Cashiers could add a main-shop row from Scan before; Dahua rows were
  -- always Big Boss only. Both stay as they were.
  if not ((select public.is_superboss()) or (not p_dahua and (select public.is_cashier()))) then
    raise exception 'Not allowed to add stock rows';
  end if;
  if v_model = '' or length(v_model) > 200 then
    raise exception 'A model name is required';
  end if;
  if p_opening is null or p_opening < 0 or p_opening > 100000 then
    raise exception 'Opening stock must be between 0 and 100000';
  end if;
  if p_min is not null and (p_min < 0 or p_min > 100000) then
    raise exception 'Minimum level must be between 0 and 100000';
  end if;
  if upper(btrim(coalesce(p_warehouse, ''))) = 'SPOILT' then
    raise exception 'SPOILT is filled by returns only';
  end if;

  if p_dahua then
    if not exists (select 1 from public.dahua_warehouses where name = p_warehouse) then
      raise exception 'No such warehouse: %', p_warehouse;
    end if;
    if exists (select 1 from public.dahua_stock
                where warehouse = p_warehouse and upper(btrim(model)) = upper(v_model)) then
      raise exception '% already stocks %', p_warehouse, v_model;
    end if;
    select max(unit_price) into v_price from public.dahua_stock where model = v_model;
    insert into public.dahua_stock (warehouse, model, opening_stock, daily_taken, invoice_taken, min_level, unit_price)
    values (p_warehouse, v_model, p_opening, '{}'::jsonb, 0, p_min, coalesce(v_price, 0))
    returning to_jsonb(dahua_stock.*) into v_row;
  else
    if not exists (select 1 from public.warehouses where name = p_warehouse) then
      raise exception 'No such warehouse: %', p_warehouse;
    end if;
    if exists (select 1 from public.warehouse_stock
                where warehouse = p_warehouse and upper(btrim(model)) = upper(v_model)) then
      raise exception '% already stocks %', p_warehouse, v_model;
    end if;
    insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, min_level)
    values (p_warehouse, v_model, p_opening, '{}'::jsonb, p_min)
    returning to_jsonb(warehouse_stock.*) into v_row;
  end if;
  return v_row;
end $$;

-- ── 4. One deduction per invoice ──────────────────────────────
-- Kept in its own table rather than as a column on the invoice, so marking
-- an invoice does not write an UPDATE into the activity log for every sale.
create table if not exists public.invoice_stock_deductions (
  line        text not null check (line in ('main', 'dahua')),
  invoice_id  uuid not null,
  deducted_by uuid,
  deducted_at timestamptz not null default now(),
  primary key (line, invoice_id)
);
alter table public.invoice_stock_deductions enable row level security;
-- No policies: only the definer functions below touch it.

-- Every invoice that already exists has already been deducted by the old
-- client-side path. Mark them all, so none can be deducted a second time.
insert into public.invoice_stock_deductions (line, invoice_id)
select 'main', id from public.invoices
on conflict do nothing;
insert into public.invoice_stock_deductions (line, invoice_id)
select 'dahua', id from public.dahua_invoices
on conflict do nothing;

-- ── 5. Main invoice → STORE STOCK ─────────────────────────────
-- The lines are read from invoice_items, with the model taken from the
-- catalogue product when the line was picked from it — exactly what the
-- invoice form used to send. The actual deduction reuses deduct_store_stock.
create or replace function public.deduct_invoice_store_stock(p_invoice_id uuid)
returns table (model text, requested integer, available integer, tracked boolean)
language plpgsql security definer set search_path = public as $$
-- The OUT column `model` would otherwise clash with the model columns below.
#variable_conflict use_column
declare
  v_owner uuid;
  v_items jsonb;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to adjust stock';
  end if;

  select created_by into v_owner from public.invoices where id = p_invoice_id;
  if not found then
    raise exception 'No such invoice';
  end if;
  if not (select public.is_superboss()) and v_owner is distinct from auth.uid() then
    raise exception 'Only the cashier who made this invoice can deduct its stock';
  end if;

  begin
    insert into public.invoice_stock_deductions (line, invoice_id, deducted_by)
    values ('main', p_invoice_id, auth.uid());
  exception when unique_violation then
    raise exception 'Stock for this invoice has already been deducted';
  end;

  select coalesce(jsonb_agg(jsonb_build_object('model', m.model, 'quantity', m.qty)), '[]'::jsonb)
    into v_items
    from (
      select min(x.model) as model, sum(x.quantity)::integer as qty
        from (
          select btrim(coalesce(nullif(btrim(p.model_number), ''), i.description)) as model, i.quantity
            from public.invoice_items i
            left join public.products p on p.id = i.product_id
           where i.invoice_id = p_invoice_id and i.quantity > 0
        ) x
       where x.model <> ''
       group by upper(x.model)
    ) m;

  return query select * from public.deduct_store_stock(v_items, 'STORE STOCK');
end $$;

-- ── 6. Dahua invoice → the stock rows its lines were picked from ──
-- Returns how many lines were deducted, as the form reports it.
create or replace function public.dahua_deduct_invoice_stock(p_invoice_id uuid)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_owner uuid;
  v_line  record;
  v_count integer := 0;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to adjust stock';
  end if;

  select created_by into v_owner from public.dahua_invoices where id = p_invoice_id;
  if not found then
    raise exception 'No such invoice';
  end if;
  if not (select public.is_superboss()) and v_owner is distinct from auth.uid() then
    raise exception 'Only the cashier who made this invoice can deduct its stock';
  end if;

  begin
    insert into public.invoice_stock_deductions (line, invoice_id, deducted_by)
    values ('dahua', p_invoice_id, auth.uid());
  exception when unique_violation then
    raise exception 'Stock for this invoice has already been deducted';
  end;

  for v_line in
    select i.stock_id, i.quantity
      from public.dahua_invoice_items i
      join public.dahua_stock s on s.id = i.stock_id
     where i.invoice_id = p_invoice_id and i.quantity > 0
     order by i.position
  loop
    update public.dahua_stock
       set invoice_taken = coalesce(invoice_taken, 0) + v_line.quantity
     where id = v_line.stock_id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end $$;

-- ── 7. Who may call what ──────────────────────────────────────
-- Functions are executable by PUBLIC unless revoked, so revoke first.
revoke all on function public.scan_adjust_stock(boolean, uuid, text, integer)         from public, anon;
revoke all on function public.scan_add_stock_row(boolean, text, text, integer, integer) from public, anon;
revoke all on function public.deduct_invoice_store_stock(uuid)                          from public, anon;
revoke all on function public.dahua_deduct_invoice_stock(uuid)                          from public, anon;
grant execute on function public.scan_adjust_stock(boolean, uuid, text, integer)         to authenticated;
grant execute on function public.scan_add_stock_row(boolean, text, text, integer, integer) to authenticated;
grant execute on function public.deduct_invoice_store_stock(uuid)                          to authenticated;
grant execute on function public.dahua_deduct_invoice_stock(uuid)                          to authenticated;

-- The free-list deduction is now internal: reachable only through
-- deduct_invoice_store_stock above.
revoke all on function public.deduct_store_stock(jsonb, text) from public, anon, authenticated;

commit;

-- ── Verification (run after committing) ───────────────────────
-- Exactly these six policies should be listed, and no others:
--
-- select tablename, policyname, cmd from pg_policies
--  where schemaname = 'public'
--    and tablename in ('warehouse_stock', 'dahua_stock', 'warehouses')
--  order by 1, 2;
--
-- As a cashier, a direct write must now fail (0 rows updated, or an error):
--
-- update public.warehouse_stock set opening_stock = opening_stock + 1
--  where warehouse = 'STORE STOCK';


-- ############################################################################
-- ## 20261005_cross_line_transfers.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Moves between the main shop and Dahua, and phone-safe saving — 2026-10-05
--
-- TWO THINGS
--
-- 1. CROSS-LINE MOVES
--    The main shop (warehouse_stock) and Dahua (dahua_stock) have been two
--    sealed pools. Goods do physically cross between them, and until now the
--    only way to show it was to edit a count on each side by hand — two
--    edits, nothing tying them together, and no record of why either figure
--    changed. cross_transfer_stock() does both sides in one transaction.
--
--    It is recorded ONCE PER SIDE under ONE number, in a series of its own:
--    XTR-2026-0001 appears in the main shop's movement history and in
--    Dahua's, so each portal can account for its own figure and the two
--    records can be matched by reference.
--
--    The two sides do not always call a product the same thing. Each item
--    may carry a `to_model` — the name it takes at the destination. Left
--    out, the destination is searched for the same name ignoring case and
--    spacing, and that row's own spelling is used, so a cross move never
--    opens a second row for something the other side already stocks.
--
-- 2. ONE SAVE PER TAP, FROM A PHONE
--    A phone in a warehouse loses signal mid-save. The app cannot tell
--    "the request never arrived" from "it arrived and the reply was lost",
--    and retrying the second case moves the stock twice. That is a count
--    going wrong with nobody having done anything wrong.
--
--    record_stock_movement() takes a request ID made up by the phone. The
--    first call with an ID does the movement; any later call with the same
--    ID does nothing and returns the first call's record. The phone can
--    therefore retry until it gets an answer.
--
-- Nothing that exists is changed in behaviour: transfer_stock, receive_stock,
-- return_stock and their dahua_ twins are called as they are.
--
-- Requires 20260922_spoilt_location.sql and 20260930_dahua_transfers.sql.
-- Run once, in the Supabase SQL editor. Idempotent.
-- ─────────────────────────────────────────────────────────────

-- ── 0. Refuse to run out of order ─────────────────────────────
do $$
begin
  if to_regclass('public.dahua_stock_transfers') is null then
    raise exception 'Run 20260930_dahua_transfers.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
  if to_regprocedure('public.return_stock(text, jsonb, text, text, timestamptz, text)') is null then
    raise exception 'Run 20260922_spoilt_location.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1. Which line each end of a movement is on ────────────────
-- Both null on every ordinary movement: it happened inside the table's own
-- line. Both set on a cross move, and then they always differ.
alter table public.stock_transfers
  add column if not exists from_line text,
  add column if not exists to_line   text;
alter table public.dahua_stock_transfers
  add column if not exists from_line text,
  add column if not exists to_line   text;

alter table public.stock_transfers drop constraint if exists stock_transfers_lines_check;
alter table public.stock_transfers
  add constraint stock_transfers_lines_check check (
    (from_line is null and to_line is null)
    or (from_line in ('main', 'dahua') and to_line in ('main', 'dahua') and from_line <> to_line)
  );
alter table public.dahua_stock_transfers drop constraint if exists dahua_stock_transfers_lines_check;
alter table public.dahua_stock_transfers
  add constraint dahua_stock_transfers_lines_check check (
    (from_line is null and to_line is null)
    or (from_line in ('main', 'dahua') and to_line in ('main', 'dahua') and from_line <> to_line)
  );

-- Both lines have a SPOILT, and nothing stops them sharing other names, so
-- "two different locations" can no longer be judged on the name alone.
alter table public.stock_transfers drop constraint if exists stock_transfers_distinct_ends;
alter table public.stock_transfers
  add constraint stock_transfers_distinct_ends check (
    from_warehouse <> to_warehouse or from_line is not null
  );

alter table public.dahua_stock_transfers drop constraint if exists dahua_stock_transfers_source_check;
alter table public.dahua_stock_transfers
  add constraint dahua_stock_transfers_source_check check (
    (kind = 'move' and from_warehouse is not null
       and (from_warehouse <> to_warehouse or from_line is not null))
    or (kind in ('receive', 'return') and from_warehouse is null)
  );

-- What the other side calls the item, when it is not the same name.
alter table public.stock_transfer_items       add column if not exists other_model text;
alter table public.dahua_stock_transfer_items add column if not exists other_model text;

-- ── 2. Keep TRF / DH-TRF numbering free of gaps ───────────────
-- A cross move is a 'move' row in both tables, so the row counts these
-- functions number from would otherwise skip one for every XTR — and a
-- missing TRF number reads as a deleted transfer.
create or replace function public.next_movement_number(p_kind text)
returns text
language plpgsql security definer set search_path = public as $$
declare
  yr     text := to_char(now(), 'YYYY');
  prefix text := case p_kind when 'receive' then 'RCV'
                             when 'return'  then 'RNA'
                             else 'TRF' end;
  cnt    integer;
begin
  select count(*) + 1 into cnt
    from public.stock_transfers
   where to_char(transferred_at, 'YYYY') = yr
     and kind = p_kind
     and from_line is null;
  return prefix || '-' || yr || '-' || lpad(cnt::text, 4, '0');
end $$;

create or replace function public.next_dahua_movement_number(p_kind text)
returns text
language plpgsql security definer set search_path = public as $$
declare
  yr     text := to_char(now(), 'YYYY');
  prefix text := case p_kind when 'receive' then 'DH-RCV'
                             when 'return'  then 'DH-RNA'
                             else 'DH-TRF' end;
  cnt    integer;
begin
  select count(*) + 1 into cnt
    from public.dahua_stock_transfers
   where to_char(transferred_at, 'YYYY') = yr
     and kind = p_kind
     and from_line is null;
  return prefix || '-' || yr || '-' || lpad(cnt::text, 4, '0');
end $$;

-- ── 3. Moving between the main shop and Dahua ─────────────────
-- p_items: [{"model": "DH-IPC-HFW1239TL1-A-IL 2MP", "quantity": 5,
--            "to_model": "optional — what the destination calls it"}, ...]
--
-- As with an ordinary transfer: a model the source has never held is
-- rejected, one the destination has never held is created there, and a
-- source that holds too few simply goes negative — the shop's rule is that
-- a bad count never blocks the work.
--
-- Returns the main shop's copy of the record.
create or replace function public.cross_transfer_stock(
  p_from_line text,
  p_from      text,
  p_to_line   text,
  p_to        text,
  p_items     jsonb,
  p_note      text default null,
  p_when      timestamptz default now()
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_main        public.stock_transfers;
  v_dahua_id    uuid;
  v_yr          text := to_char(now(), 'YYYY');
  v_number      text;
  v_note        text := nullif(btrim(coalesce(p_note, '')), '');
  v_item        jsonb;
  v_typed       text;
  v_as          text;
  v_qty         integer;
  v_src_id      uuid;
  v_src_model   text;
  v_before      integer;
  v_dst_id      uuid;
  v_dst_model   text;
  v_main_model  text;
  v_dahua_model text;
  v_pos         integer := 0;
  v_try         integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to transfer stock';
  end if;
  if p_from_line is null or p_to_line is null
     or p_from_line not in ('main', 'dahua') or p_to_line not in ('main', 'dahua')
     or p_from_line = p_to_line then
    raise exception 'This is for moves between the main shop and Dahua';
  end if;
  if p_from is null or p_to is null then
    raise exception 'A transfer needs two locations';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A transfer needs at least one item';
  end if;
  if upper(btrim(p_to)) = 'SPOILT' then
    raise exception 'SPOILT is filled by returns only';
  end if;

  if p_from_line = 'main' then
    if not exists (select 1 from public.warehouses where name = p_from) then
      raise exception 'The main shop has no location called %', p_from;
    end if;
    if not exists (select 1 from public.dahua_warehouses where name = p_to) then
      raise exception 'Dahua has no warehouse called %', p_to;
    end if;
  else
    if not exists (select 1 from public.dahua_warehouses where name = p_from) then
      raise exception 'Dahua has no warehouse called %', p_from;
    end if;
    if not exists (select 1 from public.warehouses where name = p_to) then
      raise exception 'The main shop has no location called %', p_to;
    end if;
  end if;

  -- One number for both records, taken from the main table. It counts rows,
  -- so two staff saving at once can be handed the same one; the unique
  -- constraint catches it and the retry takes the next.
  for v_try in 1..8 loop
    begin
      select 'XTR-' || v_yr || '-' || lpad((count(*) + 1)::text, 4, '0') into v_number
        from public.stock_transfers
       where transfer_number like 'XTR-' || v_yr || '-%';

      insert into public.stock_transfers
        (transfer_number, kind, from_warehouse, to_warehouse, from_line, to_line,
         note, signed_by, staff_id, transferred_at, created_by)
      values
        (v_number, 'move', p_from, p_to, p_from_line, p_to_line,
         v_note, public.current_staff_name(), public.current_staff_id(),
         coalesce(p_when, now()), auth.uid())
      returning * into v_main;
      exit;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;

  insert into public.dahua_stock_transfers
    (transfer_number, kind, from_warehouse, to_warehouse, from_line, to_line,
     note, signed_by, staff_id, transferred_at, created_by)
  values
    (v_main.transfer_number, 'move', p_from, p_to, p_from_line, p_to_line,
     v_note, v_main.signed_by, v_main.staff_id, v_main.transferred_at, auth.uid())
  returning id into v_dahua_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_typed := btrim(coalesce(v_item->>'model', ''));
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    v_as    := coalesce(nullif(btrim(coalesce(v_item->>'to_model', '')), ''), v_typed);
    if v_typed = '' or v_qty <= 0 then
      continue;
    end if;

    -- ── Source: book the units out ──
    -- Matched ignoring case and spacing, oldest row first: the same row the
    -- invoice deduction and the Stock tab would pick.
    if p_from_line = 'main' then
      select s.id, s.model, s.closing_stock into v_src_id, v_src_model, v_before
        from public.warehouse_stock s
       where s.warehouse = p_from and upper(btrim(s.model)) = upper(v_typed)
       order by s.created_at, s.id::text
       limit 1
       for update;
      if not found then
        raise exception '% does not hold %', p_from, v_typed;
      end if;
      update public.warehouse_stock
         set transfer_out = coalesce(transfer_out, 0) + v_qty
       where id = v_src_id;
    else
      select s.id, s.model, s.closing_stock into v_src_id, v_src_model, v_before
        from public.dahua_stock s
       where s.warehouse = p_from and upper(btrim(s.model)) = upper(v_typed)
       order by s.created_at, s.id::text
       limit 1
       for update;
      if not found then
        raise exception '% (Dahua) does not hold %', p_from, v_typed;
      end if;
      update public.dahua_stock
         set transfer_out = coalesce(transfer_out, 0) + v_qty
       where id = v_src_id;
    end if;

    -- ── Destination: book them in ──
    -- If the destination line already stocks this under any capitalisation,
    -- its spelling wins, the destination warehouse's own row first.
    if p_to_line = 'main' then
      select s.model into v_dst_model
        from public.warehouse_stock s
       where upper(btrim(s.model)) = upper(v_as)
       order by (s.warehouse = p_to) desc, s.created_at, s.id::text
       limit 1;
      if not found then
        v_dst_model := v_as;
      end if;

      select s.id into v_dst_id
        from public.warehouse_stock s
       where s.warehouse = p_to and s.model = v_dst_model
       order by s.created_at, s.id::text
       limit 1
       for update;
      if found then
        update public.warehouse_stock
           set transfer_in = coalesce(transfer_in, 0) + v_qty
         where id = v_dst_id;
      else
        insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, transfer_in)
        values (p_to, v_dst_model, 0, '{}'::jsonb, v_qty);
      end if;
    else
      select s.model into v_dst_model
        from public.dahua_stock s
       where upper(btrim(s.model)) = upper(v_as)
       order by (s.warehouse = p_to) desc, s.created_at, s.id::text
       limit 1;
      if not found then
        v_dst_model := v_as;
      end if;
      -- Creates the row at the model's existing Dahua price when needed.
      perform public.dahua_stock_book_in(p_to, v_dst_model, v_qty);
    end if;

    -- ── One line on each side's record, each under its own name ──
    if p_from_line = 'main' then
      v_main_model := v_src_model;  v_dahua_model := v_dst_model;
    else
      v_main_model := v_dst_model;  v_dahua_model := v_src_model;
    end if;

    v_pos := v_pos + 1;
    insert into public.stock_transfer_items
      (transfer_id, model, quantity, from_before, position, other_model)
    values
      (v_main.id, v_main_model, v_qty,
       case when p_from_line = 'main' then v_before end, v_pos,
       nullif(v_dahua_model, v_main_model));
    insert into public.dahua_stock_transfer_items
      (transfer_id, model, quantity, from_before, position, other_model)
    values
      (v_dahua_id, v_dahua_model, v_qty,
       case when p_from_line = 'dahua' then v_before end, v_pos,
       nullif(v_main_model, v_dahua_model));
  end loop;

  if v_pos = 0 then
    raise exception 'A transfer needs at least one item';
  end if;

  return v_main;
end $$;

-- ── 4. One save per request ID ────────────────────────────────
create table if not exists public.stock_movement_requests (
  request_id uuid primary key,
  result     jsonb not null default '{}'::jsonb,
  created_by uuid,
  created_at timestamptz not null default now()
);
alter table public.stock_movement_requests enable row level security;
-- No policies: only record_stock_movement() touches it.

-- p_kind 'move' | 'receive' | 'return'. On a receive or a return the line is
-- p_to_line and p_from is ignored. p_party is the supplier or the buyer.
--
-- The request row and the movement are written in the same transaction, so
-- a movement that fails leaves no request behind and can be sent again. A
-- second call with the same ID waits for the first to finish, then returns
-- its record with "duplicate": true.
create or replace function public.record_stock_movement(
  p_request_id uuid,
  p_kind       text,
  p_from_line  text,
  p_from       text,
  p_to_line    text,
  p_to         text,
  p_items      jsonb,
  p_party      text default null,
  p_note       text default null,
  p_when       timestamptz default now()
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_owner  uuid;
  v_result jsonb;
  v_to     text := coalesce(p_to_line, 'main');
  v_from   text := coalesce(p_from_line, v_to);
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record stock movements';
  end if;
  if p_request_id is null then
    raise exception 'A request ID is required';
  end if;
  if v_to not in ('main', 'dahua') or v_from not in ('main', 'dahua') then
    raise exception 'Unknown stock line';
  end if;

  begin
    insert into public.stock_movement_requests (request_id, created_by)
    values (p_request_id, auth.uid());
  exception when unique_violation then
    select created_by, result into v_owner, v_result
      from public.stock_movement_requests where request_id = p_request_id;
    if v_owner is distinct from auth.uid() then
      raise exception 'That request belongs to someone else';
    end if;
    return v_result || jsonb_build_object('duplicate', true);
  end;

  if p_kind = 'move' then
    if v_from <> v_to then
      select to_jsonb(t) into v_result
        from public.cross_transfer_stock(v_from, p_from, v_to, p_to, p_items, p_note, p_when) t;
    elsif v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_transfer_stock(p_from, p_to, p_items, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.transfer_stock(p_from, p_to, p_items, p_note, p_when) t;
    end if;
  elsif p_kind = 'receive' then
    if v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_receive_stock(p_to, p_items, p_party, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.receive_stock(p_to, p_items, p_party, p_note, p_when) t;
    end if;
  elsif p_kind = 'return' then
    if v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_return_stock(p_to, p_items, p_party, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.return_stock(p_to, p_items, p_party, p_note, p_when) t;
    end if;
  else
    raise exception 'Unknown kind of movement: %', p_kind;
  end if;

  update public.stock_movement_requests
     set result = v_result
   where request_id = p_request_id;

  return v_result;
end $$;

-- ── 5. Who may call what ──────────────────────────────────────
revoke all on function public.cross_transfer_stock(text, text, text, text, jsonb, text, timestamptz)
  from public, anon;
revoke all on function public.record_stock_movement(uuid, text, text, text, text, text, jsonb, text, text, timestamptz)
  from public, anon;
grant execute on function public.cross_transfer_stock(text, text, text, text, jsonb, text, timestamptz)
  to authenticated;
grant execute on function public.record_stock_movement(uuid, text, text, text, text, text, jsonb, text, text, timestamptz)
  to authenticated;

-- ── Verification (run after the statements above) ─────────────
-- Every cross move, with what each side called the item. Both tables should
-- list the same references:
--
-- select t.transfer_number, t.from_line, t.from_warehouse, t.to_line, t.to_warehouse,
--        t.staff_id, i.quantity, i.model, i.other_model
--   from public.stock_transfer_items i
--   join public.stock_transfers t on t.id = i.transfer_id
--  where t.from_line is not null
--  order by t.transferred_at desc, i.position;
--
-- Neither pool should have drifted from its own arithmetic (expect 0 and 0):
--
-- select (select count(*) from public.warehouse_stock
--          where closing_stock <> opening_stock + transfer_in - total_taken) as main_drifted,
--        (select count(*) from public.dahua_stock
--          where closing_stock <> opening_stock + transfer_in - total_taken) as dahua_drifted;


-- ############################################################################
-- ## 20261005_stock_handlers.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Who moved the stock, by name — 2026-10-05
--
-- The phone stock app is signed in once and stays signed in, so the login
-- says which PHONE recorded a movement, not which person was holding it.
-- Stock staff now tap their own name before they record anything, and that
-- name is written onto the movement.
--
--   staff_id   the login the phone is signed in with — as before
--   signed_by  the person who tapped their name — new for phone movements
--
-- The Transfers history already shows both, one under the other.
--
-- THE NAMES COME FROM A LIST
--   stock_handlers is kept by the Big Boss. A name that is not on it is
--   refused by the database, so the record cannot carry an invented name,
--   and "Kofi", "kofi" and "Kofi A." cannot become three people.
--
--   A tapped name is not proof: anyone holding the phone can tap a
--   colleague's. It is a record of who SAID they did it, which is what was
--   asked for. If that ever needs to be stronger, a PIN column here and one
--   check in record_stock_movement() is the whole change.
--
-- Requires 20261005_cross_line_transfers.sql. Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regclass('public.stock_movement_requests') is null then
    raise exception 'Run 20261005_cross_line_transfers.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1. The list ───────────────────────────────────────────────
create table if not exists public.stock_handlers (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(btrim(name)) between 2 and 60),
  created_at timestamptz not null default now()
);
-- One entry per person, however it is capitalised.
create unique index if not exists stock_handlers_name_key
  on public.stock_handlers (upper(btrim(name)));

alter table public.stock_handlers enable row level security;

drop policy if exists stock_handlers_read on public.stock_handlers;
drop policy if exists stock_handlers_read on public.stock_handlers;

create policy stock_handlers_read on public.stock_handlers
  for select to authenticated using (true);

drop policy if exists stock_handlers_superboss_write on public.stock_handlers;
drop policy if exists stock_handlers_superboss_write on public.stock_handlers;

create policy stock_handlers_superboss_write on public.stock_handlers
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

-- ── 2. record_stock_movement takes the name ───────────────────
-- Dropped rather than overloaded: two versions differing only by a trailing
-- argument would make every call that leaves it out ambiguous.
drop function if exists public.record_stock_movement(uuid, text, text, text, text, text, jsonb, text, text, timestamptz);

create or replace function public.record_stock_movement(
  p_request_id uuid,
  p_kind       text,
  p_from_line  text,
  p_from       text,
  p_to_line    text,
  p_to         text,
  p_items      jsonb,
  p_party      text default null,
  p_note       text default null,
  p_when       timestamptz default now(),
  p_done_by    text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_owner  uuid;
  v_result jsonb;
  v_to     text := coalesce(p_to_line, 'main');
  v_from   text := coalesce(p_from_line, v_to);
  v_typed  text := btrim(coalesce(p_done_by, ''));
  v_name   text;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record stock movements';
  end if;
  if p_request_id is null then
    raise exception 'A request ID is required';
  end if;
  if v_to not in ('main', 'dahua') or v_from not in ('main', 'dahua') then
    raise exception 'Unknown stock line';
  end if;

  -- Stored as the list spells it, not as the phone sent it.
  if v_typed <> '' then
    select h.name into v_name
      from public.stock_handlers h
     where upper(btrim(h.name)) = upper(v_typed);
    if not found then
      raise exception '% is not on the stock staff list', v_typed;
    end if;
  end if;

  begin
    insert into public.stock_movement_requests (request_id, created_by)
    values (p_request_id, auth.uid());
  exception when unique_violation then
    select created_by, result into v_owner, v_result
      from public.stock_movement_requests where request_id = p_request_id;
    if v_owner is distinct from auth.uid() then
      raise exception 'That request belongs to someone else';
    end if;
    return v_result || jsonb_build_object('duplicate', true);
  end;

  if p_kind = 'move' then
    if v_from <> v_to then
      select to_jsonb(t) into v_result
        from public.cross_transfer_stock(v_from, p_from, v_to, p_to, p_items, p_note, p_when) t;
    elsif v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_transfer_stock(p_from, p_to, p_items, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.transfer_stock(p_from, p_to, p_items, p_note, p_when) t;
    end if;
  elsif p_kind = 'receive' then
    if v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_receive_stock(p_to, p_items, p_party, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.receive_stock(p_to, p_items, p_party, p_note, p_when) t;
    end if;
  elsif p_kind = 'return' then
    if v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_return_stock(p_to, p_items, p_party, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.return_stock(p_to, p_items, p_party, p_note, p_when) t;
    end if;
  else
    raise exception 'Unknown kind of movement: %', p_kind;
  end if;

  -- The movement functions stamp the login's own name. Where a person has
  -- said who they are, theirs replaces it. Matched on the reference: TRF and
  -- DH-TRF numbers each live in one table, an XTR number lives in both, and
  -- both copies should name the same person.
  if v_name is not null then
    update public.stock_transfers
       set signed_by = v_name
     where transfer_number = v_result->>'transfer_number';
    update public.dahua_stock_transfers
       set signed_by = v_name
     where transfer_number = v_result->>'transfer_number';
    v_result := v_result || jsonb_build_object('signed_by', v_name);
  end if;

  update public.stock_movement_requests
     set result = v_result
   where request_id = p_request_id;

  return v_result;
end $$;

revoke all on function public.record_stock_movement(uuid, text, text, text, text, text, jsonb, text, text, timestamptz, text)
  from public, anon;
grant execute on function public.record_stock_movement(uuid, text, text, text, text, text, jsonb, text, text, timestamptz, text)
  to authenticated;

-- ── Verification (run after the statements above) ─────────────
-- Who has been recording movements from the phones, most recent first:
--
-- select t.transfer_number, t.transferred_at, t.signed_by as person, t.staff_id as phone_login,
--        t.from_warehouse, t.to_warehouse
--   from public.stock_transfers t
--  order by t.transferred_at desc
--  limit 50;


-- ############################################################################
-- ## 20261005_no_duplicate_names_on_moves.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- A movement never opens a second row for a product the destination
-- already stocks — 2026-10-05
--
-- THE HOLE
--   Every movement booked stock in with `where warehouse = … and model = …`,
--   an exact match on the name. FISHPONG-1 calls a camera
--   "DS-2CE16D0T-LPFS 2MP bullet"; STORE STOCK has it as
--   "ds-2ce16d0t lpfs 2MP BULLET". Move five across and the exact match
--   finds nothing, so a SECOND row is created in STORE STOCK. Now the store
--   lists one camera twice, invoices come off one row, transfers land on the
--   other, and neither is the count.
--
-- THE RULE NOW
--   Two names are the same product when they are identical once capitals,
--   spaces and punctuation are ignored — stock_model_key(). Booking stock in
--   looks for the destination's row in this order:
--
--     1. the exact name
--     2. the same code under another spelling  → the units join THAT row,
--        and it keeps its own spelling
--     3. neither → a row is created, spelled the way the rest of the line
--        already spells it if any location stocks it, so a new location
--        does not introduce a new spelling either
--
--   The same applies to finding the SOURCE row, to deliveries, to returns
--   and to moves between the main shop and Dahua.
--
-- WHAT IS DELIBERATELY NOT AUTOMATIC
--   "EAP225" and "EAP225 Wireless ceiling mount" are probably one product,
--   but a bare code is sometimes a different pack or lens. The database does
--   not guess. The app shows staff the similar name and they choose; their
--   choice arrives here as `to_model` on the item:
--
--     [{"model": "EAP225", "quantity": 4, "to_model": "EAP225 Wireless ceiling mount"}]
--
--   and the units join that row. Where the two names differ, both are kept
--   on the movement record (model / other_model).
--
-- This stops NEW duplicates. Rows already doubled are merged with
-- merge_stock_model() — Transfers → Product names.
--
-- Requires 20261005_cross_line_transfers.sql. Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regprocedure('public.cross_transfer_stock(text, text, text, text, jsonb, text, timestamptz)') is null then
    raise exception 'Run 20261005_cross_line_transfers.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1. What makes two names the same product ──────────────────
create or replace function public.stock_model_key(p_model text)
returns text
language sql immutable parallel safe as $$
  select regexp_replace(upper(coalesce(p_model, '')), '[^A-Z0-9]', '', 'g')
$$;

create index if not exists warehouse_stock_warehouse_key_idx
  on public.warehouse_stock (warehouse, public.stock_model_key(model));
create index if not exists dahua_stock_warehouse_key_idx
  on public.dahua_stock (warehouse, public.stock_model_key(model));

-- ── 2. Finding a location's row for a product ─────────────────
-- The exact name first, then the same code under another spelling; the
-- oldest row where a location already holds it twice.
create or replace function public.stock_find_row(p_warehouse text, p_model text)
returns uuid
language sql stable security definer set search_path = public as $$
  select s.id
    from public.warehouse_stock s
   where s.warehouse = p_warehouse
     and (s.model = p_model
          or (public.stock_model_key(p_model) <> ''
              and public.stock_model_key(s.model) = public.stock_model_key(p_model)))
   order by (s.model = p_model) desc, s.created_at, s.id::text
   limit 1
$$;

create or replace function public.dahua_stock_find_row(p_warehouse text, p_model text)
returns uuid
language sql stable security definer set search_path = public as $$
  select s.id
    from public.dahua_stock s
   where s.warehouse = p_warehouse
     and (s.model = p_model
          or (public.stock_model_key(p_model) <> ''
              and public.stock_model_key(s.model) = public.stock_model_key(p_model)))
   order by (s.model = p_model) desc, s.created_at, s.id::text
   limit 1
$$;

-- ── 3. Booking units in ───────────────────────────────────────
-- Returns the name the units were booked under, which is the row's own
-- spelling and may not be the one asked for.
create or replace function public.stock_book_in(p_warehouse text, p_model text, p_qty integer)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_id   uuid;
  v_name text;
begin
  v_id := public.stock_find_row(p_warehouse, p_model);
  if v_id is not null then
    update public.warehouse_stock
       set transfer_in = coalesce(transfer_in, 0) + p_qty
     where id = v_id
    returning model into v_name;
    return v_name;
  end if;

  -- New to this location. If another location already stocks it, take that
  -- spelling rather than starting a new one.
  select s.model into v_name
    from public.warehouse_stock s
   where public.stock_model_key(p_model) <> ''
     and public.stock_model_key(s.model) = public.stock_model_key(p_model)
   order by (s.model = p_model) desc, s.created_at, s.id::text
   limit 1;
  v_name := coalesce(v_name, p_model);

  insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, transfer_in)
  values (p_warehouse, v_name, 0, '{}'::jsonb, p_qty);
  return v_name;
end $$;

create or replace function public.dahua_stock_book_in_as(p_warehouse text, p_model text, p_qty integer)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_id    uuid;
  v_name  text;
  v_price numeric(12,2);
begin
  v_id := public.dahua_stock_find_row(p_warehouse, p_model);
  if v_id is not null then
    update public.dahua_stock
       set transfer_in = coalesce(transfer_in, 0) + p_qty
     where id = v_id
    returning model into v_name;
    return v_name;
  end if;

  select s.model into v_name
    from public.dahua_stock s
   where public.stock_model_key(p_model) <> ''
     and public.stock_model_key(s.model) = public.stock_model_key(p_model)
   order by (s.model = p_model) desc, s.created_at, s.id::text
   limit 1;
  v_name := coalesce(v_name, p_model);

  -- At the model's existing price, so stock moved into a new warehouse does
  -- not show up on an invoice as "no price".
  select max(s.unit_price) into v_price
    from public.dahua_stock s
   where public.stock_model_key(s.model) = public.stock_model_key(v_name);

  insert into public.dahua_stock (warehouse, model, opening_stock, daily_taken, invoice_taken, transfer_in, unit_price)
  values (p_warehouse, v_name, 0, '{}'::jsonb, 0, p_qty, coalesce(v_price, 0));
  return v_name;
end $$;

-- The original, which dahua_receive_stock and dahua_return_stock call. Same
-- name and signature, so those two pick up the new matching without being
-- rewritten.
create or replace function public.dahua_stock_book_in(p_warehouse text, p_model text, p_qty integer)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.dahua_stock_book_in_as(p_warehouse, p_model, p_qty);
end $$;

-- The header every main-shop movement opens with — the twin of
-- dahua_movement_open(). Retries on a number clash: the number counts rows,
-- so two staff saving at once can both be handed the same one.
create or replace function public.stock_movement_open(
  p_kind text, p_from text, p_to text, p_party text, p_note text, p_when timestamptz
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_rec public.stock_transfers;
  v_try integer;
begin
  for v_try in 1..8 loop
    begin
      insert into public.stock_transfers
        (transfer_number, kind, from_warehouse, to_warehouse, supplier,
         note, signed_by, staff_id, transferred_at, created_by)
      values
        (public.next_movement_number(p_kind), p_kind, p_from, p_to,
         nullif(btrim(coalesce(p_party, '')), ''),
         nullif(btrim(coalesce(p_note, '')), ''),
         public.current_staff_name(), public.current_staff_id(),
         coalesce(p_when, now()), auth.uid())
      returning * into v_rec;
      return v_rec;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;
end $$;

-- Internal: reachable only through the movement functions below.
revoke all on function public.stock_find_row(text, text)                 from public, anon, authenticated;
revoke all on function public.dahua_stock_find_row(text, text)           from public, anon, authenticated;
revoke all on function public.stock_book_in(text, text, integer)         from public, anon, authenticated;
revoke all on function public.dahua_stock_book_in_as(text, text, integer) from public, anon, authenticated;
revoke all on function public.dahua_stock_book_in(text, text, integer)   from public, anon, authenticated;
revoke all on function public.stock_movement_open(text, text, text, text, text, timestamptz) from public, anon, authenticated;

-- ── 4. Main shop: move ────────────────────────────────────────
-- p_items: [{"model": "...", "quantity": 5, "to_model": "optional"}, ...]
create or replace function public.transfer_stock(
  p_from  text,
  p_to    text,
  p_items jsonb,
  p_note  text default null,
  p_when  timestamptz default now()
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_rec       public.stock_transfers;
  v_item      jsonb;
  v_model     text;
  v_as        text;
  v_qty       integer;
  v_src_id    uuid;
  v_src_model text;
  v_dst_model text;
  v_before    integer;
  v_pos       integer := 0;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to transfer stock';
  end if;
  if p_from is null or p_to is null or p_from = p_to then
    raise exception 'A transfer needs two different locations';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A transfer needs at least one item';
  end if;

  v_rec := public.stock_movement_open('move', p_from, p_to, null, p_note, p_when);

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(coalesce(v_item->>'model', ''));
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    v_as    := coalesce(nullif(btrim(coalesce(v_item->>'to_model', '')), ''), v_model);
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    v_src_id := public.stock_find_row(p_from, v_model);
    if v_src_id is null then
      raise exception '% does not hold %', p_from, v_model;
    end if;
    -- Locked so two staff moving the same model at once cannot both read
    -- the same "before" figure.
    select s.model, s.closing_stock into v_src_model, v_before
      from public.warehouse_stock s where s.id = v_src_id for update;

    update public.warehouse_stock
       set transfer_out = coalesce(transfer_out, 0) + v_qty
     where id = v_src_id;

    v_dst_model := public.stock_book_in(p_to, v_as, v_qty);

    v_pos := v_pos + 1;
    insert into public.stock_transfer_items (transfer_id, model, quantity, from_before, position, other_model)
    values (v_rec.id, v_src_model, v_qty, v_before, v_pos, nullif(v_dst_model, v_src_model));
  end loop;

  return v_rec;
end $$;

-- ── 5. Main shop: receive ─────────────────────────────────────
create or replace function public.receive_stock(
  p_to       text,
  p_items    jsonb,
  p_supplier text default null,
  p_note     text default null,
  p_when     timestamptz default now()
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_rec   public.stock_transfers;
  v_item  jsonb;
  v_model text;
  v_qty   integer;
  v_pos   integer := 0;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to receive stock';
  end if;
  if p_to is null or btrim(p_to) = '' then
    raise exception 'Where is this delivery going?';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A delivery needs at least one item';
  end if;

  v_rec := public.stock_movement_open('receive', null, p_to, p_supplier, p_note, p_when);

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(coalesce(v_item->>'model', ''));
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    -- Recorded under the name it was booked in as, not the name typed.
    v_model := public.stock_book_in(p_to, v_model, v_qty);

    v_pos := v_pos + 1;
    insert into public.stock_transfer_items (transfer_id, model, quantity, from_before, position)
    values (v_rec.id, v_model, v_qty, null, v_pos);
  end loop;

  return v_rec;
end $$;

-- ── 6. Main shop: return ──────────────────────────────────────
create or replace function public.return_stock(
  p_to       text,
  p_items    jsonb,
  p_customer text default null,
  p_note     text default null,
  p_when     timestamptz default now(),
  p_spoilt   text default 'SPOILT'
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_rec   public.stock_transfers;
  v_item  jsonb;
  v_model text;
  v_qty   integer;
  v_cond  text;
  v_pos   integer := 0;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record returns';
  end if;
  if p_to is null or btrim(p_to) = '' then
    raise exception 'Where are the good items going back to?';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A return needs at least one item';
  end if;

  v_rec := public.stock_movement_open('return', null, p_to, p_customer, p_note, p_when);

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(coalesce(v_item->>'model', ''));
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    -- The tick is on the exception: anything not marked spoilt is resaleable.
    v_cond  := case when lower(coalesce(v_item->>'condition', 'good')) = 'spoilt'
                    then 'spoilt' else 'good' end;
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    v_model := public.stock_book_in(
      case when v_cond = 'spoilt' then p_spoilt else p_to end, v_model, v_qty);

    v_pos := v_pos + 1;
    insert into public.stock_transfer_items
      (transfer_id, model, quantity, from_before, position, condition)
    values (v_rec.id, v_model, v_qty, null, v_pos, v_cond);
  end loop;

  return v_rec;
end $$;

-- ── 7. Dahua: move ────────────────────────────────────────────
create or replace function public.dahua_transfer_stock(
  p_from  text,
  p_to    text,
  p_items jsonb,
  p_note  text default null,
  p_when  timestamptz default now()
) returns public.dahua_stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_rec       public.dahua_stock_transfers;
  v_item      jsonb;
  v_model     text;
  v_as        text;
  v_qty       integer;
  v_src_id    uuid;
  v_src_model text;
  v_dst_model text;
  v_before    integer;
  v_pos       integer := 0;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to transfer stock';
  end if;
  if p_from is null or p_to is null or p_from = p_to then
    raise exception 'A transfer needs two different locations';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A transfer needs at least one item';
  end if;

  v_rec := public.dahua_movement_open('move', p_from, p_to, null, p_note, p_when);

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(coalesce(v_item->>'model', ''));
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    v_as    := coalesce(nullif(btrim(coalesce(v_item->>'to_model', '')), ''), v_model);
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    v_src_id := public.dahua_stock_find_row(p_from, v_model);
    if v_src_id is null then
      raise exception '% does not hold %', p_from, v_model;
    end if;
    select s.model, s.closing_stock into v_src_model, v_before
      from public.dahua_stock s where s.id = v_src_id for update;

    update public.dahua_stock
       set transfer_out = coalesce(transfer_out, 0) + v_qty
     where id = v_src_id;

    v_dst_model := public.dahua_stock_book_in_as(p_to, v_as, v_qty);

    v_pos := v_pos + 1;
    insert into public.dahua_stock_transfer_items (transfer_id, model, quantity, from_before, position, other_model)
    values (v_rec.id, v_src_model, v_qty, v_before, v_pos, nullif(v_dst_model, v_src_model));
  end loop;

  return v_rec;
end $$;

-- ── 8. Between the main shop and Dahua ────────────────────────
create or replace function public.cross_transfer_stock(
  p_from_line text,
  p_from      text,
  p_to_line   text,
  p_to        text,
  p_items     jsonb,
  p_note      text default null,
  p_when      timestamptz default now()
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_main        public.stock_transfers;
  v_dahua_id    uuid;
  v_yr          text := to_char(now(), 'YYYY');
  v_number      text;
  v_note        text := nullif(btrim(coalesce(p_note, '')), '');
  v_item        jsonb;
  v_typed       text;
  v_as          text;
  v_qty         integer;
  v_src_id      uuid;
  v_src_model   text;
  v_before      integer;
  v_dst_model   text;
  v_main_model  text;
  v_dahua_model text;
  v_pos         integer := 0;
  v_try         integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to transfer stock';
  end if;
  if p_from_line is null or p_to_line is null
     or p_from_line not in ('main', 'dahua') or p_to_line not in ('main', 'dahua')
     or p_from_line = p_to_line then
    raise exception 'This is for moves between the main shop and Dahua';
  end if;
  if p_from is null or p_to is null then
    raise exception 'A transfer needs two locations';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A transfer needs at least one item';
  end if;
  if upper(btrim(p_to)) = 'SPOILT' then
    raise exception 'SPOILT is filled by returns only';
  end if;

  if p_from_line = 'main' then
    if not exists (select 1 from public.warehouses where name = p_from) then
      raise exception 'The main shop has no location called %', p_from;
    end if;
    if not exists (select 1 from public.dahua_warehouses where name = p_to) then
      raise exception 'Dahua has no warehouse called %', p_to;
    end if;
  else
    if not exists (select 1 from public.dahua_warehouses where name = p_from) then
      raise exception 'Dahua has no warehouse called %', p_from;
    end if;
    if not exists (select 1 from public.warehouses where name = p_to) then
      raise exception 'The main shop has no location called %', p_to;
    end if;
  end if;

  for v_try in 1..8 loop
    begin
      select 'XTR-' || v_yr || '-' || lpad((count(*) + 1)::text, 4, '0') into v_number
        from public.stock_transfers
       where transfer_number like 'XTR-' || v_yr || '-%';

      insert into public.stock_transfers
        (transfer_number, kind, from_warehouse, to_warehouse, from_line, to_line,
         note, signed_by, staff_id, transferred_at, created_by)
      values
        (v_number, 'move', p_from, p_to, p_from_line, p_to_line,
         v_note, public.current_staff_name(), public.current_staff_id(),
         coalesce(p_when, now()), auth.uid())
      returning * into v_main;
      exit;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;

  insert into public.dahua_stock_transfers
    (transfer_number, kind, from_warehouse, to_warehouse, from_line, to_line,
     note, signed_by, staff_id, transferred_at, created_by)
  values
    (v_main.transfer_number, 'move', p_from, p_to, p_from_line, p_to_line,
     v_note, v_main.signed_by, v_main.staff_id, v_main.transferred_at, auth.uid())
  returning id into v_dahua_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_typed := btrim(coalesce(v_item->>'model', ''));
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    v_as    := coalesce(nullif(btrim(coalesce(v_item->>'to_model', '')), ''), v_typed);
    if v_typed = '' or v_qty <= 0 then
      continue;
    end if;

    if p_from_line = 'main' then
      v_src_id := public.stock_find_row(p_from, v_typed);
      if v_src_id is null then
        raise exception '% does not hold %', p_from, v_typed;
      end if;
      select s.model, s.closing_stock into v_src_model, v_before
        from public.warehouse_stock s where s.id = v_src_id for update;
      update public.warehouse_stock
         set transfer_out = coalesce(transfer_out, 0) + v_qty
       where id = v_src_id;

      v_dst_model := public.dahua_stock_book_in_as(p_to, v_as, v_qty);
      v_main_model := v_src_model;  v_dahua_model := v_dst_model;
    else
      v_src_id := public.dahua_stock_find_row(p_from, v_typed);
      if v_src_id is null then
        raise exception '% (Dahua) does not hold %', p_from, v_typed;
      end if;
      select s.model, s.closing_stock into v_src_model, v_before
        from public.dahua_stock s where s.id = v_src_id for update;
      update public.dahua_stock
         set transfer_out = coalesce(transfer_out, 0) + v_qty
       where id = v_src_id;

      v_dst_model := public.stock_book_in(p_to, v_as, v_qty);
      v_main_model := v_dst_model;  v_dahua_model := v_src_model;
    end if;

    v_pos := v_pos + 1;
    insert into public.stock_transfer_items
      (transfer_id, model, quantity, from_before, position, other_model)
    values
      (v_main.id, v_main_model, v_qty,
       case when p_from_line = 'main' then v_before end, v_pos,
       nullif(v_dahua_model, v_main_model));
    insert into public.dahua_stock_transfer_items
      (transfer_id, model, quantity, from_before, position, other_model)
    values
      (v_dahua_id, v_dahua_model, v_qty,
       case when p_from_line = 'dahua' then v_before end, v_pos,
       nullif(v_main_model, v_dahua_model));
  end loop;

  if v_pos = 0 then
    raise exception 'A transfer needs at least one item';
  end if;

  return v_main;
end $$;

-- ── Verification (run after the statements above) ─────────────
-- Locations that ALREADY list one product twice. This file stops new ones;
-- these are cleared with Transfers → Product names:
--
-- select warehouse, public.stock_model_key(model) as code,
--        array_agg(model order by created_at) as spellings, sum(closing_stock) as units
--   from public.warehouse_stock
--  group by 1, 2
-- having count(*) > 1
--  order by 1, 2;


-- ############################################################################
-- ## 20261005_merge_product_names.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- One product, one name — 2026-10-05
--
-- Stock is keyed on the model NAME, per warehouse. Nothing ties "EAP225" in
-- one warehouse to "EAP225 Wireless ceiling mount" in another, so the same
-- product under two spellings is, to the system, two products: the piles
-- cannot be transferred into each other, a sale comes off one and never the
-- other, and neither figure is the real count.
--
-- 20260921_merge_digital_multimeter.sql fixed one such pair by hand. This
-- turns that file into a function the Big Boss can run from the app for any
-- pair, on either line:
--
--   merge_stock_model('main',  'DIGITAL MULTIMETER', 'DIGITAL MULTIMETER DT920SA')
--   merge_stock_model('dahua', 'old spelling',       'spelling to keep')
--
-- WHAT IT DOES
--   In every warehouse of that line holding the old name, the rows under
--   either name are added together onto one row — opening count, sold,
--   moved in, moved out and each day column — and that row takes the kept
--   name. Where only the old name exists it is a plain rename.
--
--   Barcodes linked to the old name follow it, so the next scan of that box
--   still resolves. On the main line a price-list entry under the old name
--   follows too, unless the kept name already has one. On Dahua, invoice
--   lines that pointed at an absorbed row are re-pointed at the surviving
--   one, and the surviving row keeps its price (or takes the highest of the
--   group when it has none).
--
-- WHAT IT DOES NOT DO
--   It does not rewrite past invoices or past movement records. Those say
--   what was printed and what was moved at the time, under the name used
--   then.
--
--   It does not decide what is a duplicate. The app suggests pairs; a person
--   confirms each one. Kit codes that differ by one character are sometimes
--   genuinely different kits, and merging on a guess is how a count stops
--   matching the shelf.
--
-- Big Boss only. Idempotent to install; each merge is a single transaction.
-- ─────────────────────────────────────────────────────────────

create or replace function public.merge_stock_model(
  p_line text,
  p_from text,
  p_into text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_from     text := btrim(coalesce(p_from, ''));
  v_into     text := btrim(coalesce(p_into, ''));
  v_wh       text;
  v_keep     uuid;
  v_gone     uuid[];
  v_opening  integer;
  v_invoice  integer;
  v_in       integer;
  v_out      integer;
  v_min      integer;
  v_daily    jsonb;
  v_price    numeric(12,2);
  v_places   integer := 0;
  v_absorbed integer := 0;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss may merge product names';
  end if;
  if p_line is null or p_line not in ('main', 'dahua') then
    raise exception 'Unknown stock line';
  end if;
  if v_from = '' or v_into = '' then
    raise exception 'Both names are required';
  end if;
  if length(v_into) > 200 then
    raise exception 'That name is too long';
  end if;
  if v_from = v_into then
    raise exception 'Those are the same name';
  end if;

  if p_line = 'main' then
    if not exists (select 1 from public.warehouse_stock where model = v_from) then
      raise exception 'Nothing is stocked as "%"', v_from;
    end if;

    for v_wh in
      select distinct warehouse from public.warehouse_stock where model = v_from
    loop
      -- The surviving row: one already under the kept name if there is one,
      -- otherwise the one on the books longest.
      select s.id into v_keep
        from public.warehouse_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into)
       order by (s.model = v_into) desc, s.created_at, s.id::text
       limit 1
       for update;

      select coalesce(sum(s.opening_stock), 0),
             coalesce(sum(coalesce(s.invoice_taken, 0)), 0),
             coalesce(sum(coalesce(s.transfer_in, 0)), 0),
             coalesce(sum(coalesce(s.transfer_out, 0)), 0),
             -- The lower reorder point is the more cautious one. MIN skips
             -- nulls, so a row without one does not erase the other's.
             min(s.min_level)
        into v_opening, v_invoice, v_in, v_out, v_min
        from public.warehouse_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into);

      -- daily_taken is a day → qty map. Days booked in both piles are added,
      -- not overwritten.
      select coalesce(jsonb_object_agg(d.day, d.qty), '{}'::jsonb) into v_daily
        from (
          select e.key as day, sum(e.value::integer) as qty
            from public.warehouse_stock s
           cross join lateral jsonb_each_text(coalesce(s.daily_taken, '{}'::jsonb)) e
           where s.warehouse = v_wh and s.model in (v_from, v_into)
           group by e.key
        ) d;

      select coalesce(array_agg(s.id), '{}') into v_gone
        from public.warehouse_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into) and s.id <> v_keep;

      delete from public.warehouse_stock where id = any (v_gone);

      -- total_taken, closing_stock and stock_status are recomputed by
      -- trg_warehouse_stock_derive from these columns.
      update public.warehouse_stock
         set model         = v_into,
             opening_stock = v_opening,
             invoice_taken = v_invoice,
             transfer_in   = v_in,
             transfer_out  = v_out,
             min_level     = v_min,
             daily_taken   = v_daily
       where id = v_keep;

      v_places   := v_places + 1;
      v_absorbed := v_absorbed + coalesce(array_length(v_gone, 1), 0);
    end loop;

    update public.product_codes
       set model = v_into, updated_at = now()
     where model = v_from;

    -- Two price entries for one name would make the price ambiguous, so the
    -- old entry only follows when the kept name has none of its own.
    update public.pricelist_items
       set model = v_into
     where model = v_from
       and not exists (
             select 1 from public.pricelist_items p
              where upper(btrim(p.model)) = upper(v_into) and p.model <> v_from
           );

  else
    if not exists (select 1 from public.dahua_stock where model = v_from) then
      raise exception 'Dahua stocks nothing as "%"', v_from;
    end if;

    for v_wh in
      select distinct warehouse from public.dahua_stock where model = v_from
    loop
      select s.id into v_keep
        from public.dahua_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into)
       order by (s.model = v_into) desc, s.created_at, s.id::text
       limit 1
       for update;

      select coalesce(sum(s.opening_stock), 0),
             coalesce(sum(coalesce(s.invoice_taken, 0)), 0),
             coalesce(sum(coalesce(s.transfer_in, 0)), 0),
             coalesce(sum(coalesce(s.transfer_out, 0)), 0),
             min(s.min_level),
             max(s.unit_price)
        into v_opening, v_invoice, v_in, v_out, v_min, v_price
        from public.dahua_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into);

      select coalesce(jsonb_object_agg(d.day, d.qty), '{}'::jsonb) into v_daily
        from (
          select e.key as day, sum(e.value::integer) as qty
            from public.dahua_stock s
           cross join lateral jsonb_each_text(coalesce(s.daily_taken, '{}'::jsonb)) e
           where s.warehouse = v_wh and s.model in (v_from, v_into)
           group by e.key
        ) d;

      select coalesce(array_agg(s.id), '{}') into v_gone
        from public.dahua_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into) and s.id <> v_keep;

      -- Invoice lines keep pointing at a row that exists. The line triggers
      -- are lifted for this one statement: they would re-stamp each old
      -- line's list price from the surviving row and log the difference as a
      -- price override that never happened.
      if exists (select 1 from public.dahua_invoice_items where stock_id = any (v_gone)) then
        alter table public.dahua_invoice_items disable trigger user;
        update public.dahua_invoice_items set stock_id = v_keep where stock_id = any (v_gone);
        alter table public.dahua_invoice_items enable trigger user;
      end if;

      delete from public.dahua_stock where id = any (v_gone);

      update public.dahua_stock
         set model         = v_into,
             opening_stock = v_opening,
             invoice_taken = v_invoice,
             transfer_in   = v_in,
             transfer_out  = v_out,
             min_level     = v_min,
             daily_taken   = v_daily,
             -- Its own price stands; a row with none takes the group's.
             unit_price    = case when coalesce(unit_price, 0) > 0 then unit_price
                                  else coalesce(v_price, 0) end
       where id = v_keep;

      v_places   := v_places + 1;
      v_absorbed := v_absorbed + coalesce(array_length(v_gone, 1), 0);
    end loop;

    update public.dahua_product_codes
       set model = v_into, updated_at = now()
     where model = v_from;
  end if;

  return jsonb_build_object(
    'line', p_line, 'from', v_from, 'into', v_into,
    'warehouses', v_places, 'rows_absorbed', v_absorbed
  );
end $$;

revoke all on function public.merge_stock_model(text, text, text) from public, anon;
grant execute on function public.merge_stock_model(text, text, text) to authenticated;

-- ── Finding candidates by hand ────────────────────────────────
-- The app lists these under Transfers → Product names. The same search in
-- SQL — names in the main shop that are identical once case, spaces and
-- punctuation are ignored:
--
-- select regexp_replace(upper(model), '[^A-Z0-9]', '', 'g') as code,
--        array_agg(distinct model) as spellings,
--        array_agg(distinct warehouse) as warehouses
--   from public.warehouse_stock
--  group by 1
-- having count(distinct model) > 1
--  order by 1;


-- ############################################################################
-- ## 20261005_model_key_keeps_decimals.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- "1.5M" is not "15M" — 2026-10-05
--
-- Corrects 20261005_no_duplicate_names_on_moves.sql, found the first time
-- the rule was read against the real stock list.
--
-- stock_model_key() dropped every character that is not a letter or a
-- digit, including the decimal point. STORE STOCK carries both
--
--     1.5M PATCH CORD      and      15M PATCH CORD
--
-- and without the point both reduce to 15MPATCHCORD — one product, as far
-- as the matching was concerned. Moving the 1.5 m cord into a location that
-- only stocked the 15 m one would have added it to the 15 m row.
--
-- A point BETWEEN TWO DIGITS is now kept (as "~" in the key). Every other
-- point is still punctuation: "DS-7608NI-Q2." and "DS-7608NI-Q2" stay the
-- same product.
--
-- The two indexes are built on this function's result, and Postgres does
-- not rebuild an index when the function under it changes. They are dropped
-- first and rebuilt after, or lookups would run against the old keys.
--
-- Also here: merge_stock_model() trimmed the name it was asked to get rid
-- of, so a name stored with a trailing space — there are two dozen — could
-- never be found to be merged. The old name is now matched exactly as it is
-- stored.
--
-- Requires 20261005_no_duplicate_names_on_moves.sql and
-- 20261005_merge_product_names.sql. Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regprocedure('public.stock_model_key(text)') is null then
    raise exception 'Run 20261005_no_duplicate_names_on_moves.sql first — this file corrects it.'
      using errcode = '42P01';
  end if;
  if to_regprocedure('public.merge_stock_model(text, text, text)') is null then
    raise exception 'Run 20261005_merge_product_names.sql first — this file corrects it.'
      using errcode = '42P01';
  end if;
end $$;

drop index if exists public.warehouse_stock_warehouse_key_idx;
drop index if exists public.dahua_stock_warehouse_key_idx;

create or replace function public.stock_model_key(p_model text)
returns text
language sql immutable parallel safe as $$
  select regexp_replace(
           regexp_replace(upper(coalesce(p_model, '')), '([0-9])\.(?=[0-9])', '\1~', 'g'),
           '[^A-Z0-9~]', '', 'g')
$$;

create index warehouse_stock_warehouse_key_idx
  on public.warehouse_stock (warehouse, public.stock_model_key(model));
create index dahua_stock_warehouse_key_idx
  on public.dahua_stock (warehouse, public.stock_model_key(model));

-- ── merge_stock_model: find the old name as it is stored ──────
-- Identical to 20261005_merge_product_names.sql except for how v_from is
-- taken: no longer trimmed.
create or replace function public.merge_stock_model(
  p_line text,
  p_from text,
  p_into text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_from     text := coalesce(p_from, '');
  v_into     text := btrim(coalesce(p_into, ''));
  v_wh       text;
  v_keep     uuid;
  v_gone     uuid[];
  v_opening  integer;
  v_invoice  integer;
  v_in       integer;
  v_out      integer;
  v_min      integer;
  v_daily    jsonb;
  v_price    numeric(12,2);
  v_places   integer := 0;
  v_absorbed integer := 0;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss may merge product names';
  end if;
  if p_line is null or p_line not in ('main', 'dahua') then
    raise exception 'Unknown stock line';
  end if;
  if btrim(v_from) = '' or v_into = '' then
    raise exception 'Both names are required';
  end if;
  if length(v_into) > 200 then
    raise exception 'That name is too long';
  end if;
  if v_from = v_into then
    raise exception 'Those are the same name';
  end if;

  if p_line = 'main' then
    if not exists (select 1 from public.warehouse_stock where model = v_from) then
      raise exception 'Nothing is stocked as "%"', v_from;
    end if;

    for v_wh in
      select distinct warehouse from public.warehouse_stock where model = v_from
    loop
      select s.id into v_keep
        from public.warehouse_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into)
       order by (s.model = v_into) desc, s.created_at, s.id::text
       limit 1
       for update;

      select coalesce(sum(s.opening_stock), 0),
             coalesce(sum(coalesce(s.invoice_taken, 0)), 0),
             coalesce(sum(coalesce(s.transfer_in, 0)), 0),
             coalesce(sum(coalesce(s.transfer_out, 0)), 0),
             min(s.min_level)
        into v_opening, v_invoice, v_in, v_out, v_min
        from public.warehouse_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into);

      select coalesce(jsonb_object_agg(d.day, d.qty), '{}'::jsonb) into v_daily
        from (
          select e.key as day, sum(e.value::integer) as qty
            from public.warehouse_stock s
           cross join lateral jsonb_each_text(coalesce(s.daily_taken, '{}'::jsonb)) e
           where s.warehouse = v_wh and s.model in (v_from, v_into)
           group by e.key
        ) d;

      select coalesce(array_agg(s.id), '{}') into v_gone
        from public.warehouse_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into) and s.id <> v_keep;

      delete from public.warehouse_stock where id = any (v_gone);

      update public.warehouse_stock
         set model         = v_into,
             opening_stock = v_opening,
             invoice_taken = v_invoice,
             transfer_in   = v_in,
             transfer_out  = v_out,
             min_level     = v_min,
             daily_taken   = v_daily
       where id = v_keep;

      v_places   := v_places + 1;
      v_absorbed := v_absorbed + coalesce(array_length(v_gone, 1), 0);
    end loop;

    update public.product_codes
       set model = v_into, updated_at = now()
     where model = v_from;

    update public.pricelist_items
       set model = v_into
     where model = v_from
       and not exists (
             select 1 from public.pricelist_items p
              where upper(btrim(p.model)) = upper(v_into) and p.model <> v_from
           );

  else
    if not exists (select 1 from public.dahua_stock where model = v_from) then
      raise exception 'Dahua stocks nothing as "%"', v_from;
    end if;

    for v_wh in
      select distinct warehouse from public.dahua_stock where model = v_from
    loop
      select s.id into v_keep
        from public.dahua_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into)
       order by (s.model = v_into) desc, s.created_at, s.id::text
       limit 1
       for update;

      select coalesce(sum(s.opening_stock), 0),
             coalesce(sum(coalesce(s.invoice_taken, 0)), 0),
             coalesce(sum(coalesce(s.transfer_in, 0)), 0),
             coalesce(sum(coalesce(s.transfer_out, 0)), 0),
             min(s.min_level),
             max(s.unit_price)
        into v_opening, v_invoice, v_in, v_out, v_min, v_price
        from public.dahua_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into);

      select coalesce(jsonb_object_agg(d.day, d.qty), '{}'::jsonb) into v_daily
        from (
          select e.key as day, sum(e.value::integer) as qty
            from public.dahua_stock s
           cross join lateral jsonb_each_text(coalesce(s.daily_taken, '{}'::jsonb)) e
           where s.warehouse = v_wh and s.model in (v_from, v_into)
           group by e.key
        ) d;

      select coalesce(array_agg(s.id), '{}') into v_gone
        from public.dahua_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into) and s.id <> v_keep;

      if exists (select 1 from public.dahua_invoice_items where stock_id = any (v_gone)) then
        alter table public.dahua_invoice_items disable trigger user;
        update public.dahua_invoice_items set stock_id = v_keep where stock_id = any (v_gone);
        alter table public.dahua_invoice_items enable trigger user;
      end if;

      delete from public.dahua_stock where id = any (v_gone);

      update public.dahua_stock
         set model         = v_into,
             opening_stock = v_opening,
             invoice_taken = v_invoice,
             transfer_in   = v_in,
             transfer_out  = v_out,
             min_level     = v_min,
             daily_taken   = v_daily,
             unit_price    = case when coalesce(unit_price, 0) > 0 then unit_price
                                  else coalesce(v_price, 0) end
       where id = v_keep;

      v_places   := v_places + 1;
      v_absorbed := v_absorbed + coalesce(array_length(v_gone, 1), 0);
    end loop;

    update public.dahua_product_codes
       set model = v_into, updated_at = now()
     where model = v_from;
  end if;

  return jsonb_build_object(
    'line', p_line, 'from', v_from, 'into', v_into,
    'warehouses', v_places, 'rows_absorbed', v_absorbed
  );
end $$;

-- ── Verification ──────────────────────────────────────────────
-- select public.stock_model_key('1.5M PATCH CORD') as a,    -- 1~5MPATCHCORD
--        public.stock_model_key('15M PATCH CORD')  as b,    -- 15MPATCHCORD
--        public.stock_model_key('DS-7608NI-Q2.')   as c;    -- DS7608NIQ2


-- ############################################################################
-- ## 20261005_uniform_names.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- One spelling per product, everywhere — 2026-10-05
--
-- Built from a read of the live stock list on 2026-10-05: 1,511 names in
-- the main shop, 302 in Dahua. It makes the names uniform. IT DOES NOT
-- CHANGE WHAT ANY WAREHOUSE HOLDS: the last step adds up every warehouse
-- before and after, and if a single unit has moved the whole file is
-- undone and nothing is saved.
--
-- WHAT IS RENAMED
--   Only names that are the same product beyond argument — identical once
--   capitals, spaces and punctuation are ignored (stock_model_key):
--
--     "ds-2ce16kot-lpfs"        →  "DS-2CE16KOT-LPFS"
--     "IOS84"                   →  "IO-S84"
--     "Video balun 8MP"         →  "VIDEO BALUN 8MP"
--     "DS-7208HGHI-M1#"         →  "DS-7208HGHI-M1"
--
--   The # and * on the end of names were marks from count sheets and mean
--   nothing about the product (confirmed by the shop), so they come off —
--   54 names. A * inside a name is a size ("520*350*180") and stays.
--   Stray and doubled spaces go too.
--
--   The spelling kept is the one most warehouses already use, then the one
--   holding most stock. Where the main shop and Dahua both stock a code,
--   Dahua takes the main shop's spelling.
--
-- WHERE TWO ROWS BECOME ONE
--   In most warehouses this is a rename and nothing else. But where ONE
--   warehouse held the same product under two spellings — BACK WAREHOUSE had
--   "DS-2CE10KF0T-LPFS" (288) and "DS-2CE10KF0T-LPFS*" (1,429) — the two rows
--   become one row holding both (1,717). That warehouse's total is exactly
--   what it was; it is now on one line instead of two.
--
-- WHAT IS NOT TOUCHED
--   Names that are only similar — "DS-2CD1027G3-LIU" and
--   "DS-2CD1027G3-LIU/SRB", "EAP225" and "EAP225 OUTDOOR", "AP3000" and
--   "CUDY AP3000". Those need a person to say they are the same product, and
--   are in the review list, not here.
--
--   Past invoices and movement records keep the wording they were written
--   with.
--
-- ALSO HERE
--   Invoices now find the STORE STOCK row the way movements do — by code,
--   not by exact spelling. Without this, renaming a row could stop a sale
--   being deducted because the product catalogue still spells it the old
--   way. With it, a spelling difference can no longer make a sale miss the
--   shelf at all.
--
-- Requires 20261005_model_key_keeps_decimals.sql. Safe to run again: a name
-- that has already been renamed is skipped.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regprocedure('public.stock_model_key(text)') is null
     or public.stock_model_key('1.5') <> '1~5' then
    raise exception 'Run 20261005_model_key_keeps_decimals.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1. The merge, without the "who is asking" check ───────────
-- merge_stock_model() is the Big Boss's button in the app and insists on a
-- Big Boss login. A migration has no login at all, so the work itself moves
-- into this internal function, which nobody can call from the app.
--
-- Two differences from the button, both for running in bulk:
--   • a name nothing is stocked under is skipped, not an error — so the
--     file can be run twice;
--   • p_from = p_into is allowed, and folds two rows that already share one
--     name in one warehouse.
create or replace function public.stock_merge_names(p_line text, p_from text, p_into text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_from     text := coalesce(p_from, '');
  v_into     text := btrim(coalesce(p_into, ''));
  v_wh       text;
  v_keep     uuid;
  v_gone     uuid[];
  v_opening  integer;
  v_invoice  integer;
  v_in       integer;
  v_out      integer;
  v_min      integer;
  v_daily    jsonb;
  v_price    numeric(12,2);
  v_places   integer := 0;
  v_absorbed integer := 0;
begin
  if p_line is null or p_line not in ('main', 'dahua') then
    raise exception 'Unknown stock line';
  end if;
  if btrim(v_from) = '' or v_into = '' then
    raise exception 'Both names are required';
  end if;
  if length(v_into) > 200 then
    raise exception 'That name is too long';
  end if;

  if p_line = 'main' then
    for v_wh in
      select distinct warehouse from public.warehouse_stock where model = v_from
    loop
      -- The surviving row: one already under the kept name if there is one,
      -- otherwise the one on the books longest.
      select s.id into v_keep
        from public.warehouse_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into)
       order by (s.model = v_into) desc, s.created_at, s.id::text
       limit 1
       for update;

      select coalesce(sum(s.opening_stock), 0),
             coalesce(sum(coalesce(s.invoice_taken, 0)), 0),
             coalesce(sum(coalesce(s.transfer_in, 0)), 0),
             coalesce(sum(coalesce(s.transfer_out, 0)), 0),
             min(s.min_level)
        into v_opening, v_invoice, v_in, v_out, v_min
        from public.warehouse_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into);

      -- daily_taken is a day → qty map. Days booked on both rows are added.
      select coalesce(jsonb_object_agg(d.day, d.qty), '{}'::jsonb) into v_daily
        from (
          select e.key as day, sum(e.value::integer) as qty
            from public.warehouse_stock s
           cross join lateral jsonb_each_text(coalesce(s.daily_taken, '{}'::jsonb)) e
           where s.warehouse = v_wh and s.model in (v_from, v_into)
           group by e.key
        ) d;

      select coalesce(array_agg(s.id), '{}') into v_gone
        from public.warehouse_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into) and s.id <> v_keep;

      delete from public.warehouse_stock where id = any (v_gone);

      update public.warehouse_stock
         set model         = v_into,
             opening_stock = v_opening,
             invoice_taken = v_invoice,
             transfer_in   = v_in,
             transfer_out  = v_out,
             min_level     = v_min,
             daily_taken   = v_daily
       where id = v_keep;

      v_places   := v_places + 1;
      v_absorbed := v_absorbed + coalesce(array_length(v_gone, 1), 0);
    end loop;

    if v_from <> v_into then
      update public.product_codes
         set model = v_into, updated_at = now()
       where model = v_from;

      -- Two price entries for one name would make the price ambiguous, so
      -- the old entry only follows when the kept name has none of its own.
      update public.pricelist_items
         set model = v_into
       where model = v_from
         and not exists (
               select 1 from public.pricelist_items p
                where upper(btrim(p.model)) = upper(v_into) and p.model <> v_from
             );
    end if;

  else
    for v_wh in
      select distinct warehouse from public.dahua_stock where model = v_from
    loop
      select s.id into v_keep
        from public.dahua_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into)
       order by (s.model = v_into) desc, s.created_at, s.id::text
       limit 1
       for update;

      select coalesce(sum(s.opening_stock), 0),
             coalesce(sum(coalesce(s.invoice_taken, 0)), 0),
             coalesce(sum(coalesce(s.transfer_in, 0)), 0),
             coalesce(sum(coalesce(s.transfer_out, 0)), 0),
             min(s.min_level),
             max(s.unit_price)
        into v_opening, v_invoice, v_in, v_out, v_min, v_price
        from public.dahua_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into);

      select coalesce(jsonb_object_agg(d.day, d.qty), '{}'::jsonb) into v_daily
        from (
          select e.key as day, sum(e.value::integer) as qty
            from public.dahua_stock s
           cross join lateral jsonb_each_text(coalesce(s.daily_taken, '{}'::jsonb)) e
           where s.warehouse = v_wh and s.model in (v_from, v_into)
           group by e.key
        ) d;

      select coalesce(array_agg(s.id), '{}') into v_gone
        from public.dahua_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into) and s.id <> v_keep;

      -- Invoice lines keep pointing at a row that exists. The line triggers
      -- are lifted for this one statement: they would re-stamp each old
      -- line's list price and log a price override that never happened.
      if exists (select 1 from public.dahua_invoice_items where stock_id = any (v_gone)) then
        alter table public.dahua_invoice_items disable trigger user;
        update public.dahua_invoice_items set stock_id = v_keep where stock_id = any (v_gone);
        alter table public.dahua_invoice_items enable trigger user;
      end if;

      delete from public.dahua_stock where id = any (v_gone);

      update public.dahua_stock
         set model         = v_into,
             opening_stock = v_opening,
             invoice_taken = v_invoice,
             transfer_in   = v_in,
             transfer_out  = v_out,
             min_level     = v_min,
             daily_taken   = v_daily,
             -- Its own price stands; a row with none takes the group's.
             unit_price    = case when coalesce(unit_price, 0) > 0 then unit_price
                                  else coalesce(v_price, 0) end
       where id = v_keep;

      v_places   := v_places + 1;
      v_absorbed := v_absorbed + coalesce(array_length(v_gone, 1), 0);
    end loop;

    if v_from <> v_into then
      update public.dahua_product_codes
         set model = v_into, updated_at = now()
       where model = v_from;
    end if;
  end if;

  return jsonb_build_object(
    'line', p_line, 'from', v_from, 'into', v_into,
    'warehouses', v_places, 'rows_absorbed', v_absorbed
  );
end $$;

revoke all on function public.stock_merge_names(text, text, text) from public, anon, authenticated;

-- The Big Boss's button: the checks a person needs, then the same work.
create or replace function public.merge_stock_model(p_line text, p_from text, p_into text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_from text := coalesce(p_from, '');
  v_into text := btrim(coalesce(p_into, ''));
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss may merge product names';
  end if;
  if p_line is null or p_line not in ('main', 'dahua') then
    raise exception 'Unknown stock line';
  end if;
  if v_from = v_into then
    raise exception 'Those are the same name';
  end if;
  if p_line = 'main' and not exists (select 1 from public.warehouse_stock where model = v_from) then
    raise exception 'Nothing is stocked as "%"', v_from;
  end if;
  if p_line = 'dahua' and not exists (select 1 from public.dahua_stock where model = v_from) then
    raise exception 'Dahua stocks nothing as "%"', v_from;
  end if;
  return public.stock_merge_names(p_line, v_from, v_into);
end $$;

-- ── 2. Invoices find the shelf by code, not by exact spelling ──
-- Supersedes the version in 20260921_deduct_store_stock_match.sql, which
-- matched on capitals and outer spaces only. "IOS84" on an invoice now comes
-- off "IO-S84" on the shelf. Still internal: reachable only through
-- deduct_invoice_store_stock().
create or replace function public.deduct_store_stock(
  p_items jsonb,
  p_store text default 'STORE STOCK'
) returns table (model text, requested integer, available integer, tracked boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_item  jsonb;
  v_typed text;
  v_qty   integer;
  v_id    uuid;
  v_model text;
  v_have  integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to adjust stock';
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_typed := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_typed = '' or v_qty <= 0 then
      continue;
    end if;

    v_id := public.stock_find_row(p_store, v_typed);
    if v_id is null then
      -- Reported, not invented: an item the shop does not stock should not
      -- create a negative row out of nothing.
      model := v_typed; requested := v_qty; available := 0; tracked := false;
      return next;
      continue;
    end if;

    -- Locked so two tills invoicing the same model cannot both read the
    -- same "before" figure.
    select s.model, s.closing_stock into v_model, v_have
      from public.warehouse_stock s where s.id = v_id for update;

    update public.warehouse_stock
       set invoice_taken = coalesce(invoice_taken, 0) + v_qty
     where id = v_id;

    -- The sale is never blocked by the count; a shortfall is reported and
    -- the closing figure simply goes negative.
    if v_have < v_qty then
      model := v_model; requested := v_qty; available := v_have; tracked := true;
      return next;
    end if;
  end loop;
end $$;

-- ── 3. The renames ────────────────────────────────────────────
-- One block, so it is all or nothing. Before anything is renamed every
-- warehouse is added up; afterwards it is added up again; any difference at
-- all raises an error, and an error here undoes every rename above it.
do $names$
declare
  v_main_before  jsonb;
  v_dahua_before jsonb;
  v_main_after   jsonb;
  v_dahua_after  jsonb;
  v_rows_before  integer;
  v_rows_after   integer;
begin
  select coalesce(jsonb_object_agg(warehouse, units), '{}'::jsonb) into v_main_before
    from (select warehouse, sum(closing_stock) as units from public.warehouse_stock group by warehouse) t;
  select coalesce(jsonb_object_agg(warehouse, units), '{}'::jsonb) into v_dahua_before
    from (select warehouse, sum(closing_stock) as units from public.dahua_stock group by warehouse) t;
  select (select count(*) from public.warehouse_stock) + (select count(*) from public.dahua_stock) into v_rows_before;

  -- Renaming a thousand rows is one event, not a thousand entries in the
  -- activity log. The summary is raised as a notice at the end instead.
  alter table public.warehouse_stock disable trigger trg_audit_warehouse_stock;
  alter table public.dahua_stock     disable trigger trg_audit_dahua_stock;

  -- Main shop: 109 names
  perform public.stock_merge_names('main', '12V5A ADAPTER', '12V 5A ADAPTER');
  perform public.stock_merge_names('main', ' 2U Westa 520*350*180 ', '2U Westa 520*350*180');
  perform public.stock_merge_names('main', '4U CABINET  600X600', '4U CABINET 600X600');
  perform public.stock_merge_names('main', '6U CABINET  600X600', '6U CABINET 600X600');
  perform public.stock_merge_names('main', '9U-CABINET', '9U-CABINET');
  perform public.stock_merge_names('main', 'Axiom cat6  Cable UTP gray 100m', 'Axiom cat6 Cable UTP gray 100m');
  perform public.stock_merge_names('main', 'Axiom cat6 SFTP outdoor PVC+PE 100m', 'Axiom cat6 SFTP OUTDOOR PVC+PE 100m');
  perform public.stock_merge_names('main', 'BNC connector copper', 'BNC CONNECTOR COPPER');
  perform public.stock_merge_names('main', 'Cable manager', 'CABLE MANAGER');
  perform public.stock_merge_names('main', 'CS-HB8c/SP', 'CS-HB8C/SP');
  perform public.stock_merge_names('main', 'CS-HB90x/SP', 'CS-HB90X/SP');
  perform public.stock_merge_names('main', 'Cs-HB90X/SP', 'CS-HB90X/SP');
  perform public.stock_merge_names('main', 'DECOx20(3pack)', 'Deco X20 3-pack');
  perform public.stock_merge_names('main', 'DH-CS4218-16ET-240', 'DH-CS4218-16ET-240');
  perform public.stock_merge_names('main', 'DH-CS4226-24ET-375', 'DH-CS4226-24ET-375');
  perform public.stock_merge_names('main', 'DH-XVRIBO4-I/T', 'DH-XVRIBO4-I/T');
  perform public.stock_merge_names('main', 'DS-1H18-A#', 'DS-1H18-A');
  perform public.stock_merge_names('main', 'DS-1LN6AUSPE-FTP#', 'DS-1LN6AUSPE-FTP');
  perform public.stock_merge_names('main', 'DS-2CD1023G2-LIU#', 'DS-2CD1023G2-LIU');
  perform public.stock_merge_names('main', 'ds-2cd1063g2-liu', 'DS-2CD1063G2-LIU');
  perform public.stock_merge_names('main', 'ds-2cd1163g2-liu', 'DS-2CD1163G2-LIU');
  perform public.stock_merge_names('main', 'DS-2CD1347G2H-LIUF/SRB  4 MP ColorVu Smart Hybrid', 'DS-2CD1347G2H-LIUF/SRB 4 MP ColorVu Smart Hybrid');
  perform public.stock_merge_names('main', 'DS-2CD2087G3-LI2UY/SRB**', 'DS-2CD2087G3-LI2UY/SRB');
  perform public.stock_merge_names('main', 'DS-2CD2187G2-LSU', 'DS-2CD2187G2+LSU');
  perform public.stock_merge_names('main', 'DS-2CE10KF0T-LPFS*', 'DS-2CE10KF0T-LPFS');
  perform public.stock_merge_names('main', 'ds-2ce16kot-lpfs', 'DS-2CE16KOT-LPFS');
  perform public.stock_merge_names('main', 'ds-2ce76kot-lpfs', 'DS-2CE76KOT-LPFS');
  perform public.stock_merge_names('main', 'DS-2CE78D0T-LPXTS*', 'DS-2CE78D0T-LPXTS');
  perform public.stock_merge_names('main', 'DS-2CFSO4/4G#', 'DS-2CFSO4/4G');
  perform public.stock_merge_names('main', 'DS-2CFSP4/4G*', 'DS-2CFSP4/4G');
  perform public.stock_merge_names('main', 'DS-2FA1225-C4(UK) 4CH POWER SUPPLY#', 'DS-2FA1225-C4(UK) 4CH POWER SUPPLY');
  perform public.stock_merge_names('main', 'DS-3E0116R-O#', 'DS-3E0116R-O');
  perform public.stock_merge_names('main', 'DS-3E1318P-E1/M*', 'DS-3E1318P-E1/M');
  perform public.stock_merge_names('main', 'DS-7204HGHI-M1/T#', 'DS-7204HGHI-M1/T');
  perform public.stock_merge_names('main', 'DS-7208HGHI-M1#', 'DS-7208HGHI-M1');
  perform public.stock_merge_names('main', 'DS-7216HGHI-M1/T*', 'DS-7216HGHI-M1/T');
  perform public.stock_merge_names('main', 'DS-7232HGH1-M2#', 'DS-7232HGH1-M2');
  perform public.stock_merge_names('main', 'DS-7604NXI-K1/4P(E)**', 'DS-7604NXI-K1/4P(E)');
  perform public.stock_merge_names('main', 'DS-7608NI-Q2-8P-E', 'DS-7608NI-Q2/8P(E)');
  perform public.stock_merge_names('main', 'DS-7608NXI-K1/8P(E)**', 'DS-7608NXI-K1/8P(E)');
  perform public.stock_merge_names('main', 'DS-7608NXI-K1(E)**', 'DS-7608NXI-K1(E)');
  perform public.stock_merge_names('main', 'DS-7616NXI-K1(E)#', 'DS-7616NXI-K1 (E)');
  perform public.stock_merge_names('main', 'DS-7616NXI-K1 NVR NONE POE 16CH*', 'DS-7616NXI-K1 NVR NONE POE 16CH');
  perform public.stock_merge_names('main', 'DS-7616NXI-K2/16P (E) NVR POE 16CH*', 'DS-7616NXI-K2/16P (E) NVR POE 16CH');
  perform public.stock_merge_names('main', 'DS-7632NXI-K2/16P(E)**', 'DS-7632NXI-K2/16P(E)');
  perform public.stock_merge_names('main', 'DS-7632NXI-K2(E)*', 'DS-7632NXI-K2(E)');
  perform public.stock_merge_names('main', 'DS-D5022F2-IV2#', 'DS-D5022F2-IV2');
  perform public.stock_merge_names('main', 'DS-D5024F2-AV2#', 'DS-D5024F2-AV2');
  perform public.stock_merge_names('main', 'DS-J142I/7208HGHI-M1+4+4 CAM/ COLOUR VU#', 'DS-J142I/7208HGHI-M1+4+4 CAM/ COLOUR VU');
  perform public.stock_merge_names('main', 'DS-K3GL606WX*', 'DS-K3GL606WX');
  perform public.stock_merge_names('main', 'DS-K7M-AW24#', 'DS-K7M-AW24');
  perform public.stock_merge_names('main', 'DS-KIA8503MF-B#', 'DS-KIA8503MF-B');
  perform public.stock_merge_names('main', 'DS-KIS303-P#', 'DS-KIS303-P');
  perform public.stock_merge_names('main', 'DS-KIS603-P(C)#', 'DS-KIS603-P (C)');
  perform public.stock_merge_names('main', 'DS-KIS608-P#', 'DS-KIS608-P');
  perform public.stock_merge_names('main', 'DS-KIS610-P#', 'DS-KIS610-P');
  perform public.stock_merge_names('main', 'DS-KIS611-S#', 'DS-KIS611-S');
  perform public.stock_merge_names('main', 'DS-KIS902-S#', 'DS-KIS902-S');
  perform public.stock_merge_names('main', 'DS-KIT343MFX#', 'DS-KIT343MFX');
  perform public.stock_merge_names('main', 'DS-KIT344MBFWX-E1*', 'DS-KIT344MBFWX-E1');
  perform public.stock_merge_names('main', 'DS-KIT808 MFWX', 'DS-KIT808MFWX');
  perform public.stock_merge_names('main', 'DS-KV6124WBE1', 'DS-KV6124-WBE1');
  perform public.stock_merge_names('main', 'DS-KV6133-WME1#', 'DS-KV6133-WME1');
  perform public.stock_merge_names('main', 'DS-KV8113-WME1(C)#', 'DS-KV8113-WME1(C)');
  perform public.stock_merge_names('main', 'DS-PDP15P-EG2-WE(B)#', 'DS-PDP15P-EG2-WE(B)');
  perform public.stock_merge_names('main', 'DS-QA20206GI-S#', 'DS-QA20206GI-S');
  perform public.stock_merge_names('main', 'DS-QAE0120GIR#', 'DS-QAE0120GIR');
  perform public.stock_merge_names('main', 'DS-QAE0A60G1-VB*', 'DS-QAE0A60G1-VB');
  perform public.stock_merge_names('main', 'DS-QAEOA60G1-VB#', 'DS-QAEOA60G1-VB');
  perform public.stock_merge_names('main', 'DS-UPS-1200-R*', 'DS-UPS-1200-R');
  perform public.stock_merge_names('main', 'DS-UPS2000va', 'DS-UPS2000VA');
  perform public.stock_merge_names('main', 'DS-ups2000va', 'DS-UPS2000VA');
  perform public.stock_merge_names('main', 'EAP215-BRIDGE KIT', 'EAP215 BRIDGE KIT');
  perform public.stock_merge_names('main', 'EAP235 Wall', 'EAP 235 WALL');
  perform public.stock_merge_names('main', 'EAP 235 WALL', 'EAP 235 WALL');
  perform public.stock_merge_names('main', 'EAP610GP Desktop (EU)', 'EAP610GP DESKTOP (EU)');
  perform public.stock_merge_names('main', 'EAP610 Outdoor', 'EAP610 OUTDOOR');
  perform public.stock_merge_names('main', 'EAP725 Outdoor', 'EAP725 OUTDOOR');
  perform public.stock_merge_names('main', 'HDMI FIBRE OPTIC 15M#', 'HDMI FIBRE OPTIC 15M');
  perform public.stock_merge_names('main', 'Hilook NVR104H-D/4P', 'HiLook NVR-104H-D/4P');
  perform public.stock_merge_names('main', 'Hilook NVR-108H-D/8P', 'HI-LOOK NVR-108H-D/8P');
  perform public.stock_merge_names('main', 'IDS-7204HQHI-M1/T#', 'IDS-7204HQHI-M1/T');
  perform public.stock_merge_names('main', 'IDS-7204HQHI-M1/XT#', 'IDS-7204HQHI-M1/XT');
  perform public.stock_merge_names('main', 'IDS-7208HQHI-M1/T#', 'IDS-7208HQHI-M1/T');
  perform public.stock_merge_names('main', 'IDS-7208HQHI-M1/XT#', 'IDS-7208HQHI-M1/XT');
  perform public.stock_merge_names('main', 'IDS-7216HQHI-M1/T#', 'IDS-7216HQHI-M1/T');
  perform public.stock_merge_names('main', 'IDS-7232HQHI-M2/XT#', 'IDS-7232HQHI-M2/XT');
  perform public.stock_merge_names('main', 'IOS84', 'IO-S84');
  perform public.stock_merge_names('main', 'IOWF145', 'IO-WF145');
  perform public.stock_merge_names('main', ' JUNCTION BOX BIG', 'JUNCTION BOX BIG');
  perform public.stock_merge_names('main', 'Junction box big size', 'JUNCTION BOX BIG SIZE');
  perform public.stock_merge_names('main', 'JUNCTION BOX BIG SIZE ROUND ', 'JUNCTION BOX BIG SIZE ROUND');
  perform public.stock_merge_names('main', 'Junction Box Small', 'JUNCTION BOX SMALL');
  perform public.stock_merge_names('main', 'Mini smart switch*', 'Mini smart switch');
  perform public.stock_merge_names('main', 'MODULAR CRIMPING TOOL PASS THROUGH', 'MODULAR CRIMPING TOOL PASS-THROUGH');
  perform public.stock_merge_names('main', 'Network Tool Kit', 'NETWORK TOOL KIT');
  perform public.stock_merge_names('main', 'NK844WDH', 'NK844WDH');
  perform public.stock_merge_names('main', 'PATRESS-BOX#', 'PATRESS-BOX');
  perform public.stock_merge_names('main', 'PDU extension board', 'PDU EXTENSION BOARD');
  perform public.stock_merge_names('main', 'PS4 GAME PAD', 'PS4 GAMEPAD');
  perform public.stock_merge_names('main', 'PS4 gamepad', 'PS4 GAMEPAD');
  perform public.stock_merge_names('main', ' PS5 GAMEPAD', 'PS5 GAMEPAD');
  perform public.stock_merge_names('main', 'PS5 GAME PAD', 'PS5 GAMEPAD');
  perform public.stock_merge_names('main', 'SD-UPS2000VA', 'SD-UPS-2000VA');
  perform public.stock_merge_names('main', ' SD-UPS-3000VA', 'SD-UPS-3000VA');
  perform public.stock_merge_names('main', 'Tapo C200', 'TAPO C200');
  perform public.stock_merge_names('main', 'U7 Lite', 'U7 LITE');
  perform public.stock_merge_names('main', 'Video Balun 8mp', 'VIDEO BALUN 8MP');
  perform public.stock_merge_names('main', 'Video balun 8MP', 'VIDEO BALUN 8MP');

  -- Dahua: 22 names
  perform public.stock_merge_names('dahua', '12V5A ADAPTER ', '12V 5A ADAPTER');
  perform public.stock_merge_names('dahua', '4U WESTA CABINET ', '4U WESTA CABINET');
  perform public.stock_merge_names('dahua', 'DH-CS4006-4ET2GT-60  SWITCH', 'DH-CS4006-4ET2GT-60 SWITCH');
  perform public.stock_merge_names('dahua', 'DH-HAC-B1A21P-U 2MP ', 'DH-HAC-B1A21P-U 2MP');
  perform public.stock_merge_names('dahua', 'DH-HAC-HDW1509CLQP-A-LED 5MP ', 'DH-HAC-HDW1509CLQP-A-LED 5MP');
  perform public.stock_merge_names('dahua', 'DH-HAC-HFW1500CLP-IL-A   5MP', 'DH-HAC-HFW1500CLP-IL-A 5MP');
  perform public.stock_merge_names('dahua', 'DHI-KTP01L(S) IP INTERCOM WITH IP SWITCH ', 'DHI-KTP01L(S) IP INTERCOM WITH IP SWITCH');
  perform public.stock_merge_names('dahua', 'DHI-KTP02 IP INTERCOM BLACK WITH SWITCH ', 'DHI-KTP02 IP INTERCOM BLACK WITH SWITCH');
  perform public.stock_merge_names('dahua', 'DHI-KTP10 VIDEO INTERCOM KIT IP INTERCOM WITH POE SWITCH ', 'DHI-KTP10 VIDEO INTERCOM KIT IP INTERCOM WITH POE SWITCH');
  perform public.stock_merge_names('dahua', 'DH-IPC-C3AP-0280B CUBE 3MP indoor Wi-Fi cube IP camera ', 'DH-IPC-C3AP-0280B CUBE 3MP indoor Wi-Fi cube IP camera');
  perform public.stock_merge_names('dahua', 'DH-IPC-HFW2439SP-SA-LED-S2 4MP ', 'DH-IPC-HFW2439SP-SA-LED-S2 4MP');
  perform public.stock_merge_names('dahua', 'DH-IPC-HFW2441DG-4G-SP-B    64Wh', 'DH-IPC-HFW2441DG-4G-SP-B 64Wh');
  perform public.stock_merge_names('dahua', 'DH-MR403 DAHUA ROUTER ', 'DH-MR403 DAHUA ROUTER');
  perform public.stock_merge_names('dahua', 'HDMI 60M KVM EXTENDER', 'HDMI 60m KVM extender');
  perform public.stock_merge_names('dahua', 'QS-V5 VIDEO CALLING CAMERA ', 'QS-V5 VIDEO CALLING CAMERA');
  perform public.stock_merge_names('dahua', 'SD-UPS1000VA', 'SD-UPS-1000VA');
  perform public.stock_merge_names('dahua', 'SOLID UPS 2000VA', 'SOLID-UPS2000Va');
  perform public.stock_merge_names('dahua', 'ST-LC55-6M-4G SOLAR STREET ', 'ST-LC55-6M-4G SOLAR STREET');
  perform public.stock_merge_names('dahua', 'WESTA CAT6 SFTP AG003  OUTDOOR', 'WESTA CAT6 SFTP AG003 OUTDOOR');
  perform public.stock_merge_names('dahua', 'WIRELESS HDMI 100M', 'Wireless HDMI 100 m');
  perform public.stock_merge_names('dahua', 'WIRELESS HDMI 150M', 'Wireless HDMI 150 m');
  perform public.stock_merge_names('dahua', 'WIRELESS HDMI 50M', 'Wireless HDMI 50 m');

  alter table public.warehouse_stock enable trigger trg_audit_warehouse_stock;
  alter table public.dahua_stock     enable trigger trg_audit_dahua_stock;

  select coalesce(jsonb_object_agg(warehouse, units), '{}'::jsonb) into v_main_after
    from (select warehouse, sum(closing_stock) as units from public.warehouse_stock group by warehouse) t;
  select coalesce(jsonb_object_agg(warehouse, units), '{}'::jsonb) into v_dahua_after
    from (select warehouse, sum(closing_stock) as units from public.dahua_stock group by warehouse) t;
  select (select count(*) from public.warehouse_stock) + (select count(*) from public.dahua_stock) into v_rows_after;

  if v_main_after <> v_main_before then
    raise exception 'A main-shop warehouse total changed — nothing has been saved. Before: %  After: %',
      v_main_before, v_main_after;
  end if;
  if v_dahua_after <> v_dahua_before then
    raise exception 'A Dahua warehouse total changed — nothing has been saved. Before: %  After: %',
      v_dahua_before, v_dahua_after;
  end if;

  raise notice 'Names made uniform. Every warehouse holds exactly what it held before. Stock rows: % before, % after (% doubled rows folded into one).',
    v_rows_before, v_rows_after, v_rows_before - v_rows_after;
end $names$;

-- ── Verification (run after the block above) ──────────────────
-- No warehouse should list one product code twice any more (expect 0 rows):
--
-- select warehouse, public.stock_model_key(model) as code, array_agg(model) as spellings
--   from public.warehouse_stock
--  group by 1, 2 having count(*) > 1;
--
-- No name should end in a # or * (expect 0):
--
-- select count(*) from public.warehouse_stock where model ~ '[#*]\s*$';
--
-- One spelling per code across all warehouses (expect 0 rows):
--
-- select public.stock_model_key(model) as code, array_agg(distinct model) as spellings
--   from public.warehouse_stock
--  group by 1 having count(distinct model) > 1;


-- ############################################################################
-- ## 20261006_stock_staff_passwords.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Stock staff set their own password — 2026-10-06
--
-- Tapping a name proved nothing: anyone holding a stock phone could tap a
-- colleague's and record under it. Each person on the stock staff list now
-- has a password of their own, set by them the first time they pick their
-- name, and asked for every time after.
--
-- HOW A MOVEMENT IS TIED TO A PERSON
--   Entering the password gives the phone a KEY for that person
--   (stock_handler_tokens). Every movement the phone records for them
--   carries the key, and record_stock_movement() refuses a movement signed
--   with a name whose key is missing or wrong. So a name on a record means
--   someone who knew that person's password recorded it.
--
--   A key, not the password itself, because movements can wait in a phone's
--   outbox for hours with no signal. The phone has to hold something to
--   send with them later, and it should not be the password.
--
--   Keys stop working when the password is changed or reset.
--
-- WHAT IS STORED
--   Never the password — a salted SHA-256 of it, in a table no app login
--   can read (RLS on, no policies). The staff list the phones read gives
--   names and "has a password: yes/no", nothing more.
--
--   Five wrong tries locks that name for five minutes.
--
-- FORGOTTEN PASSWORDS
--   The Big Boss resets it (stock_handler_reset_password). That removes the
--   password and every key; the person sets a new one the next time they
--   pick their name.
--
-- THE GAP TO KNOW ABOUT
--   Until someone has set a password, their name is open — whoever picks it
--   first sets the password. Have each person set theirs on day one; if the
--   wrong person got there first, reset it.
--
-- Movements signed with a name that has no password yet are still accepted,
-- so phones that have not updated keep working.
--
-- Requires 20261005_stock_handlers.sql. Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regclass('public.stock_handlers') is null then
    raise exception 'Run 20261005_stock_handlers.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1. Where the secrets live ─────────────────────────────────
create table if not exists public.stock_handler_secrets (
  handler_id   uuid primary key references public.stock_handlers(id) on delete cascade,
  salt         text not null,
  hash         text not null,
  failed       integer not null default 0,
  locked_until timestamptz,
  set_at       timestamptz not null default now()
);
alter table public.stock_handler_secrets enable row level security;
-- No policies: only the functions below touch it.

create table if not exists public.stock_handler_tokens (
  token      uuid primary key default gen_random_uuid(),
  handler_id uuid not null references public.stock_handlers(id) on delete cascade,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists stock_handler_tokens_handler_idx on public.stock_handler_tokens (handler_id);
alter table public.stock_handler_tokens enable row level security;
-- No policies.

create or replace function public.stock_pass_hash(p_salt text, p_password text)
returns text
language sql immutable as $$
  select encode(sha256(convert_to(p_salt || ':' || p_password, 'UTF8')), 'hex')
$$;
revoke all on function public.stock_pass_hash(text, text) from public, anon, authenticated;

-- ── 2. The list the phones read ───────────────────────────────
create or replace function public.stock_handlers_list()
returns table (name text, has_password boolean)
language sql stable security definer set search_path = public as $$
  select h.name,
         exists (select 1 from public.stock_handler_secrets s where s.handler_id = h.id)
    from public.stock_handlers h
   order by h.name
$$;

-- ── 3. Entering a password ────────────────────────────────────
-- Returns {"ok": true, "name": …, "token": …} or {"ok": false, "error": …}.
-- A wrong password is RETURNED, not raised: raising would undo the count of
-- wrong tries along with everything else, and the lock would never engage.
create or replace function public.stock_handler_sign_in(p_name text, p_password text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id     uuid;
  v_name   text;
  v_secret public.stock_handler_secrets;
  v_token  uuid;
  v_wait   integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record stock movements';
  end if;

  select h.id, h.name into v_id, v_name
    from public.stock_handlers h
   where upper(btrim(h.name)) = upper(btrim(coalesce(p_name, '')));
  if not found then
    return jsonb_build_object('ok', false, 'error', 'That name is not on the stock staff list');
  end if;

  select * into v_secret from public.stock_handler_secrets where handler_id = v_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'No password has been set for this name yet', 'no_password', true);
  end if;

  if v_secret.locked_until is not null and v_secret.locked_until > now() then
    v_wait := greatest(1, ceil(extract(epoch from (v_secret.locked_until - now())) / 60)::integer);
    return jsonb_build_object('ok', false, 'error',
      'Too many wrong tries. Try again in ' || v_wait || ' minute' || case when v_wait = 1 then '' else 's' end || '.');
  end if;

  if public.stock_pass_hash(v_secret.salt, coalesce(p_password, '')) <> v_secret.hash then
    if v_secret.failed + 1 >= 5 then
      update public.stock_handler_secrets
         set failed = 0, locked_until = now() + interval '5 minutes'
       where handler_id = v_id;
      return jsonb_build_object('ok', false, 'error', 'Wrong password. Too many wrong tries — locked for 5 minutes.');
    end if;
    update public.stock_handler_secrets set failed = failed + 1 where handler_id = v_id;
    return jsonb_build_object('ok', false, 'error', 'Wrong password');
  end if;

  update public.stock_handler_secrets set failed = 0, locked_until = null where handler_id = v_id;

  insert into public.stock_handler_tokens (handler_id, created_by)
  values (v_id, auth.uid()) returning token into v_token;
  -- A handful of keys per person is plenty for two phones; older ones go.
  delete from public.stock_handler_tokens t
   where t.handler_id = v_id
     and t.token not in (select k.token from public.stock_handler_tokens k
                          where k.handler_id = v_id order by k.created_at desc limit 6);

  return jsonb_build_object('ok', true, 'name', v_name, 'token', v_token);
end $$;

-- ── 4. Setting or changing a password ─────────────────────────
-- First time: p_old is not needed. After that the current password must be
-- given. Changing it cancels every key, so other phones ask again.
create or replace function public.stock_handler_set_password(p_name text, p_new text, p_old text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id     uuid;
  v_name   text;
  v_secret public.stock_handler_secrets;
  v_salt   text := gen_random_uuid()::text;
  v_token  uuid;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record stock movements';
  end if;

  select h.id, h.name into v_id, v_name
    from public.stock_handlers h
   where upper(btrim(h.name)) = upper(btrim(coalesce(p_name, '')));
  if not found then
    return jsonb_build_object('ok', false, 'error', 'That name is not on the stock staff list');
  end if;
  if p_new is null or length(p_new) < 4 then
    return jsonb_build_object('ok', false, 'error', 'Use at least 4 characters');
  end if;
  if length(p_new) > 72 then
    return jsonb_build_object('ok', false, 'error', 'That password is too long');
  end if;

  select * into v_secret from public.stock_handler_secrets where handler_id = v_id for update;
  if found then
    if v_secret.locked_until is not null and v_secret.locked_until > now() then
      return jsonb_build_object('ok', false, 'error', 'Too many wrong tries. Try again in a few minutes.');
    end if;
    if public.stock_pass_hash(v_secret.salt, coalesce(p_old, '')) <> v_secret.hash then
      if v_secret.failed + 1 >= 5 then
        update public.stock_handler_secrets
           set failed = 0, locked_until = now() + interval '5 minutes'
         where handler_id = v_id;
      else
        update public.stock_handler_secrets set failed = failed + 1 where handler_id = v_id;
      end if;
      return jsonb_build_object('ok', false, 'error', 'The current password is wrong');
    end if;
    update public.stock_handler_secrets
       set salt = v_salt, hash = public.stock_pass_hash(v_salt, p_new),
           failed = 0, locked_until = null, set_at = now()
     where handler_id = v_id;
  else
    insert into public.stock_handler_secrets (handler_id, salt, hash)
    values (v_id, v_salt, public.stock_pass_hash(v_salt, p_new));
  end if;

  delete from public.stock_handler_tokens where handler_id = v_id;
  insert into public.stock_handler_tokens (handler_id, created_by)
  values (v_id, auth.uid()) returning token into v_token;

  return jsonb_build_object('ok', true, 'name', v_name, 'token', v_token);
end $$;

-- ── 5. Big Boss: reset a forgotten password ───────────────────
create or replace function public.stock_handler_reset_password(p_name text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss may reset a password';
  end if;
  select h.id into v_id from public.stock_handlers h
   where upper(btrim(h.name)) = upper(btrim(coalesce(p_name, '')));
  if not found then
    raise exception 'That name is not on the stock staff list';
  end if;
  delete from public.stock_handler_tokens  where handler_id = v_id;
  delete from public.stock_handler_secrets where handler_id = v_id;
end $$;

-- ── 6. record_stock_movement checks the key ───────────────────
-- Dropped rather than overloaded: two versions differing only by a trailing
-- argument would make every call that leaves it out ambiguous.
drop function if exists public.record_stock_movement(uuid, text, text, text, text, text, jsonb, text, text, timestamptz, text);

create or replace function public.record_stock_movement(
  p_request_id uuid,
  p_kind       text,
  p_from_line  text,
  p_from       text,
  p_to_line    text,
  p_to         text,
  p_items      jsonb,
  p_party      text default null,
  p_note       text default null,
  p_when       timestamptz default now(),
  p_done_by    text default null,
  p_done_token uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_owner   uuid;
  v_result  jsonb;
  v_to      text := coalesce(p_to_line, 'main');
  v_from    text := coalesce(p_from_line, v_to);
  v_typed   text := btrim(coalesce(p_done_by, ''));
  v_name    text;
  v_handler uuid;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record stock movements';
  end if;
  if p_request_id is null then
    raise exception 'A request ID is required';
  end if;
  if v_to not in ('main', 'dahua') or v_from not in ('main', 'dahua') then
    raise exception 'Unknown stock line';
  end if;

  -- Stored as the list spells it, not as the phone sent it.
  if v_typed <> '' then
    select h.id, h.name into v_handler, v_name
      from public.stock_handlers h
     where upper(btrim(h.name)) = upper(v_typed);
    if not found then
      raise exception '% is not on the stock staff list', v_typed;
    end if;
  end if;

  begin
    insert into public.stock_movement_requests (request_id, created_by)
    values (p_request_id, auth.uid());
  exception when unique_violation then
    select created_by, result into v_owner, v_result
      from public.stock_movement_requests where request_id = p_request_id;
    if v_owner is distinct from auth.uid() then
      raise exception 'That request belongs to someone else';
    end if;
    return v_result || jsonb_build_object('duplicate', true);
  end;

  -- Checked after the duplicate test above, so a movement that was already
  -- saved still answers "already saved" even if the key has since changed.
  if v_handler is not null
     and exists (select 1 from public.stock_handler_secrets s where s.handler_id = v_handler)
     and not exists (select 1 from public.stock_handler_tokens t
                      where t.handler_id = v_handler and t.token = p_done_token) then
    raise exception '% must enter their password on this phone again before this can be saved', v_name;
  end if;

  if p_kind = 'move' then
    if v_from <> v_to then
      select to_jsonb(t) into v_result
        from public.cross_transfer_stock(v_from, p_from, v_to, p_to, p_items, p_note, p_when) t;
    elsif v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_transfer_stock(p_from, p_to, p_items, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.transfer_stock(p_from, p_to, p_items, p_note, p_when) t;
    end if;
  elsif p_kind = 'receive' then
    if v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_receive_stock(p_to, p_items, p_party, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.receive_stock(p_to, p_items, p_party, p_note, p_when) t;
    end if;
  elsif p_kind = 'return' then
    if v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_return_stock(p_to, p_items, p_party, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.return_stock(p_to, p_items, p_party, p_note, p_when) t;
    end if;
  else
    raise exception 'Unknown kind of movement: %', p_kind;
  end if;

  if v_name is not null then
    update public.stock_transfers
       set signed_by = v_name
     where transfer_number = v_result->>'transfer_number';
    update public.dahua_stock_transfers
       set signed_by = v_name
     where transfer_number = v_result->>'transfer_number';
    v_result := v_result || jsonb_build_object('signed_by', v_name);
  end if;

  update public.stock_movement_requests
     set result = v_result
   where request_id = p_request_id;

  return v_result;
end $$;

-- ── 7. Who may call what ──────────────────────────────────────
revoke all on function public.stock_handlers_list()                              from public, anon;
revoke all on function public.stock_handler_sign_in(text, text)                  from public, anon;
revoke all on function public.stock_handler_set_password(text, text, text)       from public, anon;
revoke all on function public.stock_handler_reset_password(text)                 from public, anon;
revoke all on function public.record_stock_movement(uuid, text, text, text, text, text, jsonb, text, text, timestamptz, text, uuid)
  from public, anon;
grant execute on function public.stock_handlers_list()                           to authenticated;
grant execute on function public.stock_handler_sign_in(text, text)               to authenticated;
grant execute on function public.stock_handler_set_password(text, text, text)    to authenticated;
grant execute on function public.stock_handler_reset_password(text)              to authenticated;
grant execute on function public.record_stock_movement(uuid, text, text, text, text, text, jsonb, text, text, timestamptz, text, uuid)
  to authenticated;

-- ── Verification ──────────────────────────────────────────────
-- Who has set a password:
--
-- select h.name, s.set_at, s.locked_until
--   from public.stock_handlers h
--   left join public.stock_handler_secrets s on s.handler_id = h.id
--  order by h.name;


-- ############################################################################
-- ## 20261007_delivery_from_invoice.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Deliveries logged from the invoice — 2026-10-07
--
-- A sale that is being delivered used to be entered twice: as an invoice,
-- then again in the Deliveries tab. The invoice forms now have a Delivery
-- switch that logs the delivery when the invoice is saved, so the Deliveries
-- tab is the list of them rather than a second form.
--
-- Two things a delivery logged that way knows that the table had no place
-- for: the customer's phone number, and which invoice it belongs to.
--
-- Until this is run the app still logs the delivery — it puts those two in
-- the note instead. Running this gives them columns of their own, which is
-- what lets the Deliveries tab show and search them properly.
--
-- Idempotent. Nothing existing is changed.
-- ─────────────────────────────────────────────────────────────

alter table public.deliveries
  add column if not exists customer_num   text,
  add column if not exists invoice_number text;

alter table public.dahua_deliveries
  add column if not exists customer_num   text,
  add column if not exists invoice_number text;

comment on column public.deliveries.customer_num is
  'The customer''s phone number, copied from the invoice when the delivery was switched on there.';
comment on column public.deliveries.invoice_number is
  'The invoice this delivery was logged from. Null when it was entered by hand in the Deliveries tab.';
comment on column public.dahua_deliveries.customer_num is
  'The customer''s phone number, copied from the invoice when the delivery was switched on there.';
comment on column public.dahua_deliveries.invoice_number is
  'The Dahua invoice this delivery was logged from. Null when it was entered by hand in the Deliveries tab.';

-- Finding the delivery for an invoice.
create index if not exists deliveries_invoice_number_idx
  on public.deliveries (invoice_number) where invoice_number is not null;
create index if not exists dahua_deliveries_invoice_number_idx
  on public.dahua_deliveries (invoice_number) where invoice_number is not null;

-- PostgREST keeps a copy of the table layout; tell it the columns exist now,
-- or the app would keep using the note for a while longer.
notify pgrst, 'reload schema';

-- ── Verification ──────────────────────────────────────────────
-- Deliveries logged from invoices, newest first:
--
-- select delivered_at, invoice_number, customer_name, customer_num, location, amount, payment_method
--   from public.deliveries
--  where invoice_number is not null
--  order by delivered_at desc
--  limit 50;


-- ############################################################################
-- ## 20261007_store_stock_lists_everything.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- STORE STOCK lists every product the shop carries — 2026-10-07
--
-- THE GAP
--   Invoices deduct from STORE STOCK, and only from STORE STOCK. A product
--   with no row there cannot be deducted: the sale is saved, the item is
--   reported as "not stocked in STORE STOCK", and no figure anywhere moves.
--   On 2026-10-07 the back warehouses carried 1,002 products and 806 of
--   them had no STORE STOCK row — 657 of those with units sitting in
--   another warehouse. Every one of those could be sold off the shop floor
--   without the system noticing.
--
-- WHAT THIS DOES
--   1. Gives STORE STOCK a row, at 0, for every product any other warehouse
--      stocks. Nothing that exists is changed: no quantity, no name, no
--      price. Only rows that were missing are added, and they hold nothing.
--
--   2. Keeps it that way. From now on, the moment a product first appears
--      in any warehouse — a delivery, a count, a row added in the Stock tab,
--      a scan — STORE STOCK gets its row too.
--
--   So a sale of something that was never transferred to the shop floor now
--   shows as -1 in STORE STOCK. That is not an error introduced here; it is
--   stock that left without a transfer, visible for the first time.
--
-- WHAT IS LEFT OUT
--   SPOILT. A written-off unit is not a product the shop carries, and a
--   product that exists ONLY in SPOILT gets no shop-floor row.
--
-- The Stock tab hides rows that have never held or moved anything, so the
-- 800 new zeros do not bury the rows that matter (a switch shows them).
--
-- Requires 20261005_model_key_keeps_decimals.sql. Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regprocedure('public.stock_model_key(text)') is null
     or public.stock_model_key('1.5') <> '1~5' then
    raise exception 'Run 20261005_model_key_keeps_decimals.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1. Keeping it true from now on ────────────────────────────
-- A trigger rather than a line in each function: stock rows are created in
-- six places (deliveries, returns, transfers, counts, the Stock tab, Scan)
-- and the next one written would forget.
--
-- Matched on the product code, not the exact spelling, so a product the
-- store already has under another spelling is not given a second row.
create or replace function public.fn_store_stock_lists_model()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.warehouse in ('STORE STOCK', 'SPOILT')
     or public.stock_model_key(new.model) = '' then
    return null;
  end if;
  -- A shop with no STORE STOCK location has nothing to keep in step.
  if not exists (select 1 from public.warehouses where name = 'STORE STOCK') then
    return null;
  end if;
  if not exists (
       select 1 from public.warehouse_stock s
        where s.warehouse = 'STORE STOCK'
          and public.stock_model_key(s.model) = public.stock_model_key(new.model)
     ) then
    insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken)
    values ('STORE STOCK', btrim(new.model), 0, '{}'::jsonb);
  end if;
  return null;
end $$;

drop trigger if exists trg_store_stock_lists_model on public.warehouse_stock;
create trigger trg_store_stock_lists_model
  after insert or update of model, warehouse on public.warehouse_stock
  for each row execute function public.fn_store_stock_lists_model();

-- ── 2. The rows that are missing today ────────────────────────
-- One block: every warehouse is added up before and after, and if any total
-- has moved the block is undone. Adding empty rows cannot change a total —
-- the check is there so that is proved rather than assumed.
do $fill$
declare
  v_before jsonb;
  v_after  jsonb;
  v_added  integer;
begin
  if not exists (select 1 from public.warehouses where name = 'STORE STOCK') then
    raise notice 'No STORE STOCK location — nothing to fill.';
    return;
  end if;

  select coalesce(jsonb_object_agg(warehouse, units), '{}'::jsonb) into v_before
    from (select warehouse, sum(closing_stock) as units from public.warehouse_stock group by warehouse) t;

  -- 800 empty rows are one event, not 800 entries in the activity log.
  alter table public.warehouse_stock disable trigger trg_audit_warehouse_stock;

  insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken)
  select 'STORE STOCK', m.model, 0, '{}'::jsonb
    from (
      -- One row per product code. Names are uniform since
      -- 20261005_uniform_names.sql; if a code still has two spellings, the
      -- one on the books longest is taken.
      select distinct on (public.stock_model_key(s.model)) btrim(s.model) as model
        from public.warehouse_stock s
       where s.warehouse not in ('STORE STOCK', 'SPOILT')
         and public.stock_model_key(s.model) <> ''
       order by public.stock_model_key(s.model), s.created_at, s.id::text
    ) m
   where not exists (
           select 1 from public.warehouse_stock st
            where st.warehouse = 'STORE STOCK'
              and public.stock_model_key(st.model) = public.stock_model_key(m.model)
         );
  get diagnostics v_added = row_count;

  alter table public.warehouse_stock enable trigger trg_audit_warehouse_stock;

  select coalesce(jsonb_object_agg(warehouse, units), '{}'::jsonb) into v_after
    from (select warehouse, sum(closing_stock) as units from public.warehouse_stock group by warehouse) t;

  if v_after <> v_before then
    raise exception 'A warehouse total changed — nothing has been saved. Before: %  After: %', v_before, v_after;
  end if;

  raise notice 'STORE STOCK now lists every product: % empty row(s) added. Every warehouse, STORE STOCK included, holds exactly what it held before.', v_added;
end $fill$;

-- ── Verification (run after the block above) ──────────────────
-- Products stocked somewhere but missing from STORE STOCK (expect 0 rows):
--
-- select distinct s.model
--   from public.warehouse_stock s
--  where s.warehouse not in ('STORE STOCK', 'SPOILT')
--    and not exists (select 1 from public.warehouse_stock st
--                     where st.warehouse = 'STORE STOCK'
--                       and public.stock_model_key(st.model) = public.stock_model_key(s.model));


-- ############################################################################
-- ## 20261010_delivery_is_the_sale.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- A delivered sale is logged at the invoice's amount — 2026-10-10
--
-- WHAT WENT WRONG
--   The Delivery switch on the invoice (0357b25) logged the delivery with a
--   separate "delivery fee", which staff left blank. So every delivery
--   switched on from an invoice was saved at GH₵ 0 — 7 in the main shop and
--   6 in Dahua by 2026-10-10 — and the Deliveries tab showed nothing against
--   them. Meanwhile the invoice itself went on being counted as an ordinary
--   sale, so the Sales page could not tell a delivery from a counter sale.
--
-- WHAT IS RIGHT
--   A sale with Delivery switched on IS a delivery: one sale, saved as an
--   invoice (the receipt) and as a delivery carrying the invoice's total and
--   payment method. The app now writes it that way, and the Sales page
--   counts it under Delivery and leaves its invoice out of ordinary sales.
--
-- THIS FILE
--   Brings the deliveries already logged at 0 up to their invoice's total
--   and payment method. Only rows that came from an invoice and still stand
--   at 0 are touched; a delivery typed by hand in the Deliveries tab has no
--   invoice and is left exactly as it is.
--
-- Requires 20261007_delivery_from_invoice.sql. Idempotent: a row already
-- carrying an amount is skipped.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'deliveries' and column_name = 'invoice_number'
  ) then
    raise exception 'Run 20261007_delivery_from_invoice.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

update public.deliveries d
   set amount         = i.total,
       payment_method = coalesce(nullif(btrim(i.payment_method), ''), d.payment_method)
  from public.invoices i
 where d.invoice_number = i.invoice_number
   and coalesce(d.amount, 0) = 0
   and coalesce(i.total, 0) > 0;

update public.dahua_deliveries d
   set amount         = i.total,
       payment_method = coalesce(nullif(btrim(i.payment_method), ''), d.payment_method)
  from public.dahua_invoices i
 where d.invoice_number = i.invoice_number
   and coalesce(d.amount, 0) = 0
   and coalesce(i.total, 0) > 0;

-- ── Verification ──────────────────────────────────────────────
-- Deliveries from invoices beside their invoice — the two amounts should
-- match on every row:
--
-- select d.invoice_number, d.customer_name, d.amount as delivery_amount, i.total as invoice_total, d.payment_method
--   from public.deliveries d
--   join public.invoices i on i.invoice_number = d.invoice_number
--  order by d.delivered_at desc;


-- ############################################################################
-- ## 20261011_clear_back_warehouse.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Clear BACK WAREHOUSE for a restock — 2026-10-11
--
-- BACK WAREHOUSE is being emptied on the books so it can be restocked from
-- a clean start. On 2026-10-11 it listed 244 products: 158 holding 17,371
-- units, 62 at zero, and 24 below zero (-601) — figures nobody trusts any
-- more, which is why it is being started again rather than corrected.
--
-- WHAT THIS DOES
--   Sets every BACK WAREHOUSE product to 0: the opening count, everything
--   taken, everything moved in and out. The product NAMES stay, and so do
--   their reorder levels, so the restock is booked against the names the
--   shop already uses instead of typing them in again.
--
-- WHAT IT DOES NOT TOUCH
--   Any other warehouse. STORE STOCK. Prices. Barcodes. Invoices. The
--   movement history — every past transfer in and out of BACK WAREHOUSE is
--   still on record, it just no longer adds up to today's figure.
--
-- THE OLD FIGURES ARE KEPT
--   Before anything is zeroed, every row is copied into
--   stock_clearances, in the same transaction. If this turns out to have
--   been run at the wrong moment, the figures can be put back from there
--   (see the end of this file).
--
-- RUN IT WHEN THE WAREHOUSE IS READY TO BE COUNTED IN
--   Anything moved out of BACK WAREHOUSE on the system after this runs
--   starts from 0 and will show as negative until the restock is entered.
--   Run this, then enter the restock — with Receive (a delivery from
--   outside) or a transfer in — the same day.
--
-- One block: all of it or none of it. Safe to run twice — a row already at
-- zero is neither copied again nor changed.
-- ─────────────────────────────────────────────────────────────

-- ── Where cleared figures are kept ────────────────────────────
create table if not exists public.stock_clearances (
  id            uuid primary key default gen_random_uuid(),
  cleared_at    timestamptz not null default now(),
  warehouse     text not null,
  stock_id      uuid,
  model         text not null,
  opening_stock integer,
  transfer_in   integer,
  transfer_out  integer,
  invoice_taken integer,
  total_taken   integer,
  closing_stock integer,
  daily_taken   jsonb,
  min_level     integer
);
create index if not exists stock_clearances_warehouse_idx on public.stock_clearances (warehouse, cleared_at desc);
alter table public.stock_clearances enable row level security;

-- The Big Boss can read what was cleared; nobody edits it from the app.
drop policy if exists stock_clearances_read on public.stock_clearances;
drop policy if exists stock_clearances_read on public.stock_clearances;

create policy stock_clearances_read on public.stock_clearances
  for select to authenticated using ((select public.is_superboss()));

do $clear$
declare
  v_wh      constant text := 'BACK WAREHOUSE';
  v_others  jsonb;
  v_after   jsonb;
  v_rows    integer;
  v_units   bigint;
  v_kept    integer;
  v_left    bigint;
begin
  if not exists (select 1 from public.warehouses where name = v_wh) then
    raise exception 'There is no location called %', v_wh;
  end if;

  -- Every other warehouse, added up, to prove afterwards that none moved.
  select coalesce(jsonb_object_agg(warehouse, units), '{}'::jsonb) into v_others
    from (select warehouse, sum(closing_stock) as units
            from public.warehouse_stock where warehouse <> v_wh group by warehouse) t;

  select count(*), coalesce(sum(closing_stock), 0) into v_rows, v_units
    from public.warehouse_stock where warehouse = v_wh;

  -- Keep the figures as they stand. Rows that are already empty have
  -- nothing worth keeping, which is also what makes a second run harmless.
  insert into public.stock_clearances
    (warehouse, stock_id, model, opening_stock, transfer_in, transfer_out,
     invoice_taken, total_taken, closing_stock, daily_taken, min_level)
  select s.warehouse, s.id, s.model, s.opening_stock, s.transfer_in, s.transfer_out,
         s.invoice_taken, s.total_taken, s.closing_stock, s.daily_taken, s.min_level
    from public.warehouse_stock s
   where s.warehouse = v_wh
     and (coalesce(s.opening_stock, 0) <> 0 or coalesce(s.transfer_in, 0) <> 0
          or coalesce(s.transfer_out, 0) <> 0 or coalesce(s.invoice_taken, 0) <> 0
          or coalesce(s.daily_taken, '{}'::jsonb) <> '{}'::jsonb);
  get diagnostics v_kept = row_count;

  -- 244 rows zeroed is one event, not 244 entries in the activity log.
  alter table public.warehouse_stock disable trigger trg_audit_warehouse_stock;

  -- total_taken, closing_stock and stock_status follow from these through
  -- trg_warehouse_stock_derive. min_level and the name are left alone.
  update public.warehouse_stock
     set opening_stock = 0,
         daily_taken   = '{}'::jsonb,
         invoice_taken = 0,
         transfer_in   = 0,
         transfer_out  = 0
   where warehouse = v_wh
     and (coalesce(opening_stock, 0) <> 0 or coalesce(transfer_in, 0) <> 0
          or coalesce(transfer_out, 0) <> 0 or coalesce(invoice_taken, 0) <> 0
          or coalesce(daily_taken, '{}'::jsonb) <> '{}'::jsonb);

  alter table public.warehouse_stock enable trigger trg_audit_warehouse_stock;

  select coalesce(sum(abs(closing_stock)), 0) into v_left
    from public.warehouse_stock where warehouse = v_wh;
  if v_left <> 0 then
    raise exception '% did not come out empty (% units left) — nothing has been saved.', v_wh, v_left;
  end if;

  select coalesce(jsonb_object_agg(warehouse, units), '{}'::jsonb) into v_after
    from (select warehouse, sum(closing_stock) as units
            from public.warehouse_stock where warehouse <> v_wh group by warehouse) t;
  if v_after <> v_others then
    raise exception 'Another warehouse changed — nothing has been saved. Before: %  After: %', v_others, v_after;
  end if;

  raise notice '% cleared: % products now at 0 (it showed % units). % rows of old figures kept in stock_clearances. No other warehouse changed.',
    v_wh, v_rows, v_units, v_kept;
end $clear$;

-- ── Verification (run after the block above) ──────────────────
-- Expect one row: 244 products, 0 units.
--
-- select count(*) as products, sum(closing_stock) as units
--   from public.warehouse_stock where warehouse = 'BACK WAREHOUSE';
--
-- What it held before it was cleared:
--
-- select model, closing_stock from public.stock_clearances
--  where warehouse = 'BACK WAREHOUSE' order by cleared_at desc, model;
--
-- ── Putting the old figures back, if this was run too early ───
-- Only before any restock has been entered — it overwrites what is there.
--
-- update public.warehouse_stock s
--    set opening_stock = c.opening_stock, daily_taken = c.daily_taken,
--        invoice_taken = c.invoice_taken, transfer_in = c.transfer_in, transfer_out = c.transfer_out
--   from public.stock_clearances c
--  where c.stock_id = s.id
--    and c.cleared_at = (select max(cleared_at) from public.stock_clearances where warehouse = 'BACK WAREHOUSE');


-- ############################################################################
-- ## 20261013_debtors.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Debtors — sales on credit, and what has been paid against them
-- 2026-10-13
--
-- Some customers take goods now and pay bit by bit. Until now such a sale
-- was an ordinary invoice: it counted as money in on the day it was written,
-- and nothing recorded what was still owed or what had come in since.
--
-- HOW IT WORKS NOW
--   The invoice forms have an "On credit" switch. A sale saved with it on
--   gets a row here in `debts` — who owes, on which invoice, how much — and
--   each payment the customer makes afterwards is a row in `debt_payments`.
--   What is still owed is the debt's total less its payments.
--
-- WHAT THE SALES PAGE COUNTS
--   A credit sale is NOT counted as sales when it is written. Each payment
--   IS counted, on the day it is received, in the method it was paid by. So
--   Sales shows money that has actually come in, and the Debtors tab shows
--   the money that has not. The invoice is still the invoice — printed,
--   numbered, and its stock deducted at once: the goods have left.
--
-- ONE TABLE FOR BOTH LINES
--   `line` says whether the invoice is a main-shop one or a Dahua one. The
--   invoice is referred to by id and number rather than a foreign key,
--   because the two lines keep their invoices in two tables.
--
-- WHO CAN DO WHAT
--   Any staff login can see debts and record a payment — a customer pays
--   whoever is at the counter. A payment cannot take a debt below zero.
--   Only the Big Boss can remove a payment or a debt.
--
-- Idempotent.
-- ─────────────────────────────────────────────────────────────

create table if not exists public.debts (
  id             uuid primary key default gen_random_uuid(),
  line           text not null default 'main' check (line in ('main', 'dahua')),
  invoice_id     uuid not null,
  invoice_number text not null,
  customer_name  text not null,
  customer_num   text,
  customer_loc   text,
  total          numeric(12,2) not null check (total > 0),
  -- Kept in step by the trigger below, so lists need not add up payments.
  paid           numeric(12,2) not null default 0,
  settled_at     timestamptz,
  issued_at      timestamptz not null default now(),
  created_by     uuid references auth.users(id) on delete set null,
  created_at     timestamptz not null default now(),
  unique (line, invoice_id)
);
create index if not exists debts_open_idx on public.debts (line, issued_at desc) where settled_at is null;
create index if not exists debts_invoice_number_idx on public.debts (invoice_number);

create table if not exists public.debt_payments (
  id             uuid primary key default gen_random_uuid(),
  debt_id        uuid not null references public.debts(id) on delete cascade,
  amount         numeric(12,2) not null check (amount > 0),
  payment_method text not null default 'Cash',
  paid_at        timestamptz not null default now(),
  note           text,
  created_by     uuid references auth.users(id) on delete set null,
  created_at     timestamptz not null default now()
);
create index if not exists debt_payments_debt_idx on public.debt_payments (debt_id);
create index if not exists debt_payments_paid_at_idx on public.debt_payments (paid_at desc);

-- ── A payment cannot overpay, and the debt keeps its own running total ──
create or replace function public.fn_debt_payment_check()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_total numeric(12,2);
  v_paid  numeric(12,2);
begin
  -- Locked, so two tills taking a payment on one debt at the same moment
  -- cannot both be told there is room for theirs.
  select total into v_total from public.debts where id = new.debt_id for update;
  if not found then
    raise exception 'That debt no longer exists';
  end if;
  select coalesce(sum(amount), 0) into v_paid
    from public.debt_payments
   where debt_id = new.debt_id and id is distinct from new.id;
  if v_paid + new.amount > v_total + 0.005 then
    raise exception 'That is more than is owed — % is left to pay', to_char(v_total - v_paid, 'FM999,999,990.00');
  end if;
  return new;
end $$;

drop trigger if exists trg_debt_payment_check on public.debt_payments;
create trigger trg_debt_payment_check
  before insert or update of amount, debt_id on public.debt_payments
  for each row execute function public.fn_debt_payment_check();

create or replace function public.fn_debt_resync()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_debt uuid := coalesce(new.debt_id, old.debt_id);
  v_paid numeric(12,2);
begin
  select coalesce(sum(amount), 0) into v_paid from public.debt_payments where debt_id = v_debt;
  update public.debts d
     set paid       = v_paid,
         settled_at = case when v_paid >= d.total - 0.005 then coalesce(d.settled_at, now()) else null end
   where d.id = v_debt;
  return null;
end $$;

drop trigger if exists trg_debt_resync on public.debt_payments;
create trigger trg_debt_resync
  after insert or update or delete on public.debt_payments
  for each row execute function public.fn_debt_resync();

-- ── RLS ───────────────────────────────────────────────────────
alter table public.debts         enable row level security;
alter table public.debt_payments enable row level security;

drop policy if exists debts_read on public.debts;
drop policy if exists debts_read on public.debts;

create policy debts_read on public.debts
  for select to authenticated
  using ((select public.is_boss()) or (select public.is_cashier()));

drop policy if exists debts_insert on public.debts;
drop policy if exists debts_insert on public.debts;

create policy debts_insert on public.debts
  for insert to authenticated
  with check (((select public.is_superboss()) or (select public.is_cashier())) and created_by = (select auth.uid()));

drop policy if exists debts_superboss_write on public.debts;
drop policy if exists debts_superboss_write on public.debts;

create policy debts_superboss_write on public.debts
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists debt_payments_read on public.debt_payments;
drop policy if exists debt_payments_read on public.debt_payments;

create policy debt_payments_read on public.debt_payments
  for select to authenticated
  using ((select public.is_boss()) or (select public.is_cashier()));

drop policy if exists debt_payments_insert on public.debt_payments;
drop policy if exists debt_payments_insert on public.debt_payments;

create policy debt_payments_insert on public.debt_payments
  for insert to authenticated
  with check (((select public.is_superboss()) or (select public.is_cashier())) and created_by = (select auth.uid()));

drop policy if exists debt_payments_superboss_write on public.debt_payments;
drop policy if exists debt_payments_superboss_write on public.debt_payments;

create policy debt_payments_superboss_write on public.debt_payments
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

-- ── Audit ─────────────────────────────────────────────────────
drop trigger if exists trg_audit_debts on public.debts;
create trigger trg_audit_debts
  after insert or delete on public.debts
  for each row execute function public.fn_audit();

drop trigger if exists trg_audit_debt_payments on public.debt_payments;
create trigger trg_audit_debt_payments
  after insert or update or delete on public.debt_payments
  for each row execute function public.fn_audit();

notify pgrst, 'reload schema';

-- ── Verification ──────────────────────────────────────────────
-- Who owes what, largest first:
--
-- select line, customer_name, customer_num, invoice_number, total, paid, total - paid as owed, issued_at
--   from public.debts
--  where settled_at is null
--  order by total - paid desc;


-- ############################################################################
-- ## 20261014_fishpong2_tenda_stock.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- FISHPONG-2: Tenda stock sheet — 2026-10-14
--
-- The "FISHPOND 2 WH" sheet: 27 Tenda products, 1,036 units, booked into
-- FISHPONG-2.
--
-- HOW IT IS ENTERED
--   As a delivery (an RCV movement), exactly as Receive in the Transfers
--   tab would do it — not by overwriting counts. So:
--     • a product FISHPONG-2 already stocks gets these units ADDED to it;
--     • a new product gets its row, and STORE STOCK gets its empty row too
--       (20261007_store_stock_lists_everything.sql);
--     • the sheet appears in the movement history under one RCV number, so
--       "where did these 155 AC5 routers come from" has an answer.
--
-- HOW THE SHEET WAS READ
--   "CODE-Tenda description=Npcs" became "CODE Tenda description", so each
--   name starts with the model code staff search by.
--
--   N301 is booked as "N301" — the name STORE STOCK already uses for it —
--   rather than a new spelling.
--
--   Left OUT, because the sheet gives no quantity:
--     TEF1105P-4-63W Tenda 5-Port 10/100Mbps Desktop Switch with 4-Port PoE
--   Add it with Receive once it has been counted.
--
--   Kept as written, but worth a look on the shelf: "01-5G" — Tenda sells
--   this CPE as O1-5G (letter O, not zero). If the box says O1-5G, rename it
--   in Transfers → Product names so the name matches what is scanned.
--
-- Safe to run twice: if this sheet has already been entered, it stops.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regprocedure('public.stock_book_in(text, text, integer)') is null then
    raise exception 'Run 20261005_no_duplicate_names_on_moves.sql first — this file books stock in with it.'
      using errcode = '42P01';
  end if;
end $$;

do $sheet$
declare
  v_note  constant text := 'FISHPOND 2 WH stock sheet (Tenda), 2026-10-14';
  v_wh    constant text := 'FISHPONG-2';
  v_rec   public.stock_transfers;
  v_item  record;
  v_name  text;
  v_pos   integer := 0;
  v_units integer := 0;
  v_before bigint;
begin
  if not exists (select 1 from public.warehouses where name = v_wh) then
    raise exception 'There is no location called %', v_wh;
  end if;
  if exists (select 1 from public.stock_transfers where kind = 'receive' and note = v_note) then
    raise notice 'This sheet has already been entered — nothing done.';
    return;
  end if;

  select coalesce(sum(closing_stock), 0) into v_before from public.warehouse_stock where warehouse = v_wh;

  v_rec := public.stock_movement_open('receive', null, v_wh, 'Tenda', v_note, now());
  -- Entered from the SQL editor, so there is no login to stamp it with.
  update public.stock_transfers set signed_by = 'Stock sheet, entered by the office' where id = v_rec.id;

  for v_item in
    select * from (values
      ('TEF1109P-8-63W Tenda 9-Port 10/100Mbps Desktop Switch With 8-Port PoE', 10),
      ('TEF1118P-16-150W Tenda 16FE+2GE/1SFP Desktop Switch With 16-Port PoE', 15),
      ('TEF1126P-24-250W Tenda 24FE+2GE/1SFP Rackmount Switch With 24-Port PoE', 33),
      ('TEG1105P-4-63W Tenda 5-Port Gigabit Desktop Switch with 4-Port PoE', 53),
      ('TEG1110PF-8-120W Tenda 9GE+1SFP Ethernet Switch With 8-Port PoE', 53),
      ('TEG1120P-16-150W Tenda 18GE+2SFP Ethernet Unmanaged Switch With16-Port PoE', 53),
      ('TEG1120P-16-250W Tenda 18GE+2SFP Ethernet Unmanaged Switch With16-Port PoE', 50),
      ('TEG1128P-24-250W Tenda 26GE+2SFP Ethernet Unmanaged Switch With24-Port PoE', 8),
      ('TEG1128P-24-410W Tenda 26GE+2SFP Ethernet Unmanaged Switch With24-Port PoE', 9),
      ('N301', 1),
      ('AC5 Tenda AC1200 Dual-Band Wireless Router', 155),
      ('AC10 Tenda AC1200 Dual-Band Gigabit Wireless Router', 34),
      ('TX2L Pro Tenda AX1500 Dual-Band Gigabit Wi-Fi 6 Router', 15),
      ('TEL Tenda BE3600 Dual-Band Wi-Fi 7 Router', 5),
      ('4G03 Pro Tenda N300 Wi-Fi 4G LTE Router', 143),
      ('4G06 Tenda N300 Wi-Fi 4G VoLTE Router', 90),
      ('A18 Tenda AC1200 Dual-band Range Extender', 46),
      ('A21 Tenda AC2100 Gigabit Dual-Band Wireless Signal Extender', 30),
      ('A27 Tenda AX1800 Wi-Fi 6 Dual-Band Wireless Signal Extender', 10),
      ('A9 Tenda N300 Range Extender', 177),
      ('01-5G Tenda 5GHz 9dBi 11AC 867Mbps Outdoor CPE', 5),
      ('OS3 Tenda 5GHz 12dBi 11AC 867Mbps Outdoor CPE', 5),
      ('CP3 Tenda 3MP Security Pan/Tilt Camera', 5),
      ('CP3 Pro Tenda 3MP Security Pan/Tilt Camera', 5),
      ('CH3-WCA Tenda 1080P Outdoor Wi-Fi Pan/Tilt Camera', 5),
      ('CH7-WCA Tenda 4MP Outdoor Wi-Fi Pan/Tilt Camera', 5),
      ('CH9-WCA Tenda 6MP Dual-lens Linkage Outdoor Wi-Fi Pan/Tilt Camera', 16)
    ) as t(model, qty)
  loop
    -- Joins the row FISHPONG-2 already has for the product, under any
    -- spelling of the same code; otherwise creates it.
    v_name := public.stock_book_in(v_wh, v_item.model, v_item.qty);
    v_pos := v_pos + 1;
    v_units := v_units + v_item.qty;
    insert into public.stock_transfer_items (transfer_id, model, quantity, from_before, position)
    values (v_rec.id, v_name, v_item.qty, null, v_pos);
  end loop;

  if (select coalesce(sum(closing_stock), 0) from public.warehouse_stock where warehouse = v_wh) <> v_before + v_units then
    raise exception 'FISHPONG-2 did not go up by exactly % units — nothing has been saved.', v_units;
  end if;

  raise notice '% — % products, % units booked into %.', v_rec.transfer_number, v_pos, v_units, v_wh;
end $sheet$;

-- ── Verification ──────────────────────────────────────────────
-- select model, closing_stock from public.warehouse_stock
--  where warehouse = 'FISHPONG-2' and (model ilike '%tenda%' or model = 'N301')
--  order by model;


-- ############################################################################
-- ## 20261017_dahua_movement_approval.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Dahua stock moves wait for the Big Boss's approval — 2026-10-17
--
-- Until now a Dahua move, delivery or return entered by staff changed the
-- stock the moment it was saved. From now on, one entered by staff is a
-- REQUEST: it is listed for the Big Boss, and only when he approves it does
-- the stock change. If he rejects it, nothing changes.
--
--   staff save a Dahua movement   →  a request, DH-REQ-2026-0001, "pending"
--   Big Boss approves it          →  the movement is made, as before, under
--                                    its usual DH-TRF / DH-RCV / DH-RNA (or
--                                    XTR) number, credited to the staff
--                                    member who asked, at the time they asked
--   Big Boss rejects it           →  marked rejected, with his reason; the
--                                    stock is untouched
--
-- What counts as a Dahua movement: a move between Dahua warehouses, a
-- delivery or return into a Dahua warehouse, and a move between the main
-- shop and Dahua (in either direction). Main-shop movements are unchanged.
--
-- The Big Boss's own movements are applied at once — he is the approver.
--
-- HOW IT IS ENFORCED
--   In the database, not just on screen. The four functions that change
--   Dahua stock are renamed to *_apply and replaced by thin versions that
--   let only the Big Boss through. Staff — from the Dahua portal, the main
--   Transfers tab or the phone app — go through request_dahua_movement(),
--   and record_stock_movement() (the phone app's path) turns their Dahua
--   movements into requests by itself.
--
--   NOTE FOR LATER MIGRATIONS: change the *_apply functions, not the thin
--   ones. Replacing dahua_transfer_stock() with a full body again would
--   switch the approval step off.
--
-- Requires 20261006_stock_staff_passwords.sql and
-- 20261005_no_duplicate_names_on_moves.sql. Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regprocedure('public.record_stock_movement(uuid, text, text, text, text, text, jsonb, text, text, timestamptz, text, uuid)') is null then
    raise exception 'Run 20261006_stock_staff_passwords.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1. The functions that move Dahua stock become *_apply ─────
do $$
begin
  if to_regprocedure('public.dahua_transfer_stock_apply(text, text, jsonb, text, timestamptz)') is null then
    alter function public.dahua_transfer_stock(text, text, jsonb, text, timestamptz) rename to dahua_transfer_stock_apply;
  end if;
  if to_regprocedure('public.dahua_receive_stock_apply(text, jsonb, text, text, timestamptz)') is null then
    alter function public.dahua_receive_stock(text, jsonb, text, text, timestamptz) rename to dahua_receive_stock_apply;
  end if;
  if to_regprocedure('public.dahua_return_stock_apply(text, jsonb, text, text, timestamptz, text)') is null then
    alter function public.dahua_return_stock(text, jsonb, text, text, timestamptz, text) rename to dahua_return_stock_apply;
  end if;
  if to_regprocedure('public.cross_transfer_stock_apply(text, text, text, text, jsonb, text, timestamptz)') is null then
    alter function public.cross_transfer_stock(text, text, text, text, jsonb, text, timestamptz) rename to cross_transfer_stock_apply;
  end if;
end $$;

-- Reachable only through the thin versions below and the approval step.
revoke all on function public.dahua_transfer_stock_apply(text, text, jsonb, text, timestamptz)                from public, anon, authenticated;
revoke all on function public.dahua_receive_stock_apply(text, jsonb, text, text, timestamptz)                 from public, anon, authenticated;
revoke all on function public.dahua_return_stock_apply(text, jsonb, text, text, timestamptz, text)            from public, anon, authenticated;
revoke all on function public.cross_transfer_stock_apply(text, text, text, text, jsonb, text, timestamptz)    from public, anon, authenticated;

-- ── 2. The thin versions: the Big Boss straight through, staff refused ──
create or replace function public.dahua_needs_approval()
returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not (select public.is_superboss()) then
    raise exception 'A Dahua stock movement by staff needs the Big Boss''s approval — send it for approval instead.'
      using errcode = '42501';
  end if;
end $$;

create or replace function public.dahua_transfer_stock(
  p_from text, p_to text, p_items jsonb, p_note text default null, p_when timestamptz default now()
) returns public.dahua_stock_transfers
language plpgsql security definer set search_path = public as $$
begin
  perform public.dahua_needs_approval();
  return public.dahua_transfer_stock_apply(p_from, p_to, p_items, p_note, p_when);
end $$;

create or replace function public.dahua_receive_stock(
  p_to text, p_items jsonb, p_supplier text default null, p_note text default null, p_when timestamptz default now()
) returns public.dahua_stock_transfers
language plpgsql security definer set search_path = public as $$
begin
  perform public.dahua_needs_approval();
  return public.dahua_receive_stock_apply(p_to, p_items, p_supplier, p_note, p_when);
end $$;

create or replace function public.dahua_return_stock(
  p_to text, p_items jsonb, p_customer text default null, p_note text default null, p_when timestamptz default now(), p_spoilt text default 'SPOILT'
) returns public.dahua_stock_transfers
language plpgsql security definer set search_path = public as $$
begin
  perform public.dahua_needs_approval();
  return public.dahua_return_stock_apply(p_to, p_items, p_customer, p_note, p_when, p_spoilt);
end $$;

-- Every move between the main shop and Dahua changes Dahua stock on one side.
create or replace function public.cross_transfer_stock(
  p_from_line text, p_from text, p_to_line text, p_to text, p_items jsonb, p_note text default null, p_when timestamptz default now()
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
begin
  perform public.dahua_needs_approval();
  return public.cross_transfer_stock_apply(p_from_line, p_from, p_to_line, p_to, p_items, p_note, p_when);
end $$;

grant execute on function public.dahua_transfer_stock(text, text, jsonb, text, timestamptz)              to authenticated;
grant execute on function public.dahua_receive_stock(text, jsonb, text, text, timestamptz)               to authenticated;
grant execute on function public.dahua_return_stock(text, jsonb, text, text, timestamptz, text)          to authenticated;
grant execute on function public.cross_transfer_stock(text, text, text, text, jsonb, text, timestamptz)  to authenticated;

-- ── 3. Requests ───────────────────────────────────────────────
create table if not exists public.dahua_movement_requests (
  id                 uuid primary key default gen_random_uuid(),
  request_number     text not null unique,
  kind               text not null check (kind in ('move', 'receive', 'return')),
  from_line          text check (from_line in ('main', 'dahua')),
  from_warehouse     text,
  to_line            text not null check (to_line in ('main', 'dahua')),
  to_warehouse       text not null,
  items              jsonb not null,
  party              text,       -- the supplier on a delivery, the buyer on a return
  note               text,
  requested_at       timestamptz not null default now(),
  requested_by       uuid references auth.users(id) on delete set null,
  requested_staff_id text,       -- the login it was asked from
  requested_name     text,       -- the person: the name tapped on the phone, or the login's name
  status             text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  decided_at         timestamptz,
  decided_by         uuid references auth.users(id) on delete set null,
  reject_reason      text,
  transfer_number    text        -- the movement it became, once approved
);
create index if not exists dahua_movement_requests_pending_idx on public.dahua_movement_requests (requested_at) where status = 'pending';
create index if not exists dahua_movement_requests_when_idx on public.dahua_movement_requests (requested_at desc);

alter table public.dahua_movement_requests enable row level security;
-- Bosses see every request; staff see their own, to know what became of them.
drop policy if exists dahua_movement_requests_read on public.dahua_movement_requests;
drop policy if exists dahua_movement_requests_read on public.dahua_movement_requests;

create policy dahua_movement_requests_read on public.dahua_movement_requests
  for select to authenticated
  using ((select public.is_boss()) or requested_by = (select auth.uid()));
-- Written only by the functions below.

drop trigger if exists trg_audit_dahua_movement_requests on public.dahua_movement_requests;
create trigger trg_audit_dahua_movement_requests
  after insert or update or delete on public.dahua_movement_requests
  for each row execute function public.fn_audit();

-- ── 4. Asking ─────────────────────────────────────────────────
create or replace function public.request_dahua_movement(
  p_kind      text,
  p_from_line text,
  p_from      text,
  p_to_line   text,
  p_to        text,
  p_items     jsonb,
  p_party     text default null,
  p_note      text default null,
  p_when      timestamptz default now(),
  p_done_by   text default null
) returns public.dahua_movement_requests
language plpgsql security definer set search_path = public as $$
declare
  v_rec   public.dahua_movement_requests;
  v_to    text := coalesce(p_to_line, 'dahua');
  v_from  text := case when p_kind = 'move' then coalesce(p_from_line, v_to) else null end;
  v_yr    text := to_char(now(), 'YYYY');
  v_n     text;
  v_try   integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record stock movements';
  end if;
  if p_kind not in ('move', 'receive', 'return') then
    raise exception 'Unknown kind of movement: %', p_kind;
  end if;
  if v_to not in ('main', 'dahua') or (v_from is not null and v_from not in ('main', 'dahua')) then
    raise exception 'Unknown stock line';
  end if;
  if v_to <> 'dahua' and coalesce(v_from, '') <> 'dahua' then
    raise exception 'Only Dahua stock movements go for approval';
  end if;
  if p_to is null or btrim(p_to) = '' then
    raise exception 'Where is the stock going?';
  end if;
  if p_kind = 'move' and (p_from is null or btrim(p_from) = '' or (p_from = p_to and v_from = v_to)) then
    raise exception 'A transfer needs two different locations';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Add at least one item';
  end if;

  for v_try in 1..8 loop
    begin
      select 'DH-REQ-' || v_yr || '-' || lpad((count(*) + 1)::text, 4, '0') into v_n
        from public.dahua_movement_requests where request_number like 'DH-REQ-' || v_yr || '-%';
      insert into public.dahua_movement_requests
        (request_number, kind, from_line, from_warehouse, to_line, to_warehouse, items, party, note,
         requested_at, requested_by, requested_staff_id, requested_name)
      values
        (v_n, p_kind, v_from, case when p_kind = 'move' then p_from end, v_to, p_to, p_items,
         nullif(btrim(coalesce(p_party, '')), ''), nullif(btrim(coalesce(p_note, '')), ''),
         coalesce(p_when, now()), auth.uid(), public.current_staff_id(),
         coalesce(nullif(btrim(coalesce(p_done_by, '')), ''), public.current_staff_name()))
      returning * into v_rec;
      return v_rec;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;
end $$;

-- ── 5. Approving and rejecting ────────────────────────────────
create or replace function public.approve_dahua_movement(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_req    public.dahua_movement_requests;
  v_number text;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss can approve stock movements';
  end if;
  select * into v_req from public.dahua_movement_requests where id = p_id for update;
  if not found then
    raise exception 'That request no longer exists';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'That request was already %', v_req.status;
  end if;

  -- Made exactly as it would have been if it had been applied at once, and
  -- dated when it was asked for, not when it was approved.
  if v_req.kind = 'move' and v_req.from_line <> v_req.to_line then
    select t.transfer_number into v_number
      from public.cross_transfer_stock_apply(v_req.from_line, v_req.from_warehouse, v_req.to_line, v_req.to_warehouse,
                                             v_req.items, v_req.note, v_req.requested_at) t;
  elsif v_req.kind = 'move' then
    select t.transfer_number into v_number
      from public.dahua_transfer_stock_apply(v_req.from_warehouse, v_req.to_warehouse, v_req.items, v_req.note, v_req.requested_at) t;
  elsif v_req.kind = 'receive' then
    select t.transfer_number into v_number
      from public.dahua_receive_stock_apply(v_req.to_warehouse, v_req.items, v_req.party, v_req.note, v_req.requested_at) t;
  else
    select t.transfer_number into v_number
      from public.dahua_return_stock_apply(v_req.to_warehouse, v_req.items, v_req.party, v_req.note, v_req.requested_at, 'SPOILT') t;
  end if;

  -- The movement is the staff member's, not the approver's.
  update public.dahua_stock_transfers
     set signed_by = v_req.requested_name, staff_id = v_req.requested_staff_id,
         created_by = coalesce(v_req.requested_by, created_by)
   where transfer_number = v_number;
  update public.stock_transfers
     set signed_by = v_req.requested_name, staff_id = v_req.requested_staff_id,
         created_by = coalesce(v_req.requested_by, created_by)
   where transfer_number = v_number;

  update public.dahua_movement_requests
     set status = 'approved', decided_at = now(), decided_by = auth.uid(), transfer_number = v_number
   where id = p_id;

  return jsonb_build_object('request_number', v_req.request_number, 'transfer_number', v_number);
end $$;

create or replace function public.reject_dahua_movement(p_id uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_status text;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss can reject stock movements';
  end if;
  select status into v_status from public.dahua_movement_requests where id = p_id for update;
  if not found then
    raise exception 'That request no longer exists';
  end if;
  if v_status <> 'pending' then
    raise exception 'That request was already %', v_status;
  end if;
  update public.dahua_movement_requests
     set status = 'rejected', decided_at = now(), decided_by = auth.uid(),
         reject_reason = nullif(btrim(coalesce(p_reason, '')), '')
   where id = p_id;
end $$;

revoke all on function public.request_dahua_movement(text, text, text, text, text, jsonb, text, text, timestamptz, text) from public, anon;
revoke all on function public.approve_dahua_movement(uuid)       from public, anon;
revoke all on function public.reject_dahua_movement(uuid, text)  from public, anon;
revoke all on function public.dahua_needs_approval()             from public, anon;
grant execute on function public.request_dahua_movement(text, text, text, text, text, jsonb, text, text, timestamptz, text) to authenticated;
grant execute on function public.approve_dahua_movement(uuid)      to authenticated;
grant execute on function public.reject_dahua_movement(uuid, text) to authenticated;
grant execute on function public.dahua_needs_approval()            to authenticated;

-- ── 6. The phone app's path turns staff Dahua movements into requests ──
-- Same as in 20261006_stock_staff_passwords.sql, with one step added before
-- the movement is made: a Dahua movement by staff is filed as a request and
-- answered with {"pending": true, ...} instead.
create or replace function public.record_stock_movement(
  p_request_id uuid,
  p_kind       text,
  p_from_line  text,
  p_from       text,
  p_to_line    text,
  p_to         text,
  p_items      jsonb,
  p_party      text default null,
  p_note       text default null,
  p_when       timestamptz default now(),
  p_done_by    text default null,
  p_done_token uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_owner   uuid;
  v_result  jsonb;
  v_to      text := coalesce(p_to_line, 'main');
  v_from    text := coalesce(p_from_line, v_to);
  v_typed   text := btrim(coalesce(p_done_by, ''));
  v_name    text;
  v_handler uuid;
  v_req     public.dahua_movement_requests;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record stock movements';
  end if;
  if p_request_id is null then
    raise exception 'A request ID is required';
  end if;
  if v_to not in ('main', 'dahua') or v_from not in ('main', 'dahua') then
    raise exception 'Unknown stock line';
  end if;

  if v_typed <> '' then
    select h.id, h.name into v_handler, v_name
      from public.stock_handlers h
     where upper(btrim(h.name)) = upper(v_typed);
    if not found then
      raise exception '% is not on the stock staff list', v_typed;
    end if;
  end if;

  begin
    insert into public.stock_movement_requests (request_id, created_by)
    values (p_request_id, auth.uid());
  exception when unique_violation then
    select created_by, result into v_owner, v_result
      from public.stock_movement_requests where request_id = p_request_id;
    if v_owner is distinct from auth.uid() then
      raise exception 'That request belongs to someone else';
    end if;
    return v_result || jsonb_build_object('duplicate', true);
  end;

  if v_handler is not null
     and exists (select 1 from public.stock_handler_secrets s where s.handler_id = v_handler)
     and not exists (select 1 from public.stock_handler_tokens t
                      where t.handler_id = v_handler and t.token = p_done_token) then
    raise exception '% must enter their password on this phone again before this can be saved', v_name;
  end if;

  -- A Dahua movement by staff goes to the Big Boss for approval.
  if not (select public.is_superboss())
     and (v_to = 'dahua' or (p_kind = 'move' and v_from = 'dahua')) then
    select * into v_req
      from public.request_dahua_movement(p_kind, case when p_kind = 'move' then v_from end, p_from, v_to, p_to,
                                         p_items, p_party, p_note, p_when, v_name);
    v_result := jsonb_build_object(
      'pending', true, 'request_number', v_req.request_number,
      'transfer_number', v_req.request_number, 'kind', p_kind,
      'to_warehouse', p_to, 'signed_by', v_req.requested_name);
    update public.stock_movement_requests set result = v_result where request_id = p_request_id;
    return v_result;
  end if;

  if p_kind = 'move' then
    if v_from <> v_to then
      select to_jsonb(t) into v_result
        from public.cross_transfer_stock(v_from, p_from, v_to, p_to, p_items, p_note, p_when) t;
    elsif v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_transfer_stock(p_from, p_to, p_items, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.transfer_stock(p_from, p_to, p_items, p_note, p_when) t;
    end if;
  elsif p_kind = 'receive' then
    if v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_receive_stock(p_to, p_items, p_party, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.receive_stock(p_to, p_items, p_party, p_note, p_when) t;
    end if;
  elsif p_kind = 'return' then
    if v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_return_stock(p_to, p_items, p_party, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.return_stock(p_to, p_items, p_party, p_note, p_when) t;
    end if;
  else
    raise exception 'Unknown kind of movement: %', p_kind;
  end if;

  if v_name is not null then
    update public.stock_transfers
       set signed_by = v_name
     where transfer_number = v_result->>'transfer_number';
    update public.dahua_stock_transfers
       set signed_by = v_name
     where transfer_number = v_result->>'transfer_number';
    v_result := v_result || jsonb_build_object('signed_by', v_name);
  end if;

  update public.stock_movement_requests
     set result = v_result
   where request_id = p_request_id;

  return v_result;
end $$;

notify pgrst, 'reload schema';

-- ── Verification ──────────────────────────────────────────────
-- What is waiting for approval:
--
-- select request_number, kind, from_warehouse, to_warehouse, requested_name, requested_at, items
--   from public.dahua_movement_requests where status = 'pending' order by requested_at;


-- ############################################################################
-- ## 20261023_stock_approval_everywhere.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Every staff stock movement waits for the Big Boss — 2026-10-23
--
-- 20261017_dahua_movement_approval.sql made Dahua movements by staff wait
-- for the Big Boss's approval. This does the same for the main shop, and
-- adds three things around it:
--
--   1. MAIN SHOP TOO
--      A move, delivery or return staff enter for the main shop is now a
--      request (REQ-2026-0001), like a Dahua one (DH-REQ-2026-0001). The
--      stock changes only when it is approved. The Big Boss's own
--      movements still apply at once.
--
--   2. AN APPROVED REQUEST CAN BE REVERSED
--      reverse_stock_request() undoes what the approval did, as a movement
--      of its own (REV-2026-0001, or DH-REV-… when only Dahua is involved):
--      units come back out of where they went and, on a move, back into
--      where they left. The original stays in the record; the request is
--      marked "reversed" with the reversal's number.
--
--   3. AUTO-ACCEPT AFTER 45 SECONDS
--      The Big Boss can switch on auto-accept. A request then approves
--      itself 45 seconds after it was filed, unless he has rejected it by
--      then. There is no timer in the database: settle_stock_requests()
--      approves whatever is due, and every screen that shows requests —
--      the staff member's who filed it included — calls it. Timed from
--      when the request reached the server (filed_at), not from the time
--      on the movement, so a phone that queued a move offline does not
--      skip the 45 seconds.
--
-- The request table keeps its name, dahua_movement_requests, and the old
-- request/approve/reject functions keep working (they call the new ones),
-- so a phone still running yesterday's app is not broken by this.
--
-- NOTE FOR LATER MIGRATIONS: as with Dahua, change transfer_stock_apply,
-- receive_stock_apply and return_stock_apply — not the thin versions.
--
-- Requires 20261017_dahua_movement_approval.sql. Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regclass('public.dahua_movement_requests') is null then
    raise exception 'Run 20261017_dahua_movement_approval.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1. The main shop's movement functions become *_apply ──────
do $$
begin
  if to_regprocedure('public.transfer_stock_apply(text, text, jsonb, text, timestamptz)') is null then
    alter function public.transfer_stock(text, text, jsonb, text, timestamptz) rename to transfer_stock_apply;
  end if;
  if to_regprocedure('public.receive_stock_apply(text, jsonb, text, text, timestamptz)') is null then
    alter function public.receive_stock(text, jsonb, text, text, timestamptz) rename to receive_stock_apply;
  end if;
  if to_regprocedure('public.return_stock_apply(text, jsonb, text, text, timestamptz, text)') is null then
    alter function public.return_stock(text, jsonb, text, text, timestamptz, text) rename to return_stock_apply;
  end if;
end $$;

revoke all on function public.transfer_stock_apply(text, text, jsonb, text, timestamptz)       from public, anon, authenticated;
revoke all on function public.receive_stock_apply(text, jsonb, text, text, timestamptz)        from public, anon, authenticated;
revoke all on function public.return_stock_apply(text, jsonb, text, text, timestamptz, text)   from public, anon, authenticated;

-- The thin versions: the Big Boss straight through, staff told to ask.
create or replace function public.dahua_needs_approval()
returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not (select public.is_superboss()) then
    raise exception 'A stock movement by staff needs the Big Boss''s approval — send it for approval instead.'
      using errcode = '42501';
  end if;
end $$;

create or replace function public.transfer_stock(
  p_from text, p_to text, p_items jsonb, p_note text default null, p_when timestamptz default now()
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
begin
  perform public.dahua_needs_approval();
  return public.transfer_stock_apply(p_from, p_to, p_items, p_note, p_when);
end $$;

create or replace function public.receive_stock(
  p_to text, p_items jsonb, p_supplier text default null, p_note text default null, p_when timestamptz default now()
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
begin
  perform public.dahua_needs_approval();
  return public.receive_stock_apply(p_to, p_items, p_supplier, p_note, p_when);
end $$;

create or replace function public.return_stock(
  p_to text, p_items jsonb, p_customer text default null, p_note text default null, p_when timestamptz default now(), p_spoilt text default 'SPOILT'
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
begin
  perform public.dahua_needs_approval();
  return public.return_stock_apply(p_to, p_items, p_customer, p_note, p_when, p_spoilt);
end $$;

grant execute on function public.transfer_stock(text, text, jsonb, text, timestamptz)       to authenticated;
grant execute on function public.receive_stock(text, jsonb, text, text, timestamptz)        to authenticated;
grant execute on function public.return_stock(text, jsonb, text, text, timestamptz, text)   to authenticated;

-- ── 2. Requests: reversible, and timed from when they arrived ──
alter table public.dahua_movement_requests
  add column if not exists filed_at        timestamptz not null default now(),
  add column if not exists auto_approved   boolean not null default false,
  add column if not exists reversed_at     timestamptz,
  add column if not exists reversed_by     uuid references auth.users(id) on delete set null,
  add column if not exists reversal_number text,
  add column if not exists reverse_reason  text;

alter table public.dahua_movement_requests drop constraint if exists dahua_movement_requests_status_check;
alter table public.dahua_movement_requests
  add constraint dahua_movement_requests_status_check
  check (status in ('pending', 'approved', 'rejected', 'reversed'));

create index if not exists dahua_movement_requests_due_idx
  on public.dahua_movement_requests (filed_at) where status = 'pending';

-- ── 3. A reversal is a movement of its own kind ───────────────
alter table public.stock_transfers drop constraint if exists stock_transfers_kind_check;
alter table public.stock_transfers
  add constraint stock_transfers_kind_check check (kind in ('move', 'receive', 'return', 'reversal'));

alter table public.stock_transfers drop constraint if exists stock_transfers_source_check;
alter table public.stock_transfers
  add constraint stock_transfers_source_check check (
    (kind = 'move' and from_warehouse is not null)
    or (kind in ('receive', 'return') and from_warehouse is null)
    or (kind = 'reversal' and from_warehouse is not null)
  );

alter table public.dahua_stock_transfers drop constraint if exists dahua_stock_transfers_kind_check;
alter table public.dahua_stock_transfers
  add constraint dahua_stock_transfers_kind_check check (kind in ('move', 'receive', 'return', 'reversal'));

alter table public.dahua_stock_transfers drop constraint if exists dahua_stock_transfers_source_check;
alter table public.dahua_stock_transfers
  add constraint dahua_stock_transfers_source_check check (
    (kind = 'move' and from_warehouse is not null
       and (from_warehouse <> to_warehouse or from_line is not null))
    or (kind in ('receive', 'return') and from_warehouse is null)
    or (kind = 'reversal' and from_warehouse is not null)
  );

-- ── 4. Auto-accept: one switch, the Big Boss's ────────────────
create table if not exists public.stock_approval_settings (
  id            integer primary key default 1 check (id = 1),
  auto_accept   boolean not null default false,
  delay_seconds integer not null default 45 check (delay_seconds between 5 and 3600),
  updated_at    timestamptz not null default now(),
  updated_by    uuid references auth.users(id) on delete set null
);
insert into public.stock_approval_settings (id) values (1) on conflict (id) do nothing;

alter table public.stock_approval_settings enable row level security;
-- Everyone signed in may read it: staff screens show the countdown.
drop policy if exists stock_approval_settings_read on public.stock_approval_settings;
drop policy if exists stock_approval_settings_read on public.stock_approval_settings;

create policy stock_approval_settings_read on public.stock_approval_settings
  for select to authenticated using (true);
-- Changed only through set_stock_auto_accept().

create or replace function public.set_stock_auto_accept(p_on boolean)
returns public.stock_approval_settings
language plpgsql security definer set search_path = public as $$
declare
  v_row public.stock_approval_settings;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss can switch auto-accept';
  end if;
  update public.stock_approval_settings
     set auto_accept = coalesce(p_on, false), updated_at = now(), updated_by = auth.uid()
   where id = 1
  returning * into v_row;
  return v_row;
end $$;

-- ── 5. Asking ─────────────────────────────────────────────────
-- Any staff movement, either line. DH-REQ when Dahua is involved, REQ when
-- it is the main shop alone.
create or replace function public.request_stock_movement(
  p_kind      text,
  p_from_line text,
  p_from      text,
  p_to_line   text,
  p_to        text,
  p_items     jsonb,
  p_party     text default null,
  p_note      text default null,
  p_when      timestamptz default now(),
  p_done_by   text default null
) returns public.dahua_movement_requests
language plpgsql security definer set search_path = public as $$
declare
  v_rec    public.dahua_movement_requests;
  v_to     text := coalesce(p_to_line, 'main');
  v_from   text := case when p_kind = 'move' then coalesce(p_from_line, v_to) else null end;
  v_yr     text := to_char(now(), 'YYYY');
  v_prefix text;
  v_n      text;
  v_try    integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record stock movements';
  end if;
  if p_kind not in ('move', 'receive', 'return') then
    raise exception 'Unknown kind of movement: %', p_kind;
  end if;
  if v_to not in ('main', 'dahua') or (v_from is not null and v_from not in ('main', 'dahua')) then
    raise exception 'Unknown stock line';
  end if;
  if p_to is null or btrim(p_to) = '' then
    raise exception 'Where is the stock going?';
  end if;
  if p_kind = 'move' and (p_from is null or btrim(p_from) = '' or (p_from = p_to and v_from = v_to)) then
    raise exception 'A transfer needs two different locations';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Add at least one item';
  end if;

  v_prefix := case when v_to = 'dahua' or coalesce(v_from, '') = 'dahua' then 'DH-REQ-' else 'REQ-' end;

  for v_try in 1..8 loop
    begin
      select v_prefix || v_yr || '-' || lpad((count(*) + 1)::text, 4, '0') into v_n
        from public.dahua_movement_requests where request_number like v_prefix || v_yr || '-%';
      insert into public.dahua_movement_requests
        (request_number, kind, from_line, from_warehouse, to_line, to_warehouse, items, party, note,
         requested_at, filed_at, requested_by, requested_staff_id, requested_name)
      values
        (v_n, p_kind, v_from, case when p_kind = 'move' then p_from end, v_to, p_to, p_items,
         nullif(btrim(coalesce(p_party, '')), ''), nullif(btrim(coalesce(p_note, '')), ''),
         coalesce(p_when, now()), now(), auth.uid(), public.current_staff_id(),
         coalesce(nullif(btrim(coalesce(p_done_by, '')), ''), public.current_staff_name()))
      returning * into v_rec;
      return v_rec;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;
end $$;

-- The old name, for apps loaded before this change.
create or replace function public.request_dahua_movement(
  p_kind text, p_from_line text, p_from text, p_to_line text, p_to text, p_items jsonb,
  p_party text default null, p_note text default null, p_when timestamptz default now(), p_done_by text default null
) returns public.dahua_movement_requests
language sql security definer set search_path = public as $$
  select * from public.request_stock_movement(p_kind, p_from_line, p_from, p_to_line, p_to, p_items, p_party, p_note, p_when, p_done_by)
$$;

-- ── 6. Approving ──────────────────────────────────────────────
-- Internal: makes the movement a pending request describes. The callers
-- check who may do it.
create or replace function public.stock_request_apply(p_id uuid, p_auto boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_req    public.dahua_movement_requests;
  v_number text;
begin
  select * into v_req from public.dahua_movement_requests where id = p_id for update;
  if not found then
    raise exception 'That request no longer exists';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'That request was already %', v_req.status;
  end if;

  -- Made exactly as it would have been if it had been applied at once, and
  -- dated when it was asked for, not when it was approved.
  if v_req.kind = 'move' and v_req.from_line <> v_req.to_line then
    select t.transfer_number into v_number
      from public.cross_transfer_stock_apply(v_req.from_line, v_req.from_warehouse, v_req.to_line, v_req.to_warehouse,
                                             v_req.items, v_req.note, v_req.requested_at) t;
  elsif v_req.kind = 'move' and v_req.to_line = 'dahua' then
    select t.transfer_number into v_number
      from public.dahua_transfer_stock_apply(v_req.from_warehouse, v_req.to_warehouse, v_req.items, v_req.note, v_req.requested_at) t;
  elsif v_req.kind = 'move' then
    select t.transfer_number into v_number
      from public.transfer_stock_apply(v_req.from_warehouse, v_req.to_warehouse, v_req.items, v_req.note, v_req.requested_at) t;
  elsif v_req.kind = 'receive' and v_req.to_line = 'dahua' then
    select t.transfer_number into v_number
      from public.dahua_receive_stock_apply(v_req.to_warehouse, v_req.items, v_req.party, v_req.note, v_req.requested_at) t;
  elsif v_req.kind = 'receive' then
    select t.transfer_number into v_number
      from public.receive_stock_apply(v_req.to_warehouse, v_req.items, v_req.party, v_req.note, v_req.requested_at) t;
  elsif v_req.to_line = 'dahua' then
    select t.transfer_number into v_number
      from public.dahua_return_stock_apply(v_req.to_warehouse, v_req.items, v_req.party, v_req.note, v_req.requested_at, 'SPOILT') t;
  else
    select t.transfer_number into v_number
      from public.return_stock_apply(v_req.to_warehouse, v_req.items, v_req.party, v_req.note, v_req.requested_at, 'SPOILT') t;
  end if;

  -- The movement is the staff member's, not the approver's.
  update public.dahua_stock_transfers
     set signed_by = v_req.requested_name, staff_id = v_req.requested_staff_id,
         created_by = coalesce(v_req.requested_by, created_by)
   where transfer_number = v_number;
  update public.stock_transfers
     set signed_by = v_req.requested_name, staff_id = v_req.requested_staff_id,
         created_by = coalesce(v_req.requested_by, created_by)
   where transfer_number = v_number;

  update public.dahua_movement_requests
     set status = 'approved', decided_at = now(),
         decided_by = case when p_auto then null else auth.uid() end,
         auto_approved = coalesce(p_auto, false), transfer_number = v_number
   where id = p_id;

  return jsonb_build_object('request_number', v_req.request_number, 'transfer_number', v_number, 'auto', coalesce(p_auto, false));
end $$;
revoke all on function public.stock_request_apply(uuid, boolean) from public, anon, authenticated;

create or replace function public.approve_stock_request(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss can approve stock movements';
  end if;
  return public.stock_request_apply(p_id, false);
end $$;

create or replace function public.reject_stock_request(p_id uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_status text;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss can reject stock movements';
  end if;
  select status into v_status from public.dahua_movement_requests where id = p_id for update;
  if not found then
    raise exception 'That request no longer exists';
  end if;
  if v_status <> 'pending' then
    raise exception 'That request was already %', v_status;
  end if;
  update public.dahua_movement_requests
     set status = 'rejected', decided_at = now(), decided_by = auth.uid(),
         reject_reason = nullif(btrim(coalesce(p_reason, '')), '')
   where id = p_id;
end $$;

-- The old names, for apps loaded before this change.
create or replace function public.approve_dahua_movement(p_id uuid)
returns jsonb
language sql security definer set search_path = public as $$
  select public.approve_stock_request(p_id)
$$;
create or replace function public.reject_dahua_movement(p_id uuid, p_reason text default null)
returns void
language sql security definer set search_path = public as $$
  select public.reject_stock_request(p_id, p_reason)
$$;

-- ── 7. Auto-accept: approve whatever is due ───────────────────
-- Called by every screen that shows requests. Does nothing unless the Big
-- Boss has switched auto-accept on. Returns how many it approved.
create or replace function public.settle_stock_requests()
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_set  public.stock_approval_settings;
  v_id   uuid;
  v_done integer := 0;
begin
  select * into v_set from public.stock_approval_settings where id = 1;
  if not found or not v_set.auto_accept then
    return 0;
  end if;
  -- The movement functions underneath accept staff and the Big Boss only.
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    return 0;
  end if;

  for v_id in
    select r.id from public.dahua_movement_requests r
     where r.status = 'pending'
       and r.filed_at <= now() - make_interval(secs => v_set.delay_seconds)
     order by r.filed_at
     limit 50
       for update skip locked
  loop
    begin
      perform public.stock_request_apply(v_id, true);
      v_done := v_done + 1;
    exception when others then
      -- One that cannot be made (a location renamed since, say) stays
      -- pending for the Big Boss to look at; the rest still go through.
      null;
    end;
  end loop;
  return v_done;
end $$;

-- ── 8. Reversing an approved request ──────────────────────────
-- Internal: takes units off a location's row for a product.
create or replace function public.stock_take_out(p_line text, p_warehouse text, p_model text, p_qty integer)
returns table (model text, before integer)
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if p_line = 'dahua' then
    v_id := public.dahua_stock_find_row(p_warehouse, p_model);
    if v_id is null then
      raise exception '% (Dahua) no longer lists % — it cannot be taken back out', p_warehouse, p_model;
    end if;
    return query
      update public.dahua_stock s set transfer_out = coalesce(s.transfer_out, 0) + p_qty
       where s.id = v_id
      returning s.model, (s.closing_stock + p_qty)::integer;
  else
    v_id := public.stock_find_row(p_warehouse, p_model);
    if v_id is null then
      raise exception '% no longer lists % — it cannot be taken back out', p_warehouse, p_model;
    end if;
    return query
      update public.warehouse_stock s set transfer_out = coalesce(s.transfer_out, 0) + p_qty
       where s.id = v_id
      returning s.model, (s.closing_stock + p_qty)::integer;
  end if;
end $$;
revoke all on function public.stock_take_out(text, text, text, integer) from public, anon, authenticated;

create or replace function public.reverse_stock_request(p_id uuid, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_req     public.dahua_movement_requests;
  v_main    boolean;
  v_cross   boolean;
  v_src     text;              -- the line the units go back to (moves)
  v_dst     text;              -- the line they come out of
  v_yr      text := to_char(now(), 'YYYY');
  v_prefix  text;
  v_number  text;
  v_note    text;
  v_main_id uuid;
  v_dh_id   uuid;
  v_try     integer;
  v_item    record;
  v_out     record;
  v_back    text;
  v_pos     integer := 0;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss can reverse stock movements';
  end if;
  select * into v_req from public.dahua_movement_requests where id = p_id for update;
  if not found then
    raise exception 'That request no longer exists';
  end if;
  if v_req.status <> 'approved' or v_req.transfer_number is null then
    raise exception 'Only an approved request can be reversed — this one is %', v_req.status;
  end if;

  v_dst   := v_req.to_line;
  v_src   := coalesce(v_req.from_line, v_req.to_line);
  v_cross := v_req.kind = 'move' and v_src <> v_dst;
  v_main  := v_src = 'main' or v_dst = 'main';
  v_prefix := case when v_main then 'REV-' else 'DH-REV-' end;
  v_note  := 'Reversal of ' || v_req.transfer_number || ' (' || v_req.request_number || ')'
             || coalesce(' — ' || nullif(btrim(coalesce(p_reason, '')), ''), '');

  -- The header: in the table of each line it touches, under one number.
  for v_try in 1..8 loop
    begin
      if v_main then
        select v_prefix || v_yr || '-' || lpad((count(*) + 1)::text, 4, '0') into v_number
          from public.stock_transfers where transfer_number like v_prefix || v_yr || '-%';
      else
        select v_prefix || v_yr || '-' || lpad((count(*) + 1)::text, 4, '0') into v_number
          from public.dahua_stock_transfers where transfer_number like v_prefix || v_yr || '-%';
      end if;
      if v_main then
        insert into public.stock_transfers
          (transfer_number, kind, from_warehouse, to_warehouse, from_line, to_line,
           note, signed_by, staff_id, transferred_at, created_by)
        values
          (v_number, 'reversal', v_req.to_warehouse,
           case when v_req.kind = 'move' then v_req.from_warehouse else 'REVERSED' end,
           case when v_cross then v_dst end, case when v_cross then v_src end,
           v_note, public.current_staff_name(), public.current_staff_id(), now(), auth.uid())
        returning id into v_main_id;
      end if;
      if not v_main or v_cross then
        insert into public.dahua_stock_transfers
          (transfer_number, kind, from_warehouse, to_warehouse, from_line, to_line,
           note, signed_by, staff_id, transferred_at, created_by)
        values
          (v_number, 'reversal', v_req.to_warehouse,
           case when v_req.kind = 'move' then v_req.from_warehouse else 'REVERSED' end,
           case when v_cross then v_dst end, case when v_cross then v_src end,
           v_note, public.current_staff_name(), public.current_staff_id(), now(), auth.uid())
        returning id into v_dh_id;
      end if;
      exit;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;

  -- What the approval actually booked, item by item. On a cross move each
  -- side's table holds that side's name; within one line `model` is the
  -- name it left under and `other_model` the one it joined.
  for v_item in
    select coalesce(m.position, d.position) as position,
           coalesce(m.quantity, d.quantity) as quantity,
           coalesce(case when v_req.to_line = 'dahua' then d.condition end, m.condition, d.condition, 'good') as condition,
           -- the name it sits under where it went
           case when v_cross then (case when v_dst = 'main' then m.model else d.model end)
                else coalesce((case when v_dst = 'main' then m.other_model else d.other_model end),
                              (case when v_dst = 'main' then m.model else d.model end)) end as dest_model,
           -- the name it had where it came from
           case when v_cross then (case when v_src = 'main' then m.model else d.model end)
                else (case when v_src = 'main' then m.model else d.model end) end as src_model
      from (select i.* from public.stock_transfer_items i
              join public.stock_transfers t on t.id = i.transfer_id
             where t.transfer_number = v_req.transfer_number) m
      full join (select i.* from public.dahua_stock_transfer_items i
                   join public.dahua_stock_transfers t on t.id = i.transfer_id
                  where t.transfer_number = v_req.transfer_number) d
        on d.position = m.position
     order by 1
  loop
    if v_item.dest_model is null or coalesce(v_item.quantity, 0) <= 0 then
      continue;
    end if;

    select * into v_out from public.stock_take_out(
      v_dst,
      case when v_req.kind = 'return' and v_item.condition = 'spoilt' then 'SPOILT' else v_req.to_warehouse end,
      v_item.dest_model, v_item.quantity);

    v_back := null;
    if v_req.kind = 'move' then
      if v_src = 'dahua' then
        v_back := public.dahua_stock_book_in_as(v_req.from_warehouse, v_item.src_model, v_item.quantity);
      else
        v_back := public.stock_book_in(v_req.from_warehouse, v_item.src_model, v_item.quantity);
      end if;
    end if;

    v_pos := v_pos + 1;
    if v_main_id is not null then
      insert into public.stock_transfer_items (transfer_id, model, quantity, from_before, position, condition, other_model)
      values (v_main_id,
              case when v_dst = 'main' then v_out.model else v_back end,
              v_item.quantity, case when v_dst = 'main' then v_out.before end, v_pos,
              coalesce(v_item.condition, 'good'),
              case when v_cross then (case when v_dst = 'main' then v_back else v_out.model end)
                   else nullif(v_back, v_out.model) end);
    end if;
    if v_dh_id is not null then
      insert into public.dahua_stock_transfer_items (transfer_id, model, quantity, from_before, position, condition, other_model)
      values (v_dh_id,
              case when v_dst = 'dahua' then v_out.model else v_back end,
              v_item.quantity, case when v_dst = 'dahua' then v_out.before end, v_pos,
              coalesce(v_item.condition, 'good'),
              case when v_cross then (case when v_dst = 'dahua' then v_back else v_out.model end)
                   else nullif(v_back, v_out.model) end);
    end if;
  end loop;

  if v_pos = 0 then
    raise exception 'Nothing was found to reverse on %', v_req.transfer_number;
  end if;

  update public.dahua_movement_requests
     set status = 'reversed', reversed_at = now(), reversed_by = auth.uid(),
         reversal_number = v_number, reverse_reason = nullif(btrim(coalesce(p_reason, '')), '')
   where id = p_id;

  return jsonb_build_object('request_number', v_req.request_number, 'transfer_number', v_req.transfer_number,
                            'reversal_number', v_number, 'lines', v_pos);
end $$;

revoke all on function public.request_stock_movement(text, text, text, text, text, jsonb, text, text, timestamptz, text) from public, anon;
revoke all on function public.approve_stock_request(uuid)        from public, anon;
revoke all on function public.reject_stock_request(uuid, text)   from public, anon;
revoke all on function public.reverse_stock_request(uuid, text)  from public, anon;
revoke all on function public.settle_stock_requests()            from public, anon;
revoke all on function public.set_stock_auto_accept(boolean)     from public, anon;
grant execute on function public.request_stock_movement(text, text, text, text, text, jsonb, text, text, timestamptz, text) to authenticated;
grant execute on function public.approve_stock_request(uuid)       to authenticated;
grant execute on function public.reject_stock_request(uuid, text)  to authenticated;
grant execute on function public.reverse_stock_request(uuid, text) to authenticated;
grant execute on function public.settle_stock_requests()           to authenticated;
grant execute on function public.set_stock_auto_accept(boolean)    to authenticated;

-- ── 9. The phone app's path files every staff movement as a request ──
-- Same as in 20261017_dahua_movement_approval.sql, except that the step
-- before the movement now catches every line, not only Dahua.
create or replace function public.record_stock_movement(
  p_request_id uuid,
  p_kind       text,
  p_from_line  text,
  p_from       text,
  p_to_line    text,
  p_to         text,
  p_items      jsonb,
  p_party      text default null,
  p_note       text default null,
  p_when       timestamptz default now(),
  p_done_by    text default null,
  p_done_token uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_owner   uuid;
  v_result  jsonb;
  v_to      text := coalesce(p_to_line, 'main');
  v_from    text := coalesce(p_from_line, v_to);
  v_typed   text := btrim(coalesce(p_done_by, ''));
  v_name    text;
  v_handler uuid;
  v_req     public.dahua_movement_requests;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record stock movements';
  end if;
  if p_request_id is null then
    raise exception 'A request ID is required';
  end if;
  if v_to not in ('main', 'dahua') or v_from not in ('main', 'dahua') then
    raise exception 'Unknown stock line';
  end if;

  if v_typed <> '' then
    select h.id, h.name into v_handler, v_name
      from public.stock_handlers h
     where upper(btrim(h.name)) = upper(v_typed);
    if not found then
      raise exception '% is not on the stock staff list', v_typed;
    end if;
  end if;

  begin
    insert into public.stock_movement_requests (request_id, created_by)
    values (p_request_id, auth.uid());
  exception when unique_violation then
    select created_by, result into v_owner, v_result
      from public.stock_movement_requests where request_id = p_request_id;
    if v_owner is distinct from auth.uid() then
      raise exception 'That request belongs to someone else';
    end if;
    return v_result || jsonb_build_object('duplicate', true);
  end;

  if v_handler is not null
     and exists (select 1 from public.stock_handler_secrets s where s.handler_id = v_handler)
     and not exists (select 1 from public.stock_handler_tokens t
                      where t.handler_id = v_handler and t.token = p_done_token) then
    raise exception '% must enter their password on this phone again before this can be saved', v_name;
  end if;

  -- Every movement by staff goes to the Big Boss for approval.
  if not (select public.is_superboss()) then
    select * into v_req
      from public.request_stock_movement(p_kind, case when p_kind = 'move' then v_from end, p_from, v_to, p_to,
                                         p_items, p_party, p_note, p_when, v_name);
    v_result := jsonb_build_object(
      'pending', true, 'request_number', v_req.request_number,
      'transfer_number', v_req.request_number, 'kind', p_kind,
      'to_warehouse', p_to, 'signed_by', v_req.requested_name);
    update public.stock_movement_requests set result = v_result where request_id = p_request_id;
    return v_result;
  end if;

  if p_kind = 'move' then
    if v_from <> v_to then
      select to_jsonb(t) into v_result
        from public.cross_transfer_stock(v_from, p_from, v_to, p_to, p_items, p_note, p_when) t;
    elsif v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_transfer_stock(p_from, p_to, p_items, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.transfer_stock(p_from, p_to, p_items, p_note, p_when) t;
    end if;
  elsif p_kind = 'receive' then
    if v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_receive_stock(p_to, p_items, p_party, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.receive_stock(p_to, p_items, p_party, p_note, p_when) t;
    end if;
  elsif p_kind = 'return' then
    if v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_return_stock(p_to, p_items, p_party, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.return_stock(p_to, p_items, p_party, p_note, p_when) t;
    end if;
  else
    raise exception 'Unknown kind of movement: %', p_kind;
  end if;

  if v_name is not null then
    update public.stock_transfers
       set signed_by = v_name
     where transfer_number = v_result->>'transfer_number';
    update public.dahua_stock_transfers
       set signed_by = v_name
     where transfer_number = v_result->>'transfer_number';
    v_result := v_result || jsonb_build_object('signed_by', v_name);
  end if;

  update public.stock_movement_requests
     set result = v_result
   where request_id = p_request_id;

  return v_result;
end $$;

notify pgrst, 'reload schema';

-- ── Verification ──────────────────────────────────────────────
-- What is waiting, and what auto-accept is set to:
--
-- select request_number, kind, from_warehouse, to_warehouse, requested_name, filed_at
--   from public.dahua_movement_requests where status = 'pending' order by filed_at;
-- select * from public.stock_approval_settings;


-- ############################################################################
-- ## 20261024_stock_accuracy.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Stock accuracy: the faults an end-to-end check turned up — 2026-10-24
--
-- 1. RENAMING A PRODUCT LOST ITS PRICE
--    The Stock tab renamed one row by rewriting its `model`. The main
--    shop's price is filed under the product's NAME (pricelist_items), so
--    the renamed row no longer found it and showed GH¢ 0 — and the same
--    product kept the old name in every other location, its barcodes
--    pointed at a name that was gone, and the catalogue still carried the
--    old model number.
--      → A stock row's name can no longer be changed by a plain UPDATE from
--        the app. Renames go through merge_stock_model(), which renames the
--        product in every location and takes its barcodes and price along.
--      → merge_stock_model() now also carries the price when it was filed
--        under different capitals or spacing, and updates the catalogue's
--        model number — an invoice line picked from the catalogue deducts
--        by that number, and would otherwise match no stock row and
--        silently deduct nothing.
--
-- 2. AN EDIT COULD UNDO SALES AND TRANSFERS
--    The Dahua stock editor sent the row's invoice_taken back as it was
--    when the page loaded. Any sale made since was wiped off the count.
--      → invoice_taken, transfer_in and transfer_out are kept as they are
--        on any direct UPDATE from the app. Only the sale, transfer and
--        merge functions change them.
--
-- 3. DELETING AN INVOICE DID NOT GIVE THE STOCK BACK
--    Main-shop invoices: deleted, but STORE STOCK kept the units as sold.
--    Dahua invoices: given back from the browser one row at a time, so a
--    dropped connection could restore half an invoice.
--      → delete_invoice_restoring_stock() gives back exactly what the
--        invoice took and deletes it, in one step.
--
-- 4. A PRICE WAS MISSED UNDER ANOTHER SPELLING
--    price_for_model() matched the name exactly (bar capitals and outer
--    spaces), so "ds-2ce16d0t lpfs" found no price filed as
--    "DS-2CE16D0T-LPFS".
--      → It now falls back to the same product key every stock movement
--        uses (stock_model_key).
--
-- Requires 20261005_uniform_names.sql and 20260930_lock_stock_writes.sql.
-- Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regprocedure('public.stock_merge_names(text, text, text)') is null then
    raise exception 'Run 20261005_uniform_names.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1 & 2. Guard the counters and the name on direct writes ───
-- The app's own writes arrive as the `authenticated` role. The sale,
-- transfer and merge functions run as their owner, so they pass.
create or replace function public.stock_row_guard()
returns trigger
language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') then
    new.invoice_taken := old.invoice_taken;
    new.transfer_in   := old.transfer_in;
    new.transfer_out  := old.transfer_out;
    if new.model is distinct from old.model then
      raise exception 'Rename a product with Product names — it renames it in every location and keeps its price and barcodes.'
        using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

-- Named to run before the triggers that derive closing_stock from these
-- columns (BEFORE triggers fire in name order).
drop trigger if exists trg_a_stock_row_guard on public.warehouse_stock;
create trigger trg_a_stock_row_guard
  before update on public.warehouse_stock
  for each row execute function public.stock_row_guard();

drop trigger if exists trg_a_stock_row_guard on public.dahua_stock;
create trigger trg_a_stock_row_guard
  before update on public.dahua_stock
  for each row execute function public.stock_row_guard();

-- ── 1. Renames carry the price and the catalogue along ────────
create or replace function public.merge_stock_model(p_line text, p_from text, p_into text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_from text := coalesce(p_from, '');
  v_into text := btrim(coalesce(p_into, ''));
  v_res  jsonb;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss may rename or merge product names';
  end if;
  if p_line is null or p_line not in ('main', 'dahua') then
    raise exception 'Unknown stock line';
  end if;
  if v_from = v_into then
    raise exception 'Those are the same name';
  end if;
  if p_line = 'main' and not exists (select 1 from public.warehouse_stock where model = v_from) then
    raise exception 'Nothing is stocked as "%"', v_from;
  end if;
  if p_line = 'dahua' and not exists (select 1 from public.dahua_stock where model = v_from) then
    raise exception 'Dahua stocks nothing as "%"', v_from;
  end if;

  v_res := public.stock_merge_names(p_line, v_from, v_into);

  if p_line = 'main' and upper(btrim(v_from)) <> upper(v_into) then
    -- The price, wherever it was filed under the old name — unless the
    -- kept name already has one of its own.
    update public.pricelist_items
       set model = v_into
     where upper(btrim(model)) = upper(btrim(v_from))
       and not exists (select 1 from public.pricelist_items p where upper(btrim(p.model)) = upper(v_into));
    -- The catalogue: a line picked from it deducts by this number.
    if to_regclass('public.products') is not null then
      update public.products
         set model_number = v_into
       where upper(btrim(coalesce(model_number, ''))) = upper(btrim(v_from));
    end if;
  end if;

  return v_res;
end $$;

-- ── 3. Deleting an invoice gives its stock back ───────────────
create or replace function public.delete_invoice_restoring_stock(p_line text, p_invoice_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_number   text;
  v_item     record;
  v_id       uuid;
  v_restored integer := 0;
  v_missing  text[] := '{}';
  v_deducted boolean;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss can delete invoices';
  end if;
  if p_line not in ('main', 'dahua') then
    raise exception 'Unknown stock line';
  end if;

  if p_line = 'main' then
    select invoice_number into v_number from public.invoices where id = p_invoice_id for update;
  else
    select invoice_number into v_number from public.dahua_invoices where id = p_invoice_id for update;
  end if;
  if not found then
    raise exception 'That invoice no longer exists';
  end if;

  -- Only what was actually taken is given back.
  delete from public.invoice_stock_deductions
   where line = p_line and invoice_id = p_invoice_id
  returning true into v_deducted;

  if coalesce(v_deducted, false) and p_line = 'main' then
    -- The same lines, matched the same way, as deduct_invoice_store_stock.
    for v_item in
      select min(x.model) as model, sum(x.quantity)::integer as qty
        from (
          select btrim(coalesce(nullif(btrim(p.model_number), ''), i.description)) as model, i.quantity
            from public.invoice_items i
            left join public.products p on p.id = i.product_id
           where i.invoice_id = p_invoice_id and i.quantity > 0
        ) x
       where x.model <> ''
       group by upper(x.model)
    loop
      v_id := public.stock_find_row('STORE STOCK', v_item.model);
      if v_id is null then
        continue;      -- not a stocked product: nothing was taken
      end if;
      update public.warehouse_stock
         set invoice_taken = greatest(0, coalesce(invoice_taken, 0) - v_item.qty)
       where id = v_id;
      v_restored := v_restored + 1;
    end loop;
  elsif coalesce(v_deducted, false) then
    for v_item in
      select i.stock_id, i.description, i.quantity
        from public.dahua_invoice_items i
       where i.invoice_id = p_invoice_id and i.quantity > 0 and i.stock_id is not null
    loop
      update public.dahua_stock
         set invoice_taken = greatest(0, coalesce(invoice_taken, 0) - v_item.quantity)
       where id = v_item.stock_id;
      if found then
        v_restored := v_restored + 1;
      else
        v_missing := v_missing || v_item.description;
      end if;
    end loop;
  end if;

  if p_line = 'main' then
    delete from public.invoices where id = p_invoice_id;
  else
    delete from public.dahua_invoices where id = p_invoice_id;
  end if;

  return jsonb_build_object('invoice_number', v_number, 'restored', v_restored, 'missing', to_jsonb(v_missing));
end $$;

revoke all on function public.delete_invoice_restoring_stock(text, uuid) from public, anon;
grant execute on function public.delete_invoice_restoring_stock(text, uuid) to authenticated;

-- ── 4. A price is found under any spelling of the product ─────
create or replace function public.price_for_model(p_model text)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select pi.ghs_price
       from public.pricelist_items pi
      where upper(btrim(pi.model)) = upper(btrim(coalesce(p_model, '')))
        and btrim(coalesce(p_model, '')) <> ''
        and pi.ghs_price > 0
      order by pi.created_at desc
      limit 1),
    (select pi.ghs_price
       from public.pricelist_items pi
      where public.stock_model_key(pi.model) = public.stock_model_key(p_model)
        and public.stock_model_key(p_model) <> ''
        and pi.ghs_price > 0
      order by pi.created_at desc
      limit 1)
  )
$$;
grant execute on function public.price_for_model(text) to authenticated;

notify pgrst, 'reload schema';

-- ── Verification ──────────────────────────────────────────────
-- One product under two names in different locations (each should be
-- merged in Transfers → Product names):
--
-- select public.stock_model_key(model) as code, array_agg(distinct model) as names
--   from public.warehouse_stock group by 1 having count(distinct model) > 1;
--
-- Stocked products with no price under any spelling:
--
-- select distinct model from public.warehouse_stock
--  where coalesce(public.price_for_model(model), 0) = 0 order by 1;


-- ############################################################################
-- ## 20261025_no_stock_sales_switch.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- The Big Boss's switch: may staff invoice what is not in stock? — 2026-10-25
--
-- The invoice forms refuse a stocked product the shop does not have
-- ("no stock, no sale"). Some days the Big Boss wants a sale to go through
-- anyway — the goods are on their way, or the count is known to be behind.
-- This is his switch for that, on the same one-row settings table as
-- auto-accept. Off (the default) keeps the rule. On, the invoice forms warn
-- and let the sale through, and the stock goes below zero, as it did before
-- the rule.
--
-- He flips it by right-clicking the New Invoice tab, in either portal. One
-- switch covers both the main shop and Dahua.
--
-- Requires 20261023_stock_approval_everywhere.sql. Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regclass('public.stock_approval_settings') is null then
    raise exception 'Run 20261023_stock_approval_everywhere.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

alter table public.stock_approval_settings
  add column if not exists allow_no_stock_sales boolean not null default false;

create or replace function public.set_no_stock_sales(p_on boolean)
returns public.stock_approval_settings
language plpgsql security definer set search_path = public as $$
declare
  v_row public.stock_approval_settings;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss can change this';
  end if;
  update public.stock_approval_settings
     set allow_no_stock_sales = coalesce(p_on, false), updated_at = now(), updated_by = auth.uid()
   where id = 1
  returning * into v_row;
  return v_row;
end $$;

revoke all on function public.set_no_stock_sales(boolean) from public, anon;
grant execute on function public.set_no_stock_sales(boolean) to authenticated;

notify pgrst, 'reload schema';

-- ── Verification ──────────────────────────────────────────────
-- select auto_accept, allow_no_stock_sales from public.stock_approval_settings;


-- ############################################################################
-- ## 20261026_invoice_order_numbers.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Order numbers that never repeat — 2026-10-26
--
-- Main shop: next_order_number() counted today's invoices and added one.
-- Delete an invoice (a double-saved one, say) and the count falls, so the
-- next sale is given an order number already printed on another invoice.
-- 219 order numbers had been handed out twice by 2026-10-24. It now takes
-- the highest number issued today and adds one, as invoice numbers do,
-- under the same lock trg_assign_invoice_numbers already holds.
--
-- Dahua: both numbers were worked out in the browser, from a counter read
-- once when the page opened. Two tills, or a page left open, handed out
-- the same order number (the invoice number has a unique rule and was
-- retried; the order number has none). The database now assigns both, in
-- a BEFORE INSERT trigger, and the form prints what it stored. Rows written
-- outside the app (SQL, imports) keep the numbers they bring.
--
-- Numbers already printed are left as they are. Idempotent.
-- ─────────────────────────────────────────────────────────────

-- ── Main shop ────────────────────────────────────────────────
create or replace function public.next_order_number() returns text
language plpgsql security definer set search_path = public as $$
declare
  d   text := to_char((now() at time zone 'UTC')::date, 'YYYYMMDD');
  seq int;
begin
  select coalesce(max((regexp_replace(order_no, '^.*-', ''))::int), 0) + 1
    into seq
    from public.invoices
   where order_no like 'ORD-' || d || '-%'
     and order_no ~ ('^ORD-' || d || '-\d+$');
  return 'ORD-' || d || '-' || lpad(seq::text, 3, '0');
end $$;

grant execute on function public.next_order_number() to authenticated;

-- ── Dahua ────────────────────────────────────────────────────
-- The next numbers, read across every Dahua invoice (security definer: a
-- cashier's own view of the table is narrowed by RLS).
create or replace function public.next_dahua_invoice_number() returns text
language plpgsql security definer set search_path = public as $$
declare
  yr  text := to_char(now(), 'YYYY');
  seq int;
begin
  select coalesce(max((regexp_replace(invoice_number, '^.*-', ''))::int), 0) + 1 into seq
    from public.dahua_invoices
   where invoice_number like 'DH-INV-' || yr || '-%'
     and invoice_number ~ ('^DH-INV-' || yr || '-\d+$');
  return 'DH-INV-' || yr || '-' || lpad(seq::text, 4, '0');
end $$;

create or replace function public.next_dahua_order_number() returns text
language plpgsql security definer set search_path = public as $$
declare
  d   text := to_char((now() at time zone 'UTC')::date, 'YYYYMMDD');
  seq int;
begin
  select coalesce(max((regexp_replace(order_no, '^.*-', ''))::int), 0) + 1 into seq
    from public.dahua_invoices
   where order_no like 'DH-ORD-' || d || '-%'
     and order_no ~ ('^DH-ORD-' || d || '-\d+$');
  return 'DH-ORD-' || d || '-' || lpad(seq::text, 3, '0');
end $$;

grant execute on function public.next_dahua_invoice_number() to authenticated;
grant execute on function public.next_dahua_order_number() to authenticated;

-- Not security definer, so current_user is who is writing: the app
-- (authenticated) always gets the database's numbers; SQL and imports keep
-- theirs unless they leave them blank.
create or replace function public.fn_assign_dahua_invoice_numbers() returns trigger
language plpgsql set search_path = public as $$
declare
  app boolean := current_user in ('authenticated', 'anon');
begin
  -- One Dahua invoice numbered at a time, so two tills never draw the same number.
  perform pg_advisory_xact_lock(hashtext('dahua_invoice_seq'));
  if app or coalesce(new.invoice_number, '') = '' then
    new.invoice_number := public.next_dahua_invoice_number();
  end if;
  if app or coalesce(new.order_no, '') = '' then
    new.order_no := public.next_dahua_order_number();
  end if;
  return new;
end $$;

drop trigger if exists trg_assign_dahua_invoice_numbers on public.dahua_invoices;
create trigger trg_assign_dahua_invoice_numbers before insert on public.dahua_invoices
  for each row execute function public.fn_assign_dahua_invoice_numbers();

notify pgrst, 'reload schema';

-- ── Verification ──────────────────────────────────────────────
-- Order numbers on more than one invoice (all from before this file):
-- select order_no, count(*), string_agg(invoice_number, ', ' order by invoice_number)
--   from public.invoices where order_no is not null
--  group by order_no having count(*) > 1 order by order_no desc;


-- ############################################################################
-- ## 20261117_suppliers_and_costs.sql
-- ############################################################################

-- ─────────────────────────────────────────────────────────────
-- Suppliers, what we owe them, and what our stock cost — 2026-11-17
--
-- Three things the shop asked for, built as one ledger:
--
--   1. COST PRICES IN CEDIS
--      product_costs holds the last price we paid (GH₵) for each product,
--      filed under the same product key every stock movement uses
--      (stock_model_key). Receiving goods from a supplier updates it; the
--      Big Boss can also set it by hand.
--
--   2. GOODS RECEIVED, PAYMENTS, AND THE RUNNING BALANCE
--      Each supplier has a statement made of numbered documents:
--        received  SR-2026-0001   goods in, with quantity and unit cost.
--                                 Books the units into a stock location
--                                 through receive_stock(), so the delivery
--                                 also appears in the Transfers history (RCV).
--        payment   SP-2026-0001   money paid to the supplier.
--        returned  SRN-2026-0001  goods sent back (normally spoilt), credited
--                                 at cost and taken out of a stock location.
--      Balance owed = received − returned − paid.
--
--   3. SPOILT GOODS BACK TO THE SUPPLIER
--      A return takes units out of the chosen location (STORE STOCK, SPOILT
--      or any other) by raising transfer_out on that stock row, the same
--      counter a transfer uses, so closing_stock goes down. It refuses to
--      take more than the location holds.
--
-- A document entered wrongly is VOIDED, never deleted: it stays on the
-- statement, struck out, and stops counting. Voiding a receipt takes the
-- units back out of stock (refused if they have already been sold or moved);
-- voiding a return puts them back.
--
-- Main shop only. Bosses read; only the Big Boss writes, and only through the
-- functions below. Requires 20261023_stock_approval_everywhere.sql.
-- Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regprocedure('public.receive_stock_apply(text, jsonb, text, text, timestamptz)') is null then
    raise exception 'Run 20261023_stock_approval_everywhere.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1. Tables ─────────────────────────────────────────────────
create table if not exists public.suppliers (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (btrim(name) <> ''),
  phone      text,
  note       text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create unique index if not exists suppliers_name_uq on public.suppliers (lower(btrim(name)));

create table if not exists public.supplier_docs (
  id             uuid primary key default gen_random_uuid(),
  number         text not null unique,
  kind           text not null check (kind in ('received', 'payment', 'returned')),
  supplier_id    uuid not null references public.suppliers(id) on delete restrict,
  doc_date       date not null default current_date,
  location       text,                       -- where stock went in / came out
  ref            text,                       -- the supplier's invoice or receipt number
  amount         numeric(14,2) not null default 0 check (amount >= 0),
  stock_booked   boolean not null default false,
  transfer_number text,                      -- the RCV record when a receipt booked stock
  note           text,
  signed_by      text,
  staff_id       text,
  voided_at      timestamptz,
  void_reason    text,
  created_by     uuid default auth.uid(),
  created_at     timestamptz not null default now()
);
create index if not exists supplier_docs_supplier_idx on public.supplier_docs (supplier_id, doc_date);

create table if not exists public.supplier_doc_items (
  id           uuid primary key default gen_random_uuid(),
  doc_id       uuid not null references public.supplier_docs(id) on delete cascade,
  position     integer not null default 0,
  model        text not null,
  quantity     integer not null check (quantity > 0),
  unit_cost    numeric(14,2) not null default 0 check (unit_cost >= 0),
  stock_row_id uuid                          -- the warehouse_stock row it changed
);
create index if not exists supplier_doc_items_doc_idx on public.supplier_doc_items (doc_id);

create table if not exists public.product_costs (
  model_key  text primary key,
  model      text not null,
  unit_cost  numeric(14,2) not null check (unit_cost >= 0),
  source     text,                           -- 'SR-2026-0004' or 'manual'
  updated_at timestamptz not null default now()
);

-- ── 2. Access: bosses read, nobody writes directly ────────────
alter table public.suppliers          enable row level security;
alter table public.supplier_docs      enable row level security;
alter table public.supplier_doc_items enable row level security;
alter table public.product_costs      enable row level security;

drop policy if exists suppliers_read on public.suppliers;
drop policy if exists suppliers_read on public.suppliers;
create policy suppliers_read on public.suppliers for select to authenticated using ((select public.is_boss()));
drop policy if exists supplier_docs_read on public.supplier_docs;
drop policy if exists supplier_docs_read on public.supplier_docs;
create policy supplier_docs_read on public.supplier_docs for select to authenticated using ((select public.is_boss()));
drop policy if exists supplier_doc_items_read on public.supplier_doc_items;
drop policy if exists supplier_doc_items_read on public.supplier_doc_items;
create policy supplier_doc_items_read on public.supplier_doc_items for select to authenticated using ((select public.is_boss()));
drop policy if exists product_costs_read on public.product_costs;
drop policy if exists product_costs_read on public.product_costs;
create policy product_costs_read on public.product_costs for select to authenticated using ((select public.is_boss()));

grant select on public.suppliers, public.supplier_docs, public.supplier_doc_items, public.product_costs to authenticated;

-- Every change shows up in the Log tab.
drop trigger if exists trg_audit_supplier_docs on public.supplier_docs;
create trigger trg_audit_supplier_docs after insert or update or delete on public.supplier_docs
  for each row execute function public.fn_audit();

-- ── 3. Balances ───────────────────────────────────────────────
create or replace view public.supplier_balances with (security_invoker = true) as
select s.id, s.name, s.phone, s.note,
       coalesce(sum(d.amount) filter (where d.kind = 'received' and d.voided_at is null), 0) as received,
       coalesce(sum(d.amount) filter (where d.kind = 'returned' and d.voided_at is null), 0) as returned,
       coalesce(sum(d.amount) filter (where d.kind = 'payment'  and d.voided_at is null), 0) as paid,
       coalesce(sum(case d.kind when 'received' then d.amount else -d.amount end)
                filter (where d.voided_at is null), 0) as balance,
       max(d.doc_date) as last_activity
  from public.suppliers s
  left join public.supplier_docs d on d.supplier_id = s.id
 group by s.id;
grant select on public.supplier_balances to authenticated;

-- ── 4. Internal helpers ───────────────────────────────────────
create or replace function public.supplier_only_big_boss()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss can change supplier records' using errcode = '42501';
  end if;
end $$;

-- SR-2026-0001, SP-2026-0001, SRN-2026-0001: one series per kind per year.
create or replace function public.supplier_next_number(p_kind text, p_date date)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_prefix text := case p_kind when 'received' then 'SR' when 'payment' then 'SP' else 'SRN' end
                   || '-' || to_char(coalesce(p_date, current_date), 'YYYY') || '-';
  v_last   integer;
begin
  perform pg_advisory_xact_lock(hashtext('supplier_docs_number'));
  select coalesce(max(substring(number from length(v_prefix) + 1)::integer), 0) into v_last
    from public.supplier_docs where number like v_prefix || '%'
     and substring(number from length(v_prefix) + 1) ~ '^\d+$';
  return v_prefix || lpad((v_last + 1)::text, 4, '0');
end $$;

create or replace function public.supplier_open_doc(
  p_kind text, p_supplier uuid, p_date date, p_location text, p_ref text, p_note text
) returns public.supplier_docs
language plpgsql security definer set search_path = public as $$
declare
  v_doc public.supplier_docs;
begin
  if not exists (select 1 from public.suppliers where id = p_supplier) then
    raise exception 'Pick a supplier first';
  end if;
  insert into public.supplier_docs (number, kind, supplier_id, doc_date, location, ref, note, signed_by, staff_id)
  values (public.supplier_next_number(p_kind, p_date), p_kind, p_supplier, coalesce(p_date, current_date),
          nullif(btrim(coalesce(p_location, '')), ''),
          nullif(btrim(coalesce(p_ref, '')), ''),
          nullif(btrim(coalesce(p_note, '')), ''),
          public.current_staff_name(), public.current_staff_id())
  returning * into v_doc;
  return v_doc;
end $$;

revoke all on function public.supplier_next_number(text, date) from public, anon, authenticated;
revoke all on function public.supplier_open_doc(text, uuid, date, text, text, text) from public, anon, authenticated;

-- ── 5. Suppliers ──────────────────────────────────────────────
create or replace function public.supplier_save(p_id uuid, p_name text, p_phone text default null, p_note text default null)
returns public.suppliers
language plpgsql security definer set search_path = public as $$
declare
  v public.suppliers;
begin
  perform public.supplier_only_big_boss();
  if btrim(coalesce(p_name, '')) = '' then raise exception 'A supplier needs a name'; end if;
  if p_id is null then
    insert into public.suppliers (name, phone, note)
    values (btrim(p_name), nullif(btrim(coalesce(p_phone, '')), ''), nullif(btrim(coalesce(p_note, '')), ''))
    returning * into v;
  else
    update public.suppliers
       set name = btrim(p_name), phone = nullif(btrim(coalesce(p_phone, '')), ''), note = nullif(btrim(coalesce(p_note, '')), '')
     where id = p_id returning * into v;
  end if;
  return v;
exception when unique_violation then
  raise exception '% is already on the supplier list', btrim(p_name);
end $$;

-- ── 6. Goods received ─────────────────────────────────────────
-- p_items: [{"model": "DS-2CE16D0T", "quantity": 10, "unit_cost": 145.50}, ...]
create or replace function public.supplier_receive(
  p_supplier uuid, p_items jsonb, p_date date default current_date,
  p_to text default 'STORE STOCK', p_book_stock boolean default true,
  p_ref text default null, p_note text default null
) returns public.supplier_docs
language plpgsql security definer set search_path = public as $$
declare
  v_doc   public.supplier_docs;
  v_item  jsonb;
  v_model text;
  v_qty   integer;
  v_cost  numeric;
  v_pos   integer := 0;
  v_total numeric := 0;
  v_moves jsonb := '[]'::jsonb;
  v_rcv   public.stock_transfers;
  v_name  text;
begin
  perform public.supplier_only_big_boss();
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Add at least one item';
  end if;
  if p_book_stock and btrim(coalesce(p_to, '')) = '' then
    raise exception 'Pick the location the goods went into';
  end if;

  v_doc := public.supplier_open_doc('received', p_supplier, p_date,
             case when p_book_stock then p_to end, p_ref, p_note);

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := upper(btrim(coalesce(v_item->>'model', '')));
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    v_cost  := coalesce((v_item->>'unit_cost')::numeric, 0);
    if v_model = '' or v_qty <= 0 then continue; end if;
    if v_cost < 0 then raise exception 'A cost cannot be negative (%)', v_model; end if;

    v_pos   := v_pos + 1;
    v_total := v_total + v_qty * v_cost;
    insert into public.supplier_doc_items (doc_id, position, model, quantity, unit_cost)
    values (v_doc.id, v_pos, v_model, v_qty, v_cost);
    v_moves := v_moves || jsonb_build_object('model', v_model, 'quantity', v_qty);

    if v_cost > 0 then
      insert into public.product_costs (model_key, model, unit_cost, source, updated_at)
      values (public.stock_model_key(v_model), v_model, v_cost, v_doc.number, now())
      on conflict (model_key) do update
        set model = excluded.model, unit_cost = excluded.unit_cost, source = excluded.source, updated_at = now();
    end if;
  end loop;

  if v_pos = 0 then raise exception 'Add at least one item with a quantity'; end if;

  if p_book_stock then
    select name into v_name from public.suppliers where id = p_supplier;
    v_rcv := public.receive_stock(p_to, v_moves, v_name,
               concat_ws(' · ', v_doc.number, v_doc.ref, v_doc.note),
               (coalesce(p_date, current_date) + time '12:00')::timestamptz);
    -- Remember which row each line landed on, so a void can take it back out.
    update public.supplier_doc_items i
       set stock_row_id = public.stock_find_row(p_to, i.model)
     where i.doc_id = v_doc.id;
  end if;

  update public.supplier_docs
     set amount = round(v_total, 2), stock_booked = p_book_stock, transfer_number = v_rcv.transfer_number
   where id = v_doc.id returning * into v_doc;
  return v_doc;
end $$;

-- ── 7. Payments ───────────────────────────────────────────────
create or replace function public.supplier_payment(
  p_supplier uuid, p_amount numeric, p_date date default current_date,
  p_ref text default null, p_note text default null
) returns public.supplier_docs
language plpgsql security definer set search_path = public as $$
declare
  v_doc public.supplier_docs;
begin
  perform public.supplier_only_big_boss();
  if p_amount is null or p_amount <= 0 then raise exception 'Enter the amount paid'; end if;
  v_doc := public.supplier_open_doc('payment', p_supplier, p_date, null, p_ref, p_note);
  update public.supplier_docs set amount = round(p_amount, 2) where id = v_doc.id returning * into v_doc;
  return v_doc;
end $$;

-- ── 8. Goods back to the supplier ─────────────────────────────
-- p_items: [{"model": "...", "quantity": 2, "unit_cost": 145.50}]
-- unit_cost may be left out: the product's cost price is used.
create or replace function public.supplier_return(
  p_supplier uuid, p_items jsonb, p_from text default 'SPOILT', p_date date default current_date,
  p_ref text default null, p_note text default null
) returns public.supplier_docs
language plpgsql security definer set search_path = public as $$
declare
  v_doc   public.supplier_docs;
  v_item  jsonb;
  v_model text;
  v_qty   integer;
  v_cost  numeric;
  v_row   uuid;
  v_name  text;
  v_have  integer;
  v_pos   integer := 0;
  v_total numeric := 0;
begin
  perform public.supplier_only_big_boss();
  if btrim(coalesce(p_from, '')) = '' then raise exception 'Pick the location the goods are taken from'; end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception 'Add at least one item'; end if;

  v_doc := public.supplier_open_doc('returned', p_supplier, p_date, p_from, p_ref, p_note);

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(coalesce(v_item->>'model', ''));
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_model = '' or v_qty <= 0 then continue; end if;

    v_row := public.stock_find_row(p_from, v_model);
    if v_row is null then
      raise exception '% has no % to return', p_from, v_model;
    end if;
    select model, closing_stock into v_name, v_have from public.warehouse_stock where id = v_row for update;
    if v_have < v_qty then
      raise exception '% holds only % × % — cannot return %', p_from, v_have, v_name, v_qty;
    end if;

    v_cost := nullif(v_item->>'unit_cost', '')::numeric;
    if v_cost is null then
      select unit_cost into v_cost from public.product_costs where model_key = public.stock_model_key(v_name);
    end if;
    v_cost := coalesce(v_cost, 0);
    if v_cost < 0 then raise exception 'A cost cannot be negative (%)', v_name; end if;

    update public.warehouse_stock set transfer_out = coalesce(transfer_out, 0) + v_qty where id = v_row;

    v_pos   := v_pos + 1;
    v_total := v_total + v_qty * v_cost;
    insert into public.supplier_doc_items (doc_id, position, model, quantity, unit_cost, stock_row_id)
    values (v_doc.id, v_pos, v_name, v_qty, v_cost, v_row);
  end loop;

  if v_pos = 0 then raise exception 'Add at least one item with a quantity'; end if;

  update public.supplier_docs set amount = round(v_total, 2), stock_booked = true
   where id = v_doc.id returning * into v_doc;
  return v_doc;
end $$;

-- ── 9. Voiding a mistake ──────────────────────────────────────
create or replace function public.supplier_void(p_doc uuid, p_reason text default null)
returns public.supplier_docs
language plpgsql security definer set search_path = public as $$
declare
  v_doc  public.supplier_docs;
  v_it   public.supplier_doc_items;
  v_have integer;
begin
  perform public.supplier_only_big_boss();
  select * into v_doc from public.supplier_docs where id = p_doc for update;
  if v_doc.id is null then raise exception 'That record no longer exists'; end if;
  if v_doc.voided_at is not null then raise exception '% is already voided', v_doc.number; end if;

  if v_doc.stock_booked then
    for v_it in select * from public.supplier_doc_items where doc_id = v_doc.id order by position loop
      if v_it.stock_row_id is null then continue; end if;
      if v_doc.kind = 'received' then
        -- Take the delivered units back out — only if they are still there.
        select closing_stock into v_have from public.warehouse_stock where id = v_it.stock_row_id for update;
        if coalesce(v_have, 0) < v_it.quantity then
          raise exception 'Cannot void %: % × % have already left %',
            v_doc.number, v_it.quantity - coalesce(v_have, 0), v_it.model, v_doc.location;
        end if;
        update public.warehouse_stock set transfer_out = coalesce(transfer_out, 0) + v_it.quantity
         where id = v_it.stock_row_id;
      elsif v_doc.kind = 'returned' then
        -- Put the returned units back where they were taken from.
        update public.warehouse_stock set transfer_out = greatest(coalesce(transfer_out, 0) - v_it.quantity, 0)
         where id = v_it.stock_row_id;
      end if;
    end loop;
  end if;

  update public.supplier_docs
     set voided_at = now(), void_reason = nullif(btrim(coalesce(p_reason, '')), '')
   where id = v_doc.id returning * into v_doc;
  return v_doc;
end $$;

-- ── 10. Setting a cost price by hand ──────────────────────────
create or replace function public.set_product_cost(p_model text, p_cost numeric)
returns public.product_costs
language plpgsql security definer set search_path = public as $$
declare
  v public.product_costs;
begin
  perform public.supplier_only_big_boss();
  if btrim(coalesce(p_model, '')) = '' then raise exception 'Which product?'; end if;
  if p_cost is null or p_cost < 0 then raise exception 'Enter a cost of 0 or more'; end if;
  insert into public.product_costs (model_key, model, unit_cost, source, updated_at)
  values (public.stock_model_key(p_model), upper(btrim(p_model)), round(p_cost, 2), 'manual', now())
  on conflict (model_key) do update
    set unit_cost = excluded.unit_cost, source = 'manual', updated_at = now()
  returning * into v;
  return v;
end $$;

grant execute on function public.supplier_save(uuid, text, text, text)                         to authenticated;
grant execute on function public.supplier_receive(uuid, jsonb, date, text, boolean, text, text) to authenticated;
grant execute on function public.supplier_payment(uuid, numeric, date, text, text)              to authenticated;
grant execute on function public.supplier_return(uuid, jsonb, text, date, text, text)           to authenticated;
grant execute on function public.supplier_void(uuid, text)                                      to authenticated;
grant execute on function public.set_product_cost(text, numeric)                                to authenticated;
