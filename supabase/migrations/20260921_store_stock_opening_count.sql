-- ─────────────────────────────────────────────────────────────
-- STORE STOCK opening count — 2026-09-21
--
-- The first physical count of the shop floor: 145 models, 4298 units.
--
-- These land as opening_stock, the counted baseline, exactly as the Dahua
-- recount did. They are NOT booked in as transfer_in — nothing was moved
-- from a back warehouse to put them there, they were already on the floor.
-- Units moved in from a warehouse later will add to transfer_in on top of
-- this, and invoices will take them off again.
--
-- Idempotent: a model already present in STORE STOCK is left alone, so
-- re-running this cannot double a count. To correct a figure afterwards,
-- edit the row in the Stock tab rather than re-running.
--
-- NOTE — DS-PWA64-KIT-WB appeared twice on the count sheet at 1 pc each and
-- is recorded here as 2. If those were the same unit written down twice,
-- set it back to 1 in the Stock tab.
--
-- Two models are spelled here as the back warehouses already spell them,
-- not as the count sheet wrote them. Stock is keyed on (warehouse, model),
-- so a store row named differently from the warehouse row for the same item
-- could never be transferred between the two:
--
--   count sheet                   stored as
--   DS-2FA1208-C16                DS-2FA1208-C16 16CH POWER SUPPLY
--   DIGITAL MULTIMETER DT9201A    DIGITAL MULTIMETER DT920SA
--
-- The warehouse rows were left alone deliberately: they are live, and
-- product_codes and past invoice lines are matched on those exact strings.
--
-- Requires 20260920_store_stock_transfers.sql (the STORE STOCK location and
-- the derive trigger). Run once, in the Supabase SQL editor.
-- ─────────────────────────────────────────────────────────────

begin;

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
    ('MK120 CORDED KEYBOARD AND MOUSE',                13),
    ('POE-43IP MINI DC UPS 8800MAH',                   27),
    ('P0E-432EM MINI DC UPS 10400MAH',                  9),
    ('Mk270 WIRELESS KEYBOARD AND MOUSE',               2),
    ('MK540 WIRELESS KEYBOARD AND MOUSE',               5),
    ('RJ45 CONNECTORS NORMAL',                        972),
    ('ALFAMAX C-1005',                                  5),
    ('SYS-WS O1',                                       3),
    ('POWER SWITCH 13.5MHZ',                           47),
    ('C922 PRO HD STREAM WEBCAM',                       4),
    ('Z05 WEBCAM',                                      3),
    ('DS-K7P08',                                       32),
    ('DS-K7P07',                                        8),
    ('EXIT BUTTON WITH REMOTE',                         5),
    ('EXIT BUTTON WITHOUT REMOTE',                     30),
    ('RE450',                                           3),
    ('TL-WA850RE',                                     30),
    ('ELECTRIC BOLT LOCK',                              5),
    ('RF CARD',                                       978),
    ('MIFI CARD',                                      15),
    ('104JF 4 PORT POE REPEATER',                      20),
    ('DS-K1F100-D8E',                                   2),
    ('DS-K1F820-F',                                     2),
    ('HF-CSS1',                                         1),
    ('ARCHER T2U NANO',                                 1),
    ('MAGNETIC LOCK 280KG UNBRANDED',                   6),
    ('RJ45 LAN JOINER',                                90),
    ('EP-280ZL',                                        9),
    ('U BRACKET',                                       9),
    ('DS-KAH255-LZ',                                    1),
    ('1280ZJ-XS',                                      19),
    ('DS-K4DC103',                                      4),
    ('DOME META MOUNT',                                 3),
    ('YD/T926.3-2009 PATCH PANEL 48PORT',               5),
    ('4WAY POWER SPLITTER',                           205),
    ('8WAY POWER SPLITTER',                             9),
    ('RB3011UIAS-RM MIKROTIK ROUTER BAND',              1),
    ('CABINET PDU 3 WAY HP-403',                        4),
    ('PROJECTOR CELLING MOUNT NCTS-ACM5080',            1),
    ('PROJECTOR WALL MOUNT 430-650',                    3),
    ('CABLE MANAGER',                                  16),
    ('CABINET PDU WAY',                                 1),
    ('MINI PROJECTOR',                                  3),
    ('CABINET PDU 6WAY',                                1),
    ('6WAY POWER SPLITTER',                            53),
    ('NCTS-12V9A',                                     11),
    ('RACK FAN',                                        1),
    ('HDTV TO VGA/AV ADAPTER',                          5),
    ('MINI DP TO HDTV ADAPTER',                         2),
    ('HDMI TO VGA MINI DISPLAY PORT ADAPTER',           3),
    ('HDMI TO TYPE-C ADAPTER',                          1),
    ('HDMI TO HDMI DISPLAY PORT ADAPTER',               2),
    ('1.8M DISPLAY PORT ADAPTER',                       4),
    ('USB EXTENSION CABLE 1.5M',                       12),
    ('USB RJ45 EXTENSION ADAPTER',                     47),
    ('OTG USB FLASH DRIVE',                             6),
    ('USB HUB 4 PORT 303',                              4),
    ('USB 3.0/3.1 ETHERNET ADAPTER',                   20),
    ('USB SOUND ADAPTER 7.1 CHANNEL',                   6),
    ('RJ45 CONNECTORS PASSTHROUGH',                  1119),
    ('RJ45 PASSTHROUGH CRIMPING TOOL WESTA',            1),
    ('RJ45 CRIMPING TOOL NORMAL 8P6P W-318',           16),
    ('BNC TO BNC CABLE 2M',                             4),
    ('HP M10 WIRED MOUSE',                             46),
    ('30M HDTV TO CAT 6 EXTENDER',                      6),
    ('NETWORK ADAPTER TYPE C',                          6),
    ('CABLE TRACKER',                                   3),
    ('DIGITAL MULTIMETER DT920SA',                     10),
    ('HIGH QUALITY AUTOMOTIVE EMERGENCY POWER BANK',    2),
    ('K9 WIRELESS MICROPHONE',                          4),
    ('RF433-DIY SMART SWITCH',                         14),
    ('DS-PDMCS-EG2-WE',                                 7),
    ('DS-PDC10AM-EG2-WE',                               1),
    ('DS-PDWL-E-WE',                                    1),
    ('DS-PDTPH-E-WE',                                   1),
    ('DS-PDPG12P-EG2-WE',                               2),
    ('WIRELESS PANIC BUTTON',                           4),
    ('DS-PDP18-EG2',                                    2),
    ('DS-PDMC-EG2-WE(B)',                               4),
    ('IDS-E04HQHI-D',                                   1),
    ('TC-R3104',                                        1),
    ('NCTS-NB2D6 BARCODE SCANNER',                      5),
    ('NCTS-NL10 BARCODE SCANNER',                       3),
    ('NCTS-NB2D2W BARCODE SCANNER',                     3),
    ('DS-PKF1-WB',                                      1),
    ('USB-C CHARGE CABLE 2M',                           1),
    ('M185 LOGITECH MOUSE',                             1),
    ('M90 LOGITECH MOUSE',                              1),
    ('48V-EU POE ADAPTER',                              9),
    ('UNIVERSAL FOAM CLEANING AGENT',                  19),
    ('DS-PK1-LT-WE',                                    5),
    ('F11-2 WIRELESS MICROPHONE',                       5),
    ('BOAFENG UV-5RH',                                  3),
    ('SX21 WIRELESS MICROPHONE',                        4),
    ('DS-PDP15P-EG2-WE(B)',                             5),
    ('DS-PC2002-WECKV',                                 1),
    ('V380 SMART AI CAMERA',                            8),
    ('T01 DETECTOR',                                    2),
    ('S-120-12 POWER SUPPLY',                          12),
    ('FF-Q2421B LINK FF 24PORT POE SWITCH',             5),
    ('JVS-S18-16P-240W',                                1),
    ('JVS-ND6610-HD NVR',                               1),
    ('S-240W-12 POWER SUPPLY',                          2),
    ('JVS-S10-8P-120W',                                 1),
    ('PATCH CORD 3M',                                   7),
    ('10M PATCH CORD',                                 19),
    ('15M PATCH CORD',                                  9),
    ('20M PATCH CORD',                                  3),
    ('5M PATCH CORD',                                  17),
    ('1.5M PATCH CORD',                                 2),
    ('NAP-9000-4K 360 HD CAMERA',                       1),
    ('FF-Q&A 8PORT SWITCH',                             1),
    ('60M HDMI TO CAT 6 EXTENDER',                      1),
    ('NOTEBOOK POWER ADAPTER 12V4.5A',                  1),
    ('PROFESSIONAL DOOR CLOSER 072',                    4),
    ('2420GF-24 PORT GIGABIT POE SWITCH',               8),
    ('16F22GB-16PORT AI ENHANCED POE SWITCH',           1),
    ('1018G-16PORT GIGABIT NETWORK SWITCH',             1),
    ('DS-PWA64-KIT-WB',                                 2),
    ('1006B-J-4PORT STANDARD POE SWITCH',               1),
    ('X16F20GB-16PORT UPLINK GIGABIT POE SWITCH',       2),
    ('D50 ULTRA SMART 3 GLASSES',                       5),
    ('XP-E200L PRINTER',                                4),
    ('XP-Q80A PRINTER',                                 1),
    ('XP-365B PRINTER',                                 1),
    ('12V10A POWER ADAPTER',                            3),
    ('POE424G',                                         5),
    ('DS-K1201AMF',                                     2),
    ('AK-ACS80 ACCESS CONTROL POWER SUPPLY',            3),
    ('HF-CABLE FIRE ALARM BELL',                        4),
    ('POSO PROFESSIONAL TOOLS BAG',                     2),
    ('NETWORKING TOOL KIT 200',                         2),
    ('NETWORKING TOOL KIT 250',                         1),
    ('HAMMER TOOL PE-HD',                               1),
    ('DRILLING MACHINE',                                4),
    ('KX-TS500FX',                                     18),
    ('DS-3E0116R-O',                                    5),
    ('DS-3E11326P-EI/M',                                1),
    ('DS-3E1318P-EI/M',                                 2),
    ('DS-3E0526P-E/M',                                  1),
    ('DS-3E0326P-E/M(C)',                               1),
    ('DS-2FA1208-C16 16CH POWER SUPPLY',              7),
    ('GXP2200EXT',                                      1),
    ('DS-PR1-WE(B)',                                    1),
    ('DS-KH9510-WTE(B)',                                1)
       ) as v(model, qty)
 where not exists (
         select 1 from public.warehouse_stock s
          where s.warehouse = 'STORE STOCK'
            and s.model     = v.model
       );

commit;

-- ── Verification (run after committing) ───────────────────────
-- select count(*) as models, sum(opening_stock) as units
--   from public.warehouse_stock where warehouse = 'STORE STOCK';
--   -- expect 145 models, 4298 units on a first run
