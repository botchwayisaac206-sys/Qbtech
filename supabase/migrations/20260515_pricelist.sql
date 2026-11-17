-- Price list tables
-- pricelist_categories: each category has its own GH₵/$ rate and duty toggle
-- pricelist_items: boss types name/model/USD price; GH₵ is always calculated live

create table if not exists pricelist_categories (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  rate_ghs_per_usd numeric(10,4) not null default 15,
  duty_rate_pct    numeric(6,2)  not null default 0,
  duties_enabled   boolean       not null default false,
  created_at       timestamptz   not null default now()
);

create table if not exists pricelist_items (
  id          uuid primary key default gen_random_uuid(),
  category_id uuid not null references pricelist_categories(id) on delete cascade,
  name        text not null,
  model       text not null default '',
  usd_price   numeric(12,2) not null default 0,
  created_at  timestamptz not null default now()
);

alter table pricelist_categories enable row level security;
alter table pricelist_items      enable row level security;

-- All authenticated users can read
create policy "read pricelist_categories" on pricelist_categories for select to authenticated using (true);
create policy "read pricelist_items"      on pricelist_items      for select to authenticated using (true);

-- Only boss/admin can write
create policy "write pricelist_categories" on pricelist_categories for all to authenticated using (
  exists (select 1 from user_roles where user_id = auth.uid() and role in ('boss','admin'))
);
create policy "write pricelist_items" on pricelist_items for all to authenticated using (
  exists (select 1 from user_roles where user_id = auth.uid() and role in ('boss','admin'))
);
