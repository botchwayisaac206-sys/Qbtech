-- ─────────────────────────────────────────────────────────────
-- STORE STOCK — fourth count, 2026-09-21
--
-- Networking, access control, UPS and AV: 105 new models and 297 units,
-- taking the shop floor to 361 models and 5570 units.
--
-- Recorded as opening_stock, like the counts before it — these were
-- already on the floor, not moved in from a back warehouse.
--
-- HOW THE COUNT SHEET WAS READ
--   Sums are stored added up: "6+7" -> 13, "1+3+1" -> 5, "7+5+1" -> 13,
--   "2+3" -> 5, "3+1" -> 4, and each "1+1" -> 2.
--
--   Three crossed-out lines with no quantity are NOT included: Nano 5AC,
--   Power Beam M5 PBE-M6-400, and Cabinet fan. The un-struck
--   Power Beam M5 PBE-M5-400 is included, at 1.
--
--   Entries written "Model — description" are stored as one string with the
--   dash dropped, keeping the sheet's own wording. Several carried a "[?]"
--   against an uncertain spelling; the marker is dropped and the name kept
--   as written rather than corrected on a guess. Those are ER703WP,
--   ZKT MB360, Grandstream GRP2602W, ZTE MF286R, D-Link DGS1210-28RP,
--   LSUW TLE router MF607, DS-2DE2C400MW-DB and DS-QAE0215G1-V. Fix any of
--   them in the Stock tab and the barcode and price will follow the name.
--
--   The two TV wall mounts were written with inch marks; they are stored as
--   "26-63 inch" and "14-42 inch" so they can be typed and searched.
--
-- ONE REVISED FIGURE
--   HUAWEI-B660 was counted in the second count at 1, and this sheet lists
--   another as "Huawei B660 — 4G router / wireless gateway". They are two
--   units of the same product, so the existing row is set to an ABSOLUTE 2
--   rather than a second row being created under a different spelling —
--   which would have split one product's stock across two names.
--
-- TWO NAMES ALIGNED TO THE BACK WAREHOUSE
--   Stock is keyed on (warehouse, model), so a store row spelled
--   differently from the warehouse row for the same item could never be
--   transferred between them:
--
--     count sheet                        stored as
--     D-Link DWR-M922                    DWR-M922
--     DS-QAE0A60G1-VB Analog amplifier   DS-QAE0A60G1-VB
--
--   The warehouse rows were left alone: they are live, and product_codes
--   and past invoice lines match on those exact strings.
--
-- NOT MERGED, DELIBERATELY
--   Three lines resemble a back-warehouse item but are not clearly the same
--   product, so they are kept as written rather than merged on a guess:
--   "HDMI splitter 4K" (warehouse has HDMI SPLITTER 4K 1X8), "HDMI splitter
--   2-port 4K" (HDMI SPLITTER 2 PORT) and "HDMI fibre optic 50 m"
--   (FIBRE OPTIC 50M). They sit in a different location either way; only
--   transfers between the two are affected.
--
-- Idempotent. Requires 20260920_store_stock_transfers.sql; run after the
-- earlier counts.
-- ─────────────────────────────────────────────────────────────

insert into public.warehouses (name, color, date_columns, section_labels)
select 'STORE STOCK', '#f59e0b', '{}', '{}'
 where not exists (select 1 from public.warehouses where name = 'STORE STOCK');

-- New models. The revised one carries its final figure here too, so this
-- lands correctly even if the earlier counts were never run.
insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, min_level)
select 'STORE STOCK', v.model, v.qty, '{}'::jsonb, null
  from (values
    ('EAP115 Wireless ceiling mount access point',                  2),
    ('EAP610 Outdoor',                                              2),
    ('Agile ES210GP',                                               4),
    ('SG2210P',                                                     7),
    ('ER605 Gigabit VPN gateway',                                   2),
    ('ES205GP',                                                     2),
    ('Archer AX53',                                                 2),
    ('Archer BE220 Dual-band WiFi 7 router',                        1),
    ('EAP725 Outdoor',                                              1),
    ('ER703WP 4G outdoor',                                          1),
    ('LS109P Normal switch',                                        1),
    ('TS-SF1016D',                                                  3),
    ('LS105GP',                                                     2),
    ('LS110P',                                                      3),
    ('POE160S',                                                     4),
    ('EAP610GP Desktop (EU)',                                       5),
    ('ER706W 4G (EU)',                                              1),
    ('EAP610',                                                      1),
    ('EAP653UR Ceiling mount access point',                         1),
    ('MikroTik SXTsq Lite 5',                                       1),
    ('Nano Ebiquity M5',                                            3),
    ('Ebiquity U6 Mesh Pro',                                        1),
    ('U7 Pro',                                                      1),
    ('Nano Beam 5AC',                                               1),
    ('Lite Beam 5AC',                                               2),
    ('Power Beam M5 PBE-M5-400',                                    1),
    ('ZKTCO VDP04-B4 Kit',                                          2),
    ('EAP668 Outdoor HD',                                           2),
    ('Deco M4 AC1200',                                              2),
    ('Deco X20 3-pack',                                             2),
    ('Deco X10',                                                    1),
    ('Deco X50',                                                    1),
    ('EAP235 Wall',                                                 2),
    ('WiFi 6 router 8 stream',                                      1),
    ('4G LTE router',                                               3),
    ('DWR-M922',                                                    2),
    ('ZKT F16',                                                     1),
    ('ZKT MB10-VL',                                                 1),
    ('U7 Lite',                                                     1),
    ('MikroTik hAP Lite',                                           1),
    ('MikroTik RB951Ui-2HND',                                       1),
    ('MikroTik L009 series',                                        1),
    ('ZKT MA500',                                                   1),
    ('ZKT X8-BT',                                                   1),
    ('ZKT F22',                                                     4),
    ('ZKT MB420',                                                   1),
    ('ZKT MB360',                                                   1),
    ('ZKT Multibio600',                                             1),
    ('ZKT K40 Pro',                                                 1),
    ('Grandstream GXP1625',                                        13),
    ('Grandstream GRP2602W',                                        5),
    ('Grandstream UCM6302A',                                        2),
    ('Ruijie RG-RAP72 Pro',                                         1),
    ('Telenet MF286N Router',                                       8),
    ('ZTE MF286R 4G',                                              12),
    ('ZTE MF286 4G router',                                         5),
    ('TP-Link 4G+ AI Cube',                                         2),
    ('Huawei B315S-22 4G router',                                   4),
    ('D-Link DES-1024D 24-port switch',                             7),
    ('D-Link DGS-1024C 24-port Gigabit switch',                     4),
    ('D-Link DGS-1100-18PV2 16-port switch',                        1),
    ('D-Link DGS1210-28RP 24-port Gigabit smart managed switch',    1),
    ('TP-Link SG2218',                                              3),
    ('102G 24-port full Gigabit smart network switch',              2),
    ('Tenda TEG1024D 24-port Gigabit Ethernet switch',              2),
    ('Fibre optic 100 m',                                           2),
    ('UCom L600D Gamepad',                                          2),
    ('UCom L600S',                                                  4),
    ('TV-8108HD 8-channel passive HD video balun',                  2),
    ('Starlink adjustable mount',                                   4),
    ('NCTS Qstrom Pro Qpr 2000VA Stepdown UPS',                     2),
    ('Tenda TX2 Pro Wireless router',                               1),
    ('D-Link DGS-1100-08PV2',                                       2),
    ('Sealead UPS battery 12V 17Ah',                                1),
    ('Gamister UPS battery 12V 17Ah',                               1),
    ('Voltage regulator',                                           2),
    ('1602ZJ PTZ pole mount',                                       1),
    ('ZKT MK-U/MK-H',                                               1),
    ('HDMI KVM extender 200 m',                                     5),
    ('HDMI KVM extender with audio 60 m',                           5),
    ('HDMI splitter 4K',                                            2),
    ('HDMI splitter 2-port 4K',                                     4),
    ('Hikvision DS-3E0105-O Ethernet switch',                      22),
    ('HDMI fibre optic 30 m',                                       1),
    ('HDMI fibre optic 10 m',                                       4),
    ('Q16S-1 Bulb camera',                                         13),
    ('HDMI fibre optic 50 m',                                       2),
    ('HDMI 4K 30 m',                                                1),
    ('TV wall mount 26-63 inch',                                    5),
    ('TV wall mount 14-42 inch',                                    1),
    ('Wireless intercom without screen',                            7),
    ('Wireless HDMI 100 m',                                         2),
    ('Wireless HDMI 50 m',                                          3),
    ('Wireless HDMI 150 m',                                         3),
    ('Huawei F316 4G SIM phone',                                    7),
    ('GRP2650',                                                     1),
    ('MS108GP 8-port Gigabit desktop switch',                       2),
    ('4-channel passive HD video balun',                            1),
    ('LSUW TLE router MF607',                                       1),
    ('DS-QAE0A60G1-VB',                                             2),
    ('DS-QAE1A80G1-VB Network amplifier',                           1),
    ('DS-2DE2C400MW-DB Mini PT network camera',                     1),
    ('NKS42W0H',                                                    1),
    ('DS-QAE0215G1-V Analogue ceiling speaker 45W',                 4),
    ('DS-QAE0210G1-Y Analogue ceiling speaker 10W',                 9),
    ('HUAWEI-B660',                                                 2)
       ) as v(model, qty)
 where not exists (
         select 1 from public.warehouse_stock s
          where s.warehouse = 'STORE STOCK'
            and s.model     = v.model
       );

-- The revised figure, applied whether or not the row already existed.
update public.warehouse_stock s
   set opening_stock = v.qty
  from (values
    ('HUAWEI-B660',                                                 2)
       ) as v(model, qty)
 where s.warehouse = 'STORE STOCK'
   and s.model     = v.model
   and s.opening_stock is distinct from v.qty;

-- ── Verification (run after the statements above) ─────────────
-- select count(*) as models, sum(opening_stock) as units
--   from public.warehouse_stock where warehouse = 'STORE STOCK';
--   -- expect 361 models, 5570 units once all four counts are in
