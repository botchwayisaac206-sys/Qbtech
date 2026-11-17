-- ============================================================================
-- QBNET TECH — clear the dummy (demo) data
--
-- The project's original seed scripts filled the database with fake sales so
-- the dashboard had something to draw. Every fake row was tagged:
--
--   invoices   invoice_number like 'INV-DEMO-%'    (~1,000+ over 3 years)
--              invoice_number like 'INV-FOCUS-%'   (68 "recent" ones)
--   expenses   description = 'Auto-seeded demo expense'   (400)
--              description = 'Focus seed expense'         (30)
--
-- This script removes exactly those rows and everything hanging off them.
-- Real invoices (INV-<year>-<n>), real expenses, staff, products, stock
-- levels and prices are NOT touched.
--
-- HOW TO RUN (Supabase dashboard → SQL Editor):
--   1. Run STEP 1 on its own. It only reads, and shows what will go.
--   2. Run STEP 2. It runs in one transaction: all of it happens, or none.
--   STEP 3 is an optional full reset, commented out. Read it before using it.
-- ============================================================================


-- ── STEP 1 · Preview (read-only) ───────────────────────────────────────────
select 'demo invoices' as what, count(*) as rows, min(issued_at)::date as oldest, max(issued_at)::date as newest
  from public.invoices where invoice_number like 'INV-DEMO-%' or invoice_number like 'INV-FOCUS-%'
union all
select 'their line items', count(*), null, null
  from public.invoice_items ii join public.invoices i on i.id = ii.invoice_id
 where i.invoice_number like 'INV-DEMO-%' or i.invoice_number like 'INV-FOCUS-%'
union all
select 'demo expenses', count(*), min(incurred_at)::date, max(incurred_at)::date
  from public.expenses where description in ('Auto-seeded demo expense', 'Focus seed expense')
union all
select 'REAL invoices (kept)', count(*), min(issued_at)::date, max(issued_at)::date
  from public.invoices where invoice_number not like 'INV-DEMO-%' and invoice_number not like 'INV-FOCUS-%'
union all
select 'REAL expenses (kept)', count(*), min(incurred_at)::date, max(incurred_at)::date
  from public.expenses where description is distinct from 'Auto-seeded demo expense'
                         and description is distinct from 'Focus seed expense';


-- ── STEP 2 · Delete the dummy rows ─────────────────────────────────────────
begin;

-- The rows to remove, collected once so every delete below agrees.
create temp table _demo_inv on commit drop as
  select id, invoice_number from public.invoices
   where invoice_number like 'INV-DEMO-%' or invoice_number like 'INV-FOCUS-%';

create temp table _demo_exp on commit drop as
  select id from public.expenses
   where description in ('Auto-seeded demo expense', 'Focus seed expense');

-- Anything linked to a demo invoice. Each table is skipped if this database
-- does not have it yet (older migrations), so the script never fails on that.
do $$
begin
  -- Price-watch alerts would otherwise be kept with a blank invoice.
  if to_regclass('public.watch_alerts') is not null then
    delete from public.watch_alerts where invoice_id in (select id from _demo_inv);
  end if;
  -- "Stock already deducted" markers (no foreign key, so not cleaned up by cascade).
  if to_regclass('public.invoice_stock_deductions') is not null then
    delete from public.invoice_stock_deductions where line = 'main' and invoice_id in (select id from _demo_inv);
  end if;
  -- Credit sales on a demo invoice. Payments first, then the debt, so the
  -- payment triggers never try to update a debt that is mid-delete.
  if to_regclass('public.debts') is not null then
    create temp table _demo_debts on commit drop as
      select id from public.debts where line = 'main'
         and (invoice_id in (select id from _demo_inv) or invoice_number in (select invoice_number from _demo_inv));
    create temp table _demo_pay on commit drop as
      select id from public.debt_payments where debt_id in (select id from _demo_debts);
    delete from public.debt_payments where id in (select id from _demo_pay);
    delete from public.debts where id in (select id from _demo_debts);
    delete from public.audit_log
     where (table_name = 'debts' and row_id in (select id::text from _demo_debts))
        or (table_name = 'debt_payments' and row_id in (select id::text from _demo_pay));
  end if;
  -- Deliveries logged from a demo invoice.
  if to_regclass('public.deliveries') is not null
     and exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'deliveries' and column_name = 'invoice_number') then
    create temp table _demo_del on commit drop as
      select id from public.deliveries where invoice_number in (select invoice_number from _demo_inv);
    delete from public.deliveries where id in (select id from _demo_del);
    delete from public.audit_log where table_name = 'deliveries' and row_id in (select id::text from _demo_del);
  end if;
end $$;

-- The invoices themselves. invoice_items go with them (on delete cascade).
delete from public.invoices where id in (select id from _demo_inv);
delete from public.expenses where id in (select id from _demo_exp);

-- The audit log recorded every fake row twice (when seeded, and just now when
-- deleted). Neither entry is real activity, so both are removed to keep the
-- Log tab about the real business.
delete from public.audit_log
 where (table_name = 'invoices' and row_id in (select id::text from _demo_inv))
    or (table_name = 'expenses' and row_id in (select id::text from _demo_exp));

-- Check: both counts must be 0.
select
  (select count(*) from public.invoices where invoice_number like 'INV-DEMO-%' or invoice_number like 'INV-FOCUS-%') as demo_invoices_left,
  (select count(*) from public.expenses where description in ('Auto-seeded demo expense', 'Focus seed expense'))    as demo_expenses_left;

commit;


-- ── STEP 3 · OPTIONAL: full fresh start (go-live reset) ────────────────────
-- Use ONLY if everything recorded so far was testing — including invoices
-- typed by staff while trying the system — and you want the books to start
-- empty on go-live day.
--
-- Empties: invoices + items, expenses, deliveries, debts + payments, transfers,
-- stock movement requests, supplier documents, stock clearances, the audit log,
-- and the same for the Dahua line.
-- Keeps:   staff and roles, products, price lists, product codes, suppliers,
--          cost prices, warehouses, and every stock level AS IT IS NOW
--          (wiping sales does not put stock back — recount if needed).
-- Invoice numbers restart from INV-<year>-1 on their own.
--
-- It cannot be undone. Take a backup first (Database → Backups), then remove
-- the /* and */ lines and run it.
/*
do $$
declare
  wanted text[] := array[
    'invoice_items', 'watch_alerts', 'invoice_stock_deductions', 'invoices',
    'expenses', 'deliveries', 'debt_payments', 'debts',
    'stock_transfer_items', 'stock_transfers', 'stock_movement_requests',
    'supplier_doc_items', 'supplier_docs', 'stock_clearances',
    'dahua_invoice_items', 'dahua_invoices', 'dahua_expenses', 'dahua_deliveries',
    'dahua_stock_transfer_items', 'dahua_stock_transfers', 'dahua_movement_requests',
    'audit_log'
  ];
  present text;
begin
  -- Only the tables this database actually has.
  select string_agg(format('public.%I', t), ', ') into present
    from unnest(wanted) t where to_regclass('public.' || t) is not null;
  -- No CASCADE on purpose: if some other table points at one of these, the
  -- reset stops with an error instead of quietly emptying that table too.
  execute 'truncate table ' || present || ' restart identity';
  raise notice 'Emptied: %', present;
end $$;
*/
