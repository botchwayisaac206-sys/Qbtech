-- ─────────────────────────────────────────────────────────────
-- The Big Boss's switch: may staff invoice what is not in stock? — 2026-10-25
--
-- The invoice forms refuse a stocked product the shop does not have
-- ("no stock, no sale"). Some days the Big Boss wants a sale to go through
-- anyway — the goods are on their way, or the count is known to be behind.
-- This is his switch for that, on the same one-row settings table as
-- auto-accept. Off (the default) keeps the rule. On, the invoice forms warn
-- and let the sale through, and the stock goes below zero, as it did before
-- the rule.
--
-- He flips it by right-clicking the New Invoice tab, in either portal. One
-- switch covers both the main shop and Dahua.
--
-- Requires 20261023_stock_approval_everywhere.sql. Idempotent.
-- ─────────────────────────────────────────────────────────────

do $$
begin
  if to_regclass('public.stock_approval_settings') is null then
    raise exception 'Run 20261023_stock_approval_everywhere.sql first — this file builds on it.'
      using errcode = '42P01';
  end if;
end $$;

alter table public.stock_approval_settings
  add column if not exists allow_no_stock_sales boolean not null default false;

create or replace function public.set_no_stock_sales(p_on boolean)
returns public.stock_approval_settings
language plpgsql security definer set search_path = public as $$
declare
  v_row public.stock_approval_settings;
begin
  if not (select public.is_superboss()) then
    raise exception 'Only the Big Boss can change this';
  end if;
  update public.stock_approval_settings
     set allow_no_stock_sales = coalesce(p_on, false), updated_at = now(), updated_by = auth.uid()
   where id = 1
  returning * into v_row;
  return v_row;
end $$;

revoke all on function public.set_no_stock_sales(boolean) from public, anon;
grant execute on function public.set_no_stock_sales(boolean) to authenticated;

notify pgrst, 'reload schema';

-- ── Verification ──────────────────────────────────────────────
-- select auto_accept, allow_no_stock_sales from public.stock_approval_settings;
