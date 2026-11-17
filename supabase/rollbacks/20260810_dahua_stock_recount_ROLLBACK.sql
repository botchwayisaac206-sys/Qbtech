-- ─────────────────────────────────────────────────────────────
-- ROLLBACK for 20260810_dahua_stock_recount.sql
--
-- Snapshot of warehouse 'DAHUA-SHOWROOM' taken 2026-08-10T16:31:01.017Z
-- BEFORE the recount migration was applied. Verified clean at capture time:
-- none of the 10 newly-inserted models were present.
--
-- Restores opening_stock and min_level to their pre-recount values and
-- deletes the 10 inserted rows, then recomputes the derived columns.
--
-- WHAT THIS DOES NOT UNDO
--   * Invoices raised after the recount still count. This script deliberately
--     restores only opening_stock/min_level and RECOMPUTES closing_stock from
--     whatever daily_taken/invoice_taken hold at rollback time, so stock issued
--     in between is not silently resurrected.
--   * If any of the 10 inserted models were sold before you roll back, their
--     dahua_invoice_items rows will keep a stock_id pointing at a deleted row
--     (the FK is ON DELETE unset, so the delete will fail — see step 2).
--
-- Run once, in the Supabase SQL editor.
-- ─────────────────────────────────────────────────────────────

begin;

-- ── 1. Restore opening_stock / min_level on the 78 updated rows ────
with prior(model, opening_stock, min_level) as (
  values
    ('DHI-NVR5464-EL 64CH',                               2,    null),
    ('DH-IPC-HDW2449T-S-PRO WIZ COLOR',                   1,    null),
    ('DH-IPC-HFW2439MP-AS-LED-B-S2 FULL COLOR',           2,    null),
    ('DH-XVR5232AN-I3 HDCVI DIGITAL',                     2,    null),
    ('DH-XVR4232AN-I DIGITAL VIDEO RECORDER',             2,    null),
    ('DHI-NVR2216-4KS3 16CH NVR',                         4,    null),
    ('DHI-NVR4432-4KS3 32CH',                             3,    null),
    ('DH-CS4218-16ET-240 POE SWITCH',                     6,    null),
    ('DHI-NVR1104HS-P-S3/H NETWORK VIDEO RECORDER',      18,    null),
    ('DHI-NVR1108HS-8P-S3/H NETWORK VIDEO RECORDER',     27,    null),
    ('DH-KIT/XVR1B08-1/8-HFW1200CLP-IL-A0360B',           1,    null),
    ('DH-SD3C405DB-GNY-A-PV',                             2,    null),
    ('DH-SD3E405DB-GNY-A-PV1',                            1,    null),
    ('DH-IPC-HFW1239TL1-A-IL 2MP',                      478,    null),
    ('DH-CS4226-24ET-375 POE SWITCH',                    18,    null),
    ('DH-IPC-HDW1439V-A-IL 4MP INDOOR',                 100,    null),
    ('DHI-NVR4232-16P-4KS3 32CH WITH POE',                7,    null),
    ('DH-IPC-HFW2849T-AS-IL SMART DUAL LIGHT',            4,    null),
    ('DH-HAC-T1A21P-U 2MP',                             127,    null),
    ('DH-HAC-B1A21P-U 2MP ',                             89,    null),
    ('DH-PFM976-631 RJ45 CONNECTOR',                    500,    null),
    ('DH-PFM976-631-PT RJ45 CONNECTOR',                 500,    null),
    ('DH-IPC-HDW1230T1-S5',                               2,    null),
    ('DH-HAC-HFW1500CLP-IL-A   5MP',                    227,    null),
    ('DH-HAC-HFW1200TLMP-IL-T 2MP',                      15,    null),
    ('DH-PFM914 CRIMPING TOOL',                         469,    null),
    ('DH-IPC-HFW2249TL-S-PV 2MP',                         5,    null),
    ('DH-HAC-T1A21P-U-IL-A 2MP',                         40,    null),
    ('DH-IPC-HDW2549T-S-IL 5MP',                         29,    null),
    ('DH-IPC-HFW1439S-A-LED-S4 4MP',                     39,    null),
    ('DH-IPC-HFW2549S-S-IL 5MP',                         20,    null),
    ('DH-PFM344D-8CH-BS POWER SUPPLY',                  108,    null),
    ('DH-IPC-HDW1239T1-LED-S5 2MP',                       9,    null),
    ('DH-IPC-HDW1239T1-A-LED 2MP',                       18,    null),
    ('DH-IPC-HDW2649T-S-IL 6MP',                         14,    null),
    ('DH-IPC-HFW2649S-S-IL 6MP',                         20,    null),
    ('DH-IPC-HFW2449S-S-IL 4MP',                         54,    null),
    ('DH-IPC-HDW1439V-PV 4MP',                           40,    null),
    ('DH-IPC-HDW1239V-PV 2MP',                           22,    null),
    ('DH-HAC-HFW1200RLP-IL-T 2MP',                       18,    null),
    ('DH-IPC-HFW1431S1P-S4 4MP',                          5,    null),
    ('DH-IPC-HFW1239TL1-PV 2MP',                          5,    null),
    ('DH-HAC-B1A21P-U-IL-A 2MP',                         25,    null),
    ('DH-IPC-HFW2439SP-SA-LED-S2 4MP ',                   9,    null),
    ('DH-HAC-HFW1509CLP-A-LED 5MP',                      25,    null),
    ('DH-HAC-HDW1509CLQP-A-LED 5MP ',                    80,    null),
    ('DH-IPC-HDW1239V-A-IL 2MP',                         58,    null),
    ('DH-HAC-HFW1500RLP-IL-T 5MP',                       20,    null),
    ('DH-HAC-HDW1500TQP-IL-T 5MP',                       17,    null),
    ('DH-HAC-HDW1209CLQP-A-LED 2MP',                     30,    null),
    ('DH-HAC-T2A51P 5MP',                                 4,    null),
    ('DH-HAC-T2A21P 2MP',                                 5,    null),
    ('DH-PFA12A JUNCTION BOX',                          180,    null),
    ('DH-HAC-PTS1500CP-E2-IL-A 5MP',                      5,    null),
    ('DH-H5D-5F 10MP',                                    8,    null),
    ('DH-H5B 5MP',                                        9,    null),
    ('DH-H5A 5MP',                                       11,    null),
    ('DH-IPC-PDW3849-A180-AS-PV 8MP',                     1,    null),
    ('DH-T4A-PV 4MP',                                     9,    null),
    ('DH-SD2A500NB-GNY-A-PV 5MP',                         1,    null),
    ('DH-P5AE-PV 5MP',                                    1,    null),
    ('DH-SD2C400NA-B-PV-PRO 4MP',                         1,    null),
    ('DHI-ASA1222GL ACCESS CONTROL',                      1,    null),
    ('DHI-KTA02 VIDEO INTERCOM KIT',                     28,    null),
    ('DH-CS4010-8ET2GT-110 SWITCH',                      18,    null),
    ('DH-CS4010-ET-110 SWITCH',                          10,    null),
    ('DH-HAC-PT1509AP-A-LED 5MP',                         2,    null),
    ('DH-IPC-HFW1239DT-4G-ST-IL-EU-B 2MP',                1,    null),
    ('DH-IPC-HFW1230S1-S5 2MP',                           1,    null),
    ('DH-C3A 3MP',                                        3,    null),
    ('DH-PFM800-N',                                      90,    null),
    ('DHI-KTH01',                                         5,    null),
    ('DH-HAC-ME1239THP-A-PV',                             5,    null),
    ('DH-IPC-HDW2249T-S-PV',                              5,    null),
    ('DH-HAC-ME1239HP-A-PV',                              5,    null),
    ('DHI-NVR5464-16P-EL',                                1,    null),
    ('DH-PFM979-DCP POWER PIN',                       15450,    null),
    ('DH-CS4006-4ET2GT-60  SWITCH',                      12,    null)
)
update dahua_stock s
   set opening_stock = p.opening_stock,
       min_level     = p.min_level,
       updated_at    = now()
  from prior p
 where s.warehouse = 'DAHUA-SHOWROOM'
   and s.model     = p.model;

-- ── 2. Remove the 10 inserted rows ───────────────────────────────
-- Guarded: only deletes rows never referenced by an invoice and never touched.
delete from dahua_stock s
 where s.warehouse = 'DAHUA-SHOWROOM'
   and s.model in (
         'DH-BP3EW-4G',
         'DH-IPC-EB5541P-AS',
         'DH-H3B',
         'DH-P5B-PV',
         'DH-HAC-PT1500AP-IL-A',
         'DH-IPC-PTS2649C-3E3Z-4GB20',
         'DH-IPC-HDW1200TQP-IL-T',
         'DH-CS4010-8ET2GT-60',
         'DH-PFM344D-4CH-BS',
         'DHI-KTW03'
       )
   and coalesce(s.invoice_taken, 0) = 0
   and s.daily_taken = '{}'::jsonb
   and not exists (select 1 from dahua_invoice_items i where i.stock_id = s.id);

-- ── 3. Recompute derived columns ──────────────────────────────
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

-- ── Check what survived ───────────────────────────────────────
-- Any inserted model still listed here was sold or edited, so it was kept:
-- select model, opening_stock, invoice_taken, daily_taken
--   from dahua_stock
--  where warehouse = 'DAHUA-SHOWROOM'
--    and model in ('DH-BP3EW-4G', 'DH-IPC-EB5541P-AS', 'DH-H3B' /* … */);
