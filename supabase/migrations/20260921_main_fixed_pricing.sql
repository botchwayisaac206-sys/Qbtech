-- ─────────────────────────────────────────────────────────────
-- Main-shop fixed pricing — 2026-09-21
--
-- Gives every main-shop product ONE selling price and makes that price the
-- price an invoice line is written with — the same treatment Dahua got in
-- 20260906_dahua_pricing.sql / _price_override.sql.
--
-- WHERE THE PRICE LIVES
--   pricelist_items.ghs_price, keyed on the model string, NOT a column on
--   warehouse_stock. Dahua could put the price on the stock row because it
--   has a single warehouse; here the same model sits in BACK WAREHOUSE,
--   FISHPONG-1 and STORE STOCK at once, and three rows would mean three
--   prices to keep in step by hand. pricelist_items is also already what
--   the invoice form reads, so nothing has to be migrated onto a new table.
--
-- WHO MAY REPRICE
--   Already settled: "write pricelist_items" is superboss-only RLS
--   (20260807_superboss.sql), so the Big-Boss lock Dahua needed a trigger
--   for is enforced here by the policy. No lock trigger is added.
--
-- WHAT THE TRIGGERS DO
--   1. invoice_item_apply_price     a line with no price typed takes the
--                                   model's price; line_total is always
--                                   derived, never trusted from the client.
--   2. invoice_log_price_override   selling at anything other than the list
--                                   price is written to audit_log.
--   3. invoice_resync_totals        the header (subtotal / VAT / total) is
--                                   recomputed from its own lines.
--
-- A line typed free-hand, or picked from the product catalogue (whose
-- description reads "Title — MODEL"), matches no pricelist model. Those are
-- left exactly as the cashier entered them: unpriced, not zeroed.
--
-- Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────

begin;

-- ── 1. Somewhere to file a price entered from the Stock tab ───
-- pricelist_items.category_id is NOT NULL, so a price for a model that has
-- no catalogue entry yet needs a category to land in.
insert into public.pricelist_categories (name)
select 'Stock items'
 where not exists (select 1 from public.pricelist_categories where name = 'Stock items');

-- ── 2. The price of a model ───────────────────────────────────
-- Case- and whitespace-insensitive, because a model typed on an invoice and
-- the same model typed into the price list rarely agree on either.
--
-- Nothing constrains pricelist_items to one row per model, and the shop has
-- been entering rows by hand for months, so a model CAN have several. The
-- most recently entered priced row wins: "the last price I typed is the
-- price" is a rule staff can predict without being taught it.
create or replace function public.price_for_model(p_model text)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select pi.ghs_price
    from public.pricelist_items pi
   where upper(btrim(pi.model)) = upper(btrim(coalesce(p_model, '')))
     and btrim(coalesce(p_model, '')) <> ''
     and pi.ghs_price > 0
   order by pi.created_at desc
   limit 1
$$;

-- The lookup above runs for every invoice line saved.
create index if not exists pricelist_items_model_upper_idx
  on public.pricelist_items (upper(btrim(model)));

-- ── 3. Remember the price that applied at the time of sale ────
-- An override is only detectable against the price that applied WHEN the
-- line was written. Reading the price list later gives today's figure, so a
-- repricing would silently turn old sales into overrides, or hide real ones.
alter table public.invoice_items
  add column if not exists list_price numeric(12,2) not null default 0;

comment on column public.invoice_items.list_price is
  'The model''s fixed price at the moment this line was saved. 0 = the model '
  'had no fixed price (or the line is free text). An override is '
  'list_price > 0 and unit_price <> list_price.';

-- Deliberately NOT back-filled. Lines written before this migration were
-- priced by hand with no list price in force, and setting list_price =
-- unit_price would invent a fixed price that never existed and make every
-- historical sale look like it matched one.

-- ── 4. Apply the price ────────────────────────────────────────
create or replace function public.fn_invoice_item_apply_price()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  fixed numeric(12,2);
begin
  fixed := public.price_for_model(new.description);
  new.list_price := coalesce(fixed, 0);

  -- A line saved with no price takes the model's price. This is what makes
  -- pricing automatic in the ordinary case: the cashier picks the item and
  -- does nothing else. Typing a different figure is an override, and step 5
  -- logs it rather than blocking it — a counter negotiation must not fail.
  if coalesce(new.unit_price, 0) = 0 and coalesce(fixed, 0) > 0 then
    new.unit_price := fixed;
  end if;

  new.line_total := round(coalesce(new.quantity, 0) * coalesce(new.unit_price, 0), 2);
  return new;
end;
$$;

drop trigger if exists trg_invoice_item_apply_price on public.invoice_items;
create trigger trg_invoice_item_apply_price
  before insert or update on public.invoice_items
  for each row execute function public.fn_invoice_item_apply_price();

-- ── 5. Log every override ─────────────────────────────────────
-- Definer because a cashier has no INSERT on audit_log — the same pattern
-- fn_audit() uses for invoices and expenses.
create or replace function public.fn_invoice_log_price_override()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  inv record;
begin
  if coalesce(new.list_price, 0) <= 0     then return null; end if;
  if new.unit_price = new.list_price      then return null; end if;

  select invoice_number, customer_name into inv
    from public.invoices where id = new.invoice_id;

  insert into public.audit_log (actor_id, actor_role, action, table_name, row_id, diff)
  values (
    auth.uid(),
    public.current_role(),
    'override',
    'invoice_price_override',
    new.id::text,
    jsonb_build_object(
      'model',          new.description,
      'description',    new.description,
      'invoice_id',     new.invoice_id,
      'invoice_number', inv.invoice_number,
      'customer_name',  inv.customer_name,
      'quantity',       new.quantity,
      'list_price',     new.list_price,
      'unit_price',     new.unit_price,
      'difference',     round(new.unit_price - new.list_price, 2),
      'total_effect',   round((new.unit_price - new.list_price) * new.quantity, 2)
    )
  );
  return null;
end;
$$;

drop trigger if exists trg_invoice_log_price_override on public.invoice_items;
create trigger trg_invoice_log_price_override
  after insert or update on public.invoice_items
  for each row execute function public.fn_invoice_log_price_override();

-- ── 6. Header totals always match the lines ───────────────────
-- Without this, a line the trigger repriced would leave the header showing
-- the figure the client computed before the price was applied.
create or replace function public.fn_invoice_resync_totals()
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

  select vat_rate into rate from public.invoices where id = inv;
  if rate is null then
    return null;  -- invoice already gone (cascade delete)
  end if;

  select coalesce(sum(line_total), 0) into sub
    from public.invoice_items where invoice_id = inv;

  vat := round(sub * rate / 100, 2);

  update public.invoices
     set subtotal   = sub,
         vat_amount = vat,
         total      = round(sub + vat, 2)
   where id = inv;

  return null;
end;
$$;

drop trigger if exists trg_invoice_resync_totals on public.invoice_items;
create trigger trg_invoice_resync_totals
  after insert or update or delete on public.invoice_items
  for each row execute function public.fn_invoice_resync_totals();

-- ── 7. Setting a price from the Stock tab ─────────────────────
-- The Prices screen thinks in models, not in price-list rows: it should not
-- have to know about categories, or whether a row for this model exists.
-- Updates the most recent row for the model, or creates one.
--
-- Definer so the category lookup and insert are not blocked by RLS, but
-- gated to the Big Boss explicitly — otherwise this would be a hole straight
-- through the superboss-only write policy it is standing in front of.
create or replace function public.set_model_price(p_model text, p_price numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_model text := btrim(coalesce(p_model, ''));
  v_id    uuid;
  v_cat   uuid;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss may set a selling price'
      using errcode = '42501';
  end if;
  if v_model = '' then
    raise exception 'A price needs a model';
  end if;
  if p_price is null or p_price < 0 then
    raise exception 'A price cannot be negative';
  end if;

  select id into v_id
    from public.pricelist_items
   where upper(btrim(model)) = upper(v_model)
   order by created_at desc
   limit 1;

  if v_id is not null then
    update public.pricelist_items set ghs_price = p_price where id = v_id;
  else
    select id into v_cat from public.pricelist_categories where name = 'Stock items' limit 1;
    if v_cat is null then
      insert into public.pricelist_categories (name) values ('Stock items') returning id into v_cat;
    end if;
    -- `name` is NOT NULL and is what the Price List tab shows; the model is
    -- the only name this row has.
    insert into public.pricelist_items (category_id, name, model, ghs_price)
    values (v_cat, v_model, v_model, p_price);
  end if;
end;
$$;

grant execute on function public.price_for_model(text)        to authenticated;
grant execute on function public.set_model_price(text, numeric) to authenticated;

commit;

-- ── Verification ──────────────────────────────────────────────
-- How much of STORE STOCK is priced:
--
-- select count(*) filter (where public.price_for_model(model) > 0) as priced,
--        count(*) filter (where coalesce(public.price_for_model(model), 0) = 0) as unpriced
--   from public.warehouse_stock where warehouse = 'STORE STOCK';
--
-- Overrides so far, newest first:
--
-- select created_at,
--        diff->>'invoice_number' as invoice,
--        diff->>'model'          as model,
--        diff->>'list_price'     as should_be,
--        diff->>'unit_price'     as sold_at,
--        diff->>'total_effect'   as effect
--   from public.audit_log
--  where table_name = 'invoice_price_override'
--  order by created_at desc;
