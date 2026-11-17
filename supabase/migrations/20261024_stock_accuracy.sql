-- ─────────────────────────────────────────────────────────────
-- Stock accuracy: the faults an end-to-end check turned up — 2026-10-24
--
-- 1. RENAMING A PRODUCT LOST ITS PRICE
--    The Stock tab renamed one row by rewriting its `model`. The main
--    shop's price is filed under the product's NAME (pricelist_items), so
--    the renamed row no longer found it and showed GH¢ 0 — and the same
--    product kept the old name in every other location, its barcodes
--    pointed at a name that was gone, and the catalogue still carried the
--    old model number.
--      → A stock row's name can no longer be changed by a plain UPDATE from
--        the app. Renames go through merge_stock_model(), which renames the
--        product in every location and takes its barcodes and price along.
--      → merge_stock_model() now also carries the price when it was filed
--        under different capitals or spacing, and updates the catalogue's
--        model number — an invoice line picked from the catalogue deducts
--        by that number, and would otherwise match no stock row and
--        silently deduct nothing.
--
-- 2. AN EDIT COULD UNDO SALES AND TRANSFERS
--    The Dahua stock editor sent the row's invoice_taken back as it was
--    when the page loaded. Any sale made since was wiped off the count.
--      → invoice_taken, transfer_in and transfer_out are kept as they are
--        on any direct UPDATE from the app. Only the sale, transfer and
--        merge functions change them.
--
-- 3. DELETING AN INVOICE DID NOT GIVE THE STOCK BACK
--    Main-shop invoices: deleted, but STORE STOCK kept the units as sold.
--    Dahua invoices: given back from the browser one row at a time, so a
--    dropped connection could restore half an invoice.
--      → delete_invoice_restoring_stock() gives back exactly what the
--        invoice took and deletes it, in one step.
--
-- 4. A PRICE WAS MISSED UNDER ANOTHER SPELLING
--    price_for_model() matched the name exactly (bar capitals and outer
--    spaces), so "ds-2ce16d0t lpfs" found no price filed as
--    "DS-2CE16D0T-LPFS".
--      → It now falls back to the same product key every stock movement
--        uses (stock_model_key).
--
-- Requires 20261005_uniform_names.sql and 20260930_lock_stock_writes.sql.
-- Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regprocedure('public.stock_merge_names(text, text, text)') is null then
    raise exception 'Run 20261005_uniform_names.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1 & 2. Guard the counters and the name on direct writes ───
-- The app's own writes arrive as the `authenticated` role. The sale,
-- transfer and merge functions run as their owner, so they pass.
create or replace function public.stock_row_guard()
returns trigger
language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') then
    new.invoice_taken := old.invoice_taken;
    new.transfer_in   := old.transfer_in;
    new.transfer_out  := old.transfer_out;
    if new.model is distinct from old.model then
      raise exception 'Rename a product with Product names — it renames it in every location and keeps its price and barcodes.'
        using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

-- Named to run before the triggers that derive closing_stock from these
-- columns (BEFORE triggers fire in name order).
drop trigger if exists trg_a_stock_row_guard on public.warehouse_stock;
create trigger trg_a_stock_row_guard
  before update on public.warehouse_stock
  for each row execute function public.stock_row_guard();

drop trigger if exists trg_a_stock_row_guard on public.dahua_stock;
create trigger trg_a_stock_row_guard
  before update on public.dahua_stock
  for each row execute function public.stock_row_guard();

-- ── 1. Renames carry the price and the catalogue along ────────
create or replace function public.merge_stock_model(p_line text, p_from text, p_into text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_from text := coalesce(p_from, '');
  v_into text := btrim(coalesce(p_into, ''));
  v_res  jsonb;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss may rename or merge product names';
  end if;
  if p_line is null or p_line not in ('main', 'dahua') then
    raise exception 'Unknown stock line';
  end if;
  if v_from = v_into then
    raise exception 'Those are the same name';
  end if;
  if p_line = 'main' and not exists (select 1 from public.warehouse_stock where model = v_from) then
    raise exception 'Nothing is stocked as "%"', v_from;
  end if;
  if p_line = 'dahua' and not exists (select 1 from public.dahua_stock where model = v_from) then
    raise exception 'Dahua stocks nothing as "%"', v_from;
  end if;

  v_res := public.stock_merge_names(p_line, v_from, v_into);

  if p_line = 'main' and upper(btrim(v_from)) <> upper(v_into) then
    -- The price, wherever it was filed under the old name — unless the
    -- kept name already has one of its own.
    update public.pricelist_items
       set model = v_into
     where upper(btrim(model)) = upper(btrim(v_from))
       and not exists (select 1 from public.pricelist_items p where upper(btrim(p.model)) = upper(v_into));
    -- The catalogue: a line picked from it deducts by this number.
    if to_regclass('public.products') is not null then
      update public.products
         set model_number = v_into
       where upper(btrim(coalesce(model_number, ''))) = upper(btrim(v_from));
    end if;
  end if;

  return v_res;
end $$;

-- ── 3. Deleting an invoice gives its stock back ───────────────
create or replace function public.delete_invoice_restoring_stock(p_line text, p_invoice_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_number   text;
  v_item     record;
  v_id       uuid;
  v_restored integer := 0;
  v_missing  text[] := '{}';
  v_deducted boolean;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss can delete invoices';
  end if;
  if p_line not in ('main', 'dahua') then
    raise exception 'Unknown stock line';
  end if;

  if p_line = 'main' then
    select invoice_number into v_number from public.invoices where id = p_invoice_id for update;
  else
    select invoice_number into v_number from public.dahua_invoices where id = p_invoice_id for update;
  end if;
  if not found then
    raise exception 'That invoice no longer exists';
  end if;

  -- Only what was actually taken is given back.
  delete from public.invoice_stock_deductions
   where line = p_line and invoice_id = p_invoice_id
  returning true into v_deducted;

  if coalesce(v_deducted, false) and p_line = 'main' then
    -- The same lines, matched the same way, as deduct_invoice_store_stock.
    for v_item in
      select min(x.model) as model, sum(x.quantity)::integer as qty
        from (
          select btrim(coalesce(nullif(btrim(p.model_number), ''), i.description)) as model, i.quantity
            from public.invoice_items i
            left join public.products p on p.id = i.product_id
           where i.invoice_id = p_invoice_id and i.quantity > 0
        ) x
       where x.model <> ''
       group by upper(x.model)
    loop
      v_id := public.stock_find_row('STORE STOCK', v_item.model);
      if v_id is null then
        continue;      -- not a stocked product: nothing was taken
      end if;
      update public.warehouse_stock
         set invoice_taken = greatest(0, coalesce(invoice_taken, 0) - v_item.qty)
       where id = v_id;
      v_restored := v_restored + 1;
    end loop;
  elsif coalesce(v_deducted, false) then
    for v_item in
      select i.stock_id, i.description, i.quantity
        from public.dahua_invoice_items i
       where i.invoice_id = p_invoice_id and i.quantity > 0 and i.stock_id is not null
    loop
      update public.dahua_stock
         set invoice_taken = greatest(0, coalesce(invoice_taken, 0) - v_item.quantity)
       where id = v_item.stock_id;
      if found then
        v_restored := v_restored + 1;
      else
        v_missing := v_missing || v_item.description;
      end if;
    end loop;
  end if;

  if p_line = 'main' then
    delete from public.invoices where id = p_invoice_id;
  else
    delete from public.dahua_invoices where id = p_invoice_id;
  end if;

  return jsonb_build_object('invoice_number', v_number, 'restored', v_restored, 'missing', to_jsonb(v_missing));
end $$;

revoke all on function public.delete_invoice_restoring_stock(text, uuid) from public, anon;
grant execute on function public.delete_invoice_restoring_stock(text, uuid) to authenticated;

-- ── 4. A price is found under any spelling of the product ─────
create or replace function public.price_for_model(p_model text)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select pi.ghs_price
       from public.pricelist_items pi
      where upper(btrim(pi.model)) = upper(btrim(coalesce(p_model, '')))
        and btrim(coalesce(p_model, '')) <> ''
        and pi.ghs_price > 0
      order by pi.created_at desc
      limit 1),
    (select pi.ghs_price
       from public.pricelist_items pi
      where public.stock_model_key(pi.model) = public.stock_model_key(p_model)
        and public.stock_model_key(p_model) <> ''
        and pi.ghs_price > 0
      order by pi.created_at desc
      limit 1)
  )
$$;
grant execute on function public.price_for_model(text) to authenticated;

notify pgrst, 'reload schema';

-- ── Verification ──────────────────────────────────────────────
-- One product under two names in different locations (each should be
-- merged in Transfers → Product names):
--
-- select public.stock_model_key(model) as code, array_agg(distinct model) as names
--   from public.warehouse_stock group by 1 having count(distinct model) > 1;
--
-- Stocked products with no price under any spelling:
--
-- select distinct model from public.warehouse_stock
--  where coalesce(public.price_for_model(model), 0) = 0 order by 1;
