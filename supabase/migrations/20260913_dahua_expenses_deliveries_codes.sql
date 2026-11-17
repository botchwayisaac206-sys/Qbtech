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
create policy dexp_read on public.dahua_expenses for select
  using (
    (select public.is_superboss())
    or ((select public.is_restricted_boss()) and incurred_at >= (select public.window_start()))
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists dexp_insert on public.dahua_expenses;
create policy dexp_insert on public.dahua_expenses for insert
  with check (
    (select public.is_superboss())
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists dexp_update on public.dahua_expenses;
create policy dexp_update on public.dahua_expenses for update
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

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
create policy ddel_read on public.dahua_deliveries for select
  using (
    (select public.is_superboss())
    or ((select public.is_restricted_boss()) and delivered_at >= (select public.window_start()))
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists ddel_insert on public.dahua_deliveries;
create policy ddel_insert on public.dahua_deliveries for insert
  with check (
    (select public.is_superboss())
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists ddel_update on public.dahua_deliveries;
create policy ddel_update on public.dahua_deliveries for update
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

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
create policy "read dahua_product_codes" on public.dahua_product_codes
  for select to authenticated using (true);

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
