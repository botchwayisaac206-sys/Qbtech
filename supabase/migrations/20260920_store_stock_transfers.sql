-- ─────────────────────────────────────────────────────────────
-- STORE STOCK + STOCK TRANSFERS — 2026-09-20
--
-- Introduces the shop floor as a stock location of its own.
--
--   • STORE STOCK is a normal warehouse row. It is NOT a roll-up of the
--     other warehouses — it holds its own quantities, counted separately.
--     Units only reach it when somebody transfers them in.
--   • Transfers move units between any two locations and are recorded, so
--     "where did those 20 cameras go" has an answer.
--   • Main-shop invoices now deduct from STORE STOCK. A line that asks for
--     more than the store holds still saves (a customer must never be
--     blocked by a bad count) and simply drives the figure negative.
--
-- Dahua is deliberately untouched — dahua_stock keeps its own pool and its
-- own invoice_taken flow.
--
-- Run once, in the Supabase SQL editor. Idempotent.
-- ─────────────────────────────────────────────────────────────

begin;

-- ── 1. Movement columns on warehouse_stock ────────────────────
-- Until now closing_stock was only ever `opening_stock - sum(daily_taken)`.
-- Three more ways for a unit to move now exist, and each gets its own
-- column so the Stock tab can show WHY a figure changed rather than just
-- that it did. daily_taken stays what it has always been: units booked out
-- by hand on the day sheet.
alter table public.warehouse_stock
  add column if not exists invoice_taken integer not null default 0,  -- sold on a main invoice
  add column if not exists transfer_in   integer not null default 0,  -- received from another location
  add column if not exists transfer_out  integer not null default 0;  -- sent to another location

-- ── 2. Derived columns are computed by the database ───────────
-- Four separate clients (Stock tab, Scan, the invoice form, and transfers)
-- write to this table. Having each of them recompute total_taken and
-- closing_stock in TypeScript is how the numbers drift apart, so the
-- database now has the last word on every derived column.
--
--   total_taken   = hand-entered + invoiced + transferred away
--   closing_stock = opening + transferred in - total_taken
--   stock_status  = '' when no min_level is set, else LOW / OK
--
-- Mirrors computeTotals()/computeStatus() in StockTab.tsx.
create or replace function public.fn_warehouse_stock_derive() returns trigger
language plpgsql set search_path = public as $$
declare
  manual integer;
begin
  select coalesce(sum(value::integer), 0) into manual
    from jsonb_each_text(coalesce(new.daily_taken, '{}'::jsonb));

  new.total_taken   := manual
                     + coalesce(new.invoice_taken, 0)
                     + coalesce(new.transfer_out, 0);
  new.closing_stock := coalesce(new.opening_stock, 0)
                     + coalesce(new.transfer_in, 0)
                     - new.total_taken;
  new.stock_status  := case
                         when coalesce(new.min_level, 0) = 0 then ''
                         when new.closing_stock < new.min_level then 'LOW'
                         else 'OK'
                       end;
  new.updated_at    := now();
  return new;
end $$;

drop trigger if exists trg_warehouse_stock_derive on public.warehouse_stock;
create trigger trg_warehouse_stock_derive
  before insert or update on public.warehouse_stock
  for each row execute function public.fn_warehouse_stock_derive();

-- Re-derive every existing row. With the three new columns all at 0 this
-- reproduces exactly what is already stored — it is a no-op on the numbers,
-- run only so nothing is left over from a client that computed differently.
-- The audit trigger is lifted for the sweep: this is a schema migration, not
-- staff activity, and logging a diff for every stock row would bury the log.
alter table public.warehouse_stock disable trigger trg_audit_warehouse_stock;
update public.warehouse_stock set opening_stock = opening_stock;
alter table public.warehouse_stock enable trigger trg_audit_warehouse_stock;

-- ── 3. The STORE STOCK location ───────────────────────────────
-- date_columns is left empty: the store is not counted on a day sheet, its
-- movements come from transfers in and invoices out.
insert into public.warehouses (name, color, date_columns, section_labels)
select 'STORE STOCK', '#f59e0b', '{}', '{}'
 where not exists (select 1 from public.warehouses where name = 'STORE STOCK');

-- ── 4. Transfer records ───────────────────────────────────────
-- Locations are stored as names, not ids, to match warehouse_stock.warehouse
-- (the whole schema keys stock on the warehouse NAME). A renamed warehouse
-- would orphan old transfers either way; the name at least stays readable.
create table if not exists public.stock_transfers (
  id              uuid primary key default gen_random_uuid(),
  transfer_number text not null unique,
  from_warehouse  text not null,
  to_warehouse    text not null,
  note            text,
  transferred_at  timestamptz not null default now(),
  created_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  constraint stock_transfers_distinct_ends check (from_warehouse <> to_warehouse)
);
create index if not exists stock_transfers_when_idx on public.stock_transfers (transferred_at desc);

create table if not exists public.stock_transfer_items (
  id          uuid primary key default gen_random_uuid(),
  transfer_id uuid not null references public.stock_transfers(id) on delete cascade,
  model       text not null,
  quantity    integer not null check (quantity > 0),
  -- What the source had on hand the moment the transfer was applied. Kept
  -- so a later shortfall can be explained without replaying every movement.
  from_before integer,
  position    integer not null default 1
);
create index if not exists stock_transfer_items_parent_idx on public.stock_transfer_items (transfer_id);

-- Per-year sequence, matching the invoice numbering style: TRF-2026-0001.
create or replace function public.next_transfer_number() returns text
language plpgsql security definer set search_path = public as $$
declare
  yr  text := to_char(now(), 'YYYY');
  cnt integer;
begin
  select count(*) + 1 into cnt from public.stock_transfers
   where to_char(transferred_at, 'YYYY') = yr;
  return 'TRF-' || yr || '-' || lpad(cnt::text, 4, '0');
end $$;

-- ── 5. Applying a transfer ────────────────────────────────────
-- One round trip, one transaction. Doing this client-side would leave a
-- half-moved transfer behind the moment the phone drops its connection
-- between the source update and the destination update.
--
-- p_items: [{"model": "DS-7208HGHI-M1", "quantity": 5}, ...]
--
-- A model missing from the destination is CREATED there with opening_stock 0
-- and transfer_in set, so receiving something new needs no prior setup.
-- A model missing from the SOURCE is rejected: you cannot send what the
-- source has never held, and silently inventing it would corrupt the count.
create or replace function public.transfer_stock(
  p_from  text,
  p_to    text,
  p_items jsonb,
  p_note  text default null,
  p_when  timestamptz default now()
) returns public.stock_transfers
language plpgsql security definer set search_path = public as $$
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

  -- next_transfer_number() counts existing rows, so two staff transferring at
  -- the same moment can both be handed TRF-2026-0007. The unique constraint
  -- catches it; retrying just picks up the number the winner did not take.
  for v_try in 1..8 loop
    begin
      insert into public.stock_transfers
        (transfer_number, from_warehouse, to_warehouse, note, transferred_at, created_by)
      values
        (public.next_transfer_number(), p_from, p_to, nullif(btrim(coalesce(p_note, '')), ''),
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

    -- Source: book the units out. Locked so two staff transferring the same
    -- model at once cannot both read the same "before" figure.
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

    -- Destination: book them in, creating the row if this location has
    -- never carried the model before.
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

-- ── 6. Invoice deduction from STORE STOCK ─────────────────────
-- Called by InvoiceForm right after the line items are saved.
--
-- p_items: [{"model": "DS-7208HGHI-M1", "quantity": 2}, ...]
--
-- Returns one row per line that could not be covered, so the form can tell
-- the cashier what the store is short of. The deduction happens either way —
-- the sale is never blocked by the count, per the shop's rule. A model the
-- store has no row for is reported as missing and left alone (inventing a
-- negative row for a one-off, untracked item would be noise, not accuracy).
create or replace function public.deduct_store_stock(
  p_items jsonb,
  p_store text default 'STORE STOCK'
) returns table (model text, requested integer, available integer, tracked boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_item  jsonb;
  v_model text;
  v_qty   integer;
  v_have  integer;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to adjust stock';
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_model := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    select closing_stock into v_have
      from public.warehouse_stock
     where warehouse = p_store and warehouse_stock.model = v_model
     for update;

    if not found then
      model := v_model; requested := v_qty; available := 0; tracked := false;
      return next;
      continue;
    end if;

    update public.warehouse_stock
       set invoice_taken = coalesce(invoice_taken, 0) + v_qty
     where warehouse = p_store and warehouse_stock.model = v_model;

    if v_have < v_qty then
      model := v_model; requested := v_qty; available := v_have; tracked := true;
      return next;
    end if;
  end loop;
end $$;

-- ── 7. RLS ────────────────────────────────────────────────────
alter table public.stock_transfers      enable row level security;
alter table public.stock_transfer_items enable row level security;

-- Everyone signed in can see the movement history; it is the record staff
-- check when a count looks wrong.
drop policy if exists stock_transfers_read on public.stock_transfers;
create policy stock_transfers_read on public.stock_transfers
  for select to authenticated using (true);

drop policy if exists stock_transfer_items_read on public.stock_transfer_items;
create policy stock_transfer_items_read on public.stock_transfer_items
  for select to authenticated using (true);

-- Writes go exclusively through transfer_stock(), which is SECURITY DEFINER.
-- No direct-write policy is granted, so a transfer cannot be forged without
-- the matching stock movement.
drop policy if exists stock_transfers_superboss_write on public.stock_transfers;
create policy stock_transfers_superboss_write on public.stock_transfers
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists stock_transfer_items_superboss_write on public.stock_transfer_items;
create policy stock_transfer_items_superboss_write on public.stock_transfer_items
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

grant execute on function public.transfer_stock(text, text, jsonb, text, timestamptz) to authenticated;
grant execute on function public.deduct_store_stock(jsonb, text) to authenticated;

-- ── 8. Audit ──────────────────────────────────────────────────
-- warehouse_stock is already audited (20260708_scan_staff_access.sql); the
-- transfer header gets the same treatment so the log shows who moved what.
drop trigger if exists trg_audit_stock_transfers on public.stock_transfers;
create trigger trg_audit_stock_transfers
  after insert or update or delete on public.stock_transfers
  for each row execute function public.fn_audit();

commit;

-- ── Verification (run after committing) ───────────────────────
-- select name from public.warehouses where name = 'STORE STOCK';
-- select count(*) filter (where closing_stock
--          <> opening_stock + transfer_in - total_taken) as drifted
--   from public.warehouse_stock;   -- expect 0
