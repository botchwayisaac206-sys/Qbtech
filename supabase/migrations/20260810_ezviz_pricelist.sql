-- ─────────────────────────────────────────────────────────────
-- EZVIZ price list — 22 products
--
-- Creates the 'EZVIZ' category (matching the existing brand-per-category
-- convention: HIKVISION-PRODUCTS, TP-LINK, Tenda Networking) and adds the
-- product list to it.
--
-- COLUMN MAPPING (see addItem() in src/components/admin/PriceList.tsx)
--   Code        -> model
--   Description -> specifications
--   Price       -> ghs_price      (Ghana cedis; the UI reads this directly)
--   name        -> mirrors model  (legacy not-null column, unused by the UI)
--   usd_price   -> 0              (legacy; the FX/duty workflow was dropped in
--                                  20260522_pricelist_revamp.sql)
--
-- Safe to re-run: the category and every item are guarded by NOT EXISTS,
-- so a second run inserts nothing.
-- ─────────────────────────────────────────────────────────────

begin;

-- ── 1. Category ───────────────────────────────────────────────
insert into pricelist_categories (name)
select 'EZVIZ'
 where not exists (
         select 1 from pricelist_categories where name = 'EZVIZ'
       );

-- ── 2. Products ───────────────────────────────────────────────
insert into pricelist_items (category_id, model, name, specifications, ghs_price, usd_price)
select (select id from pricelist_categories where name = 'EZVIZ' limit 1),
       v.model, v.model, v.specifications, v.ghs_price, 0
  from (values
    ('CS-C7-44WF',             'EZVIZ IDual-Lens Pan & Tilt Wi-Fi Camera',                        750),
    ('CS-CB1',                 'Ezviz CB1 Wi-Fi Smart Home Battery Camera-1080p 2MP Resoluti',    550),
    ('CS-CB2-B',               'Ezviz Bullet 2.0Mp Smart Wifi Camera With Battery - Black',       800),
    ('CS-CB2-W',               'Ezviz Bullet 2.0Mp Smart Wifi Camera With Battery - White',       800),
    ('CS-CB3/SP-2K',           'Ezviz Outdoor Smart Home Battery Camera|2Mp Resolution|Recha',    950),
    ('CS-E4P-6MP',             'Smart Wi-Fi Panoramic Fisheye Camera',                           1000),
    ('CS-EB3/SP-2K',           'Ezviz EB3 4G Smart Home Battery Camera',                         1000),
    ('CS-EB8/SP-4KW4GA',       'Ezviz Pt 4K Pan/Tilt Camera 4G With Battery And Solar Panel',    1850),
    ('CS-EP3x/SD7-KIT',        'Ezviz Battery-Powered Video Doorbell Kit',                       1800),
    ('CS-H1C',                 'EZVIZ H1C 1080p Smart Home Wi-Fi Camera',                         350),
    ('CS-H3C-3MP/Colored',     'Ezviz Bullet 3.0MP WiFi Camera Colored',                          550),
    ('CS-H5-4G',               'EZVIZ 3mp 4G Smart Home Camera',                                  665),
    ('CS-H6-5WF-3K',           'Ezviz H6 Smart Home Camera 3K',                                   450),
    ('CS-H7C-44WFW2',          'Ezviz Dual-Lens Pan & Tilt Wi-Fi Camera',                         650),
    ('CS-H80X-8MP+2MP4M',      'EZVIZ 8mp+2mp Dual-Lens Pan & Tilt Wi-Fi Camera',                 950),
    ('CS-H90-4MP+4MP',         'EZVIZ 4mp+4mp Dual-Lens Pan & Tilt Wi-Fi Camera',                 950),
    ('CS-H9C-3MP',             'Ezviz Pan/Tilt 3MP+3MP Dual Lence WiFi Camera',                   750),
    ('CS-HB8/SP-4k',           'Ezviz PT 8.0MP Wifi Camera With Battery With Solar',             1565),
    ('CS-HB8C/SP-4MPW4G',      'Ezviz PT 4.0MP WiFi Camera With Battery 4G',                     1250),
    ('CS-HB90/SP-4MP+4MP',     'Ezviz 4+4mp Dual-Lens All-Day Recording Wi-Fi Camera + Solar',   1750),
    ('CS-HB90X/SP-4MP+4M-4G',  'Ezviz 4+4mp Dual-Lens All-Day Recording Wi-Fi Camera + Solar',   2200),
    ('CS-SD7',                 'Ezviz Smart Screen',                                             1000)
       ) as v(model, specifications, ghs_price)
 where not exists (
         select 1 from pricelist_items pi where pi.model = v.model
       );

commit;

-- ── Verification ──────────────────────────────────────────────
-- select pi.model, pi.specifications, pi.ghs_price
--   from pricelist_items pi
--   join pricelist_categories pc on pc.id = pi.category_id
--  where pc.name = 'EZVIZ'
--  order by pi.model;
