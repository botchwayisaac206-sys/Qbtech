-- ─────────────────────────────────────────────────────────────
-- Dahua transfers, receiving, returns (RNA) and SPOILT — 2026-09-30
--
-- Gives the Dahua line the stock movements the main shop has had since
-- 20260920_store_stock_transfers.sql, 20260922_returns_and_staff_id.sql and
-- 20260922_spoilt_location.sql:
--
--   move     units leave one Dahua warehouse and arrive at another, in one
--            transaction.
--   receive  a supplier delivery — units enter the system, nothing is
--            deducted anywhere.
--   return   goods back from a buyer. Good lines go back into stock;
--            spoilt lines go to the Dahua SPOILT location instead.
--
-- Everything lands on one numbered record per movement, in series of its
-- own — DH-TRF / DH-RCV / DH-RNA — so a Dahua movement can never be read as
-- a main-shop one. Who did it is the staff ID of whoever is signed in,
-- recorded by the database rather than typed.
--
-- WHAT IS DIFFERENT FROM THE MAIN SHOP
--   There is no STORE STOCK here. Dahua invoices deduct from whichever
--   stock row the cashier picks, as they always have, so a transfer is just
--   units changing warehouse.
--
--   dahua_stock has no unique (warehouse, model) key, so the functions below
--   always act on the OLDEST matching row — the same one the Stock tab lists
--   first. A row created at a destination copies the model's selling price
--   from its existing rows, so stock moved into a new warehouse does not
--   show up on an invoice as "no price".
--
-- DERIVED COLUMNS
--   Until now total_taken and closing_stock were computed by each client
--   (Stock tab, invoice form, invoice delete, Scan). With transfer_in and
--   transfer_out added, the database takes that over, exactly as
--   fn_warehouse_stock_derive() does for the main shop:
--
--     total_taken   = hand-entered + invoiced + transferred away
--     closing_stock = opening + transferred in - total_taken
--
--   With both new columns at 0 that is the formula every client already
--   uses, so re-deriving existing rows changes nothing that was computed
--   correctly. Run the DRIFT CHECK below first if you want to see whether
--   any row was not.
--
-- Requires 20260906_dahua_pricing.sql (unit_price) and
-- 20260922_returns_and_staff_id.sql (current_staff_id / current_staff_name).
-- Run once, in the Supabase SQL editor. Idempotent.
--
-- DRIFT CHECK (optional, run before this file):
--   select warehouse, model, closing_stock,
--          opening_stock - (invoice_taken + (select coalesce(sum(v::integer), 0)
--                                             from jsonb_each_text(daily_taken) as t(k, v))) as derived
--     from public.dahua_stock
--    where closing_stock <> opening_stock - (invoice_taken + (select coalesce(sum(v::integer), 0)
--                                             from jsonb_each_text(daily_taken) as t(k, v)));
-- ─────────────────────────────────────────────────────────────

-- ── 0. Refuse to run out of order ─────────────────────────────
do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'dahua_stock' and column_name = 'unit_price'
  ) then
    raise exception 'Run 20260906_dahua_pricing.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
  if to_regprocedure('public.current_staff_id()') is null then
    raise exception 'Run 20260922_returns_and_staff_id.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

begin;

-- ── 1. Movement columns on dahua_stock ────────────────────────
alter table public.dahua_stock
  add column if not exists transfer_in  integer not null default 0,  -- received, moved in, or returned
  add column if not exists transfer_out integer not null default 0;  -- moved to another Dahua warehouse

-- ── 2. Derived columns are computed by the database ───────────
-- Mirrors computeTotals()/computeStatus() in DahuaStockTab.tsx.
create or replace function public.fn_dahua_stock_derive() returns trigger
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

drop trigger if exists trg_dahua_stock_derive on public.dahua_stock;
create trigger trg_dahua_stock_derive
  before insert or update on public.dahua_stock
  for each row execute function public.fn_dahua_stock_derive();

-- Re-derive every existing row. The audit trigger is lifted for the sweep:
-- this is a schema migration, not staff activity.
alter table public.dahua_stock disable trigger trg_audit_dahua_stock;
update public.dahua_stock set opening_stock = opening_stock;
alter table public.dahua_stock enable trigger trg_audit_dahua_stock;

-- ── 3. The Dahua SPOILT location ──────────────────────────────
-- Red, no date columns: spoilt goods are not counted on a day sheet. Filled
-- only by marking a returned line spoilt; the invoice form does not offer it.
insert into public.dahua_warehouses (name, color, date_columns, section_labels)
select 'SPOILT', '#ef4444', '{}', '{}'
 where not exists (select 1 from public.dahua_warehouses where name = 'SPOILT');

-- ── 4. Movement records ───────────────────────────────────────
create table if not exists public.dahua_stock_transfers (
  id              uuid primary key default gen_random_uuid(),
  transfer_number text not null unique,
  kind            text not null default 'move',
  from_warehouse  text,
  to_warehouse    text not null,
  supplier        text,       -- the supplier on a receive, the buyer on a return
  note            text,
  signed_by       text,       -- their name at the time
  staff_id        text,       -- their login ID at the time
  transferred_at  timestamptz not null default now(),
  created_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  constraint dahua_stock_transfers_kind_check check (kind in ('move', 'receive', 'return')),
  constraint dahua_stock_transfers_source_check check (
    (kind = 'move' and from_warehouse is not null and from_warehouse <> to_warehouse)
    or (kind in ('receive', 'return') and from_warehouse is null)
  )
);
create index if not exists dahua_stock_transfers_when_idx
  on public.dahua_stock_transfers (transferred_at desc);

create table if not exists public.dahua_stock_transfer_items (
  id          uuid primary key default gen_random_uuid(),
  transfer_id uuid not null references public.dahua_stock_transfers(id) on delete cascade,
  model       text not null,
  quantity    integer not null check (quantity > 0),
  from_before integer,        -- what the source held when the move applied
  position    integer not null default 1,
  condition   text not null default 'good',
  constraint dahua_stock_transfer_items_condition_check check (condition in ('good', 'spoilt'))
);
create index if not exists dahua_stock_transfer_items_parent_idx
  on public.dahua_stock_transfer_items (transfer_id);

-- ── 5. Numbering: DH-TRF-2026-0001, DH-RCV-…, DH-RNA-… ────────
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
     and kind = p_kind;
  return prefix || '-' || yr || '-' || lpad(cnt::text, 4, '0');
end $$;

-- ── 6. Shared steps ───────────────────────────────────────────
-- Writes the header, retrying on a number clash: the number counts rows, so
-- two staff saving at once can both be handed the same one.
create or replace function public.dahua_movement_open(
  p_kind text, p_from text, p_to text, p_party text, p_note text, p_when timestamptz
) returns public.dahua_stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_rec public.dahua_stock_transfers;
  v_try integer;
begin
  for v_try in 1..8 loop
    begin
      insert into public.dahua_stock_transfers
        (transfer_number, kind, from_warehouse, to_warehouse, supplier,
         note, signed_by, staff_id, transferred_at, created_by)
      values
        (public.next_dahua_movement_number(p_kind), p_kind, p_from, p_to,
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

-- Books units in at a warehouse, creating the row (at the model's existing
-- price) when that warehouse has never carried it.
create or replace function public.dahua_stock_book_in(p_warehouse text, p_model text, p_qty integer)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_id    uuid;
  v_price numeric(12,2);
begin
  select id into v_id
    from public.dahua_stock
   where warehouse = p_warehouse and model = p_model
   order by created_at, id
   limit 1
   for update;

  if found then
    update public.dahua_stock
       set transfer_in = coalesce(transfer_in, 0) + p_qty
     where id = v_id;
  else
    select max(unit_price) into v_price from public.dahua_stock where model = p_model;
    insert into public.dahua_stock (warehouse, model, opening_stock, daily_taken, invoice_taken, transfer_in, unit_price)
    values (p_warehouse, p_model, 0, '{}'::jsonb, 0, p_qty, coalesce(v_price, 0));
  end if;
end $$;

-- Internal helpers: reachable only through the three functions below.
revoke all on function public.dahua_movement_open(text, text, text, text, text, timestamptz) from public, anon, authenticated;
revoke all on function public.dahua_stock_book_in(text, text, integer) from public, anon, authenticated;

-- ── 7. Moving between warehouses ──────────────────────────────
-- p_items: [{"model": "DH-IPC-HFW1239TL1-A-IL 2MP", "quantity": 5}, ...]
-- A model the source has never held is rejected; one the destination has
-- never held is created there.
create or replace function public.dahua_transfer_stock(
  p_from  text,
  p_to    text,
  p_items jsonb,
  p_note  text default null,
  p_when  timestamptz default now()
) returns public.dahua_stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_rec    public.dahua_stock_transfers;
  v_item   jsonb;
  v_model  text;
  v_qty    integer;
  v_id     uuid;
  v_before integer;
  v_pos    integer := 0;
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
    v_model := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    select id, closing_stock into v_id, v_before
      from public.dahua_stock
     where warehouse = p_from and model = v_model
     order by created_at, id
     limit 1
     for update;
    if not found then
      raise exception '% does not hold %', p_from, v_model;
    end if;

    update public.dahua_stock
       set transfer_out = coalesce(transfer_out, 0) + v_qty
     where id = v_id;

    perform public.dahua_stock_book_in(p_to, v_model, v_qty);

    v_pos := v_pos + 1;
    insert into public.dahua_stock_transfer_items (transfer_id, model, quantity, from_before, position)
    values (v_rec.id, v_model, v_qty, v_before, v_pos);
  end loop;

  return v_rec;
end $$;

-- ── 8. Receiving from a supplier ──────────────────────────────
create or replace function public.dahua_receive_stock(
  p_to       text,
  p_items    jsonb,
  p_supplier text default null,
  p_note     text default null,
  p_when     timestamptz default now()
) returns public.dahua_stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_rec   public.dahua_stock_transfers;
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

  v_rec := public.dahua_movement_open('receive', null, p_to, p_supplier, p_note, p_when);

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    perform public.dahua_stock_book_in(p_to, v_model, v_qty);

    v_pos := v_pos + 1;
    insert into public.dahua_stock_transfer_items (transfer_id, model, quantity, from_before, position)
    values (v_rec.id, v_model, v_qty, null, v_pos);
  end loop;

  return v_rec;
end $$;

-- ── 9. Returns from buyers ────────────────────────────────────
-- p_items: [{"model": "...", "quantity": 2, "condition": "good"|"spoilt"}, ...]
-- Good lines go back into p_to; spoilt lines go to p_spoilt. Both are
-- recorded on the same DH-RNA record.
create or replace function public.dahua_return_stock(
  p_to       text,
  p_items    jsonb,
  p_customer text default null,
  p_note     text default null,
  p_when     timestamptz default now(),
  p_spoilt   text default 'SPOILT'
) returns public.dahua_stock_transfers
language plpgsql security definer set search_path = public as $$
declare
  v_rec   public.dahua_stock_transfers;
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

  v_rec := public.dahua_movement_open('return', null, p_to, p_customer, p_note, p_when);

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(v_item->>'model');
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    -- The tick is on the exception: anything not marked spoilt is resaleable.
    v_cond  := case when lower(coalesce(v_item->>'condition', 'good')) = 'spoilt'
                    then 'spoilt' else 'good' end;
    if v_model = '' or v_qty <= 0 then
      continue;
    end if;

    perform public.dahua_stock_book_in(
      case when v_cond = 'spoilt' then p_spoilt else p_to end, v_model, v_qty);

    v_pos := v_pos + 1;
    insert into public.dahua_stock_transfer_items
      (transfer_id, model, quantity, from_before, position, condition)
    values (v_rec.id, v_model, v_qty, null, v_pos, v_cond);
  end loop;

  return v_rec;
end $$;

-- ── 10. RLS ───────────────────────────────────────────────────
-- The history is boss-only, as the main shop's is since
-- 20260922_movement_history_boss_only.sql. Cashiers still RECORD movements:
-- the functions are definer, so they write and return the new row without
-- the caller needing read access.
alter table public.dahua_stock_transfers      enable row level security;
alter table public.dahua_stock_transfer_items enable row level security;

drop policy if exists dahua_stock_transfers_read on public.dahua_stock_transfers;
create policy dahua_stock_transfers_read on public.dahua_stock_transfers
  for select to authenticated using ((select public.is_boss()));

drop policy if exists dahua_stock_transfer_items_read on public.dahua_stock_transfer_items;
create policy dahua_stock_transfer_items_read on public.dahua_stock_transfer_items
  for select to authenticated using ((select public.is_boss()));

-- Writes go through the functions. Only the Big Boss may touch rows directly.
drop policy if exists dahua_stock_transfers_superboss_write on public.dahua_stock_transfers;
create policy dahua_stock_transfers_superboss_write on public.dahua_stock_transfers
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists dahua_stock_transfer_items_superboss_write on public.dahua_stock_transfer_items;
create policy dahua_stock_transfer_items_superboss_write on public.dahua_stock_transfer_items
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

grant execute on function public.dahua_transfer_stock(text, text, jsonb, text, timestamptz)      to authenticated;
grant execute on function public.dahua_receive_stock(text, jsonb, text, text, timestamptz)       to authenticated;
grant execute on function public.dahua_return_stock(text, jsonb, text, text, timestamptz, text)  to authenticated;
grant execute on function public.next_dahua_movement_number(text)                                to authenticated;

-- ── 11. Audit ─────────────────────────────────────────────────
drop trigger if exists trg_audit_dahua_stock_transfers on public.dahua_stock_transfers;
create trigger trg_audit_dahua_stock_transfers
  after insert or update or delete on public.dahua_stock_transfers
  for each row execute function public.fn_audit();

commit;

-- ── Verification (run after committing) ───────────────────────
-- select name from public.dahua_warehouses where name = 'SPOILT';
-- select count(*) filter (where closing_stock
--          <> opening_stock + transfer_in - total_taken) as drifted
--   from public.dahua_stock;   -- expect 0
--
-- Recent Dahua movements:
-- select t.transfer_number, t.kind, t.from_warehouse, t.to_warehouse,
--        t.staff_id, i.model, i.quantity, i.condition
--   from public.dahua_stock_transfer_items i
--   join public.dahua_stock_transfers t on t.id = i.transfer_id
--  order by t.transferred_at desc, i.position
--  limit 50;
