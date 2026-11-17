-- ============================================================================
-- Performance: collapse the last-sold-price lookup into the database.
--
-- fetchLastSoldPrices() was pulling every invoice_items row (9,029 at the time
-- of writing) WITH an embedded invoices(issued_at) join, purely to reduce them
-- client-side to "most recent unit price per description". That is a second
-- full scan of the largest table on every sign-in, on top of the one
-- fetchInvoiceItems() already does.
--
-- There are only 2,383 distinct descriptions behind those 9,029 rows, so doing
-- the reduction in Postgres cuts the payload ~3.8x and drops the request from
-- 10 sequential pages to 3.
--
-- security_invoker keeps row-level security applying to the CALLER — without
-- it the view would run with the owner's rights and hand every role the full
-- price history regardless of the invoice policies.
-- ============================================================================

create or replace view public.last_sold_prices
with (security_invoker = on) as
select distinct on (lower(btrim(ii.description)))
       lower(btrim(ii.description)) as key,
       btrim(ii.description)        as description,
       ii.unit_price                as price,
       i.issued_at                  as issued_at
  from public.invoice_items ii
  join public.invoices i on i.id = ii.invoice_id
 where ii.description is not null
   and btrim(ii.description) <> ''
 order by lower(btrim(ii.description)), i.issued_at desc, ii.id desc;

-- Supports both the DISTINCT ON ordering above and the invoice_items -> invoices
-- join that every dashboard query drives through.
create index if not exists invoice_items_desc_idx
  on public.invoice_items (lower(btrim(description)));
create index if not exists invoice_items_invoice_id_idx
  on public.invoice_items (invoice_id);
create index if not exists invoices_issued_at_idx
  on public.invoices (issued_at desc);

-- The 24-hour window predicates added in 20260807_superboss.sql filter on these.
create index if not exists expenses_incurred_at_idx
  on public.expenses (incurred_at desc);
create index if not exists deliveries_delivered_at_idx
  on public.deliveries (delivered_at desc);
