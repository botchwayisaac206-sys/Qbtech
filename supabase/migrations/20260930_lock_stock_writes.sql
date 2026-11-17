-- ─────────────────────────────────────────────────────────────
-- Stock can only change the way the app changes it — 2026-09-30
--
-- THE HOLE
--   The app signs in with the public anon key, so anything the app can do,
--   a cashier can also do from a script with their own login. Until now
--   cashiers held a plain UPDATE policy on warehouse_stock and dahua_stock
--   (20260807_superboss.sql) — needed because the Scan tab and the Dahua
--   invoice form wrote stock rows directly. That policy is row-level only,
--   so outside the app a cashier could rewrite ANY column of ANY stock row:
--   opening counts, invoice deductions, transfer figures, all of it.
--
--   deduct_store_stock() had the same shape of problem: it takes a free
--   list of models and quantities, so it could take units off STORE STOCK
--   with no invoice behind them.
--
-- THE FIX
--   Cashiers lose direct write access to the stock tables entirely. Every
--   stock change the app makes as a cashier now goes through a function
--   that can do exactly that one thing and nothing more:
--
--     scan_adjust_stock           Scan tab: add/remove units taken, for one
--                                 day column of one row. Only daily_taken
--                                 moves; the derive triggers recompute the
--                                 rest.
--     scan_add_stock_row          Scan tab: stock a model in a location that
--                                 has never carried it. Refuses a row that
--                                 already exists. Main shop only for
--                                 cashiers, as before (Dahua inserts were
--                                 already Big-Boss-only).
--     deduct_invoice_store_stock  Main invoice save: deducts what the
--                                 INVOICE's saved lines say — read from the
--                                 database, not sent by the client — and
--                                 only once per invoice, only by the
--                                 cashier who made it.
--     dahua_deduct_invoice_stock  The same for a Dahua invoice.
--
--   Transfers, receipts and returns already went through definer functions
--   that record a numbered movement with the staff ID, so they are left as
--   they are.
--
--   The Big Boss keeps full direct access — the Stock tabs edit rows
--   directly and are theirs alone.
--
-- Requires 20260920_store_stock_transfers.sql and 20260930_dahua_transfers.sql
-- (the derive triggers that recompute totals after a scan). Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regprocedure('public.fn_dahua_stock_derive()') is null then
    raise exception 'Run 20260930_dahua_transfers.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
  if to_regprocedure('public.fn_warehouse_stock_derive()') is null then
    raise exception 'Run 20260920_store_stock_transfers.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

begin;

-- ── 1. Reset the stock tables' policies ───────────────────────
-- Dropped by listing what is actually there rather than by name: a policy
-- added by hand in the dashboard at some point would otherwise survive,
-- and policies OR together, so one stray permissive policy reopens the hole.
do $$
declare r record;
begin
  for r in
    select policyname, tablename from pg_policies
     where schemaname = 'public'
       and tablename in ('warehouse_stock', 'dahua_stock', 'warehouses')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

alter table public.warehouse_stock enable row level security;
alter table public.dahua_stock     enable row level security;
alter table public.warehouses      enable row level security;

-- Everyone signed in reads stock: the invoice forms, Scan and Transfers all
-- show on-hand figures.
create policy warehouse_stock_read on public.warehouse_stock
  for select to authenticated using (true);
create policy dahua_stock_read on public.dahua_stock
  for select to authenticated using (true);
create policy warehouses_read on public.warehouses
  for select to authenticated using (true);

-- Only the Big Boss writes directly.
create policy warehouse_stock_superboss_write on public.warehouse_stock
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));
create policy dahua_stock_superboss_write on public.dahua_stock
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));
create policy warehouses_superboss_write on public.warehouses
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

-- dahua_warehouses is already read-all / Big-Boss-write (20260807_superboss.sql).

-- ── 2. Scan: units taken, one day column at a time ────────────
-- p_key is the daily_taken key the Scan tab writes: "<day>" for the first
-- section, "<section>:<day>" for the others. It must name a day column and a
-- section the row's warehouse actually has, so a script cannot invent keys.
-- A slot that falls to zero or below is removed, as the tab does.
create or replace function public.scan_adjust_stock(
  p_dahua boolean,
  p_id    uuid,
  p_key   text,
  p_delta integer
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_wh       text;
  v_daily    jsonb;
  v_cols     text[];
  v_labels   text[];
  v_section  integer;
  v_day      text;
  v_next     integer;
  v_row      jsonb;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to record stock';
  end if;
  if p_delta is null or p_delta = 0 or abs(p_delta) > 100000 then
    raise exception 'Quantity must be a whole number between -100000 and 100000, not zero';
  end if;
  if p_key is null or p_key !~ '^([0-9]{1,3}:)?[^:]{1,20}$' then
    raise exception 'Not a day column: %', p_key;
  end if;

  if p_key like '%:%' then
    v_section := split_part(p_key, ':', 1)::integer;
    v_day     := split_part(p_key, ':', 2);
  else
    v_section := 0;
    v_day     := p_key;
  end if;

  -- Lock the row, then check the key against its warehouse.
  if p_dahua then
    select warehouse, coalesce(daily_taken, '{}'::jsonb) into v_wh, v_daily
      from public.dahua_stock where id = p_id for update;
    if not found then raise exception 'That stock row no longer exists'; end if;
    select date_columns, section_labels into v_cols, v_labels
      from public.dahua_warehouses where name = v_wh;
  else
    select warehouse, coalesce(daily_taken, '{}'::jsonb) into v_wh, v_daily
      from public.warehouse_stock where id = p_id for update;
    if not found then raise exception 'That stock row no longer exists'; end if;
    select date_columns, section_labels into v_cols, v_labels
      from public.warehouses where name = v_wh;
  end if;

  if v_cols is null or not (v_day = any (v_cols)) then
    raise exception '% has no day column %', v_wh, v_day;
  end if;
  if v_section >= greatest(coalesce(array_length(v_labels, 1), 0), 1) then
    raise exception '% has no section %', v_wh, v_section;
  end if;

  v_next := coalesce((v_daily->>p_key)::integer, 0) + p_delta;
  v_daily := case when v_next <= 0 then v_daily - p_key
                  else jsonb_set(v_daily, array[p_key], to_jsonb(v_next)) end;

  -- Only daily_taken is written; fn_*_stock_derive recomputes the totals.
  if p_dahua then
    update public.dahua_stock set daily_taken = v_daily where id = p_id
      returning to_jsonb(dahua_stock.*) into v_row;
  else
    update public.warehouse_stock set daily_taken = v_daily where id = p_id
      returning to_jsonb(warehouse_stock.*) into v_row;
  end if;
  return v_row;
end $$;

-- ── 3. Scan: stock a model somewhere new ──────────────────────
create or replace function public.scan_add_stock_row(
  p_dahua     boolean,
  p_warehouse text,
  p_model     text,
  p_opening   integer,
  p_min       integer default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_model text := btrim(coalesce(p_model, ''));
  v_row   jsonb;
  v_price numeric(12,2);
begin
  -- Cashiers could add a main-shop row from Scan before; Dahua rows were
  -- always Big Boss only. Both stay as they were.
  if not ((select public.is_superboss()) or (not p_dahua and (select public.is_cashier()))) then
    raise exception 'Not allowed to add stock rows';
  end if;
  if v_model = '' or length(v_model) > 200 then
    raise exception 'A model name is required';
  end if;
  if p_opening is null or p_opening < 0 or p_opening > 100000 then
    raise exception 'Opening stock must be between 0 and 100000';
  end if;
  if p_min is not null and (p_min < 0 or p_min > 100000) then
    raise exception 'Minimum level must be between 0 and 100000';
  end if;
  if upper(btrim(coalesce(p_warehouse, ''))) = 'SPOILT' then
    raise exception 'SPOILT is filled by returns only';
  end if;

  if p_dahua then
    if not exists (select 1 from public.dahua_warehouses where name = p_warehouse) then
      raise exception 'No such warehouse: %', p_warehouse;
    end if;
    if exists (select 1 from public.dahua_stock
                where warehouse = p_warehouse and upper(btrim(model)) = upper(v_model)) then
      raise exception '% already stocks %', p_warehouse, v_model;
    end if;
    select max(unit_price) into v_price from public.dahua_stock where model = v_model;
    insert into public.dahua_stock (warehouse, model, opening_stock, daily_taken, invoice_taken, min_level, unit_price)
    values (p_warehouse, v_model, p_opening, '{}'::jsonb, 0, p_min, coalesce(v_price, 0))
    returning to_jsonb(dahua_stock.*) into v_row;
  else
    if not exists (select 1 from public.warehouses where name = p_warehouse) then
      raise exception 'No such warehouse: %', p_warehouse;
    end if;
    if exists (select 1 from public.warehouse_stock
                where warehouse = p_warehouse and upper(btrim(model)) = upper(v_model)) then
      raise exception '% already stocks %', p_warehouse, v_model;
    end if;
    insert into public.warehouse_stock (warehouse, model, opening_stock, daily_taken, min_level)
    values (p_warehouse, v_model, p_opening, '{}'::jsonb, p_min)
    returning to_jsonb(warehouse_stock.*) into v_row;
  end if;
  return v_row;
end $$;

-- ── 4. One deduction per invoice ──────────────────────────────
-- Kept in its own table rather than as a column on the invoice, so marking
-- an invoice does not write an UPDATE into the activity log for every sale.
create table if not exists public.invoice_stock_deductions (
  line        text not null check (line in ('main', 'dahua')),
  invoice_id  uuid not null,
  deducted_by uuid,
  deducted_at timestamptz not null default now(),
  primary key (line, invoice_id)
);
alter table public.invoice_stock_deductions enable row level security;
-- No policies: only the definer functions below touch it.

-- Every invoice that already exists has already been deducted by the old
-- client-side path. Mark them all, so none can be deducted a second time.
insert into public.invoice_stock_deductions (line, invoice_id)
select 'main', id from public.invoices
on conflict do nothing;
insert into public.invoice_stock_deductions (line, invoice_id)
select 'dahua', id from public.dahua_invoices
on conflict do nothing;

-- ── 5. Main invoice → STORE STOCK ─────────────────────────────
-- The lines are read from invoice_items, with the model taken from the
-- catalogue product when the line was picked from it — exactly what the
-- invoice form used to send. The actual deduction reuses deduct_store_stock.
create or replace function public.deduct_invoice_store_stock(p_invoice_id uuid)
returns table (model text, requested integer, available integer, tracked boolean)
language plpgsql security definer set search_path = public as $$
-- The OUT column `model` would otherwise clash with the model columns below.
#variable_conflict use_column
declare
  v_owner uuid;
  v_items jsonb;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to adjust stock';
  end if;

  select created_by into v_owner from public.invoices where id = p_invoice_id;
  if not found then
    raise exception 'No such invoice';
  end if;
  if not (select public.is_superboss()) and v_owner is distinct from auth.uid() then
    raise exception 'Only the cashier who made this invoice can deduct its stock';
  end if;

  begin
    insert into public.invoice_stock_deductions (line, invoice_id, deducted_by)
    values ('main', p_invoice_id, auth.uid());
  exception when unique_violation then
    raise exception 'Stock for this invoice has already been deducted';
  end;

  select coalesce(jsonb_agg(jsonb_build_object('model', m.model, 'quantity', m.qty)), '[]'::jsonb)
    into v_items
    from (
      select min(x.model) as model, sum(x.quantity)::integer as qty
        from (
          select btrim(coalesce(nullif(btrim(p.model_number), ''), i.description)) as model, i.quantity
            from public.invoice_items i
            left join public.products p on p.id = i.product_id
           where i.invoice_id = p_invoice_id and i.quantity > 0
        ) x
       where x.model <> ''
       group by upper(x.model)
    ) m;

  return query select * from public.deduct_store_stock(v_items, 'STORE STOCK');
end $$;

-- ── 6. Dahua invoice → the stock rows its lines were picked from ──
-- Returns how many lines were deducted, as the form reports it.
create or replace function public.dahua_deduct_invoice_stock(p_invoice_id uuid)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_owner uuid;
  v_line  record;
  v_count integer := 0;
begin
  if not ((select public.is_superboss()) or (select public.is_cashier())) then
    raise exception 'Not allowed to adjust stock';
  end if;

  select created_by into v_owner from public.dahua_invoices where id = p_invoice_id;
  if not found then
    raise exception 'No such invoice';
  end if;
  if not (select public.is_superboss()) and v_owner is distinct from auth.uid() then
    raise exception 'Only the cashier who made this invoice can deduct its stock';
  end if;

  begin
    insert into public.invoice_stock_deductions (line, invoice_id, deducted_by)
    values ('dahua', p_invoice_id, auth.uid());
  exception when unique_violation then
    raise exception 'Stock for this invoice has already been deducted';
  end;

  for v_line in
    select i.stock_id, i.quantity
      from public.dahua_invoice_items i
      join public.dahua_stock s on s.id = i.stock_id
     where i.invoice_id = p_invoice_id and i.quantity > 0
     order by i.position
  loop
    update public.dahua_stock
       set invoice_taken = coalesce(invoice_taken, 0) + v_line.quantity
     where id = v_line.stock_id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end $$;

-- ── 7. Who may call what ──────────────────────────────────────
-- Functions are executable by PUBLIC unless revoked, so revoke first.
revoke all on function public.scan_adjust_stock(boolean, uuid, text, integer)         from public, anon;
revoke all on function public.scan_add_stock_row(boolean, text, text, integer, integer) from public, anon;
revoke all on function public.deduct_invoice_store_stock(uuid)                          from public, anon;
revoke all on function public.dahua_deduct_invoice_stock(uuid)                          from public, anon;
grant execute on function public.scan_adjust_stock(boolean, uuid, text, integer)         to authenticated;
grant execute on function public.scan_add_stock_row(boolean, text, text, integer, integer) to authenticated;
grant execute on function public.deduct_invoice_store_stock(uuid)                          to authenticated;
grant execute on function public.dahua_deduct_invoice_stock(uuid)                          to authenticated;

-- The free-list deduction is now internal: reachable only through
-- deduct_invoice_store_stock above.
revoke all on function public.deduct_store_stock(jsonb, text) from public, anon, authenticated;

commit;

-- ── Verification (run after committing) ───────────────────────
-- Exactly these six policies should be listed, and no others:
--
-- select tablename, policyname, cmd from pg_policies
--  where schemaname = 'public'
--    and tablename in ('warehouse_stock', 'dahua_stock', 'warehouses')
--  order by 1, 2;
--
-- As a cashier, a direct write must now fail (0 rows updated, or an error):
--
-- update public.warehouse_stock set opening_stock = opening_stock + 1
--  where warehouse = 'STORE STOCK';
