-- ============================================================================
-- Server-side, RLS-proof invoice number + order number assignment.
--
-- Bug: cashiers can only SELECT their own invoices (inv_read policy:
--   "public.is_boss() or created_by = auth.uid()"). The old client generated
--   the invoice number in the browser from max(invoice_number)+1, but that
--   query only saw the cashier's own rows -> it kept reusing numbers that
--   already exist (created by other staff, invisible to them) -> 23505
--   duplicate -> "Could not assign invoice number after 5 attempts".
--   The boss (e.g. AISHA) sees all rows, so it worked only for her.
--
-- Fix: assign both numbers in a BEFORE INSERT trigger using SECURITY DEFINER
-- functions, which run as the function owner and bypass RLS (so they see ALL
-- invoices). An advisory lock serializes concurrent inserts so two cashiers
-- can't grab the same number at the same instant.
--
-- Safe to run multiple times.
-- ============================================================================

create or replace function public.next_invoice_number() returns text
language plpgsql security definer set search_path = public as $$
declare
  yr  text := to_char(now(), 'YYYY');
  seq int;
begin
  select coalesce(max((regexp_replace(invoice_number, '^.*-', ''))::int), 0) + 1
    into seq
    from public.invoices
    where invoice_number like 'INV-' || yr || '-%'
      and invoice_number ~ ('^INV-' || yr || '-\d+$');  -- ignore demo / odd formats
  return 'INV-' || yr || '-' || lpad(seq::text, 4, '0');
end $$;

grant execute on function public.next_invoice_number() to authenticated;

create or replace function public.fn_assign_invoice_numbers() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  yr text := to_char(now(), 'YYYY');
begin
  -- Serialize concurrent inserts for this year so numbers never collide.
  perform pg_advisory_xact_lock(hashtext('invoice_seq_' || yr));

  if new.invoice_number is null or new.invoice_number = '' then
    new.invoice_number := public.next_invoice_number();
  end if;

  if new.order_no is null or new.order_no = '' then
    new.order_no := public.next_order_number();
  end if;

  return new;
end $$;

-- Must run BEFORE the existing audit trigger; trigger order is alphabetical,
-- and 'trg_assign...' sorts before 'trg_audit...', so this is fine.
drop trigger if exists trg_assign_invoice_numbers on public.invoices;
create trigger trg_assign_invoice_numbers before insert on public.invoices
  for each row execute function public.fn_assign_invoice_numbers();
