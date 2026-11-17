-- ─────────────────────────────────────────────────────────────
-- Moves between the main shop and Dahua, and phone-safe saving — 2026-10-05
--
-- TWO THINGS
--
-- 1. CROSS-LINE MOVES
--    The main shop (warehouse_stock) and Dahua (dahua_stock) have been two
--    sealed pools. Goods do physically cross between them, and until now the
--    only way to show it was to edit a count on each side by hand — two
--    edits, nothing tying them together, and no record of why either figure
--    changed. cross_transfer_stock() does both sides in one transaction.
--
--    It is recorded ONCE PER SIDE under ONE number, in a series of its own:
--    XTR-2026-0001 appears in the main shop's movement history and in
--    Dahua's, so each portal can account for its own figure and the two
--    records can be matched by reference.
--
--    The two sides do not always call a product the same thing. Each item
--    may carry a `to_model` — the name it takes at the destination. Left
--    out, the destination is searched for the same name ignoring case and
--    spacing, and that row's own spelling is used, so a cross move never
--    opens a second row for something the other side already stocks.
--
-- 2. ONE SAVE PER TAP, FROM A PHONE
--    A phone in a warehouse loses signal mid-save. The app cannot tell
--    "the request never arrived" from "it arrived and the reply was lost",
--    and retrying the second case moves the stock twice. That is a count
--    going wrong with nobody having done anything wrong.
--
--    record_stock_movement() takes a request ID made up by the phone. The
--    first call with an ID does the movement; any later call with the same
--    ID does nothing and returns the first call's record. The phone can
--    therefore retry until it gets an answer.
--
-- Nothing that exists is changed in behaviour: transfer_stock, receive_stock,
-- return_stock and their dahua_ twins are called as they are.
--
-- Requires 20260922_spoilt_location.sql and 20260930_dahua_transfers.sql.
-- Run once, in the Supabase SQL editor. Idempotent.
-- ─────────────────────────────────────────────────────────────

-- ── 0. Refuse to run out of order ─────────────────────────────
do $$
begin
  if to_regclass('public.dahua_stock_transfers') is null then
    raise exception 'Run 20260930_dahua_transfers.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
  if to_regprocedure('public.return_stock(text, jsonb, text, text, timestamptz, text)') is null then
    raise exception 'Run 20260922_spoilt_location.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1. Which line each end of a movement is on ────────────────
-- Both null on every ordinary movement: it happened inside the table's own
-- line. Both set on a cross move, and then they always differ.
alter table public.stock_transfers
  add column if not exists from_line text,
  add column if not exists to_line   text;
alter table public.dahua_stock_transfers
  add column if not exists from_line text,
  add column if not exists to_line   text;

alter table public.stock_transfers drop constraint if exists stock_transfers_lines_check;
alter table public.stock_transfers
  add constraint stock_transfers_lines_check check (
    (from_line is null and to_line is null)
    or (from_line in ('main', 'dahua') and to_line in ('main', 'dahua') and from_line <> to_line)
  );
alter table public.dahua_stock_transfers drop constraint if exists dahua_stock_transfers_lines_check;
alter table public.dahua_stock_transfers
  add constraint dahua_stock_transfers_lines_check check (
    (from_line is null and to_line is null)
    or (from_line in ('main', 'dahua') and to_line in ('main', 'dahua') and from_line <> to_line)
  );

-- Both lines have a SPOILT, and nothing stops them sharing other names, so
-- "two different locations" can no longer be judged on the name alone.
alter table public.stock_transfers drop constraint if exists stock_transfers_distinct_ends;
alter table public.stock_transfers
  add constraint stock_transfers_distinct_ends check (
    from_warehouse <> to_warehouse or from_line is not null
  );

alter table public.dahua_stock_transfers drop constraint if exists dahua_stock_transfers_source_check;
alter table public.dahua_stock_transfers
  add constraint dahua_stock_transfers_source_check check (
    (kind = 'move' and from_warehouse is not null
       and (from_warehouse <> to_warehouse or from_line is not null))
    or (kind in ('receive', 'return') and from_warehouse is null)
  );

-- What the other side calls the item, when it is not the same name.
alter table public.stock_transfer_items       add column if not exists other_model text;
alter table public.dahua_stock_transfer_items add column if not exists other_model text;

-- ── 2. Keep TRF / DH-TRF numbering free of gaps ───────────────
-- A cross move is a 'move' row in both tables, so the row counts these
-- functions number from would otherwise skip one for every XTR — and a
-- missing TRF number reads as a deleted transfer.
create or replace function public.next_movement_number(p_kind text)
returns text
language plpgsql security definer set search_path = public as $$
declare
  yr     text := to_char(now(), 'YYYY');
  prefix text := case p_kind when 'receive' then 'RCV'
                             when 'return'  then 'RNA'
                             else 'TRF' end;
  cnt    integer;
begin
  select count(*) + 1 into cnt
    from public.stock_transfers
   where to_char(transferred_at, 'YYYY') = yr
     and kind = p_kind
     and from_line is null;
  return prefix || '-' || yr || '-' || lpad(cnt::text, 4, '0');
end $$;

create or replace function public.next_dahua_movement_number(p_kind text)
returns text
language plpgsql security definer set search_path = public as $$
declare
  yr     text := to_char(now(), 'YYYY');
  prefix text := case p_kind when 'receive' then 'DH-RCV'
                             when 'return'  then 'DH-RNA'
                             else 'DH-TRF' end;
  cnt    integer;
begin
  select count(*) + 1 into cnt
    from public.dahua_stock_transfers
   where to_char(transferred_at, 'YYYY') = yr
     and kind = p_kind
     and from_line is null;
  return prefix || '-' || yr || '-' || lpad(cnt::text, 4, '0');
end $$;

-- ── 3. Moving between the main shop and Dahua ─────────────────
-- p_items: [{"model": "DH-IPC-HFW1239TL1-A-IL 2MP", "quantity": 5,
--            "to_model": "optional — what the destination calls it"}, ...]
--
-- As with an ordinary transfer: a model the source has never held is
-- rejected, one the destination has never held is created there, and a
-- source that holds too few simply goes negative — the shop's rule is that
-- a bad count never blocks the work.
--
-- Returns the main shop's copy of the record.
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
  v_dst_id      uuid;
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

  -- One number for both records, taken from the main table. It counts rows,
  -- so two staff saving at once can be handed the same one; the unique
  -- constraint catches it and the retry takes the next.
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

    -- ── Source: book the units out ──
    -- Matched ignoring case and spacing, oldest row first: the same row the
    -- invoice deduction and the Stock tab would pick.
    if p_from_line = 'main' then
      select s.id, s.model, s.closing_stock into v_src_id, v_src_model, v_before
        from public.warehouse_stock s
       where s.warehouse = p_from and upper(btrim(s.model)) = upper(v_typed)
       order by s.created_at, s.id::text
       limit 1
       for update;
      if not found then
        raise exception '% does not hold %', p_from, v_typed;
      end if;
      update public.warehouse_stock
         set transfer_out = coalesce(transfer_out, 0) + v_qty
       where id = v_src_id;
    else
      select s.id, s.model, s.closing_stock into v_src_id, v_src_model, v_before
        from public.dahua_stock s
       where s.warehouse = p_from and upper(btrim(s.model)) = upper(v_typed)
       order by s.created_at, s.id::text
       limit 1
       for update;
      if not found then
        raise exception '% (Dahua) does not hold %', p_from, v_typed;
      end if;
      update public.dahua_stock
         set transfer_out = coalesce(transfer_out, 0) + v_qty
       where id = v_src_id;
    end if;

    -- ── Destination: book them in ──
    -- If the destination line already stocks this under any capitalisation,
    -- its spelling wins, the destination warehouse's own row first.
    if p_to_line = 'main' then
      select s.model into v_dst_model
        from public.warehouse_stock s
       where upper(btrim(s.model)) = upper(v_as)
       order by (s.warehouse = p_to) desc, s.created_at, s.id::text
       limit 1;
      if not found then
        v_dst_model := v_as;
      end if;

      select s.id into v_dst_id
        from public.warehouse_stock s
       where s.warehouse = p_to and s.model = v_dst_model
       order by s.created_at, s.id::text
       limit 1
       for update;
      if found then
        update public.warehouse_stock
           set transfer_in = coalesce(transfer_in, 0) + v_qty
         where id = v_dst_id;
      else
        insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, transfer_in)
        values (p_to, v_dst_model, 0, '{}'::jsonb, v_qty);
      end if;
    else
      select s.model into v_dst_model
        from public.dahua_stock s
       where upper(btrim(s.model)) = upper(v_as)
       order by (s.warehouse = p_to) desc, s.created_at, s.id::text
       limit 1;
      if not found then
        v_dst_model := v_as;
      end if;
      -- Creates the row at the model's existing Dahua price when needed.
      perform public.dahua_stock_book_in(p_to, v_dst_model, v_qty);
    end if;

    -- ── One line on each side's record, each under its own name ──
    if p_from_line = 'main' then
      v_main_model := v_src_model;  v_dahua_model := v_dst_model;
    else
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

-- ── 4. One save per request ID ────────────────────────────────
create table if not exists public.stock_movement_requests (
  request_id uuid primary key,
  result     jsonb not null default '{}'::jsonb,
  created_by uuid,
  created_at timestamptz not null default now()
);
alter table public.stock_movement_requests enable row level security;
-- No policies: only record_stock_movement() touches it.

-- p_kind 'move' | 'receive' | 'return'. On a receive or a return the line is
-- p_to_line and p_from is ignored. p_party is the supplier or the buyer.
--
-- The request row and the movement are written in the same transaction, so
-- a movement that fails leaves no request behind and can be sent again. A
-- second call with the same ID waits for the first to finish, then returns
-- its record with "duplicate": true.
create or replace function public.record_stock_movement(
  p_request_id uuid,
  p_kind       text,
  p_from_line  text,
  p_from       text,
  p_to_line    text,
  p_to         text,
  p_items      jsonb,
  p_party      text default null,
  p_note       text default null,
  p_when       timestamptz default now()
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_owner  uuid;
  v_result jsonb;
  v_to     text := coalesce(p_to_line, 'main');
  v_from   text := coalesce(p_from_line, v_to);
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record stock movements';
  end if;
  if p_request_id is null then
    raise exception 'A request ID is required';
  end if;
  if v_to not in ('main', 'dahua') or v_from not in ('main', 'dahua') then
    raise exception 'Unknown stock line';
  end if;

  begin
    insert into public.stock_movement_requests (request_id, created_by)
    values (p_request_id, auth.uid());
  exception when unique_violation then
    select created_by, result into v_owner, v_result
      from public.stock_movement_requests where request_id = p_request_id;
    if v_owner is distinct from auth.uid() then
      raise exception 'That request belongs to someone else';
    end if;
    return v_result || jsonb_build_object('duplicate', true);
  end;

  if p_kind = 'move' then
    if v_from <> v_to then
      select to_jsonb(t) into v_result
        from public.cross_transfer_stock(v_from, p_from, v_to, p_to, p_items, p_note, p_when) t;
    elsif v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_transfer_stock(p_from, p_to, p_items, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.transfer_stock(p_from, p_to, p_items, p_note, p_when) t;
    end if;
  elsif p_kind = 'receive' then
    if v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_receive_stock(p_to, p_items, p_party, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.receive_stock(p_to, p_items, p_party, p_note, p_when) t;
    end if;
  elsif p_kind = 'return' then
    if v_to = 'dahua' then
      select to_jsonb(t) into v_result
        from public.dahua_return_stock(p_to, p_items, p_party, p_note, p_when) t;
    else
      select to_jsonb(t) into v_result
        from public.return_stock(p_to, p_items, p_party, p_note, p_when) t;
    end if;
  else
    raise exception 'Unknown kind of movement: %', p_kind;
  end if;

  update public.stock_movement_requests
     set result = v_result
   where request_id = p_request_id;

  return v_result;
end $$;

-- ── 5. Who may call what ──────────────────────────────────────
revoke all on function public.cross_transfer_stock(text, text, text, text, jsonb, text, timestamptz)
  from public, anon;
revoke all on function public.record_stock_movement(uuid, text, text, text, text, text, jsonb, text, text, timestamptz)
  from public, anon;
grant execute on function public.cross_transfer_stock(text, text, text, text, jsonb, text, timestamptz)
  to authenticated;
grant execute on function public.record_stock_movement(uuid, text, text, text, text, text, jsonb, text, text, timestamptz)
  to authenticated;

-- ── Verification (run after the statements above) ─────────────
-- Every cross move, with what each side called the item. Both tables should
-- list the same references:
--
-- select t.transfer_number, t.from_line, t.from_warehouse, t.to_line, t.to_warehouse,
--        t.staff_id, i.quantity, i.model, i.other_model
--   from public.stock_transfer_items i
--   join public.stock_transfers t on t.id = i.transfer_id
--  where t.from_line is not null
--  order by t.transferred_at desc, i.position;
--
-- Neither pool should have drifted from its own arithmetic (expect 0 and 0):
--
-- select (select count(*) from public.warehouse_stock
--          where closing_stock <> opening_stock + transfer_in - total_taken) as main_drifted,
--        (select count(*) from public.dahua_stock
--          where closing_stock <> opening_stock + transfer_in - total_taken) as dahua_drifted;
