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
