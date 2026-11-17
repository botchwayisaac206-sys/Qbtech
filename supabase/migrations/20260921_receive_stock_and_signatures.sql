-- ─────────────────────────────────────────────────────────────
-- Receiving stock from outside, and signing for it — 2026-09-21
--
-- Until now the only way units could enter the system was a physical count
-- written into opening_stock by a migration. Anything a supplier delivered
-- had to be back-filled by hand, so the moment a delivery arrived the
-- figures were wrong and stayed wrong until someone noticed.
--
-- Receiving is NOT a transfer: nothing is deducted from anywhere, stock
-- enters. It shares the transfer record anyway, because "where did this
-- stock come from" should have one answer in one list rather than two
-- screens to cross-reference. `kind` tells the two apart:
--
--   move     warehouse -> warehouse. Source goes down, destination goes up.
--   receive  outside -> warehouse. Destination goes up, nothing goes down.
--            from_warehouse is null, and `supplier` says who brought it.
--
-- SIGNATURES
--   Both kinds can carry a signature drawn on screen, stored as a PNG data
--   URL. The staff member's name is copied onto the record at the time of
--   signing rather than read back through created_by: a name resolved later
--   would follow a renamed or deleted staff row, and the point of a
--   signature is what was true when it was signed.
--
-- Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────

-- ── 1. Columns ────────────────────────────────────────────────
alter table public.stock_transfers
  add column if not exists kind      text not null default 'move',
  add column if not exists supplier  text,
  add column if not exists signature text,
  add column if not exists signed_by text;

comment on column public.stock_transfers.kind is
  'move = between two locations; receive = in from outside (from_warehouse null).';
comment on column public.stock_transfers.signature is
  'PNG data URL of a signature drawn on screen. Null when unsigned.';
comment on column public.stock_transfers.signed_by is
  'Who signed, copied in at the time — not resolved from created_by later.';

-- A receive has no source, so the column can no longer be mandatory.
alter table public.stock_transfers alter column from_warehouse drop not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'stock_transfers_kind_check') then
    alter table public.stock_transfers
      add constraint stock_transfers_kind_check check (kind in ('move', 'receive'));
  end if;
  -- A receive names no source; a move must name one.
  if not exists (select 1 from pg_constraint where conname = 'stock_transfers_source_check') then
    alter table public.stock_transfers
      add constraint stock_transfers_source_check check (
        (kind = 'receive' and from_warehouse is null)
        or (kind = 'move' and from_warehouse is not null)
      );
  end if;
  -- A drawn signature is a few tens of KB; anything far larger is a bug or
  -- an attempt to use this column as file storage.
  if not exists (select 1 from pg_constraint where conname = 'stock_transfers_signature_len') then
    alter table public.stock_transfers
      add constraint stock_transfers_signature_len check (
        signature is null or length(signature) <= 200000
      );
  end if;
end $$;

create index if not exists stock_transfers_kind_idx on public.stock_transfers (kind, transferred_at desc);

-- ── 2. Numbering ──────────────────────────────────────────────
-- Receipts get their own RCV series so a delivery note and an internal move
-- can never be confused for one another in conversation.
create or replace function public.next_movement_number(p_kind text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  yr     text := to_char(now(), 'YYYY');
  prefix text := case when p_kind = 'receive' then 'RCV' else 'TRF' end;
  cnt    integer;
begin
  select count(*) + 1 into cnt
    from public.stock_transfers
   where to_char(transferred_at, 'YYYY') = yr
     and kind = p_kind;
  return prefix || '-' || yr || '-' || lpad(cnt::text, 4, '0');
end $$;

-- ── 3. Who is signing ─────────────────────────────────────────
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

-- ── 4. Receiving ──────────────────────────────────────────────
-- p_items: [{"model": "DS-7208HGHI-M1", "quantity": 5}, ...]
--
-- A model the destination has never carried is created there, because that
-- is the ordinary case for a delivery — new stock arrives before anyone has
-- set up a row for it. Units land in transfer_in, leaving opening_stock as
-- what the last physical count actually found.
create or replace function public.receive_stock(
  p_to        text,
  p_items     jsonb,
  p_supplier  text default null,
  p_note      text default null,
  p_signature text default null,
  p_when      timestamptz default now()
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

  -- next_movement_number() counts rows, so two staff receiving at the same
  -- moment can both be handed RCV-2026-0007. The unique constraint catches
  -- it; retrying picks up the number the winner did not take.
  for v_try in 1..8 loop
    begin
      insert into public.stock_transfers
        (transfer_number, kind, from_warehouse, to_warehouse, supplier,
         note, signature, signed_by, transferred_at, created_by)
      values
        (public.next_movement_number('receive'), 'receive', null, p_to,
         nullif(btrim(coalesce(p_supplier, '')), ''),
         nullif(btrim(coalesce(p_note, '')), ''),
         nullif(btrim(coalesce(p_signature, '')), ''),
         public.current_staff_name(),
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
    -- from_before is null: there is no source to have held anything.
    insert into public.stock_transfer_items (transfer_id, model, quantity, from_before, position)
    values (v_rec.id, v_model, v_qty, null, v_pos);
  end loop;

  return v_rec;
end $$;

-- ── 5. Moves can be signed too ────────────────────────────────
-- Dropped rather than overloaded: two transfer_stock functions differing
-- only by a trailing argument would make every existing call ambiguous.
drop function if exists public.transfer_stock(text, text, jsonb, text, timestamptz);

create or replace function public.transfer_stock(
  p_from      text,
  p_to        text,
  p_items     jsonb,
  p_note      text default null,
  p_when      timestamptz default now(),
  p_signature text default null
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

  for v_try in 1..8 loop
    begin
      insert into public.stock_transfers
        (transfer_number, kind, from_warehouse, to_warehouse,
         note, signature, signed_by, transferred_at, created_by)
      values
        (public.next_movement_number('move'), 'move', p_from, p_to,
         nullif(btrim(coalesce(p_note, '')), ''),
         nullif(btrim(coalesce(p_signature, '')), ''),
         public.current_staff_name(),
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

grant execute on function public.receive_stock(text, jsonb, text, text, text, timestamptz) to authenticated;
grant execute on function public.transfer_stock(text, text, jsonb, text, timestamptz, text) to authenticated;
grant execute on function public.next_movement_number(text) to authenticated;
grant execute on function public.current_staff_name() to authenticated;

-- ── Verification ──────────────────────────────────────────────
-- Everything received from outside, newest first:
--
-- select transfer_number, to_warehouse, supplier, signed_by, transferred_at,
--        (signature is not null) as signed
--   from public.stock_transfers where kind = 'receive'
--  order by transferred_at desc;
--
-- What a given delivery brought in:
--
-- select i.model, i.quantity
--   from public.stock_transfer_items i
--   join public.stock_transfers t on t.id = i.transfer_id
--  where t.transfer_number = 'RCV-2026-0001'
--  order by i.position;
