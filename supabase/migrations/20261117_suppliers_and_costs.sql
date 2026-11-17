-- ─────────────────────────────────────────────────────────────
-- Suppliers, what we owe them, and what our stock cost — 2026-11-17
--
-- Three things the shop asked for, built as one ledger:
--
--   1. COST PRICES IN CEDIS
--      product_costs holds the last price we paid (GH₵) for each product,
--      filed under the same product key every stock movement uses
--      (stock_model_key). Receiving goods from a supplier updates it; the
--      Big Boss can also set it by hand.
--
--   2. GOODS RECEIVED, PAYMENTS, AND THE RUNNING BALANCE
--      Each supplier has a statement made of numbered documents:
--        received  SR-2026-0001   goods in, with quantity and unit cost.
--                                 Books the units into a stock location
--                                 through receive_stock(), so the delivery
--                                 also appears in the Transfers history (RCV).
--        payment   SP-2026-0001   money paid to the supplier.
--        returned  SRN-2026-0001  goods sent back (normally spoilt), credited
--                                 at cost and taken out of a stock location.
--      Balance owed = received − returned − paid.
--
--   3. SPOILT GOODS BACK TO THE SUPPLIER
--      A return takes units out of the chosen location (STORE STOCK, SPOILT
--      or any other) by raising transfer_out on that stock row, the same
--      counter a transfer uses, so closing_stock goes down. It refuses to
--      take more than the location holds.
--
-- A document entered wrongly is VOIDED, never deleted: it stays on the
-- statement, struck out, and stops counting. Voiding a receipt takes the
-- units back out of stock (refused if they have already been sold or moved);
-- voiding a return puts them back.
--
-- Main shop only. Bosses read; only the Big Boss writes, and only through the
-- functions below. Requires 20261023_stock_approval_everywhere.sql.
-- Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regprocedure('public.receive_stock_apply(text, jsonb, text, text, timestamptz)') is null then
    raise exception 'Run 20261023_stock_approval_everywhere.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

-- ── 1. Tables ─────────────────────────────────────────────────
create table if not exists public.suppliers (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (btrim(name) <> ''),
  phone      text,
  note       text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create unique index if not exists suppliers_name_uq on public.suppliers (lower(btrim(name)));

create table if not exists public.supplier_docs (
  id             uuid primary key default gen_random_uuid(),
  number         text not null unique,
  kind           text not null check (kind in ('received', 'payment', 'returned')),
  supplier_id    uuid not null references public.suppliers(id) on delete restrict,
  doc_date       date not null default current_date,
  location       text,                       -- where stock went in / came out
  ref            text,                       -- the supplier's invoice or receipt number
  amount         numeric(14,2) not null default 0 check (amount >= 0),
  stock_booked   boolean not null default false,
  transfer_number text,                      -- the RCV record when a receipt booked stock
  note           text,
  signed_by      text,
  staff_id       text,
  voided_at      timestamptz,
  void_reason    text,
  created_by     uuid default auth.uid(),
  created_at     timestamptz not null default now()
);
create index if not exists supplier_docs_supplier_idx on public.supplier_docs (supplier_id, doc_date);

create table if not exists public.supplier_doc_items (
  id           uuid primary key default gen_random_uuid(),
  doc_id       uuid not null references public.supplier_docs(id) on delete cascade,
  position     integer not null default 0,
  model        text not null,
  quantity     integer not null check (quantity > 0),
  unit_cost    numeric(14,2) not null default 0 check (unit_cost >= 0),
  stock_row_id uuid                          -- the warehouse_stock row it changed
);
create index if not exists supplier_doc_items_doc_idx on public.supplier_doc_items (doc_id);

create table if not exists public.product_costs (
  model_key  text primary key,
  model      text not null,
  unit_cost  numeric(14,2) not null check (unit_cost >= 0),
  source     text,                           -- 'SR-2026-0004' or 'manual'
  updated_at timestamptz not null default now()
);

-- ── 2. Access: bosses read, nobody writes directly ────────────
alter table public.suppliers          enable row level security;
alter table public.supplier_docs      enable row level security;
alter table public.supplier_doc_items enable row level security;
alter table public.product_costs      enable row level security;

drop policy if exists suppliers_read on public.suppliers;
create policy suppliers_read on public.suppliers for select to authenticated using ((select public.is_boss()));
drop policy if exists supplier_docs_read on public.supplier_docs;
create policy supplier_docs_read on public.supplier_docs for select to authenticated using ((select public.is_boss()));
drop policy if exists supplier_doc_items_read on public.supplier_doc_items;
create policy supplier_doc_items_read on public.supplier_doc_items for select to authenticated using ((select public.is_boss()));
drop policy if exists product_costs_read on public.product_costs;
create policy product_costs_read on public.product_costs for select to authenticated using ((select public.is_boss()));

grant select on public.suppliers, public.supplier_docs, public.supplier_doc_items, public.product_costs to authenticated;

-- Every change shows up in the Log tab.
drop trigger if exists trg_audit_supplier_docs on public.supplier_docs;
create trigger trg_audit_supplier_docs after insert or update or delete on public.supplier_docs
  for each row execute function public.fn_audit();

-- ── 3. Balances ───────────────────────────────────────────────
create or replace view public.supplier_balances with (security_invoker = true) as
select s.id, s.name, s.phone, s.note,
       coalesce(sum(d.amount) filter (where d.kind = 'received' and d.voided_at is null), 0) as received,
       coalesce(sum(d.amount) filter (where d.kind = 'returned' and d.voided_at is null), 0) as returned,
       coalesce(sum(d.amount) filter (where d.kind = 'payment'  and d.voided_at is null), 0) as paid,
       coalesce(sum(case d.kind when 'received' then d.amount else -d.amount end)
                filter (where d.voided_at is null), 0) as balance,
       max(d.doc_date) as last_activity
  from public.suppliers s
  left join public.supplier_docs d on d.supplier_id = s.id
 group by s.id;
grant select on public.supplier_balances to authenticated;

-- ── 4. Internal helpers ───────────────────────────────────────
create or replace function public.supplier_only_big_boss()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss can change supplier records' using errcode = '42501';
  end if;
end $$;

-- SR-2026-0001, SP-2026-0001, SRN-2026-0001: one series per kind per year.
create or replace function public.supplier_next_number(p_kind text, p_date date)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_prefix text := case p_kind when 'received' then 'SR' when 'payment' then 'SP' else 'SRN' end
                   || '-' || to_char(coalesce(p_date, current_date), 'YYYY') || '-';
  v_last   integer;
begin
  perform pg_advisory_xact_lock(hashtext('supplier_docs_number'));
  select coalesce(max(substring(number from length(v_prefix) + 1)::integer), 0) into v_last
    from public.supplier_docs where number like v_prefix || '%'
     and substring(number from length(v_prefix) + 1) ~ '^\d+$';
  return v_prefix || lpad((v_last + 1)::text, 4, '0');
end $$;

create or replace function public.supplier_open_doc(
  p_kind text, p_supplier uuid, p_date date, p_location text, p_ref text, p_note text
) returns public.supplier_docs
language plpgsql security definer set search_path = public as $$
declare
  v_doc public.supplier_docs;
begin
  if not exists (select 1 from public.suppliers where id = p_supplier) then
    raise exception 'Pick a supplier first';
  end if;
  insert into public.supplier_docs (number, kind, supplier_id, doc_date, location, ref, note, signed_by, staff_id)
  values (public.supplier_next_number(p_kind, p_date), p_kind, p_supplier, coalesce(p_date, current_date),
          nullif(btrim(coalesce(p_location, '')), ''),
          nullif(btrim(coalesce(p_ref, '')), ''),
          nullif(btrim(coalesce(p_note, '')), ''),
          public.current_staff_name(), public.current_staff_id())
  returning * into v_doc;
  return v_doc;
end $$;

revoke all on function public.supplier_next_number(text, date) from public, anon, authenticated;
revoke all on function public.supplier_open_doc(text, uuid, date, text, text, text) from public, anon, authenticated;

-- ── 5. Suppliers ──────────────────────────────────────────────
create or replace function public.supplier_save(p_id uuid, p_name text, p_phone text default null, p_note text default null)
returns public.suppliers
language plpgsql security definer set search_path = public as $$
declare
  v public.suppliers;
begin
  perform public.supplier_only_big_boss();
  if btrim(coalesce(p_name, '')) = '' then raise exception 'A supplier needs a name'; end if;
  if p_id is null then
    insert into public.suppliers (name, phone, note)
    values (btrim(p_name), nullif(btrim(coalesce(p_phone, '')), ''), nullif(btrim(coalesce(p_note, '')), ''))
    returning * into v;
  else
    update public.suppliers
       set name = btrim(p_name), phone = nullif(btrim(coalesce(p_phone, '')), ''), note = nullif(btrim(coalesce(p_note, '')), '')
     where id = p_id returning * into v;
  end if;
  return v;
exception when unique_violation then
  raise exception '% is already on the supplier list', btrim(p_name);
end $$;

-- ── 6. Goods received ─────────────────────────────────────────
-- p_items: [{"model": "DS-2CE16D0T", "quantity": 10, "unit_cost": 145.50}, ...]
create or replace function public.supplier_receive(
  p_supplier uuid, p_items jsonb, p_date date default current_date,
  p_to text default 'STORE STOCK', p_book_stock boolean default true,
  p_ref text default null, p_note text default null
) returns public.supplier_docs
language plpgsql security definer set search_path = public as $$
declare
  v_doc   public.supplier_docs;
  v_item  jsonb;
  v_model text;
  v_qty   integer;
  v_cost  numeric;
  v_pos   integer := 0;
  v_total numeric := 0;
  v_moves jsonb := '[]'::jsonb;
  v_rcv   public.stock_transfers;
  v_name  text;
begin
  perform public.supplier_only_big_boss();
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Add at least one item';
  end if;
  if p_book_stock and btrim(coalesce(p_to, '')) = '' then
    raise exception 'Pick the location the goods went into';
  end if;

  v_doc := public.supplier_open_doc('received', p_supplier, p_date,
             case when p_book_stock then p_to end, p_ref, p_note);

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := upper(btrim(coalesce(v_item->>'model', '')));
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    v_cost  := coalesce((v_item->>'unit_cost')::numeric, 0);
    if v_model = '' or v_qty <= 0 then continue; end if;
    if v_cost < 0 then raise exception 'A cost cannot be negative (%)', v_model; end if;

    v_pos   := v_pos + 1;
    v_total := v_total + v_qty * v_cost;
    insert into public.supplier_doc_items (doc_id, position, model, quantity, unit_cost)
    values (v_doc.id, v_pos, v_model, v_qty, v_cost);
    v_moves := v_moves || jsonb_build_object('model', v_model, 'quantity', v_qty);

    if v_cost > 0 then
      insert into public.product_costs (model_key, model, unit_cost, source, updated_at)
      values (public.stock_model_key(v_model), v_model, v_cost, v_doc.number, now())
      on conflict (model_key) do update
        set model = excluded.model, unit_cost = excluded.unit_cost, source = excluded.source, updated_at = now();
    end if;
  end loop;

  if v_pos = 0 then raise exception 'Add at least one item with a quantity'; end if;

  if p_book_stock then
    select name into v_name from public.suppliers where id = p_supplier;
    v_rcv := public.receive_stock(p_to, v_moves, v_name,
               concat_ws(' · ', v_doc.number, v_doc.ref, v_doc.note),
               (coalesce(p_date, current_date) + time '12:00')::timestamptz);
    -- Remember which row each line landed on, so a void can take it back out.
    update public.supplier_doc_items i
       set stock_row_id = public.stock_find_row(p_to, i.model)
     where i.doc_id = v_doc.id;
  end if;

  update public.supplier_docs
     set amount = round(v_total, 2), stock_booked = p_book_stock, transfer_number = v_rcv.transfer_number
   where id = v_doc.id returning * into v_doc;
  return v_doc;
end $$;

-- ── 7. Payments ───────────────────────────────────────────────
create or replace function public.supplier_payment(
  p_supplier uuid, p_amount numeric, p_date date default current_date,
  p_ref text default null, p_note text default null
) returns public.supplier_docs
language plpgsql security definer set search_path = public as $$
declare
  v_doc public.supplier_docs;
begin
  perform public.supplier_only_big_boss();
  if p_amount is null or p_amount <= 0 then raise exception 'Enter the amount paid'; end if;
  v_doc := public.supplier_open_doc('payment', p_supplier, p_date, null, p_ref, p_note);
  update public.supplier_docs set amount = round(p_amount, 2) where id = v_doc.id returning * into v_doc;
  return v_doc;
end $$;

-- ── 8. Goods back to the supplier ─────────────────────────────
-- p_items: [{"model": "...", "quantity": 2, "unit_cost": 145.50}]
-- unit_cost may be left out: the product's cost price is used.
create or replace function public.supplier_return(
  p_supplier uuid, p_items jsonb, p_from text default 'SPOILT', p_date date default current_date,
  p_ref text default null, p_note text default null
) returns public.supplier_docs
language plpgsql security definer set search_path = public as $$
declare
  v_doc   public.supplier_docs;
  v_item  jsonb;
  v_model text;
  v_qty   integer;
  v_cost  numeric;
  v_row   uuid;
  v_name  text;
  v_have  integer;
  v_pos   integer := 0;
  v_total numeric := 0;
begin
  perform public.supplier_only_big_boss();
  if btrim(coalesce(p_from, '')) = '' then raise exception 'Pick the location the goods are taken from'; end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception 'Add at least one item'; end if;

  v_doc := public.supplier_open_doc('returned', p_supplier, p_date, p_from, p_ref, p_note);

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_model := btrim(coalesce(v_item->>'model', ''));
    v_qty   := coalesce((v_item->>'quantity')::integer, 0);
    if v_model = '' or v_qty <= 0 then continue; end if;

    v_row := public.stock_find_row(p_from, v_model);
    if v_row is null then
      raise exception '% has no % to return', p_from, v_model;
    end if;
    select model, closing_stock into v_name, v_have from public.warehouse_stock where id = v_row for update;
    if v_have < v_qty then
      raise exception '% holds only % × % — cannot return %', p_from, v_have, v_name, v_qty;
    end if;

    v_cost := nullif(v_item->>'unit_cost', '')::numeric;
    if v_cost is null then
      select unit_cost into v_cost from public.product_costs where model_key = public.stock_model_key(v_name);
    end if;
    v_cost := coalesce(v_cost, 0);
    if v_cost < 0 then raise exception 'A cost cannot be negative (%)', v_name; end if;

    update public.warehouse_stock set transfer_out = coalesce(transfer_out, 0) + v_qty where id = v_row;

    v_pos   := v_pos + 1;
    v_total := v_total + v_qty * v_cost;
    insert into public.supplier_doc_items (doc_id, position, model, quantity, unit_cost, stock_row_id)
    values (v_doc.id, v_pos, v_name, v_qty, v_cost, v_row);
  end loop;

  if v_pos = 0 then raise exception 'Add at least one item with a quantity'; end if;

  update public.supplier_docs set amount = round(v_total, 2), stock_booked = true
   where id = v_doc.id returning * into v_doc;
  return v_doc;
end $$;

-- ── 9. Voiding a mistake ──────────────────────────────────────
create or replace function public.supplier_void(p_doc uuid, p_reason text default null)
returns public.supplier_docs
language plpgsql security definer set search_path = public as $$
declare
  v_doc  public.supplier_docs;
  v_it   public.supplier_doc_items;
  v_have integer;
begin
  perform public.supplier_only_big_boss();
  select * into v_doc from public.supplier_docs where id = p_doc for update;
  if v_doc.id is null then raise exception 'That record no longer exists'; end if;
  if v_doc.voided_at is not null then raise exception '% is already voided', v_doc.number; end if;

  if v_doc.stock_booked then
    for v_it in select * from public.supplier_doc_items where doc_id = v_doc.id order by position loop
      if v_it.stock_row_id is null then continue; end if;
      if v_doc.kind = 'received' then
        -- Take the delivered units back out — only if they are still there.
        select closing_stock into v_have from public.warehouse_stock where id = v_it.stock_row_id for update;
        if coalesce(v_have, 0) < v_it.quantity then
          raise exception 'Cannot void %: % × % have already left %',
            v_doc.number, v_it.quantity - coalesce(v_have, 0), v_it.model, v_doc.location;
        end if;
        update public.warehouse_stock set transfer_out = coalesce(transfer_out, 0) + v_it.quantity
         where id = v_it.stock_row_id;
      elsif v_doc.kind = 'returned' then
        -- Put the returned units back where they were taken from.
        update public.warehouse_stock set transfer_out = greatest(coalesce(transfer_out, 0) - v_it.quantity, 0)
         where id = v_it.stock_row_id;
      end if;
    end loop;
  end if;

  update public.supplier_docs
     set voided_at = now(), void_reason = nullif(btrim(coalesce(p_reason, '')), '')
   where id = v_doc.id returning * into v_doc;
  return v_doc;
end $$;

-- ── 10. Setting a cost price by hand ──────────────────────────
create or replace function public.set_product_cost(p_model text, p_cost numeric)
returns public.product_costs
language plpgsql security definer set search_path = public as $$
declare
  v public.product_costs;
begin
  perform public.supplier_only_big_boss();
  if btrim(coalesce(p_model, '')) = '' then raise exception 'Which product?'; end if;
  if p_cost is null or p_cost < 0 then raise exception 'Enter a cost of 0 or more'; end if;
  insert into public.product_costs (model_key, model, unit_cost, source, updated_at)
  values (public.stock_model_key(p_model), upper(btrim(p_model)), round(p_cost, 2), 'manual', now())
  on conflict (model_key) do update
    set unit_cost = excluded.unit_cost, source = 'manual', updated_at = now()
  returning * into v;
  return v;
end $$;

grant execute on function public.supplier_save(uuid, text, text, text)                         to authenticated;
grant execute on function public.supplier_receive(uuid, jsonb, date, text, boolean, text, text) to authenticated;
grant execute on function public.supplier_payment(uuid, numeric, date, text, text)              to authenticated;
grant execute on function public.supplier_return(uuid, jsonb, text, date, text, text)           to authenticated;
grant execute on function public.supplier_void(uuid, text)                                      to authenticated;
grant execute on function public.set_product_cost(text, numeric)                                to authenticated;
