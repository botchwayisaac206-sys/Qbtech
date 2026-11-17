-- ─────────────────────────────────────────────────────────────
-- A movement never opens a second row for a product the destination
-- already stocks — 2026-10-05
--
-- THE HOLE
--   Every movement booked stock in with `where warehouse = … and model = …`,
--   an exact match on the name. FISHPONG-1 calls a camera
--   "DS-2CE16D0T-LPFS 2MP bullet"; STORE STOCK has it as
--   "ds-2ce16d0t lpfs 2MP BULLET". Move five across and the exact match
--   finds nothing, so a SECOND row is created in STORE STOCK. Now the store
--   lists one camera twice, invoices come off one row, transfers land on the
--   other, and neither is the count.
--
-- THE RULE NOW
--   Two names are the same product when they are identical once capitals,
--   spaces and punctuation are ignored — stock_model_key(). Booking stock in
--   looks for the destination's row in this order:
--
--     1. the exact name
--     2. the same code under another spelling  → the units join THAT row,
--        and it keeps its own spelling
--     3. neither → a row is created, spelled the way the rest of the line
--        already spells it if any location stocks it, so a new location
--        does not introduce a new spelling either
--
--   The same applies to finding the SOURCE row, to deliveries, to returns
--   and to moves between the main shop and Dahua.
--
-- WHAT IS DELIBERATELY NOT AUTOMATIC
--   "EAP225" and "EAP225 Wireless ceiling mount" are probably one product,
--   but a bare code is sometimes a different pack or lens. The database does
--   not guess. The app shows staff the similar name and they choose; their
--   choice arrives here as `to_model` on the item:
--
--     [{"model": "EAP225", "quantity": 4, "to_model": "EAP225 Wireless ceiling mount"}]
--
--   and the units join that row. Where the two names differ, both are kept
--   on the movement record (model / other_model).
--
-- This stops NEW duplicates. Rows already doubled are merged with
-- merge_stock_model() — Transfers → Product names.
--
-- Requires 20261005_cross_line_transfers.sql. Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regprocedure('public.cross_transfer_stock(text, text, text, text, jsonb, text, timestamptz)') is null then
    raise exception 'Run 20261005_cross_line_transfers.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1. What makes two names the same product ──────────────────
create or replace function public.stock_model_key(p_model text)
returns text
language sql immutable parallel safe as $$
  select regexp_replace(upper(coalesce(p_model, '')), '[^A-Z0-9]', '', 'g')
$$;

create index if not exists warehouse_stock_warehouse_key_idx
  on public.warehouse_stock (warehouse, public.stock_model_key(model));
create index if not exists dahua_stock_warehouse_key_idx
  on public.dahua_stock (warehouse, public.stock_model_key(model));

-- ── 2. Finding a location's row for a product ─────────────────
-- The exact name first, then the same code under another spelling; the
-- oldest row where a location already holds it twice.
create or replace function public.stock_find_row(p_warehouse text, p_model text)
returns uuid
language sql stable security definer set search_path = public as $$
  select s.id
    from public.warehouse_stock s
   where s.warehouse = p_warehouse
     and (s.model = p_model
          or (public.stock_model_key(p_model) <> ''
              and public.stock_model_key(s.model) = public.stock_model_key(p_model)))
   order by (s.model = p_model) desc, s.created_at, s.id::text
   limit 1
$$;

create or replace function public.dahua_stock_find_row(p_warehouse text, p_model text)
returns uuid
language sql stable security definer set search_path = public as $$
  select s.id
    from public.dahua_stock s
   where s.warehouse = p_warehouse
     and (s.model = p_model
          or (public.stock_model_key(p_model) <> ''
              and public.stock_model_key(s.model) = public.stock_model_key(p_model)))
   order by (s.model = p_model) desc, s.created_at, s.id::text
   limit 1
$$;

-- ── 3. Booking units in ───────────────────────────────────────
-- Returns the name the units were booked under, which is the row's own
-- spelling and may not be the one asked for.
create or replace function public.stock_book_in(p_warehouse text, p_model text, p_qty integer)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_id   uuid;
  v_name text;
begin
  v_id := public.stock_find_row(p_warehouse, p_model);
  if v_id is not null then
    update public.warehouse_stock
       set transfer_in = coalesce(transfer_in, 0) + p_qty
     where id = v_id
    returning model into v_name;
    return v_name;
  end if;

  -- New to this location. If another location already stocks it, take that
  -- spelling rather than starting a new one.
  select s.model into v_name
    from public.warehouse_stock s
   where public.stock_model_key(p_model) <> ''
     and public.stock_model_key(s.model) = public.stock_model_key(p_model)
   order by (s.model = p_model) desc, s.created_at, s.id::text
   limit 1;
  v_name := coalesce(v_name, p_model);

  insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, transfer_in)
  values (p_warehouse, v_name, 0, '{}'::jsonb, p_qty);
  return v_name;
end $$;

create or replace function public.dahua_stock_book_in_as(p_warehouse text, p_model text, p_qty integer)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_id    uuid;
  v_name  text;
  v_price numeric(12,2);
begin
  v_id := public.dahua_stock_find_row(p_warehouse, p_model);
  if v_id is not null then
    update public.dahua_stock
       set transfer_in = coalesce(transfer_in, 0) + p_qty
     where id = v_id
    returning model into v_name;
    return v_name;
  end if;

  select s.model into v_name
    from public.dahua_stock s
   where public.stock_model_key(p_model) <> ''
     and public.stock_model_key(s.model) = public.stock_model_key(p_model)
   order by (s.model = p_model) desc, s.created_at, s.id::text
   limit 1;
  v_name := coalesce(v_name, p_model);

  -- At the model's existing price, so stock moved into a new warehouse does
  -- not show up on an invoice as "no price".
  select max(s.unit_price) into v_price
    from public.dahua_stock s
   where public.stock_model_key(s.model) = public.stock_model_key(v_name);

  insert into public.dahua_stock (warehouse, model, opening_stock, daily_taken, invoice_taken, transfer_in, unit_price)
  values (p_warehouse, v_name, 0, '{}'::jsonb, 0, p_qty, coalesce(v_price, 0));
  return v_name;
end $$;

-- The original, which dahua_receive_stock and dahua_return_stock call. Same
-- name and signature, so those two pick up the new matching without being
-- rewritten.
create or replace function public.dahua_stock_book_in(p_warehouse text, p_model text, p_qty integer)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.dahua_stock_book_in_as(p_warehouse, p_model, p_qty);
end $$;

-- The header every main-shop movement opens with — the twin of
-- dahua_movement_open(). Retries on a number clash: the number counts rows,
-- so two staff saving at once can both be handed the same one.
create or replace function public.stock_movement_open(
  p_kind text, p_from text, p_to text, p_party text, p_note text, p_when timestamptz
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_rec public.stock_transfers;
  v_try integer;
begin
  for v_try in 1..8 loop
    begin
      insert into public.stock_transfers
        (transfer_number, kind, from_warehouse, to_warehouse, supplier,
         note, signed_by, staff_id, transferred_at, created_by)
      values
        (public.next_movement_number(p_kind), p_kind, p_from, p_to,
         nullif(btrim(coalesce(p_party, '')), ''),
         nullif(btrim(coalesce(p_note, '')), ''),
         public.current_staff_name(), public.current_staff_id(),
         coalesce(p_when, now()), auth.uid())
      returning * into v_rec;
      return v_rec;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;
end $$;

-- Internal: reachable only through the movement functions below.
revoke all on function public.stock_find_row(text, text)                 from public, anon, authenticated;
revoke all on function public.dahua_stock_find_row(text, text)           from public, anon, authenticated;
revoke all on function public.stock_book_in(text, text, integer)         from public, anon, authenticated;
revoke all on function public.dahua_stock_book_in_as(text, text, integer) from public, anon, authenticated;
revoke all on function public.dahua_stock_book_in(text, text, integer)   from public, anon, authenticated;
revoke all on function public.stock_movement_open(text, text, text, text, text, timestamptz) from public, anon, authenticated;

-- ── 4. Main shop: move ────────────────────────────────────────
-- p_items: [{"model": "...", "quantity": 5, "to_model": "optional"}, ...]
create or replace function public.transfer_stock(
  p_from  text,
  p_to    text,
  p_items jsonb,
  p_note  text default null,
  p_when  timestamptz default now()
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_rec       public.stock_transfers;
  v_item      jsonb;
  v_model     text;
  v_as        text;
  v_qty       integer;
  v_src_id    uuid;
  v_src_model text;
  v_dst_model text;
  v_before    integer;
  v_pos       integer := 0;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to transfer stock';
  end if;
  if p_from is null or p_to is null or p_from = p_to then
    raise exception 'A transfer needs two different locations';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A transfer needs at least one item';
  end if;

  v_rec := public.stock_movement_open('move', p_from, p_to, null, p_note, p_when);

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(coalesce(v_item->>'model', ''));
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    v_as    := coalesce(nullif(btrim(coalesce(v_item->>'to_model', '')), ''), v_model);
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    v_src_id := public.stock_find_row(p_from, v_model);
    if v_src_id is null then
      raise exception '% does not hold %', p_from, v_model;
    end if;
    -- Locked so two staff moving the same model at once cannot both read
    -- the same "before" figure.
    select s.model, s.closing_stock into v_src_model, v_before
      from public.warehouse_stock s where s.id = v_src_id for update;

    update public.warehouse_stock
       set transfer_out = coalesce(transfer_out, 0) + v_qty
     where id = v_src_id;

    v_dst_model := public.stock_book_in(p_to, v_as, v_qty);

    v_pos := v_pos + 1;
    insert into public.stock_transfer_items (transfer_id, model, quantity, from_before, position, other_model)
    values (v_rec.id, v_src_model, v_qty, v_before, v_pos, nullif(v_dst_model, v_src_model));
  end loop;

  return v_rec;
end $$;

-- ── 5. Main shop: receive ─────────────────────────────────────
create or replace function public.receive_stock(
  p_to       text,
  p_items    jsonb,
  p_supplier text default null,
  p_note     text default null,
  p_when     timestamptz default now()
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_rec   public.stock_transfers;
  v_item  jsonb;
  v_model text;
  v_qty   integer;
  v_pos   integer := 0;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to receive stock';
  end if;
  if p_to is null or btrim(p_to) = '' then
    raise exception 'Where is this delivery going?';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A delivery needs at least one item';
  end if;

  v_rec := public.stock_movement_open('receive', null, p_to, p_supplier, p_note, p_when);

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(coalesce(v_item->>'model', ''));
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    -- Recorded under the name it was booked in as, not the name typed.
    v_model := public.stock_book_in(p_to, v_model, v_qty);

    v_pos := v_pos + 1;
    insert into public.stock_transfer_items (transfer_id, model, quantity, from_before, position)
    values (v_rec.id, v_model, v_qty, null, v_pos);
  end loop;

  return v_rec;
end $$;

-- ── 6. Main shop: return ──────────────────────────────────────
create or replace function public.return_stock(
  p_to       text,
  p_items    jsonb,
  p_customer text default null,
  p_note     text default null,
  p_when     timestamptz default now(),
  p_spoilt   text default 'SPOILT'
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_rec   public.stock_transfers;
  v_item  jsonb;
  v_model text;
  v_qty   integer;
  v_cond  text;
  v_pos   integer := 0;
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

  v_rec := public.stock_movement_open('return', null, p_to, p_customer, p_note, p_when);

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(coalesce(v_item->>'model', ''));
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    -- The tick is on the exception: anything not marked spoilt is resaleable.
    v_cond  := case when lower(coalesce(v_item->>'condition', 'good')) = 'spoilt'
                    then 'spoilt' else 'good' end;
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    v_model := public.stock_book_in(
      case when v_cond = 'spoilt' then p_spoilt else p_to end, v_model, v_qty);

    v_pos := v_pos + 1;
    insert into public.stock_transfer_items
      (transfer_id, model, quantity, from_before, position, condition)
    values (v_rec.id, v_model, v_qty, null, v_pos, v_cond);
  end loop;

  return v_rec;
end $$;

-- ── 7. Dahua: move ────────────────────────────────────────────
create or replace function public.dahua_transfer_stock(
  p_from  text,
  p_to    text,
  p_items jsonb,
  p_note  text default null,
  p_when  timestamptz default now()
) returns public.dahua_stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_rec       public.dahua_stock_transfers;
  v_item      jsonb;
  v_model     text;
  v_as        text;
  v_qty       integer;
  v_src_id    uuid;
  v_src_model text;
  v_dst_model text;
  v_before    integer;
  v_pos       integer := 0;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to transfer stock';
  end if;
  if p_from is null or p_to is null or p_from = p_to then
    raise exception 'A transfer needs two different locations';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A transfer needs at least one item';
  end if;

  v_rec := public.dahua_movement_open('move', p_from, p_to, null, p_note, p_when);

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(coalesce(v_item->>'model', ''));
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    v_as    := coalesce(nullif(btrim(coalesce(v_item->>'to_model', '')), ''), v_model);
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    v_src_id := public.dahua_stock_find_row(p_from, v_model);
    if v_src_id is null then
      raise exception '% does not hold %', p_from, v_model;
    end if;
    select s.model, s.closing_stock into v_src_model, v_before
      from public.dahua_stock s where s.id = v_src_id for update;

    update public.dahua_stock
       set transfer_out = coalesce(transfer_out, 0) + v_qty
     where id = v_src_id;

    v_dst_model := public.dahua_stock_book_in_as(p_to, v_as, v_qty);

    v_pos := v_pos + 1;
    insert into public.dahua_stock_transfer_items (transfer_id, model, quantity, from_before, position, other_model)
    values (v_rec.id, v_src_model, v_qty, v_before, v_pos, nullif(v_dst_model, v_src_model));
  end loop;

  return v_rec;
end $$;

-- ── 8. Between the main shop and Dahua ────────────────────────
create or replace function public.cross_transfer_stock(
  p_from_line text,
  p_from      text,
  p_to_line   text,
  p_to        text,
  p_items     jsonb,
  p_note      text default null,
  p_when      timestamptz default now()
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_main        public.stock_transfers;
  v_dahua_id    uuid;
  v_yr          text := to_char(now(), 'YYYY');
  v_number      text;
  v_note        text := nullif(btrim(coalesce(p_note, '')), '');
  v_item        jsonb;
  v_typed       text;
  v_as          text;
  v_qty         integer;
  v_src_id      uuid;
  v_src_model   text;
  v_before      integer;
  v_dst_model   text;
  v_main_model  text;
  v_dahua_model text;
  v_pos         integer := 0;
  v_try         integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to transfer stock';
  end if;
  if p_from_line is null or p_to_line is null
     or p_from_line not in ('main', 'dahua') or p_to_line not in ('main', 'dahua')
     or p_from_line = p_to_line then
    raise exception 'This is for moves between the main shop and Dahua';
  end if;
  if p_from is null or p_to is null then
    raise exception 'A transfer needs two locations';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'A transfer needs at least one item';
  end if;
  if upper(btrim(p_to)) = 'SPOILT' then
    raise exception 'SPOILT is filled by returns only';
  end if;

  if p_from_line = 'main' then
    if not exists (select 1 from public.warehouses where name = p_from) then
      raise exception 'The main shop has no location called %', p_from;
    end if;
    if not exists (select 1 from public.dahua_warehouses where name = p_to) then
      raise exception 'Dahua has no warehouse called %', p_to;
    end if;
  else
    if not exists (select 1 from public.dahua_warehouses where name = p_from) then
      raise exception 'Dahua has no warehouse called %', p_from;
    end if;
    if not exists (select 1 from public.warehouses where name = p_to) then
      raise exception 'The main shop has no location called %', p_to;
    end if;
  end if;

  for v_try in 1..8 loop
    begin
      select 'XTR-' || v_yr || '-' || lpad((count(*) + 1)::text, 4, '0') into v_number
        from public.stock_transfers
       where transfer_number like 'XTR-' || v_yr || '-%';

      insert into public.stock_transfers
        (transfer_number, kind, from_warehouse, to_warehouse, from_line, to_line,
         note, signed_by, staff_id, transferred_at, created_by)
      values
        (v_number, 'move', p_from, p_to, p_from_line, p_to_line,
         v_note, public.current_staff_name(), public.current_staff_id(),
         coalesce(p_when, now()), auth.uid())
      returning * into v_main;
      exit;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;

  insert into public.dahua_stock_transfers
    (transfer_number, kind, from_warehouse, to_warehouse, from_line, to_line,
     note, signed_by, staff_id, transferred_at, created_by)
  values
    (v_main.transfer_number, 'move', p_from, p_to, p_from_line, p_to_line,
     v_note, v_main.signed_by, v_main.staff_id, v_main.transferred_at, auth.uid())
  returning id into v_dahua_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_typed := btrim(coalesce(v_item->>'model', ''));
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    v_as    := coalesce(nullif(btrim(coalesce(v_item->>'to_model', '')), ''), v_typed);
    if v_typed = '' or v_qty <= 0 then
      continue;
    end if;

    if p_from_line = 'main' then
      v_src_id := public.stock_find_row(p_from, v_typed);
      if v_src_id is null then
        raise exception '% does not hold %', p_from, v_typed;
      end if;
      select s.model, s.closing_stock into v_src_model, v_before
        from public.warehouse_stock s where s.id = v_src_id for update;
      update public.warehouse_stock
         set transfer_out = coalesce(transfer_out, 0) + v_qty
       where id = v_src_id;

      v_dst_model := public.dahua_stock_book_in_as(p_to, v_as, v_qty);
      v_main_model := v_src_model;  v_dahua_model := v_dst_model;
    else
      v_src_id := public.dahua_stock_find_row(p_from, v_typed);
      if v_src_id is null then
        raise exception '% (Dahua) does not hold %', p_from, v_typed;
      end if;
      select s.model, s.closing_stock into v_src_model, v_before
        from public.dahua_stock s where s.id = v_src_id for update;
      update public.dahua_stock
         set transfer_out = coalesce(transfer_out, 0) + v_qty
       where id = v_src_id;

      v_dst_model := public.stock_book_in(p_to, v_as, v_qty);
      v_main_model := v_dst_model;  v_dahua_model := v_src_model;
    end if;

    v_pos := v_pos + 1;
    insert into public.stock_transfer_items
      (transfer_id, model, quantity, from_before, position, other_model)
    values
      (v_main.id, v_main_model, v_qty,
       case when p_from_line = 'main' then v_before end, v_pos,
       nullif(v_dahua_model, v_main_model));
    insert into public.dahua_stock_transfer_items
      (transfer_id, model, quantity, from_before, position, other_model)
    values
      (v_dahua_id, v_dahua_model, v_qty,
       case when p_from_line = 'dahua' then v_before end, v_pos,
       nullif(v_main_model, v_dahua_model));
  end loop;

  if v_pos = 0 then
    raise exception 'A transfer needs at least one item';
  end if;

  return v_main;
end $$;

-- ── Verification (run after the statements above) ─────────────
-- Locations that ALREADY list one product twice. This file stops new ones;
-- these are cleared with Transfers → Product names:
--
-- select warehouse, public.stock_model_key(model) as code,
--        array_agg(model order by created_at) as spellings, sum(closing_stock) as units
--   from public.warehouse_stock
--  group by 1, 2
-- having count(*) > 1
--  order by 1, 2;
