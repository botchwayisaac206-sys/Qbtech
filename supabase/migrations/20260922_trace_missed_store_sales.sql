-- ─────────────────────────────────────────────────────────────
-- Trace sales that never came off STORE STOCK — 2026-09-22
--
-- Invoices were written for items the shop floor does hold, but the stock
-- did not move, because the model had not been counted in yet: there was
-- no row to deduct from, so deduct_store_stock() reported it untracked and
-- carried on. Those models exist now, and the sales are still sitting in
-- the invoices with nothing on the stock side to match them.
--
-- WHY THE EXISTING RESYNC DOES NOT CATCH THEM
--   resync_store_invoice_taken() only counts invoices issued AFTER a
--   model's row was created, because opening_stock is a count taken at a
--   moment in time and anything sold before that moment is already
--   reflected on the shelf. That holds for the first count, which was
--   entered the day it was taken. It does NOT hold for the fourth and
--   fifth counts: those sheets were written days before the rows were
--   created, so every sale in between falls in the gap — counted on the
--   sheet as still present, and never deducted afterwards.
--
--   The fix is a cutoff the shop chooses rather than one inferred from
--   created_at. That is what p_since is for, on both functions here.
--
-- This file adds two REPORTS and one option. It changes no stock by
-- itself: trace_store_sales() is read-only, and the resync still only
-- writes when told to.
--
-- Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────

-- ── 1. What does not add up, by model ─────────────────────────
-- p_since null means "every invoice ever". Pass a date to limit it to the
-- period the counts actually describe.
create or replace function public.trace_store_sales(
  p_since timestamptz default null,
  p_store text default 'STORE STOCK'
) returns table (
  model      text,
  counted_at timestamptz,
  invoiced   integer,
  deducted   integer,
  missed     integer,
  first_sale timestamptz,
  last_sale  timestamptz,
  on_hand    integer
)
language sql
stable
security definer
set search_path = public
as $$
  select s.model,
         s.created_at,
         coalesce(x.units, 0)::integer,
         coalesce(s.invoice_taken, 0),
         (coalesce(x.units, 0) - coalesce(s.invoice_taken, 0))::integer,
         x.first_sale,
         x.last_sale,
         s.closing_stock
    from public.warehouse_stock s
    left join lateral (
      select sum(ii.quantity)::integer as units,
             min(i.issued_at)          as first_sale,
             max(i.issued_at)          as last_sale
        from public.invoice_items ii
        join public.invoices i on i.id = ii.invoice_id
       where (p_since is null or i.issued_at >= p_since)
         and (
           -- Typed, autocompleted or scanned: the description IS the model.
           upper(btrim(ii.description)) = upper(btrim(s.model))
           -- Picked from the catalogue: "Title — MODEL". Compared from the
           -- right rather than with LIKE, so a model containing % or _
           -- cannot turn into a wildcard.
           or right(upper(btrim(ii.description)),
                    length(' — ' || upper(btrim(s.model))))
              = ' — ' || upper(btrim(s.model))
         )
    ) x on true
   where s.warehouse = p_store
     and coalesce(x.units, 0) <> coalesce(s.invoice_taken, 0)
   order by (coalesce(x.units, 0) - coalesce(s.invoice_taken, 0)) desc, s.model
$$;

-- ── 2. The actual sales behind one model ──────────────────────
-- For when a number looks wrong and you want the invoices, the dates and
-- the customers rather than a total.
create or replace function public.trace_store_sales_detail(
  p_model text,
  p_since timestamptz default null
) returns table (
  invoice_number text,
  issued_at      timestamptz,
  customer_name  text,
  description    text,
  quantity       numeric,
  unit_price     numeric
)
language sql
stable
security definer
set search_path = public
as $$
  select i.invoice_number, i.issued_at, i.customer_name,
         ii.description, ii.quantity, ii.unit_price
    from public.invoice_items ii
    join public.invoices i on i.id = ii.invoice_id
   where (p_since is null or i.issued_at >= p_since)
     and (
       upper(btrim(ii.description)) = upper(btrim(p_model))
       or right(upper(btrim(ii.description)),
                length(' — ' || upper(btrim(p_model))))
          = ' — ' || upper(btrim(p_model))
     )
   order by i.issued_at desc
$$;

-- ── 3. The resync can be given an explicit cutoff ─────────────
-- Dropped rather than overloaded: a variant differing only by a trailing
-- argument would make every existing call ambiguous.
drop function if exists public.resync_store_invoice_taken(boolean, text);

create or replace function public.resync_store_invoice_taken(
  p_apply boolean default false,
  p_store text default 'STORE STOCK',
  p_since timestamptz default null
) returns table (
  model      text,
  counted_at timestamptz,
  was        integer,
  should_be  integer,
  difference integer
)
language plpgsql
security definer
set search_path = public
as $$
begin
  -- A session with no JWT is the SQL editor, psql or the service role, not
  -- an app user — those bypass RLS anyway, and refusing them here would
  -- block the very console this is meant to be run from.
  if (select auth.uid()) is not null and not (select public.is_superboss()) then
    raise exception 'Only the Big Boss may rebuild stock figures'
      using errcode = '42501';
  end if;

  return query
  with figures as (
    select
      s.id,
      s.model,
      s.created_at,
      coalesce(s.invoice_taken, 0) as was,
      coalesce((
        select sum(ii.quantity)::integer
          from public.invoice_items ii
          join public.invoices i on i.id = ii.invoice_id
         -- With no cutoff given, fall back to the row's own creation date:
         -- a count taken the day it was entered already reflects everything
         -- sold before it. Pass p_since where that is not true.
         where i.issued_at > coalesce(p_since, s.created_at)
           and (
             upper(btrim(ii.description)) = upper(btrim(s.model))
             or right(upper(btrim(ii.description)),
                      length(' — ' || upper(btrim(s.model))))
                = ' — ' || upper(btrim(s.model))
           )
      ), 0) as should_be
    from public.warehouse_stock s
    where s.warehouse = p_store
  ),
  changed as (
    select * from figures f where f.was is distinct from f.should_be
  ),
  -- A data-modifying CTE always runs to completion, whether or not the
  -- outer query reads it.
  applied as (
    update public.warehouse_stock w
       set invoice_taken = c.should_be
      from changed c
     where w.id = c.id
       and p_apply
    returning w.id
  )
  select c.model, c.created_at, c.was, c.should_be, c.should_be - c.was
    from changed c
   order by abs(c.should_be - c.was) desc, c.model;
end $$;

grant execute on function public.trace_store_sales(timestamptz, text)              to authenticated;
grant execute on function public.trace_store_sales_detail(text, timestamptz)       to authenticated;
grant execute on function public.resync_store_invoice_taken(boolean, text, timestamptz) to authenticated;

-- ── How to use this ───────────────────────────────────────────
-- 1. See what does not add up. Read-only:
--
--    select * from public.trace_store_sales();
--
--    `missed` is units invoiced that the stock never lost. A NEGATIVE
--    missed means the opposite — deducted more than the invoices show,
--    which usually means a sale was deleted after the stock came off.
--
-- 2. Look at one of them properly:
--
--    select * from public.trace_store_sales_detail('DS-2CD1123G2-LIU');
--
--    Check the dates against when that stock was physically counted. Sales
--    from BEFORE the count are already reflected in opening_stock and must
--    not be deducted again; sales after it must.
--
-- 3. Once the cutoff is clear, preview the correction:
--
--    select * from public.resync_store_invoice_taken(false, 'STORE STOCK',
--                                                    timestamptz '2026-09-15');
--
-- 4. Apply the same thing:
--
--    select * from public.resync_store_invoice_taken(true, 'STORE STOCK',
--                                                    timestamptz '2026-09-15');
--
--    Absolute, not additive, so it can be re-run and cannot double.
