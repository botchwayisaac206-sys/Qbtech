-- ─────────────────────────────────────────────────────────────
-- A delivered sale is logged at the invoice's amount — 2026-10-10
--
-- WHAT WENT WRONG
--   The Delivery switch on the invoice (0357b25) logged the delivery with a
--   separate "delivery fee", which staff left blank. So every delivery
--   switched on from an invoice was saved at GH₵ 0 — 7 in the main shop and
--   6 in Dahua by 2026-10-10 — and the Deliveries tab showed nothing against
--   them. Meanwhile the invoice itself went on being counted as an ordinary
--   sale, so the Sales page could not tell a delivery from a counter sale.
--
-- WHAT IS RIGHT
--   A sale with Delivery switched on IS a delivery: one sale, saved as an
--   invoice (the receipt) and as a delivery carrying the invoice's total and
--   payment method. The app now writes it that way, and the Sales page
--   counts it under Delivery and leaves its invoice out of ordinary sales.
--
-- THIS FILE
--   Brings the deliveries already logged at 0 up to their invoice's total
--   and payment method. Only rows that came from an invoice and still stand
--   at 0 are touched; a delivery typed by hand in the Deliveries tab has no
--   invoice and is left exactly as it is.
--
-- Requires 20261007_delivery_from_invoice.sql. Idempotent: a row already
-- carrying an amount is skipped.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'deliveries' and column_name = 'invoice_number'
  ) then
    raise exception 'Run 20261007_delivery_from_invoice.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

update public.deliveries d
   set amount         = i.total,
       payment_method = coalesce(nullif(btrim(i.payment_method), ''), d.payment_method)
  from public.invoices i
 where d.invoice_number = i.invoice_number
   and coalesce(d.amount, 0) = 0
   and coalesce(i.total, 0) > 0;

update public.dahua_deliveries d
   set amount         = i.total,
       payment_method = coalesce(nullif(btrim(i.payment_method), ''), d.payment_method)
  from public.dahua_invoices i
 where d.invoice_number = i.invoice_number
   and coalesce(d.amount, 0) = 0
   and coalesce(i.total, 0) > 0;

-- ── Verification ──────────────────────────────────────────────
-- Deliveries from invoices beside their invoice — the two amounts should
-- match on every row:
--
-- select d.invoice_number, d.customer_name, d.amount as delivery_amount, i.total as invoice_total, d.payment_method
--   from public.deliveries d
--   join public.invoices i on i.invoice_number = d.invoice_number
--  order by d.delivered_at desc;
