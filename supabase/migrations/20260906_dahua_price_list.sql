-- ─────────────────────────────────────────────────────────────
-- Dahua price list — 2026-09-06
--
-- Sets dahua_stock.unit_price from the shop's price sheet. Requires
-- 20260906_dahua_pricing.sql (the unit_price column and its triggers).
--
-- Run it in the Supabase SQL editor. The SQL editor connects as postgres with
-- no JWT, which trg_dahua_stock_lock_price treats as a privileged console
-- session and lets through; the lock still binds every price change that
-- arrives through the app. (If the trigger rejects this file, the database is
-- still on the first version of 20260906_dahua_pricing.sql — re-run that file,
-- it is idempotent, then come back to this one.)
--
-- MATCHING
--   The sheet writes bare model codes ("DH-H5B") while dahua_stock stores the
--   code plus a descriptor ("DH-H5B 5MP"), so codes were matched on the model
--   with that trailing descriptor removed, ignoring case and punctuation.
--   68 matched outright. 9 were accepted as character misreads where the
--   intent is unambiguous (I read as 1, S as 5, EI for EL); each is marked
--   inline with the code as it appears on the sheet.
--
--   Lookalikes were NOT auto-matched. A digit that changes the megapixel class
--   (1239 vs 1439) or the series letters (HFW vs HDW) is a different camera,
--   so those are left for a decision rather than guessed at — see the notes at
--   the foot of this file.
--
-- Prices are in GH¢. Re-running is safe: it simply reasserts the same values.
-- ─────────────────────────────────────────────────────────────

begin;

with incoming(model, price) as (
  values
    ('DH-BP3EW-4G'                            ,     750),
    ('DH-C3A 3MP'                             ,     350),
    ('DH-CS4006-4ET2GT-60  SWITCH'            ,     400),
    ('DH-CS4010-8ET2GT-110 SWITCH'            ,     600),  -- sheet reads "DHI-CS410-8ET2GT---110"
    ('DH-CS4010-8ET2GT-60'                    ,     500),
    ('DH-CS4218-16ET-240 POE SWITCH'          ,    1600),
    ('DH-H3B'                                 ,     700),
    ('DH-H5A 5MP'                             ,     500),
    ('DH-H5B 5MP'                             ,     600),
    ('DH-H5D-5F 10MP'                         ,     650),
    ('DH-HAC-B1A21P-U 2MP '                   ,     150),  -- sheet reads "DH-HAC-BIA21P-U"
    ('DH-HAC-B1A21P-U-IL-A 2MP'               ,     180),  -- sheet reads "DH-HAC-BIA21P-U-IL-A"
    ('DH-HAC-HDW1209CLQP-A-LED 2MP'           ,     190),
    ('DH-HAC-HDW1500TQP-IL-T 5MP'             ,     320),
    ('DH-HAC-HDW1509CLQP-A-LED 5MP '          ,     295),
    ('DH-HAC-HFW1200TLMP-IL-T 2MP'            ,     300),
    ('DH-HAC-HFW1500CLP-IL-A   5MP'           ,     200),
    ('DH-HAC-HFW1500RLP-IL-T 5MP'             ,     320),
    ('DH-HAC-HFW1509CLP-A-LED 5MP'            ,     295),
    ('DH-HAC-ME1239HP-A-PV'                   ,     450),
    ('DH-HAC-ME1239THP-A-PV'                  ,     450),
    ('DH-HAC-PT1500AP-IL-A'                   ,     550),
    ('DH-HAC-PT1509AP-A-LED 5MP'              ,     550),
    ('DH-HAC-PTS1500CP-E2-IL-A 5MP'           ,     700),
    ('DH-HAC-T1A21P-U-IL-A 2MP'               ,     180),
    ('DH-HAC-T2A21P 2MP'                      ,     150),
    ('DH-IPC-EB5541P-AS'                      ,    2000),
    ('DH-IPC-HDW1200TQP-IL-T'                 ,     250),
    ('DH-IPC-HDW1239T1-A-LED 2MP'             ,     350),
    ('DH-IPC-HDW1239T1-LED-S5 2MP'            ,     350),
    ('DH-IPC-HDW1239V-PV 2MP'                 ,     450),
    ('DH-IPC-HDW1439V-A-IL 4MP INDOOR'        ,     555),
    ('DH-IPC-HDW1439V-PV 4MP'                 ,     550),
    ('DH-IPC-HDW2249T-S-PV'                   ,     650),
    ('DH-IPC-HDW2449T-S-PRO WIZ COLOR'        ,     950),
    ('DH-IPC-HDW2549T-S-IL 5MP'               ,     750),  -- sheet reads "DH-IPC-HDW2549T-5-IL"
    ('DH-IPC-HDW2649T-S-IL 6MP'               ,     750),
    ('DH-IPC-HFW1230S1-S5 2MP'                ,     300),
    ('DH-IPC-HFW1239DT-4G-ST-IL-EU-B 2MP'     ,     800),
    ('DH-IPC-HFW1239TL1-A-IL 2MP'             ,     410),
    ('DH-IPC-HFW1239TL1-PV 2MP'               ,     420),
    ('DH-IPC-HFW1431S1P-S4 4MP'               ,     300),
    ('DH-IPC-HFW1439S-A-LED-S4 4MP'           ,     500),
    ('DH-IPC-HFW2249TL-S-PV 2MP'              ,     650),
    ('DH-IPC-HFW2439MP-AS-LED-B-S2 FULL COLOR',     700),
    ('DH-IPC-HFW2439SP-SA-LED-S2 4MP '        ,     500),
    ('DH-IPC-HFW2449S-S-IL 4MP'               ,     650),
    ('DH-IPC-HFW2549S-S-IL 5MP'               ,     750),
    ('DH-IPC-HFW2649S-S-IL 6MP'               ,     750),
    ('DH-IPC-HFW2849T-AS-IL SMART DUAL LIGHT' ,    1300),
    ('DH-IPC-PDW3849-A180-AS-PV 8MP'          ,    2700),
    ('DH-IPC-PTS2649C-3E3Z-4GB20'             ,    1850),
    ('DH-KIT/XVR1B08-1/8-HFW1200CLP-IL-A0360B',    2450),  -- sheet reads "DH-KIT/XVR1B08-I/8-HFW1200CLP-IL-A-0360B"
    ('DH-P5B-PV'                              ,     650),
    ('DH-PFA12A JUNCTION BOX'                 ,      35),
    ('DH-PFM344D-4CH-BS'                      ,     100),
    ('DH-PFM344D-8CH-BS POWER SUPPLY'         ,     130),
    ('DH-PFM800-N'                            ,      25),
    ('DH-PFM914 CRIMPING TOOL'                ,     130),
    ('DH-PFM976-631 RJ45 CONNECTOR'           ,     0.5),
    ('DH-PFM976-631-PT RJ45 CONNECTOR'        ,     0.5),
    ('DH-PFM979-DCP POWER PIN'                ,       3),
    ('DH-SD2A500NB-GNY-A-PV 5MP'              ,     650),
    ('DH-SD3C405DB-GNY-A-PV'                  ,    1650),
    ('DH-SD3E405DB-GNY-A-PV1'                 ,    2000),
    ('DH-T4A-PV 4MP'                          ,     550),
    ('DH-XVR4232AN-I DIGITAL VIDEO RECORDER'  ,    2200),  -- sheet reads "DH-XVR4232AN-1"
    ('DH-XVR5232AN-I3 HDCVI DIGITAL'          ,    3200),  -- sheet reads "DH-XVR5232AN-13"
    ('DHI-ASA1222GL ACCESS CONTROL'           ,     700),
    ('DHI-KTA02 VIDEO INTERCOM KIT'           ,     750),
    ('DHI-KTH01'                              ,    1100),
    ('DHI-KTW03'                              ,    1650),
    ('DHI-NVR2216-4KS3 16CH NVR'              ,    1000),
    ('DHI-NVR4232-16P-4KS3 32CH WITH POE'     ,    2650),
    ('DHI-NVR4432-4KS3 32CH'                  ,    2500),  -- sheet reads "DHI-NVR4432-4K53"
    ('DHI-NVR5464-16P-EL'                     ,    7500),
    ('DHI-NVR5464-EL 64CH'                    ,    6800)  -- sheet reads "DHI-NVR5464-EI"
)
update public.dahua_stock s
   set unit_price = i.price,
       updated_at = now()
  from incoming i
 where s.model = i.model
   and s.unit_price is distinct from i.price;

commit;

-- ── Verification ──────────────────────────────────────────────
-- select count(*) filter (where unit_price > 0) as priced,
--        count(*) filter (where unit_price = 0) as unpriced
--   from public.dahua_stock;
--
-- select model from public.dahua_stock where unit_price = 0 order by model;

-- ═════════════════════════════════════════════════════════════
-- NOT APPLIED — needs a decision
-- ═════════════════════════════════════════════════════════════
--
-- 1. CONTRADICTORY PRICES — the sheet lists these twice, at two prices.
--    Neither was applied; pick one in Admin → Dahua Stock → 💰 Prices.
--      DH-HAC-T1A21P-U 2MP
--        "DH-HAC-T1A21P-U" = GH¢180  vs  "DH-HAC-TIA21P-U" = GH¢150
--      DHI-NVR1108HS-8P-S3/H NETWORK VIDEO RECORDER
--        "DHI-NVR1108HS-8P-S3/H" = GH¢900  vs  "DHI-NVR1108HS-8P-S3/H" = GH¢950
--      DH-IPC-HDW1239V-A-IL 2MP
--        "DH-IPC-HDW1239V-A-IL" = GH¢450  vs  "DH-IPC-HDW1239V-A-IL" = GH¢420
--
-- 2. PROBABLE MISREADS — likely the same product, but the change is not
--    self-evident, so they were left alone rather than guessed:
--      sheet "DH-P5AF-PV"  ->  db "DH-P5AE-PV 5MP"  @ GH¢650
--      sheet "DHI-NVR1104HS-4P-S3/H"  ->  db "DHI-NVR1104HS-P-S3/H NETWORK VIDEO RECORDER"  @ GH¢650
--      sheet "DH-CS4225-24ET-375"  ->  db "DH-CS4226-24ET-375 POE SWITCH"  @ GH¢1950
--      sheet "DH-CS4010-8ET-110"  ->  db "DH-CS4010-ET-110 SWITCH"  @ GH¢600
--
-- 3. NOT IN dahua_stock — on the sheet but no such product in the table.
--    HANDLED: 20260906_dahua_new_products.sql creates and prices these, with
--    opening stock 0. Run it after this file; each still needs a real
--    opening count entering on the Dahua Stock tab.
--      DH-IPC-HFW1439TL1-A-IL                       GH¢585   (near, but NOT the same as "DH-IPC-HFW1239TL1-A-IL 2MP")
--      DH-IPC-HFW1439TL1-PV                         GH¢510   (near, but NOT the same as "DH-IPC-HFW1239TL1-PV 2MP")
--      DH-IPC-HDW2449T-S-IL                         GH¢620   (near, but NOT the same as "DH-IPC-HDW2549T-S-IL 5MP")
--      DH-IPC-HFW1239S1-A-LED                       GH¢400   (near, but NOT the same as "DH-IPC-HDW1239T1-A-LED 2MP")
--      DH-IPC-HFW1439S1-A-LED                       GH¢500   (near, but NOT the same as "DH-IPC-HFW1439S-A-LED-S4 4MP")
--      DH-IPC-HDW1439T1-A-LED                       GH¢500   (near, but NOT the same as "DH-IPC-HDW1239T1-A-LED 2MP")
--      DHI-KTP01L                                   GH¢2200   (near, but NOT the same as "DHI-KTH01")
--      DHI-KTP10                                    GH¢2200   (near, but NOT the same as "DHI-KTH01")
--      DHI-KTP02                                    GH¢1900   (near, but NOT the same as "DHI-KTA02 VIDEO INTERCOM KIT")
--      DH-HAC-HDW1200TQP-IL-T ANALOG                GH¢235
--      DH-XVR1B16-I/T                               GH¢900
--      DH-XVR1B04H-I/T                              GH¢550
--      DH-XVR1B08H-I                                GH¢750
--      DH-XVR1B08H-I/T                              GH¢750
--      DH-XVR1B16H-I                                GH¢900
--      DH-XVR1B08-I/T                               GH¢450
--      DH-SD4E425GB-HNR-A-PV1                       GH¢4300
--      DH-SDT4E425-8P-GB-APV1                       GH¢5300
--      DH-SD3D416NB-GNY                             GH¢2350
--      DH-SDT3E410-8P-MB-A-PV1                      GH¢3400
