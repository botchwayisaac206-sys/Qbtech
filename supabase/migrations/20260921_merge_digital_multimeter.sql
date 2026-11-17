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
