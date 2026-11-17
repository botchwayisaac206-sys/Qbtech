-- ============================================================================
-- QBNET TECH — remove the Dahua stock line's data
--
-- The app no longer has a Dahua line (main shop only). This empties what the
-- Dahua line recorded: its invoices, expenses, deliveries, stock, warehouses,
-- barcodes, transfers, its credit sales, its approval requests and its
-- entries in the activity log.
--
-- The TABLES are kept, empty. Database functions still refer to them, and a
-- dropped table would make those functions fail. The approval table
-- dahua_movement_requests is shared with the main shop despite its name:
-- only the Dahua requests in it are removed.
--
-- NOT touched: anything of the main shop, including old moves between the
-- main shop and Dahua in the main shop's transfer history (they explain the
-- main shop's stock figures).
--
-- It cannot be undone. Take a backup first (Database → Backups).
-- Run STEP 1 first (read-only), then STEP 2. STEP 2 is one transaction.
-- ============================================================================


-- ── STEP 1 · Preview (read-only) ───────────────────────────────────────────
-- Rows each Dahua table holds now (tables this database lacks are skipped).
do $$
declare t text; n bigint;
begin
  foreach t in array array[
    'dahua_invoices', 'dahua_invoice_items', 'dahua_expenses', 'dahua_deliveries',
    'dahua_stock', 'dahua_warehouses', 'dahua_product_codes',
    'dahua_stock_transfers', 'dahua_stock_transfer_items'
  ] loop
    if to_regclass('public.' || t) is not null then
      execute format('select count(*) from public.%I', t) into n;
      raise notice '% : % rows', t, n;
    end if;
  end loop;
  if to_regclass('public.dahua_movement_requests') is not null then
    select count(*) into n from public.dahua_movement_requests where to_line = 'dahua' or from_line = 'dahua';
    raise notice 'Dahua approval requests : %', n;
  end if;
  if to_regclass('public.debts') is not null then
    select count(*) into n from public.debts where line = 'dahua';
    raise notice 'Dahua credit sales : %', n;
  end if;
  select count(*) into n from public.audit_log where table_name like 'dahua\_%';
  raise notice 'Dahua activity-log entries : %', n;
end $$;


-- ── STEP 2 · Remove ────────────────────────────────────────────────────────
begin;

do $$
declare
  wanted text[] := array[
    'dahua_invoice_items', 'dahua_invoices', 'dahua_expenses', 'dahua_deliveries',
    'dahua_stock_transfer_items', 'dahua_stock_transfers',
    'dahua_product_codes', 'dahua_stock', 'dahua_warehouses'
  ];
  present text;
begin
  select string_agg(format('public.%I', t), ', ') into present
    from unnest(wanted) t where to_regclass('public.' || t) is not null;
  -- No CASCADE on purpose: if a main-shop table points at one of these, this
  -- stops with an error instead of quietly emptying that table too.
  if present is not null then
    execute 'truncate table ' || present;
    raise notice 'Emptied: %', present;
  end if;

  -- Credit sales on the Dahua line: payments first, then the debts.
  if to_regclass('public.debts') is not null then
    delete from public.debt_payments where debt_id in (select id from public.debts where line = 'dahua');
    delete from public.debts where line = 'dahua';
  end if;

  -- "Stock already deducted" markers for Dahua invoices.
  if to_regclass('public.invoice_stock_deductions') is not null then
    delete from public.invoice_stock_deductions where line = 'dahua';
  end if;

  -- Dahua requests in the shared approval table. Main-shop requests stay.
  if to_regclass('public.dahua_movement_requests') is not null then
    delete from public.dahua_movement_requests where to_line = 'dahua' or from_line = 'dahua';
  end if;
end $$;

-- The Dahua tables' entries in the activity log.
delete from public.audit_log where table_name like 'dahua\_%';

commit;
