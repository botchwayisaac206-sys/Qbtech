-- ─────────────────────────────────────────────────────────────
-- One product, one name — 2026-10-05
--
-- Stock is keyed on the model NAME, per warehouse. Nothing ties "EAP225" in
-- one warehouse to "EAP225 Wireless ceiling mount" in another, so the same
-- product under two spellings is, to the system, two products: the piles
-- cannot be transferred into each other, a sale comes off one and never the
-- other, and neither figure is the real count.
--
-- 20260921_merge_digital_multimeter.sql fixed one such pair by hand. This
-- turns that file into a function the Big Boss can run from the app for any
-- pair, on either line:
--
--   merge_stock_model('main',  'DIGITAL MULTIMETER', 'DIGITAL MULTIMETER DT920SA')
--   merge_stock_model('dahua', 'old spelling',       'spelling to keep')
--
-- WHAT IT DOES
--   In every warehouse of that line holding the old name, the rows under
--   either name are added together onto one row — opening count, sold,
--   moved in, moved out and each day column — and that row takes the kept
--   name. Where only the old name exists it is a plain rename.
--
--   Barcodes linked to the old name follow it, so the next scan of that box
--   still resolves. On the main line a price-list entry under the old name
--   follows too, unless the kept name already has one. On Dahua, invoice
--   lines that pointed at an absorbed row are re-pointed at the surviving
--   one, and the surviving row keeps its price (or takes the highest of the
--   group when it has none).
--
-- WHAT IT DOES NOT DO
--   It does not rewrite past invoices or past movement records. Those say
--   what was printed and what was moved at the time, under the name used
--   then.
--
--   It does not decide what is a duplicate. The app suggests pairs; a person
--   confirms each one. Kit codes that differ by one character are sometimes
--   genuinely different kits, and merging on a guess is how a count stops
--   matching the shelf.
--
-- Big Boss only. Idempotent to install; each merge is a single transaction.
-- ─────────────────────────────────────────────────────────────

create or replace function public.merge_stock_model(
  p_line text,
  p_from text,
  p_into text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_from     text := btrim(coalesce(p_from, ''));
  v_into     text := btrim(coalesce(p_into, ''));
  v_wh       text;
  v_keep     uuid;
  v_gone     uuid[];
  v_opening  integer;
  v_invoice  integer;
  v_in       integer;
  v_out      integer;
  v_min      integer;
  v_daily    jsonb;
  v_price    numeric(12,2);
  v_places   integer := 0;
  v_absorbed integer := 0;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss may merge product names';
  end if;
  if p_line is null or p_line not in ('main', 'dahua') then
    raise exception 'Unknown stock line';
  end if;
  if v_from = '' or v_into = '' then
    raise exception 'Both names are required';
  end if;
  if length(v_into) > 200 then
    raise exception 'That name is too long';
  end if;
  if v_from = v_into then
    raise exception 'Those are the same name';
  end if;

  if p_line = 'main' then
    if not exists (select 1 from public.warehouse_stock where model = v_from) then
      raise exception 'Nothing is stocked as "%"', v_from;
    end if;

    for v_wh in
      select distinct warehouse from public.warehouse_stock where model = v_from
    loop
      -- The surviving row: one already under the kept name if there is one,
      -- otherwise the one on the books longest.
      select s.id into v_keep
        from public.warehouse_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into)
       order by (s.model = v_into) desc, s.created_at, s.id::text
       limit 1
       for update;

      select coalesce(sum(s.opening_stock), 0),
             coalesce(sum(coalesce(s.invoice_taken, 0)), 0),
             coalesce(sum(coalesce(s.transfer_in, 0)), 0),
             coalesce(sum(coalesce(s.transfer_out, 0)), 0),
             -- The lower reorder point is the more cautious one. MIN skips
             -- nulls, so a row without one does not erase the other's.
             min(s.min_level)
        into v_opening, v_invoice, v_in, v_out, v_min
        from public.warehouse_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into);

      -- daily_taken is a day → qty map. Days booked in both piles are added,
      -- not overwritten.
      select coalesce(jsonb_object_agg(d.day, d.qty), '{}'::jsonb) into v_daily
        from (
          select e.key as day, sum(e.value::integer) as qty
            from public.warehouse_stock s
           cross join lateral jsonb_each_text(coalesce(s.daily_taken, '{}'::jsonb)) e
           where s.warehouse = v_wh and s.model in (v_from, v_into)
           group by e.key
        ) d;

      select coalesce(array_agg(s.id), '{}') into v_gone
        from public.warehouse_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into) and s.id <> v_keep;

      delete from public.warehouse_stock where id = any (v_gone);

      -- total_taken, closing_stock and stock_status are recomputed by
      -- trg_warehouse_stock_derive from these columns.
      update public.warehouse_stock
         set model         = v_into,
             opening_stock = v_opening,
             invoice_taken = v_invoice,
             transfer_in   = v_in,
             transfer_out  = v_out,
             min_level     = v_min,
             daily_taken   = v_daily
       where id = v_keep;

      v_places   := v_places + 1;
      v_absorbed := v_absorbed + coalesce(array_length(v_gone, 1), 0);
    end loop;

    update public.product_codes
       set model = v_into, updated_at = now()
     where model = v_from;

    -- Two price entries for one name would make the price ambiguous, so the
    -- old entry only follows when the kept name has none of its own.
    update public.pricelist_items
       set model = v_into
     where model = v_from
       and not exists (
             select 1 from public.pricelist_items p
              where upper(btrim(p.model)) = upper(v_into) and p.model <> v_from
           );

  else
    if not exists (select 1 from public.dahua_stock where model = v_from) then
      raise exception 'Dahua stocks nothing as "%"', v_from;
    end if;

    for v_wh in
      select distinct warehouse from public.dahua_stock where model = v_from
    loop
      select s.id into v_keep
        from public.dahua_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into)
       order by (s.model = v_into) desc, s.created_at, s.id::text
       limit 1
       for update;

      select coalesce(sum(s.opening_stock), 0),
             coalesce(sum(coalesce(s.invoice_taken, 0)), 0),
             coalesce(sum(coalesce(s.transfer_in, 0)), 0),
             coalesce(sum(coalesce(s.transfer_out, 0)), 0),
             min(s.min_level),
             max(s.unit_price)
        into v_opening, v_invoice, v_in, v_out, v_min, v_price
        from public.dahua_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into);

      select coalesce(jsonb_object_agg(d.day, d.qty), '{}'::jsonb) into v_daily
        from (
          select e.key as day, sum(e.value::integer) as qty
            from public.dahua_stock s
           cross join lateral jsonb_each_text(coalesce(s.daily_taken, '{}'::jsonb)) e
           where s.warehouse = v_wh and s.model in (v_from, v_into)
           group by e.key
        ) d;

      select coalesce(array_agg(s.id), '{}') into v_gone
        from public.dahua_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into) and s.id <> v_keep;

      -- Invoice lines keep pointing at a row that exists. The line triggers
      -- are lifted for this one statement: they would re-stamp each old
      -- line's list price from the surviving row and log the difference as a
      -- price override that never happened.
      if exists (select 1 from public.dahua_invoice_items where stock_id = any (v_gone)) then
        alter table public.dahua_invoice_items disable trigger user;
        update public.dahua_invoice_items set stock_id = v_keep where stock_id = any (v_gone);
        alter table public.dahua_invoice_items enable trigger user;
      end if;

      delete from public.dahua_stock where id = any (v_gone);

      update public.dahua_stock
         set model         = v_into,
             opening_stock = v_opening,
             invoice_taken = v_invoice,
             transfer_in   = v_in,
             transfer_out  = v_out,
             min_level     = v_min,
             daily_taken   = v_daily,
             -- Its own price stands; a row with none takes the group's.
             unit_price    = case when coalesce(unit_price, 0) > 0 then unit_price
                                  else coalesce(v_price, 0) end
       where id = v_keep;

      v_places   := v_places + 1;
      v_absorbed := v_absorbed + coalesce(array_length(v_gone, 1), 0);
    end loop;

    update public.dahua_product_codes
       set model = v_into, updated_at = now()
     where model = v_from;
  end if;

  return jsonb_build_object(
    'line', p_line, 'from', v_from, 'into', v_into,
    'warehouses', v_places, 'rows_absorbed', v_absorbed
  );
end $$;

revoke all on function public.merge_stock_model(text, text, text) from public, anon;
grant execute on function public.merge_stock_model(text, text, text) to authenticated;

-- ── Finding candidates by hand ────────────────────────────────
-- The app lists these under Transfers → Product names. The same search in
-- SQL — names in the main shop that are identical once case, spaces and
-- punctuation are ignored:
--
-- select regexp_replace(upper(model), '[^A-Z0-9]', '', 'g') as code,
--        array_agg(distinct model) as spellings,
--        array_agg(distinct warehouse) as warehouses
--   from public.warehouse_stock
--  group by 1
-- having count(distinct model) > 1
--  order by 1;
