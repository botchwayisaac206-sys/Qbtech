-- ─────────────────────────────────────────────────────────────
-- Deliveries logged from the invoice — 2026-10-07
--
-- A sale that is being delivered used to be entered twice: as an invoice,
-- then again in the Deliveries tab. The invoice forms now have a Delivery
-- switch that logs the delivery when the invoice is saved, so the Deliveries
-- tab is the list of them rather than a second form.
--
-- Two things a delivery logged that way knows that the table had no place
-- for: the customer's phone number, and which invoice it belongs to.
--
-- Until this is run the app still logs the delivery — it puts those two in
-- the note instead. Running this gives them columns of their own, which is
-- what lets the Deliveries tab show and search them properly.
--
-- Idempotent. Nothing existing is changed.
-- ─────────────────────────────────────────────────────────────

alter table public.deliveries
  add column if not exists customer_num   text,
  add column if not exists invoice_number text;

alter table public.dahua_deliveries
  add column if not exists customer_num   text,
  add column if not exists invoice_number text;

comment on column public.deliveries.customer_num is
  'The customer''s phone number, copied from the invoice when the delivery was switched on there.';
comment on column public.deliveries.invoice_number is
  'The invoice this delivery was logged from. Null when it was entered by hand in the Deliveries tab.';
comment on column public.dahua_deliveries.customer_num is
  'The customer''s phone number, copied from the invoice when the delivery was switched on there.';
comment on column public.dahua_deliveries.invoice_number is
  'The Dahua invoice this delivery was logged from. Null when it was entered by hand in the Deliveries tab.';

-- Finding the delivery for an invoice.
create index if not exists deliveries_invoice_number_idx
  on public.deliveries (invoice_number) where invoice_number is not null;
create index if not exists dahua_deliveries_invoice_number_idx
  on public.dahua_deliveries (invoice_number) where invoice_number is not null;

-- PostgREST keeps a copy of the table layout; tell it the columns exist now,
-- or the app would keep using the note for a while longer.
notify pgrst, 'reload schema';

-- ── Verification ──────────────────────────────────────────────
-- Deliveries logged from invoices, newest first:
--
-- select delivered_at, invoice_number, customer_name, customer_num, location, amount, payment_method
--   from public.deliveries
--  where invoice_number is not null
--  order by delivered_at desc
--  limit 50;
