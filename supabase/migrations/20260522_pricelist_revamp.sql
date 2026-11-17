-- Pricelist revamp: drop FX rate / duty workflow, store price directly in GH₵,
-- add specifications and image fields.
--
-- Old columns (usd_price, name, rate_ghs_per_usd, duty_rate_pct, duties_enabled)
-- are kept for safety so any external readers don't break; the UI no longer
-- writes to them.

alter table pricelist_items
  add column if not exists specifications text          not null default '',
  add column if not exists image_url       text,
  add column if not exists ghs_price       numeric(12,2) not null default 0;

-- Back-fill ghs_price from the old usd_price * rate * (1+duty) formula so
-- existing rows keep the price they showed before this migration.
update pricelist_items pi
set ghs_price = round(
  pi.usd_price * pc.rate_ghs_per_usd
  * (case when pc.duties_enabled then 1 + pc.duty_rate_pct / 100 else 1 end),
  2
)
from pricelist_categories pc
where pi.category_id = pc.id
  and pi.ghs_price = 0
  and pi.usd_price > 0;
