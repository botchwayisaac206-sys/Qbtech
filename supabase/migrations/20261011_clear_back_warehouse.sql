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
