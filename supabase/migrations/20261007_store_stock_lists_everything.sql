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
