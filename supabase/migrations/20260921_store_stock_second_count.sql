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
