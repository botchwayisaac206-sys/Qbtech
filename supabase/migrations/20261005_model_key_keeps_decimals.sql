-- ─────────────────────────────────────────────────────────────
-- "1.5M" is not "15M" — 2026-10-05
--
-- Corrects 20261005_no_duplicate_names_on_moves.sql, found the first time
-- the rule was read against the real stock list.
--
-- stock_model_key() dropped every character that is not a letter or a
-- digit, including the decimal point. STORE STOCK carries both
--
--     1.5M PATCH CORD      and      15M PATCH CORD
--
-- and without the point both reduce to 15MPATCHCORD — one product, as far
-- as the matching was concerned. Moving the 1.5 m cord into a location that
-- only stocked the 15 m one would have added it to the 15 m row.
--
-- A point BETWEEN TWO DIGITS is now kept (as "~" in the key). Every other
-- point is still punctuation: "DS-7608NI-Q2." and "DS-7608NI-Q2" stay the
-- same product.
--
-- The two indexes are built on this function's result, and Postgres does
-- not rebuild an index when the function under it changes. They are dropped
-- first and rebuilt after, or lookups would run against the old keys.
--
-- Also here: merge_stock_model() trimmed the name it was asked to get rid
-- of, so a name stored with a trailing space — there are two dozen — could
-- never be found to be merged. The old name is now matched exactly as it is
-- stored.
--
-- Requires 20261005_no_duplicate_names_on_moves.sql and
-- 20261005_merge_product_names.sql. Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regprocedure('public.stock_model_key(text)') is null then
    raise exception 'Run 20261005_no_duplicate_names_on_moves.sql first — this file corrects it.'
      using errcode = '42P01';
  end if;
  if to_regprocedure('public.merge_stock_model(text, text, text)') is null then
    raise exception 'Run 20261005_merge_product_names.sql first — this file corrects it.'
      using errcode = '42P01';
  end if;
end $$;

drop index if exists public.warehouse_stock_warehouse_key_idx;
drop index if exists public.dahua_stock_warehouse_key_idx;

create or replace function public.stock_model_key(p_model text)
returns text
language sql immutable parallel safe as $$
  select regexp_replace(
           regexp_replace(upper(coalesce(p_model, '')), '([0-9])\.(?=[0-9])', '\1~', 'g'),
           '[^A-Z0-9~]', '', 'g')
$$;

create index warehouse_stock_warehouse_key_idx
  on public.warehouse_stock (warehouse, public.stock_model_key(model));
create index dahua_stock_warehouse_key_idx
  on public.dahua_stock (warehouse, public.stock_model_key(model));

-- ── merge_stock_model: find the old name as it is stored ──────
-- Identical to 20261005_merge_product_names.sql except for how v_from is
-- taken: no longer trimmed.
create or replace function public.merge_stock_model(
  p_line text,
  p_from text,
  p_into text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_from     text := coalesce(p_from, '');
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
  if btrim(v_from) = '' or v_into = '' then
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
             min(s.min_level)
        into v_opening, v_invoice, v_in, v_out, v_min
        from public.warehouse_stock s
       where s.warehouse = v_wh and s.model in (v_from, v_into);

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

-- ── Verification ──────────────────────────────────────────────
-- select public.stock_model_key('1.5M PATCH CORD') as a,    -- 1~5MPATCHCORD
--        public.stock_model_key('15M PATCH CORD')  as b,    -- 15MPATCHCORD
--        public.stock_model_key('DS-7608NI-Q2.')   as c;    -- DS7608NIQ2
