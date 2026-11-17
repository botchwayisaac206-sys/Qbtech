-- ─────────────────────────────────────────────────────────────
-- Dahua stock recount — 2026-08-10
--
-- Sets opening_stock from a physical count sheet, inserts models that
-- were not previously tracked, then recomputes the derived columns.
--
-- SCOPE: warehouse 'DAHUA-SHOWROOM' only. This is the sole warehouse
-- present in dahua_stock; the four section headings on the count sheet
-- (MAIN / OTHER ACCESSORIES / INTERCOM / SHOP MINI) were pooled into it,
-- and a model appearing in more than one section had its counts summed.
--
--    78 rows updated  (opening_stock overwritten, not added to)
--    10 rows inserted (models not previously in the table)
--    39 rows untouched (not on the count sheet — keep current values)
--
-- daily_taken and invoice_taken are PRESERVED on updated rows, so units
-- already issued via invoices or daily entries are not lost. Rows 1-19 of
-- the count sheet's main section were not supplied and are not covered.
--
-- Run once, in the Supabase SQL editor. Wrapped in a transaction.
-- ─────────────────────────────────────────────────────────────

begin;

-- ── 1. Update opening_stock for models already tracked ────────
with incoming(model, opening_stock) as (
  values
    ('DH-SD3E405DB-GNY-A-PV1',                            1),
    ('DH-SD3C405DB-GNY-A-PV',                             7),
    ('DH-H5D-5F 10MP',                                   11),
    ('DH-H5B 5MP',                                        9),
    ('DH-H5A 5MP',                                       11),
    ('DH-C3A 3MP',                                        1),
    ('DH-HAC-PTS1500CP-E2-IL-A 5MP',                      5),
    ('DH-T4A-PV 4MP',                                     8),
    ('DH-P5AE-PV 5MP',                                    1),
    ('DH-SD2A500NB-GNY-A-PV 5MP',                         1),
    ('DH-HAC-PT1509AP-A-LED 5MP',                         2),
    ('DH-SD2C400NA-B-PV-PRO 4MP',                         1),
    ('DH-HAC-ME1239THP-A-PV',                             5),
    ('DH-HAC-ME1239HP-A-PV',                              5),
    ('DH-IPC-HDW2249T-S-PV',                              5),
    ('DH-IPC-HFW1230S1-S5 2MP',                           1),
    ('DH-IPC-HFW2249TL-S-PV 2MP',                         5),
    ('DH-IPC-PDW3849-A180-AS-PV 8MP',                     1),
    ('DH-IPC-HFW1239DT-4G-ST-IL-EU-B 2MP',                1),
    ('DH-HAC-T2A21P 2MP',                                 5),
    ('DH-IPC-HDW1230T1-S5',                               2),
    ('DH-IPC-HFW1239TL1-PV 2MP',                         41),
    ('DH-IPC-HFW1431S1P-S4 4MP',                          5),
    ('DH-HAC-HFW1200TLMP-IL-T 2MP',                      16),
    ('DH-HAC-T2A51P 5MP',                                 4),
    ('DHI-NVR1108HS-8P-S3/H NETWORK VIDEO RECORDER',     25),
    ('DH-KIT/XVR1B08-1/8-HFW1200CLP-IL-A0360B',           2),
    ('DHI-NVR5464-EL 64CH',                               1),
    ('DH-IPC-HFW2439MP-AS-LED-B-S2 FULL COLOR',           2),
    ('DH-HAC-T1A21P-U 2MP',                             117),
    ('DH-HAC-HDW1509CLQP-A-LED 5MP ',                    71),
    ('DH-HAC-HFW1509CLP-A-LED 5MP',                      22),
    ('DH-HAC-HFW1500RLP-IL-T 5MP',                       22),
    ('DH-HAC-B1A21P-U 2MP ',                             85),
    ('DH-HAC-HFW1500CLP-IL-A   5MP',                    231),
    ('DH-IPC-HFW1439S-A-LED-S4 4MP',                     39),
    ('DH-IPC-HFW2549S-S-IL 5MP',                         20),
    ('DH-IPC-HDW1439V-PV 4MP',                           41),
    ('DH-IPC-HDW1239V-A-IL 2MP',                         48),
    ('DH-IPC-HDW2549T-S-IL 5MP',                         30),
    ('DH-IPC-HFW2649S-S-IL 6MP',                         20),
    ('DH-IPC-HDW1239T1-LED-S5 2MP',                       9),
    ('DH-IPC-HDW1239T1-A-LED 2MP',                       13),
    ('DH-IPC-HDW2649T-S-IL 6MP',                         30),
    ('DH-IPC-HFW2439SP-SA-LED-S2 4MP ',                   4),
    ('DH-IPC-HFW2449S-S-IL 4MP',                         54),
    ('DH-HAC-HDW1500TQP-IL-T 5MP',                       17),
    ('DH-HAC-HFW1200RLP-IL-T 2MP',                       11),
    ('DH-HAC-T1A21P-U-IL-A 2MP',                         26),
    ('DH-HAC-B1A21P-U-IL-A 2MP',                          1),
    ('DH-IPC-HDW1239V-PV 2MP',                           20),
    ('DH-HAC-HDW1209CLQP-A-LED 2MP',                      7),
    ('DH-IPC-HFW2849T-AS-IL SMART DUAL LIGHT',            4),
    ('DH-IPC-HDW2449T-S-PRO WIZ COLOR',                   1),
    ('DHI-NVR1104HS-P-S3/H NETWORK VIDEO RECORDER',      15),
    ('DH-XVR5232AN-I3 HDCVI DIGITAL',                     2),
    ('DH-XVR4232AN-I DIGITAL VIDEO RECORDER',             2),
    ('DHI-NVR2216-4KS3 16CH NVR',                         4),
    ('DHI-NVR4232-16P-4KS3 32CH WITH POE',                5),
    ('DHI-NVR5464-16P-EL',                                1),
    ('DHI-NVR4432-4KS3 32CH',                             3),
    ('DH-CS4226-24ET-375 POE SWITCH',                    26),
    ('DH-CS4218-16ET-240 POE SWITCH',                     6),
    ('DH-CS4010-ET-110 SWITCH',                          10),
    ('DH-CS4010-8ET2GT-110 SWITCH',                       8),
    ('DH-CS4006-4ET2GT-60  SWITCH',                      11),
    ('DH-PFM976-631-PT RJ45 CONNECTOR',               50000),
    ('DH-PFM976-631 RJ45 CONNECTOR',                  50000),
    ('DH-PFM800-N',                                      90),
    ('DH-PFM914 CRIMPING TOOL',                         499),
    ('DH-PFM979-DCP POWER PIN',                       15500),
    ('DH-PFA12A JUNCTION BOX',                          160),
    ('DH-PFM344D-8CH-BS POWER SUPPLY',                   42),
    ('DHI-KTH01',                                        12),
    ('DHI-KTA02 VIDEO INTERCOM KIT',                     30),
    ('DHI-ASA1222GL ACCESS CONTROL',                      1),
    ('DH-IPC-HFW1239TL1-A-IL 2MP',                       61),
    ('DH-IPC-HDW1439V-A-IL 4MP INDOOR',                  30)
)
update dahua_stock s
   set opening_stock = i.opening_stock,
       updated_at    = now()
  from incoming i
 where s.warehouse = 'DAHUA-SHOWROOM'
   and s.model     = i.model;

-- ── 2. Insert models not previously tracked ───────────────────
insert into dahua_stock (warehouse, model, opening_stock, daily_taken, invoice_taken, min_level)
select 'DAHUA-SHOWROOM', v.model, v.opening_stock, '{}'::jsonb, 0, null
  from (values
    ('DH-BP3EW-4G',                    32),
    ('DH-IPC-EB5541P-AS',               2),
    ('DH-H3B',                          3),
    ('DH-P5B-PV',                       5),
    ('DH-HAC-PT1500AP-IL-A',            3),
    ('DH-IPC-PTS2649C-3E3Z-4GB20',     17),
    ('DH-IPC-HDW1200TQP-IL-T',         20),
    ('DH-CS4010-8ET2GT-60',             6),
    ('DH-PFM344D-4CH-BS',              93),
    ('DHI-KTW03',                       2)
       ) as v(model, opening_stock)
 where not exists (
         select 1 from dahua_stock s
          where s.warehouse = 'DAHUA-SHOWROOM'
            and s.model     = v.model
       );

-- ── 3. Recompute derived columns ──────────────────────────────
-- total_taken   = manual daily entries + invoice deductions
-- closing_stock = opening_stock - total_taken
-- stock_status  = '' when no min_level, else LOW / OK
-- Mirrors computeTotals() / computeStatus() in DahuaStockTab.tsx.
update dahua_stock s
   set total_taken   = t.taken,
       closing_stock = s.opening_stock - t.taken,
       stock_status  = case
                         when coalesce(s.min_level, 0) = 0 then ''
                         when s.opening_stock - t.taken < s.min_level then 'LOW'
                         else 'OK'
                       end,
       updated_at    = now()
  from (
         select id,
                coalesce((select sum(value::int)
                            from jsonb_each_text(daily_taken)), 0)
              + coalesce(invoice_taken, 0) as taken
           from dahua_stock
          where warehouse = 'DAHUA-SHOWROOM'
       ) t
 where t.id = s.id;

commit;

-- ── Verification (run after committing) ───────────────────────
-- select count(*)                              as total_rows,
--        count(*) filter (where closing_stock < 0) as negative_closing
--   from dahua_stock where warehouse = 'DAHUA-SHOWROOM';
