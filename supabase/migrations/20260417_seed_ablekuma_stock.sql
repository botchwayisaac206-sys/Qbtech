-- ============================================================================
-- Seed ABLEKUMA1, ABLEKUMA2 & FISHPONG-1 warehouse stock (62 items, ~15,642 pcs).
-- Idempotent: each row is inserted only if (warehouse, model) doesn't exist.
-- ============================================================================

insert into public.warehouse_stock
  (warehouse, model, opening_stock, daily_taken, total_taken, closing_stock, min_level, stock_status)
select v.warehouse, v.model, v.qty, '{}'::jsonb, 0, v.qty, null, ''
from (
  values
  -- ── ABLEKUMA2 ──────────────────────────────────────────────────────
  ('ABLEKUMA2', 'Waste 520*350*180 2U',                            870),
  ('ABLEKUMA2', 'Waste 3U 520*350*210',                            840),
  ('ABLEKUMA2', 'Waste 9U 520*400*450',                              4),
  ('ABLEKUMA2', 'Waste 4U 530*400*240',                            621),
  ('ABLEKUMA2', 'Hik view 4U 520*400*240',                         155),
  ('ABLEKUMA2', 'Axiom cat6 SFTP outdoor PVC+PE 100m',             120),
  ('ABLEKUMA2', 'Axiom cat6 UTP black',                             90),
  ('ABLEKUMA2', 'Axiom cat6 UTP 100m',                             376),
  ('ABLEKUMA2', 'Waste cat6 indoor pure copper FC001',              38),
  ('ABLEKUMA2', 'Waste cat6 SFTP outdoor AG004',                    24),
  ('ABLEKUMA2', 'Round junction box B001',                         600),
  ('ABLEKUMA2', 'Small junction box 100F',                        1000),
  ('ABLEKUMA2', 'Junction box octagon shape medium',              1300),
  ('ABLEKUMA2', 'HD wireless extender 200m KVM',                     3),
  ('ABLEKUMA2', 'Network kit LKT-300110Y',                          40),
  ('ABLEKUMA2', 'Metal camera mount PFA152-E unbranded',           135),
  ('ABLEKUMA2', 'Metal camera mount PFA152-E branded',              30),
  ('ABLEKUMA2', 'Metal camera mount 1258ZJ-120',                    30),
  ('ABLEKUMA2', 'Metal camera wall mount PFD203W',                  22),
  ('ABLEKUMA2', 'Metal camera mount 1602ZJ',                        24),
  ('ABLEKUMA2', 'Video balun C1 8PM',                             5000),
  ('ABLEKUMA2', 'HDMI 60m KVM extender',                             3),
  ('ABLEKUMA2', 'HDMI 2x2 video wall controller',                    1),
  ('ABLEKUMA2', 'Fiber optic 4K 8K UHD 30m',                         8),
  ('ABLEKUMA2', 'Westa cat6 SFTP 305m outdoor AG003',              404),
  ('ABLEKUMA2', 'Wireless intercom HY626',                          40),
  ('ABLEKUMA2', 'Wireless intercom HY636',                          40),
  ('ABLEKUMA2', 'Motor rag',                                       100),
  ('ABLEKUMA2', 'ST-558-6M-4G-12X',                                  4),
  ('ABLEKUMA2', 'BNC connector copper',                            130),
  ('ABLEKUMA2', 'Single cat6',                                     500),
  ('ABLEKUMA2', 'Siren 30W',                                        24),
  ('ABLEKUMA2', 'Cable manager',                                    36),
  ('ABLEKUMA2', 'Solar fan',                                         2),
  ('ABLEKUMA2', 'Hikvision cat6 DS-1LN6U-W/CCA',                     6),
  ('ABLEKUMA2', 'DS-TMG035 trigger radar',                           1),

  -- ── ABLEKUMA1 ──────────────────────────────────────────────────────
  ('ABLEKUMA1', 'Magnetic lock DS-K4H255S',                        200),
  ('ABLEKUMA1', 'Solid SD-UTP 320m cable',                         380),
  ('ABLEKUMA1', 'Solid SD-UTP 120m cable',                         138),
  ('ABLEKUMA1', 'Solid SD-SFTP 305m',                              158),
  ('ABLEKUMA1', 'Solid SD-FTP 305m cable',                          10),
  ('ABLEKUMA1', 'AK 305m cat6 cable',                               38),
  ('ABLEKUMA1', 'Westa cat6 UTP 305m indoor AG001',                558),
  ('ABLEKUMA1', 'Westa cat6 UTP 305m outdoor AG002',                50),
  ('ABLEKUMA1', 'Westa cat6 UTP 100m indoor',                      174),
  ('ABLEKUMA1', 'Axiom UTP cat6 gray 305m',                        486),
  ('ABLEKUMA1', 'Axiom UTP cat6 orange 305m',                      246),
  ('ABLEKUMA1', 'Hilook cat6 305m NC-1LN6UU/CCA/M',                 24),
  ('ABLEKUMA1', 'Dahua cat6 cable 305m DH-PFM922I-6UN-C',          154),
  ('ABLEKUMA1', 'D-Link cat6 cable 305m',                            8),
  ('ABLEKUMA1', '1U rug',                                           24),
  ('ABLEKUMA1', 'DS-D5C98RB/B',                                      1),
  ('ABLEKUMA1', 'DS-D5ABKY2-B',                                      1),
  ('ABLEKUMA1', '42U 800x1000x2000',                                 1),
  ('ABLEKUMA1', '15U 800HX600WX450D',                                1),

  -- ── FISHPONG-1 ─────────────────────────────────────────────────────
  ('FISHPONG-1', 'HILOOK-THC-B127-LPS 2MP',                        192),
  ('FISHPONG-1', 'HILOOK-DVR-116G-M1-16-1U 2MP',                    10),
  ('FISHPONG-1', 'HILOOK-NVR-104H-D/4P NVR',                        13),
  ('FISHPONG-1', 'HILOOK-NVR-216MH-C/16P 4K NVR',                   16),
  ('FISHPONG-1', 'HILOOK-NVR-108H-D/8P',                            27),
  ('FISHPONG-1', 'THC-T140-P 4MP',                                  53),
  ('FISHPONG-1', 'HILOOK-THC-T127-LPC 2MP',                         58)
) as v(warehouse, model, qty)
where not exists (
  select 1 from public.warehouse_stock ws
  where ws.warehouse = v.warehouse and ws.model = v.model
);

-- Quick verification
select warehouse, count(*) as items, sum(opening_stock) as total_pcs
from public.warehouse_stock
where warehouse in ('ABLEKUMA1','ABLEKUMA2','FISHPONG-1')
group by warehouse
order by warehouse;
