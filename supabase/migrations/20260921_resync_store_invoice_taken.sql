-- ─────────────────────────────────────────────────────────────
-- Rebuild STORE STOCK's sold figures from the invoices — 2026-09-21
--
-- Sales were made that never came off the shelf. Three ways that happened,
-- all of them quiet:
--
--   * the line was picked from the product catalogue, so its description
--     read "Title — MODEL" and matched no stock row at all;
--   * the spelling differed in case or spacing from the stock row, because
--     the deduction matched with a plain `=` (fixed in
--     20260921_deduct_store_stock_match.sql);
--   * the model had not been counted into STORE STOCK yet, so there was no
--     row to take it off.
--
-- WHY THIS RECOMPUTES RATHER THAN ADDS
--   Some sales DID deduct. Adding the missing ones would mean knowing
--   exactly which, and nothing on invoice_items records whether stock was
--   taken — so any "add the difference" approach risks double-counting the
--   ones that worked. Instead invoice_taken is derived from scratch: it is
--   simply what the invoices say was sold. That is idempotent, self-
--   correcting, and safe to run again whenever a figure looks wrong.
--
-- WHICH SALES COUNT
--   Only invoices issued AFTER a model's row was created — that is, after
--   it was physically counted. opening_stock is a count taken at a moment
--   in time, so anything sold before that moment is already reflected in
--   the number on the shelf. Counting it again would deduct it twice.
--   This is per model, so a model added in the second or third count uses
--   its own date, not the store's.
--
-- WHAT IT DOES NOT TOUCH
--   opening_stock, transfer_in, transfer_out and daily_taken are left
--   alone. Only invoice_taken is rebuilt, and the derive trigger then
--   recomputes closing_stock from it.
--
-- HOW TO RUN IT
--   Preview first — this writes nothing:
--     select * from public.resync_store_invoice_taken();
--   Then apply:
--     select * from public.resync_store_invoice_taken(true);
--   Both return the same rows, so what you previewed is what you get.
--
-- Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────

create or replace function public.resync_store_invoice_taken(
  p_apply boolean default false,
  p_store text default 'STORE STOCK'
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
  -- block the very console this is meant to be run from. The check still
  -- binds every request arriving through the app.
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
         where i.issued_at > s.created_at
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

grant execute on function public.resync_store_invoice_taken(boolean, text) to authenticated;

-- ── After applying ────────────────────────────────────────────
-- What the shop floor has sold, and what is left:
--
-- select model, opening_stock, transfer_in, invoice_taken, closing_stock
--   from public.warehouse_stock
--  where warehouse = 'STORE STOCK' and invoice_taken > 0
--  order by invoice_taken desc;
--
-- Anything now showing negative — sold more than was ever counted in, which
-- means the count missed some or the sale was of a model spelled differently:
--
-- select model, opening_stock, transfer_in, invoice_taken, closing_stock
--   from public.warehouse_stock
--  where warehouse = 'STORE STOCK' and closing_stock < 0
--  order by closing_stock;
--
-- Invoiced lines that STILL match no store row, i.e. sales the shop floor
-- has no record of stocking at all:
--
-- select upper(btrim(ii.description)) as description, sum(ii.quantity) as units
--   from public.invoice_items ii
--   join public.invoices i on i.id = ii.invoice_id
--  where i.issued_at > (select min(created_at) from public.warehouse_stock
--                        where warehouse = 'STORE STOCK')
--    and not exists (
--          select 1 from public.warehouse_stock s
--           where s.warehouse = 'STORE STOCK'
--             and (upper(btrim(s.model)) = upper(btrim(ii.description))
--               or right(upper(btrim(ii.description)),
--                        length(' — ' || upper(btrim(s.model))))
--                  = ' — ' || upper(btrim(s.model))))
--  group by 1 order by units desc;
