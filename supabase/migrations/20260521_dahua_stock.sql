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
create policy "read dahua_warehouses" on dahua_warehouses
  for select to authenticated using (true);

-- Only boss/admin can add, edit, delete warehouses
create policy "boss write dahua_warehouses" on dahua_warehouses
  for all to authenticated
  using (exists (
    select 1 from user_roles
    where user_id = auth.uid() and role in ('boss','admin')
  ));

-- ── dahua_stock ───────────────────────────────────────────────
-- All authenticated users can read
create policy "read dahua_stock" on dahua_stock
  for select to authenticated using (true);

-- Only boss/admin can INSERT new items or DELETE items
create policy "boss insert dahua_stock" on dahua_stock
  for insert to authenticated
  with check (exists (
    select 1 from user_roles
    where user_id = auth.uid() and role in ('boss','admin')
  ));

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
create policy "staff update dahua_stock" on dahua_stock
  for update to authenticated
  using (true)
  with check (true);

-- ── dahua_invoices ────────────────────────────────────────────
-- All authenticated users can read
create policy "read dahua_invoices" on dahua_invoices
  for select to authenticated using (true);

-- All authenticated users can create invoices (boss + cashier)
create policy "write dahua_invoices" on dahua_invoices
  for insert to authenticated
  with check (true);

-- Only boss/admin can edit or delete invoices
create policy "boss update dahua_invoices" on dahua_invoices
  for update to authenticated
  using (exists (
    select 1 from user_roles
    where user_id = auth.uid() and role in ('boss','admin')
  ));

create policy "boss delete dahua_invoices" on dahua_invoices
  for delete to authenticated
  using (exists (
    select 1 from user_roles
    where user_id = auth.uid() and role in ('boss','admin')
  ));

-- ── dahua_invoice_items ───────────────────────────────────────
-- All authenticated users can read
create policy "read dahua_invoice_items" on dahua_invoice_items
  for select to authenticated using (true);

-- All authenticated users can insert line items (part of creating an invoice)
create policy "write dahua_invoice_items" on dahua_invoice_items
  for insert to authenticated
  with check (true);

-- Only boss/admin can edit or delete invoice line items
create policy "boss update dahua_invoice_items" on dahua_invoice_items
  for update to authenticated
  using (exists (
    select 1 from user_roles
    where user_id = auth.uid() and role in ('boss','admin')
  ));

create policy "boss delete dahua_invoice_items" on dahua_invoice_items
  for delete to authenticated
  using (exists (
    select 1 from user_roles
    where user_id = auth.uid() and role in ('boss','admin')
  ));
