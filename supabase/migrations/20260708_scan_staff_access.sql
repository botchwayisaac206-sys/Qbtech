-- Give staff (cashiers) the ability to record stock via the Scan tab, and log
-- every stock change to the audit trail.
--
-- 1. Audit logging: reuse the existing security-definer fn_audit() trigger
--    (already used on invoices/expenses). Attaching it to warehouse_stock and
--    product_codes records actor_id + actor_role + a row snapshot on every
--    insert/update/delete — so we can see WHO changed stock and WHEN, whether
--    the change came from scanning or manual editing.
--
-- 2. Write access: a permissive policy so any signed-in staff member can save
--    stock counts (previously stock writes were effectively boss-only). This
--    policy is OR'd with any existing policy, so it only widens access and does
--    NOT change whether RLS is enabled on the table.

drop trigger if exists trg_audit_warehouse_stock on public.warehouse_stock;
create trigger trg_audit_warehouse_stock
  after insert or update or delete on public.warehouse_stock
  for each row execute function public.fn_audit();

drop trigger if exists trg_audit_product_codes on public.product_codes;
create trigger trg_audit_product_codes
  after insert or update or delete on public.product_codes
  for each row execute function public.fn_audit();

-- Allow signed-in staff to UPDATE stock (record counts) via scanning. Scoped to
-- UPDATE only — scanning never creates or deletes stock rows (that stays with
-- the boss-only Stock tab), so staff can't accidentally add/remove products.
drop policy if exists warehouse_stock_staff_update on public.warehouse_stock;
create policy warehouse_stock_staff_update on public.warehouse_stock
  for update to authenticated using (true) with check (true);
