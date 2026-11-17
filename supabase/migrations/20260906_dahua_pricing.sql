-- ─────────────────────────────────────────────────────────────
-- Dahua fixed pricing — 2026-09-06
--
-- Gives every Dahua product ONE selling price, held on the product itself,
-- and makes that price the price an invoice line is written with.
--
-- Before this migration the cashier typed a unit price by hand on every
-- Dahua invoice line. Nothing tied the number to the product, so the same
-- model went out at different prices and dahua_invoices.total could not be
-- read as "what this product sells for" — which is what broke sales
-- tracking. dahua_stock now carries unit_price, and three triggers keep it
-- honest:
--
--   1. dahua_stock_lock_price      only the Big Boss may change a price.
--   2. dahua_item_apply_price      an invoice line linked to a product is
--                                  written at that product's price, whoever
--                                  saves it; line_total is always derived.
--   3. dahua_invoice_resync_totals the invoice header (subtotal / VAT /
--                                  total) is recomputed from its own lines,
--                                  so a snapped price can never leave the
--                                  header disagreeing with the items.
--
-- Enforcement is in the database, not only in the React gates. Cashiers hold
-- UPDATE on dahua_stock (invoice save deducts quantities) and INSERT on
-- dahua_invoice_items, so a REST client with the anon key could otherwise
-- rewrite prices freely. RLS cannot express "every column but this one", so
-- the column-level rule is a trigger.
--
-- Unpriced products (unit_price = 0) are deliberately left alone by trigger 2
-- so the shop is not blocked before the price list is entered — the cashier
-- can still type a price on those, and the admin UI flags them.
--
-- Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────

begin;

-- ── 1. The price column ───────────────────────────────────────
alter table public.dahua_stock
  add column if not exists unit_price numeric(12,2) not null default 0;

comment on column public.dahua_stock.unit_price is
  'Fixed selling price in GH¢. Big Boss only. Auto-fills and locks the unit '
  'price on any invoice line linked to this product. 0 = not yet priced.';

-- ── 2. Only the Big Boss may change a price ───────────────────
-- Cashiers legitimately UPDATE this table on every invoice save (stock
-- deduction). Those updates leave unit_price untouched, so they pass; an
-- attempt to alter the price itself is rejected.
--
-- The auth.uid() test is what lets a migration run. A session with no JWT is
-- not an app user at all — it is the Supabase SQL editor, psql, or the
-- service-role key. Those already bypass RLS entirely, so refusing them here
-- buys no safety and only blocks the very migrations that set prices in bulk.
-- The lock still binds every request that arrives through the app, which is
-- where cashiers actually are.
create or replace function public.dahua_stock_lock_price()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.unit_price is distinct from old.unit_price
     and (select auth.uid()) is not null
     and not (select public.is_superboss()) then
    raise exception
      'Only the Big Boss may change a Dahua selling price (%)', old.model
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_dahua_stock_lock_price on public.dahua_stock;
create trigger trg_dahua_stock_lock_price
  before update on public.dahua_stock
  for each row execute function public.dahua_stock_lock_price();

-- ── 3. Invoice lines are written at the product's price ───────
-- The Big Boss keeps the ability to override a line (a negotiated sale).
-- Everyone else gets the fixed price regardless of what the client sent.
-- line_total is always derived, never trusted from the client.
create or replace function public.dahua_item_apply_price()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  fixed numeric(12,2);
begin
  if new.stock_id is not null then
    select unit_price into fixed
      from public.dahua_stock
     where id = new.stock_id;

    -- unit_price = 0 means the product has not been priced yet; leave the
    -- typed price alone rather than zeroing out the sale. As above, a session
    -- with no JWT is a console or the service role, not a cashier — it writes
    -- the price it states.
    if fixed is not null and fixed > 0
       and (select auth.uid()) is not null
       and not (select public.is_superboss()) then
      new.unit_price := fixed;
    end if;
  end if;

  new.line_total := round(new.quantity * new.unit_price, 2);
  return new;
end;
$$;

drop trigger if exists trg_dahua_item_apply_price on public.dahua_invoice_items;
create trigger trg_dahua_item_apply_price
  before insert or update on public.dahua_invoice_items
  for each row execute function public.dahua_item_apply_price();

-- ── 4. Header totals always match the lines ───────────────────
-- Runs as definer because a cashier has no UPDATE on dahua_invoices.
create or replace function public.dahua_invoice_resync_totals()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  inv  uuid;
  sub  numeric(12,2);
  rate numeric(5,2);
  vat  numeric(12,2);
begin
  inv := coalesce(new.invoice_id, old.invoice_id);

  select vat_rate into rate from public.dahua_invoices where id = inv;
  if rate is null then
    return null;  -- invoice already gone (cascade delete)
  end if;

  select coalesce(sum(line_total), 0) into sub
    from public.dahua_invoice_items
   where invoice_id = inv;

  vat := round(sub * rate / 100, 2);

  update public.dahua_invoices
     set subtotal   = sub,
         vat_amount = vat,
         total      = round(sub + vat, 2)
   where id = inv;

  return null;
end;
$$;

drop trigger if exists trg_dahua_invoice_resync_totals on public.dahua_invoice_items;
create trigger trg_dahua_invoice_resync_totals
  after insert or update or delete on public.dahua_invoice_items
  for each row execute function public.dahua_invoice_resync_totals();

-- ── 5. Sales-tracking index ───────────────────────────────────
-- The dashboard and invoice list both scan by date.
create index if not exists dahua_invoices_issued_at_idx
  on public.dahua_invoices (issued_at desc);
create index if not exists dahua_invoice_items_invoice_id_idx
  on public.dahua_invoice_items (invoice_id);

commit;

-- ── Optional: seed prices from the existing pricelist ─────────
-- Copies ghs_price onto any Dahua product whose model matches a pricelist
-- code exactly. Most Dahua models are not in pricelist_items, so this only
-- saves a little typing — the rest are entered in Admin → Dahua Stock →
-- 💰 Prices. Run it as the Big Boss, or the price-lock trigger will reject it.
--
-- update public.dahua_stock s
--    set unit_price = pi.ghs_price
--   from public.pricelist_items pi
--  where upper(trim(s.model)) = upper(trim(pi.model))
--    and s.unit_price = 0
--    and pi.ghs_price > 0;

-- ── Verification ──────────────────────────────────────────────
-- select count(*) filter (where unit_price > 0) as priced,
--        count(*) filter (where unit_price = 0) as unpriced
--   from public.dahua_stock;
