-- ─────────────────────────────────────────────────────────────
-- Make the invoice deduction match a model the way everything else does
-- 2026-09-21
--
-- deduct_store_stock() matched the invoice line against the stock row with
-- a plain `=`, so the match was case- and spacing-sensitive. Every other
-- lookup in the system is not: price_for_model() resolves on
-- upper(btrim(model)), and the Prices screen keys on the same. A line could
-- therefore be priced correctly and still fail to come off the shelf, and
-- the failure is quiet — the model is simply reported as untracked, which
-- reads as "the store does not carry this" rather than "the spelling did
-- not line up".
--
-- The barcode path makes this more than theoretical: a scanned line takes
-- its model from product_codes, which is populated by hand as staff link
-- codes, so its spelling need not match warehouse_stock exactly.
--
-- The shortfall now also names the model AS STORED rather than as typed, so
-- a warning points at the row the cashier will actually go and look at.
--
-- Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────

-- Every invoice save runs one lookup per line against this.
create index if not exists warehouse_stock_warehouse_model_upper_idx
  on public.warehouse_stock (warehouse, upper(btrim(model)));

create or replace function public.deduct_store_stock(
  p_items jsonb,
  p_store text default 'STORE STOCK'
) returns table (model text, requested integer, available integer, tracked boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item  jsonb;
  v_typed text;
  v_qty   integer;
  v_id    uuid;
  v_model text;
  v_have  integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to adjust stock';
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_typed := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_typed = '' or v_qty <= 0 then
      continue;
    end if;

    -- Locked so two tills invoicing the same model cannot both read the
    -- same "before" figure. Nothing stops two rows in one location
    -- differing only by case, so the oldest wins — deterministic, and the
    -- same row every time rather than whichever the planner returned.
    select s.id, s.model, s.closing_stock
      into v_id, v_model, v_have
      from public.warehouse_stock s
     where s.warehouse = p_store
       and upper(btrim(s.model)) = upper(v_typed)
     order by s.created_at, s.id::text
     limit 1
     for update;

    if not found then
      -- Reported, not invented. A line typed free-hand, or an item the shop
      -- genuinely does not stock, should not create a negative row out of
      -- nothing; the form decides whether this is worth mentioning.
      model := v_typed; requested := v_qty; available := 0; tracked := false;
      return next;
      continue;
    end if;

    update public.warehouse_stock
       set invoice_taken = coalesce(invoice_taken, 0) + v_qty
     where id = v_id;

    -- The sale is never blocked by the count; a shortfall is reported and
    -- the closing figure simply goes negative.
    if v_have < v_qty then
      model := v_model; requested := v_qty; available := v_have; tracked := true;
      return next;
    end if;
  end loop;
end $$;

grant execute on function public.deduct_store_stock(jsonb, text) to authenticated;

-- ── Verification ──────────────────────────────────────────────
-- What the store holds for a model, however it was typed:
--
-- select model, opening_stock, transfer_in, invoice_taken, closing_stock
--   from public.warehouse_stock
--  where warehouse = 'STORE STOCK'
--    and upper(btrim(model)) = upper(btrim('ds-2ce16d0t-lpfs'));
--
-- Everything the shop floor has sold so far:
--
-- select model, invoice_taken, closing_stock
--   from public.warehouse_stock
--  where warehouse = 'STORE STOCK' and invoice_taken > 0
--  order by invoice_taken desc;
