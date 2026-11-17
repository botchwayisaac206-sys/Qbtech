-- ─────────────────────────────────────────────────────────────
-- Returns (RNA), and staff ID in place of a drawn signature — 2026-09-22
--
-- Supersedes the signature pad added in
-- 20260921_receive_stock_and_signatures.sql. A drawn squiggle proves less
-- than the login it was drawn under: the staff ID is already unique, it
-- cannot be traced by someone else's hand, and it is what the shop uses to
-- identify people everywhere else. The signature column is dropped.
--
-- RETURNS (RNA)
--   A third kind of movement, alongside moving and receiving. Goods come
--   back from a buyer, and each line is either
--
--     not spoilt  resaleable — the units go back into stock, normally
--                 STORE STOCK, exactly as a delivery would.
--     spoilt      written off. Recorded in full, but NO stock is added:
--                 putting damaged goods back on the shelf as sellable is
--                 how a shop ends up invoicing something it cannot supply.
--
--   Both are logged either way, on the same numbered record, so a return is
--   never a quantity that changed with nothing to explain it.
--
--   Receipts and returns each get their own series — TRF / RCV / RNA — so a
--   delivery note, an internal move and a customer return can never be
--   confused for one another.
--
-- Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────

-- ── 1. Staff ID replaces the signature ────────────────────────
alter table public.stock_transfers
  add column if not exists kind      text not null default 'move',
  add column if not exists supplier  text,
  add column if not exists signed_by text,
  add column if not exists staff_id  text;

alter table public.stock_transfers drop constraint if exists stock_transfers_signature_len;
alter table public.stock_transfers drop column if exists signature;

comment on column public.stock_transfers.staff_id is
  'Login ID of the staff member who recorded this, copied in at the time.';
comment on column public.stock_transfers.signed_by is
  'Their name at the time. Stored alongside the ID so the record still reads '
  'plainly if the staff row is later renamed or removed.';
comment on column public.stock_transfers.supplier is
  'Who the stock came from — the supplier on a receive, the buyer on a return.';

-- ── 2. Returns are a third kind ───────────────────────────────
alter table public.stock_transfers alter column from_warehouse drop not null;
alter table public.stock_transfers drop constraint if exists stock_transfers_kind_check;
alter table public.stock_transfers drop constraint if exists stock_transfers_source_check;

alter table public.stock_transfers
  add constraint stock_transfers_kind_check check (kind in ('move', 'receive', 'return'));

-- Only a move has a source location; a delivery and a return both come
-- from outside the warehouses.
alter table public.stock_transfers
  add constraint stock_transfers_source_check check (
    (kind = 'move' and from_warehouse is not null)
    or (kind in ('receive', 'return') and from_warehouse is null)
  );

-- ── 3. Condition, per returned line ───────────────────────────
-- On a move or a receive every line is simply stock, so 'good' is the
-- default and those paths never set it.
alter table public.stock_transfer_items
  add column if not exists condition text not null default 'good';

alter table public.stock_transfer_items drop constraint if exists stock_transfer_items_condition_check;
alter table public.stock_transfer_items
  add constraint stock_transfer_items_condition_check check (condition in ('good', 'spoilt'));

comment on column public.stock_transfer_items.condition is
  'good = went back into stock; spoilt = written off, recorded but not restocked.';

create index if not exists stock_transfer_items_condition_idx
  on public.stock_transfer_items (condition) where condition = 'spoilt';

-- ── 4. Numbering ──────────────────────────────────────────────
create or replace function public.next_movement_number(p_kind text)
returns text
language plpgsql
security definer
set search_path = public
as $$
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
     and kind = p_kind;
  return prefix || '-' || yr || '-' || lpad(cnt::text, 4, '0');
end $$;

-- ── 5. Who is recording it ────────────────────────────────────
create or replace function public.current_staff_id()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select staff_id from public.user_roles where user_id = auth.uid()
$$;

create or replace function public.current_staff_name()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(nullif(btrim(full_name), ''), role)
    from public.user_roles where user_id = auth.uid()
$$;

-- ── 6. Rebuild the movement functions without p_signature ─────
-- Dropped rather than overloaded: variants differing only by a trailing
-- argument would make every existing call ambiguous.
drop function if exists public.transfer_stock(text, text, jsonb, text, timestamptz);
drop function if exists public.transfer_stock(text, text, jsonb, text, timestamptz, text);
drop function if exists public.receive_stock(text, jsonb, text, text, text, timestamptz);

create or replace function public.transfer_stock(
  p_from  text,
  p_to    text,
  p_items jsonb,
  p_note  text default null,
  p_when  timestamptz default now()
) returns public.stock_transfers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transfer public.stock_transfers;
  v_item     jsonb;
  v_model    text;
  v_qty      integer;
  v_before   integer;
  v_pos      integer := 0;
  v_try      integer;
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

  -- next_movement_number() counts rows, so two staff acting at the same
  -- moment can both be handed the same number. The unique constraint
  -- catches it; retrying picks up the one the winner did not take.
  for v_try in 1..8 loop
    begin
      insert into public.stock_transfers
        (transfer_number, kind, from_warehouse, to_warehouse,
         note, signed_by, staff_id, transferred_at, created_by)
      values
        (public.next_movement_number('move'), 'move', p_from, p_to,
         nullif(btrim(coalesce(p_note, '')), ''),
         public.current_staff_name(), public.current_staff_id(),
         coalesce(p_when, now()), auth.uid())
      returning * into v_transfer;
      exit;
    exception when unique_violation then
      if v_try = 8 then raise; end if;
    end;
  end loop;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    select closing_stock into v_before
      from public.warehouse_stock
     where warehouse = p_from and model = v_model
     for update;
    if not found then
      raise exception '% does not hold %', p_from, v_model;
    end if;

    update public.warehouse_stock
       set transfer_out = coalesce(transfer_out, 0) + v_qty
     where warehouse = p_from and model = v_model;

    update public.warehouse_stock
       set transfer_in = coalesce(transfer_in, 0) + v_qty
     where warehouse = p_to and model = v_model;
    if not found then
      insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, transfer_in)
      values (p_to, v_model, 0, '{}'::jsonb, v_qty);
    end if;

    v_pos := v_pos + 1;
    insert into public.stock_transfer_items (transfer_id, model, quantity, from_before, position)
    values (v_transfer.id, v_model, v_qty, v_before, v_pos);
  end loop;

  return v_transfer;
end $$;

create or replace function public.receive_stock(
  p_to       text,
  p_items    jsonb,
  p_supplier text default null,
  p_note     text default null,
  p_when     timestamptz default now()
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
  v_pos   integer := 0;
  v_try   integer;
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

  for v_try in 1..8 loop
    begin
      insert into public.stock_transfers
        (transfer_number, kind, from_warehouse, to_warehouse, supplier,
         note, signed_by, staff_id, transferred_at, created_by)
      values
        (public.next_movement_number('receive'), 'receive', null, p_to,
         nullif(btrim(coalesce(p_supplier, '')), ''),
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
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    update public.warehouse_stock
       set transfer_in = coalesce(transfer_in, 0) + v_qty
     where warehouse = p_to and model = v_model;

    if not found then
      insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, transfer_in)
      values (p_to, v_model, 0, '{}'::jsonb, v_qty);
    end if;

    v_pos := v_pos + 1;
    insert into public.stock_transfer_items (transfer_id, model, quantity, from_before, position)
    values (v_rec.id, v_model, v_qty, null, v_pos);
  end loop;

  return v_rec;
end $$;

-- ── 7. Returns ────────────────────────────────────────────────
-- p_items: [{"model": "...", "quantity": 2, "condition": "good"|"spoilt"}, ...]
--
-- A 'good' line goes back into stock at p_to. A 'spoilt' line is recorded
-- and nothing is restocked — that is the whole point of asking.
create or replace function public.return_stock(
  p_to       text,
  p_items    jsonb,
  p_customer text default null,
  p_note     text default null,
  p_when     timestamptz default now()
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

    if v_cond = 'good' then
      update public.warehouse_stock
         set transfer_in = coalesce(transfer_in, 0) + v_qty
       where warehouse = p_to and model = v_model;

      if not found then
        insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, transfer_in)
        values (p_to, v_model, 0, '{}'::jsonb, v_qty);
      end if;
    end if;

    v_pos := v_pos + 1;
    insert into public.stock_transfer_items
      (transfer_id, model, quantity, from_before, position, condition)
    values (v_rec.id, v_model, v_qty, null, v_pos, v_cond);
  end loop;

  return v_rec;
end $$;

grant execute on function public.transfer_stock(text, text, jsonb, text, timestamptz)   to authenticated;
grant execute on function public.receive_stock(text, jsonb, text, text, timestamptz)    to authenticated;
grant execute on function public.return_stock(text, jsonb, text, text, timestamptz)     to authenticated;
grant execute on function public.next_movement_number(text) to authenticated;
grant execute on function public.current_staff_id()         to authenticated;
grant execute on function public.current_staff_name()       to authenticated;

-- ── Verification ──────────────────────────────────────────────
-- Everything returned, and whether it went back on the shelf:
--
-- select t.transfer_number, t.transferred_at, t.supplier as returned_by,
--        t.staff_id, i.model, i.quantity, i.condition
--   from public.stock_transfer_items i
--   join public.stock_transfers t on t.id = i.transfer_id
--  where t.kind = 'return'
--  order by t.transferred_at desc, i.position;
--
-- Written off this month, by model:
--
-- select i.model, sum(i.quantity) as spoilt
--   from public.stock_transfer_items i
--   join public.stock_transfers t on t.id = i.transfer_id
--  where t.kind = 'return' and i.condition = 'spoilt'
--    and t.transferred_at >= date_trunc('month', now())
--  group by 1 order by spoilt desc;
