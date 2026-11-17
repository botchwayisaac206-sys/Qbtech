-- ─────────────────────────────────────────────────────────────
-- Spoilt goods pile up in their own location — 2026-09-22
--
-- Until now a spoilt return was recorded on the RNA record and nowhere
-- else: correct, but it meant the only way to answer "how much have we
-- written off" was to read every return. Write-offs now accumulate in a
-- location of their own, so the Stock tab answers it at a glance.
--
-- WHY A LOCATION RATHER THAN A COLUMN
--   Everything the shop already knows how to do with stock — list it,
--   search it, export it, move it back out — works on a warehouse without
--   another screen being written. A damaged unit is still a physical thing
--   sitting somewhere; SPOILT is where.
--
-- WHAT IT IS NOT
--   Not sellable. Invoices deduct from STORE STOCK alone, so nothing here
--   can be invoiced by accident. The form does not offer SPOILT as a
--   destination either — stock arrives here only by being marked spoilt on
--   a return. It CAN be moved out, which is how a repaired unit goes back
--   into circulation, or a disposal is recorded as leaving.
--
-- Units land in transfer_in, leaving opening_stock at 0: nothing here was
-- ever counted onto a shelf, it arrived by being written off.
--
-- Requires 20260922_returns_and_staff_id.sql. Idempotent.
-- ─────────────────────────────────────────────────────────────

-- ── 0. Refuse to run out of order ─────────────────────────────
-- Without the returns migration there is no `condition` column, no
-- 'return' kind and no staff-id functions, and this file fails partway
-- through with "column i.condition does not exist" — which says nothing
-- about what to do next.
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name   = 'stock_transfer_items'
       and column_name  = 'condition'
  ) then
    raise exception
      'Run 20260922_returns_and_staff_id.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1. The location ───────────────────────────────────────────
-- Red, and no date columns: spoilt goods are not counted on a day sheet.
insert into public.warehouses (name, color, date_columns, section_labels)
select 'SPOILT', '#ef4444', '{}', '{}'
 where not exists (select 1 from public.warehouses where name = 'SPOILT');

-- ── 2. Returns file spoilt lines there ────────────────────────
-- Dropped rather than overloaded: a variant differing only by a trailing
-- argument would make every existing call ambiguous.
drop function if exists public.return_stock(text, jsonb, text, text, timestamptz);

create or replace function public.return_stock(
  p_to       text,
  p_items    jsonb,
  p_customer text default null,
  p_note     text default null,
  p_when     timestamptz default now(),
  p_spoilt   text default 'SPOILT'
) returns public.stock_transfers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rec   public.stock_transfers;
  v_item  jsonb;
  v_model text;
  v_qty   integer;
  v_cond  text;
  v_dest  text;
  v_pos   integer := 0;
  v_try   integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record returns';
  end if;
  if p_to is null or btrim(p_to) = '' then
    raise exception 'Where are the good items going back to?';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A return needs at least one item';
  end if;

  for v_try in 1..8 loop
    begin
      insert into public.stock_transfers
        (transfer_number, kind, from_warehouse, to_warehouse, supplier,
         note, signed_by, staff_id, transferred_at, created_by)
      values
        (public.next_movement_number('return'), 'return', null, p_to,
         nullif(btrim(coalesce(p_customer, '')), ''),
         nullif(btrim(coalesce(p_note, '')), ''),
         public.current_staff_name(), public.current_staff_id(),
         coalesce(p_when, now()), auth.uid())
      returning * into v_rec;
      exit;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    -- Anything not explicitly marked spoilt is treated as resaleable, which
    -- matches how the form is filled in: the tick is on the exception.
    v_cond  := case when lower(coalesce(v_item->>'condition', 'good')) = 'spoilt'
                    then 'spoilt' else 'good' end;
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    -- A good line goes back on the shelf; a spoilt one goes to the
    -- write-off pile. Either way the units land somewhere countable, so a
    -- return never ends as a quantity that vanished.
    v_dest := case when v_cond = 'spoilt' then p_spoilt else p_to end;

    update public.warehouse_stock
       set transfer_in = coalesce(transfer_in, 0) + v_qty
     where warehouse = v_dest and model = v_model;

    if not found then
      insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, transfer_in)
      values (v_dest, v_model, 0, '{}'::jsonb, v_qty);
    end if;

    v_pos := v_pos + 1;
    insert into public.stock_transfer_items
      (transfer_id, model, quantity, from_before, position, condition)
    values (v_rec.id, v_model, v_qty, null, v_pos, v_cond);
  end loop;

  return v_rec;
end $$;

grant execute on function public.return_stock(text, jsonb, text, text, timestamptz, text) to authenticated;

-- ── 3. Back-fill anything already written off ─────────────────
-- Spoilt lines recorded before this migration restocked nothing anywhere,
-- so the pile would start empty and understate the true total. Computed as
-- an absolute figure from the return records rather than added to, so it is
-- safe to run again and cannot double anything.
insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, transfer_in)
select 'SPOILT', x.model, 0, '{}'::jsonb, x.units
  from (
    select i.model, sum(i.quantity)::integer as units
      from public.stock_transfer_items i
      join public.stock_transfers t on t.id = i.transfer_id
     where t.kind = 'return' and i.condition = 'spoilt'
     group by i.model
  ) x
 where not exists (
         select 1 from public.warehouse_stock s
          where s.warehouse = 'SPOILT' and s.model = x.model
       );

update public.warehouse_stock s
   set transfer_in = x.units
  from (
    select i.model, sum(i.quantity)::integer as units
      from public.stock_transfer_items i
      join public.stock_transfers t on t.id = i.transfer_id
     where t.kind = 'return' and i.condition = 'spoilt'
     group by i.model
  ) x
 where s.warehouse = 'SPOILT'
   and s.model = x.model
   and s.transfer_in is distinct from x.units;

-- ── Verification ──────────────────────────────────────────────
-- What has been written off, worst first:
--
-- select model, closing_stock as spoilt
--   from public.warehouse_stock
--  where warehouse = 'SPOILT' and closing_stock > 0
--  order by spoilt desc;
--
-- Total written off, against what it would have sold for:
--
-- select sum(s.closing_stock)                                        as units,
--        sum(s.closing_stock * coalesce(public.price_for_model(s.model), 0)) as at_list_price
--   from public.warehouse_stock s
--  where s.warehouse = 'SPOILT' and s.closing_stock > 0;
