-- ─────────────────────────────────────────────────────────────
-- Order numbers that never repeat — 2026-10-26
--
-- Main shop: next_order_number() counted today's invoices and added one.
-- Delete an invoice (a double-saved one, say) and the count falls, so the
-- next sale is given an order number already printed on another invoice.
-- 219 order numbers had been handed out twice by 2026-10-24. It now takes
-- the highest number issued today and adds one, as invoice numbers do,
-- under the same lock trg_assign_invoice_numbers already holds.
--
-- Dahua: both numbers were worked out in the browser, from a counter read
-- once when the page opened. Two tills, or a page left open, handed out
-- the same order number (the invoice number has a unique rule and was
-- retried; the order number has none). The database now assigns both, in
-- a BEFORE INSERT trigger, and the form prints what it stored. Rows written
-- outside the app (SQL, imports) keep the numbers they bring.
--
-- Numbers already printed are left as they are. Idempotent.
-- ─────────────────────────────────────────────────────────────

-- ── Main shop ────────────────────────────────────────────────
create or replace function public.next_order_number() returns text
language plpgsql security definer set search_path = public as $$
declare
  d   text := to_char((now() at time zone 'UTC')::date, 'YYYYMMDD');
  seq int;
begin
  select coalesce(max((regexp_replace(order_no, '^.*-', ''))::int), 0) + 1
    into seq
    from public.invoices
   where order_no like 'ORD-' || d || '-%'
     and order_no ~ ('^ORD-' || d || '-\d+$');
  return 'ORD-' || d || '-' || lpad(seq::text, 3, '0');
end $$;

grant execute on function public.next_order_number() to authenticated;

-- ── Dahua ────────────────────────────────────────────────────
-- The next numbers, read across every Dahua invoice (security definer: a
-- cashier's own view of the table is narrowed by RLS).
create or replace function public.next_dahua_invoice_number() returns text
language plpgsql security definer set search_path = public as $$
declare
  yr  text := to_char(now(), 'YYYY');
  seq int;
begin
  select coalesce(max((regexp_replace(invoice_number, '^.*-', ''))::int), 0) + 1 into seq
    from public.dahua_invoices
   where invoice_number like 'DH-INV-' || yr || '-%'
     and invoice_number ~ ('^DH-INV-' || yr || '-\d+$');
  return 'DH-INV-' || yr || '-' || lpad(seq::text, 4, '0');
end $$;

create or replace function public.next_dahua_order_number() returns text
language plpgsql security definer set search_path = public as $$
declare
  d   text := to_char((now() at time zone 'UTC')::date, 'YYYYMMDD');
  seq int;
begin
  select coalesce(max((regexp_replace(order_no, '^.*-', ''))::int), 0) + 1 into seq
    from public.dahua_invoices
   where order_no like 'DH-ORD-' || d || '-%'
     and order_no ~ ('^DH-ORD-' || d || '-\d+$');
  return 'DH-ORD-' || d || '-' || lpad(seq::text, 3, '0');
end $$;

grant execute on function public.next_dahua_invoice_number() to authenticated;
grant execute on function public.next_dahua_order_number() to authenticated;

-- Not security definer, so current_user is who is writing: the app
-- (authenticated) always gets the database's numbers; SQL and imports keep
-- theirs unless they leave them blank.
create or replace function public.fn_assign_dahua_invoice_numbers() returns trigger
language plpgsql set search_path = public as $$
declare
  app boolean := current_user in ('authenticated', 'anon');
begin
  -- One Dahua invoice numbered at a time, so two tills never draw the same number.
  perform pg_advisory_xact_lock(hashtext('dahua_invoice_seq'));
  if app or coalesce(new.invoice_number, '') = '' then
    new.invoice_number := public.next_dahua_invoice_number();
  end if;
  if app or coalesce(new.order_no, '') = '' then
    new.order_no := public.next_dahua_order_number();
  end if;
  return new;
end $$;

drop trigger if exists trg_assign_dahua_invoice_numbers on public.dahua_invoices;
create trigger trg_assign_dahua_invoice_numbers before insert on public.dahua_invoices
  for each row execute function public.fn_assign_dahua_invoice_numbers();

notify pgrst, 'reload schema';

-- ── Verification ──────────────────────────────────────────────
-- Order numbers on more than one invoice (all from before this file):
-- select order_no, count(*), string_agg(invoice_number, ', ' order by invoice_number)
--   from public.invoices where order_no is not null
--  group by order_no having count(*) > 1 order by order_no desc;
