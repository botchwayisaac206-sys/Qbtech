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
