-- Barcode / material-code → model lookup for scan-based stock taking & pricelist.
--
-- Each physical CCTV box carries a manufacturer "material code" (Hikvision's
-- internal part number). Unlike the serial number, the material code is SHARED
-- by every unit of the same model, so it maps cleanly to our product `model`
-- string (the shared identity used by both warehouse_stock and pricelist_items).
--
-- Populated "learn as you scan": the first time an unknown code is scanned the
-- operator links it to a model; every future scan of that model resolves instantly.

create table if not exists product_codes (
  id            uuid primary key default gen_random_uuid(),
  material_code text not null,
  model         text not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- One model per code. Scanning the same code again updates the mapping in place.
create unique index if not exists product_codes_material_code_key
  on product_codes (material_code);

alter table product_codes enable row level security;

-- All authenticated staff can read (scanning needs lookups) and link codes,
-- since stock-taking is done by cashiers/staff, not just the boss.
create policy "read product_codes"  on product_codes for select to authenticated using (true);
create policy "write product_codes"  on product_codes for all    to authenticated using (true) with check (true);
