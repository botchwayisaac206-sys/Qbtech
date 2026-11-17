-- ============================================================================
-- Extensions for staff management + VAT toggle on invoices.
-- Safe to run multiple times.
-- ============================================================================

-- 1. Staff name (shown on the Staff Manager list)
alter table public.user_roles
  add column if not exists full_name text;

-- 2. Optional VAT toggle — invoices already store vat_rate & vat_amount as numeric,
--    so "VAT off" simply means vat_rate = 0 and vat_amount = 0. No new columns needed,
--    but we loosen the constraint on vat_rate just in case:
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='invoices' and column_name='vat_rate'
  ) then
    execute 'alter table public.invoices alter column vat_rate set default 15';
  end if;
end $$;

-- 3. RLS policy: cashier can read own user_roles row already; also allow them
--    to insert expenses they create (boss can read all via existing exp_boss policy).
drop policy if exists exp_cashier_insert on public.expenses;
create policy exp_cashier_insert on public.expenses for insert
  with check (auth.uid() is not null and auth.uid() = created_by);

drop policy if exists exp_cashier_select_own on public.expenses;
create policy exp_cashier_select_own on public.expenses for select
  using (public.is_boss() or created_by = auth.uid());
