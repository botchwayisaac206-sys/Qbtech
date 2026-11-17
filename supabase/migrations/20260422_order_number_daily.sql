-- ============================================================================
-- Per-day auto-incrementing order number for invoices.
-- Format: ORD-YYYYMMDD-NNN  (NNN resets to 001 each new day)
-- Safe to run multiple times.
-- ============================================================================

create or replace function public.next_order_number() returns text
language plpgsql security definer set search_path = public as $$
declare
  d   text := to_char((now() at time zone 'UTC')::date, 'YYYYMMDD');
  cnt int;
begin
  select count(*) + 1 into cnt
    from public.invoices
    where to_char((issued_at at time zone 'UTC')::date, 'YYYYMMDD') = d;
  return 'ORD-' || d || '-' || lpad(cnt::text, 3, '0');
end $$;

grant execute on function public.next_order_number() to authenticated;
