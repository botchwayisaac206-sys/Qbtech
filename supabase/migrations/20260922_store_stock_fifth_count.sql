-- ─────────────────────────────────────────────────────────────
-- STORE STOCK — fifth count, 2026-09-22
--
-- 153 models on this sheet: 127 never counted before, and 26 that were,
-- whose figures are ADDED to what is already recorded. 672 units in total.
--
-- THE REPEATED ITEMS ARE DELIBERATE
--   The last two dozen lines of this sheet repeat the second count word for
--   word — Paper roll 50, DS-PD1-MC-MS 14, AX3000 1, and so on. That was
--   put to the shop as a question and confirmed: these are further units
--   that arrived on top, not the same ones written down twice. So Paper
--   roll becomes 100, not 50.
--
--   If that turns out to be wrong, every affected model is listed in the
--   UPDATE at the bottom of this file with its new total, and the figures
--   can be halved back in the Stock tab. The list is short and explicit for
--   exactly that reason.
--
-- HOW THE FIGURES ARE WRITTEN
--   As ABSOLUTE totals, not increments. An increment would double again on
--   every re-run, and these migrations have already been run out of order
--   once. Each total is "what the earlier counts set" plus "what this sheet
--   adds", so running this twice leaves the same number.
--
--   For that to hold, THE FOURTH COUNT MUST RUN FIRST — it sets some of
--   these models to absolute figures of its own and would otherwise
--   overwrite the totals here. The guard below refuses to run before it.
--
-- HOW THE SHEET WAS READ
--   Sums are stored added up ("2+2", "4+4+2", "22+200", "9+1", "1+1+1").
--   Repeats within the sheet are two piles of one thing: DS-2CE18D0T-LFS
--   (2 and 1) is 3, and the 7204HGHI ColorVu kit (twice at 1) is 2.
--
--   Three struck-out lines with no quantity are excluded: the second
--   DS-2CD2T83G2-4LI2U, the second DS-J1421/7208HGHI-M1+4+4 CAM, and
--   Power Supply C8. "Patrex box" had no quantity either and is excluded.
--
--   Seven entries carried a "[?]" against an uncertain spelling. The marker
--   is dropped and the name kept as written rather than corrected on a
--   guess: DS-2CD2T46G2P-ISU/SL, DS-2CD2346G2P-ISU/SL, HiLook VI-K13P,
--   DS-3E1318P-E1/M, ST-517C-3M-4G, RBX-830, DS-KH6110-WIE1, Westa
--   ZT550LED, DS-3D501T, NCTS Qstrom Pro 1500VA and HDMI 1.5 m.
--
--   Repeated items are spelled as the database already spells them, so the
--   units land on the existing row instead of opening a second row under
--   different wording for the same product.
--
-- NOT MERGED, DELIBERATELY
--   DS-J1421/7208HGHI/M1+4+4 (slash) and DS-J1421/7208HGHI-M1+4+4 (hyphen)
--   are kept apart, as are the 7204HGHI kits and BACK WAREHOUSE's
--   DS-J1427204HGH1-M1+2+2 CAM. They look like one product written three
--   ways, but merging kit codes on a guess is how a count stops matching
--   the shelf.
--
-- Idempotent. Requires the earlier counts and
-- 20260920_store_stock_transfers.sql.
-- ─────────────────────────────────────────────────────────────

-- ── 0. Refuse to run before the fourth count ──────────────────
do $$
begin
  if not exists (
    select 1 from public.warehouse_stock
     where warehouse = 'STORE STOCK'
       and model = 'EAP115 Wireless ceiling mount access point'
  ) then
    raise exception
      'Run 20260921_store_stock_fourth_count.sql first — the totals here build on it.'
      using errcode = '42P01';
  end if;
end $$;

insert into public.warehouses (name, color, date_columns, section_labels)
select 'STORE STOCK', '#f59e0b', '{}', '{}'
 where not exists (select 1 from public.warehouses where name = 'STORE STOCK');

-- ── 1. Models the shop floor has not carried before ───────────
insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, min_level)
select 'STORE STOCK', v.model, v.qty, '{}'::jsonb, null
  from (values
    ('DS-3WF0BC-2NT(B) Wireless bridge',                   3),
    ('DS-3WAP522-S1 Smart managed access point',           5),
    ('DS-QE0206G1-V Analogue ceiling speaker',             1),
    ('HF-KS2 Smoke alarm kit',                             2),
    ('HF-KS1 Smoke alarm kit',                             2),
    ('DS-K1105EMKB Card reader',                           3),
    ('DS-3WF02C-5AC/O Wireless bridge',                    1),
    ('DS-K1T801M Standalone access control terminal',      2),
    ('DS-2SE7C425MWG-EB/26',                               1),
    ('DS-2SE4C225MWG-E/26',                                1),
    ('DS-2SE2C225MWG-E',                                   1),
    ('DS-2CD2T47G2-LSU/SL',                                1),
    ('DS-2CD2T83G2-2LI2U',                                 2),
    ('DS-2CD2T83G2-4LI2U',                                 4),
    ('DS-2CD2T63G2-4LI2U',                                 1),
    ('DS-2CD2T46G2P-ISU/SL',                               1),
    ('DS-2CD2643G2-LIZS2U',                                1),
    ('DS-2CD2663G2-LIZS2U',                                1),
    ('DS-3WR4G3N-O 4G LTE router',                         2),
    ('DS-QACAM07G1-4LIZSU',                                1),
    ('DS-2CD2T126G3-IS2UY/SRB',                            1),
    ('DS-2CD2T166G3-IS2UY/SRB',                            1),
    ('DS-2CD2T47G3-LIY',                                   1),
    ('DS-2CD2T87G2H-LISU/SL',                              1),
    ('DS-2CD2T43G2-4LI2U',                                 1),
    ('DS-2CD2643G2-IZS',                                   1),
    ('DS-2CD2T47G2P-LSU/SL',                               1),
    ('DS-2CD6825G0/C-IVS',                                 1),
    ('DS-3WAP521-S1 In-wall access point',                 2),
    ('DS-2CD1643G2-LIZU',                                  3),
    ('NK844WDH Dome',                                      1),
    ('DS-KD3003-E6 Outdoor station',                       1),
    ('DS-2CD2083G2-I',                                     1),
    ('DS-2CD2743G2-IZS',                                   6),
    ('DS-2DE2C400IWG-K/4G/C05S10',                         1),
    ('DS-2DE2C200IWG/W',                                   3),
    ('DS-2DE2C400MWG-4G',                                  1),
    ('DS-2CFS04/4G',                                       1),
    ('DS-2DE2C400MWG-E',                                   3),
    ('DS-2CFSP4/4G',                                       3),
    ('NK42E0H/H 2MP bullet kit',                           1),
    ('DS-J1421/7208HGHI/M1+4+4 cameras ColorVu',           1),
    ('DS-J1421/7208HGHI-M1+4+4 CAM',                       1),
    ('DS-J1421/7204HGHI-M1+2+2 cameras ColorVu',           2),
    ('DS-QAE0KA60120-2 Analog audio kit',                  1),
    ('NK844WBH',                                           1),
    ('DS-2CFSP8-D/4G',                                     2),
    ('DS-2CD2187G3-LIS2UY',                               10),
    ('DS-2CD2T43G2-4L',                                    1),
    ('DS-2CD2346G2P-ISU/SL',                               2),
    ('DS-2CD2087G3-LI2UY/SRB',                             5),
    ('DS-2CD2087G2-LU',                                    3),
    ('PS4 gamepad',                                        6),
    ('Logitech H390 Headphone',                            4),
    ('DS-2CD2347G2P-LSU/SL',                               1),
    ('DS-2CD5147G2/V-XS',                                  1),
    ('DS-2CD3641G2-IZS',                                   3),
    ('DS-2CD3343G2/X2-LIZSUY/SL',                          1),
    ('DS-2CD2187G2+LSU',                                   1),
    ('DS-2CD2183G2-IU',                                    1),
    ('DS-KAS808 Fingerprint access control kit',           4),
    ('DS-2DE3A404IW-DE/W Mini PTZ camera',                 1),
    ('DS-2SE3C204MWG-E/12 Mini camera',                    2),
    ('DS-TCG40G-E',                                        1),
    ('DS-2CD2347G2H-LIU',                                  1),
    ('DS-K1T670MX Face recognition terminal',              7),
    ('DS-K1T809MWX Outdoor access control',                6),
    ('DS-K1T673DWFX Face recognition',                     1),
    ('DS-K1T323MBWX-E1 Face recognition',                 10),
    ('DS-K1T808MFWX',                                      6),
    ('DS-K1T321MFWX-B Face recognition',                   2),
    ('DS-K1T807MBFWX-E1',                                  4),
    ('DS-K1A8503MF-B',                                     7),
    ('DS-KV8113-WME1(C)',                                  4),
    ('DS-K1T343MFX',                                       1),
    ('DS-2CE13DF0T-LXTS Sound MAX with speaker',           3),
    ('DS-PS1-EWE AX Pro wireless external sounder',        1),
    ('DS-PK1-LRT-HWE Wired LCD keypad for AX Pro',         1),
    ('DS-PHA64-KIT-WE(B)',                                 4),
    ('DS-2CE12KF3TP-DLS Turbo camera',                     2),
    ('DS-3T1512HP-SI-8P4F Ethernet switch',                1),
    ('Tapo C200',                                          3),
    ('DS-2CV2Q21G1-IDW Network camera',                    1),
    ('Tapo C501GW 4G PTZ outdoor camera',                  1),
    ('Tapo C425 WiFi camera 4-pack',                       1),
    ('Tapo C720 Smart floodlight camera',                  1),
    ('DS-PR1-WE AX Pro wireless repeater',                 1),
    ('HiLook VI-K43P Intercom',                            3),
    ('DS-KIS614-P IP video intercom',                      4),
    ('HiLook VI-K46P Intercom',                            2),
    ('DS-KIS902-S',                                        4),
    ('DS-KH2220 Indoor analogue station',                  4),
    ('HiLook VI-K13P 4-wire video intercom',               1),
    ('HiLook VI-K23P Hybrid intercom',                     5),
    ('DS-KH2230T Analogue intercom screen',                7),
    ('DS-PDTT15AM-LM-WP',                                  2),
    ('DS-2CE18D0T-LFS',                                    3),
    ('DS-KH6320-WTE1 IP video intercom indoor station',    5),
    ('Ultra MT-S3 4G UBox app',                            1),
    ('IOMA IO-SG440 HiEasy app',                           1),
    ('ST-558-6M-12X-4G UBox app',                          4),
    ('ES-SC180UV UBox app',                                2),
    ('ST-698-6M-36X-4G UBox app',                          1),
    ('DS-3E1318P-E1/M Ethernet switch',                    1),
    ('Epson HA86B Projector',                              1),
    ('IOMA IO-WF145',                                      1),
    ('ES30 Ultra Esee Cloud',                              1),
    ('ES30W Ultra Esee Cloud',                             1),
    ('4G (EU) Solar camera iCam+',                         2),
    ('ST-515-6M-12X-4G',                                   1),
    ('ST-517C-3M-4G',                                      1),
    ('RBX-830',                                            2),
    ('IOMA IO-RP42W12A',                                   1),
    ('DS-PC2002-WECKV',                                   28),
    ('DS-QAE0A120G1-VB6',                                  1),
    ('1602ZJ PTZ pole mount',                              3),
    ('DYMO Label Manager DYM160 Printer',                 10),
    ('TMG090-4B Controller box',                           2),
    ('DS-J1421/7108HQHI-K1+8 CAM',                         1),
    ('Panasonic KX-TE82474X',                              2),
    ('DS-2CD1021G0-I',                                     5),
    ('DS-2CD1321G0-I',                                     3),
    ('DS-KH6110-WIE1 IP video intercom station',           1),
    ('DS-1H18-A',                                        222),
    ('DS-K2602T Access controller',                        2),
    ('DS-3WR30X-V Wireless router',                        3),
    ('A30-HD 20x optical zoom UBox',                       1),
    ('Yunteng VCT880 Video tripod',                        2),
    ('VGA 30 m',                                           2),
    ('AX3000 WiFi 6 ceiling access point',                 2),
    ('10 HDMI Cable',                                     22),
    ('VGA 10M',                                            2),
    ('HDMI 1.5 m',                                         4),
    ('DS-PD1-MC-MS MAGNETIC CONTACT',                     28),
    ('Paper roll',                                       100),
    ('Grand Stream GWN7660ELR',                            6),
    ('Westa ZT550LED',                                     2),
    ('DS-2CD1023G2H-LIU',                                  8),
    ('THC-B127-LPS',                                      16),
    ('SP4 Solar Camera',                                   4),
    ('Ecotank-L3252',                                      2),
    ('DS-7216HGHI-M1/T',                                  14),
    ('HUAWEI-B660',                                        3),
    ('12V 7AH',                                            6),
    ('AG003',                                              4),
    ('PV',                                                 4),
    ('DS-2CE72DF0T-LPFS',                                  4),
    ('West 100M Indoor',                                   2),
    ('DS-2CD1047G3-LIU/SRB',                              22),
    ('120 m KVM',                                          2),
    ('DS-2CD1147G3-LIU',                                  13),
    ('DS-3D501T FIBRE OPTIC TRANSCEIVER',                  6),
    ('NCTS Qstrom Pro 1500VA',                             2)
       ) as v(model, qty)
 where not exists (
         select 1 from public.warehouse_stock s
          where s.warehouse = 'STORE STOCK'
            and s.model     = v.model
       );

-- ── 2. Models already counted: the new total ──────────────────
-- Absolute, so a re-run cannot double them. Only opening_stock is touched;
-- anything since sold, transferred or returned lives in its own column and
-- still lands on the right closing figure.
update public.warehouse_stock s
   set opening_stock = v.qty
  from (values
    ('DS-PC2002-WECKV',                                   28),
    ('1602ZJ PTZ pole mount',                              3),
    ('AX3000 WiFi 6 ceiling access point',                 2),
    ('10 HDMI Cable',                                     22),
    ('VGA 10M',                                            2),
    ('HDMI 1.5 m',                                         4),
    ('DS-PD1-MC-MS MAGNETIC CONTACT',                     28),
    ('Paper roll',                                       100),
    ('Grand Stream GWN7660ELR',                            6),
    ('Westa ZT550LED',                                     2),
    ('DS-2CD1023G2H-LIU',                                  8),
    ('THC-B127-LPS',                                      16),
    ('SP4 Solar Camera',                                   4),
    ('Ecotank-L3252',                                      2),
    ('DS-7216HGHI-M1/T',                                  14),
    ('HUAWEI-B660',                                        3),
    ('12V 7AH',                                            6),
    ('AG003',                                              4),
    ('PV',                                                 4),
    ('DS-2CE72DF0T-LPFS',                                  4),
    ('West 100M Indoor',                                   2),
    ('DS-2CD1047G3-LIU/SRB',                              22),
    ('120 m KVM',                                          2),
    ('DS-2CD1147G3-LIU',                                  13),
    ('DS-3D501T FIBRE OPTIC TRANSCEIVER',                  6),
    ('NCTS Qstrom Pro 1500VA',                             2)
       ) as v(model, qty)
 where s.warehouse = 'STORE STOCK'
   and s.model     = v.model
   and s.opening_stock is distinct from v.qty;

-- ── Verification (run after the statements above) ─────────────
-- select count(*) as models, sum(opening_stock) as units
--   from public.warehouse_stock where warehouse = 'STORE STOCK';
--   -- expect 488 models and 6242 units once all five counts are in
--   -- (plus any rows added by hand or created by a transfer)
