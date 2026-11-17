-- ============================================================================
-- QBNET TECH — "Big Boss" (superboss) role
--
-- Introduces a tier ABOVE the existing boss/admin:
--
--   superboss      Big Boss. Everything boss/admin could do before this
--                  migration, unrestricted.
--   boss / admin   Same tabs and same UI as before, but read-only and clamped
--                  to a rolling 24-hour window. No invoice list, no staff
--                  creation, no writes of any kind.
--   cashier        Unchanged.
--
-- Enforcement lives here, in RLS — not just in the React gates. A restricted
-- boss with the anon key and a REST client gets exactly the same answers the
-- UI shows them.
--
-- Idempotent: safe to re-run.
--
-- PERFORMANCE NOTE — why every predicate below reads `(select public.is_x())`
-- rather than `public.is_x()`:
--
-- These are SECURITY DEFINER functions, so Postgres will not inline them. Called
-- bare in a policy they are re-evaluated ONCE PER ROW — across invoice_items
-- (9,029 rows) that is 9,029 extra function calls, each doing its own lookup
-- against user_roles, on every single query. Wrapping the call in a scalar
-- subquery lets the planner hoist it into an InitPlan that runs exactly once per
-- query and is then reused. Same reason auth.uid() is wrapped. This is the
-- documented Supabase RLS pattern and the difference is large at these row
-- counts — do not "simplify" the parentheses away.
-- ============================================================================

-- ──────────────────────────────────────────────────────────────────────────
-- 1. ROLE VOCABULARY
-- ──────────────────────────────────────────────────────────────────────────
alter table public.user_roles drop constraint if exists user_roles_role_check;
alter table public.user_roles add  constraint user_roles_role_check
  check (role in ('superboss','boss','admin','cashier'));

-- is_boss() keeps its original meaning — "has boss-level reach" — and now
-- includes superboss. Every pre-existing policy that calls it therefore grants
-- the Big Boss at least what the old boss had. Restrictions are applied by
-- explicitly REPLACING the sensitive policies further down.
create or replace function public.is_boss() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.current_role() in ('superboss','boss','admin'), false)
$$;

-- Unrestricted top tier.
create or replace function public.is_superboss() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.current_role() = 'superboss', false)
$$;

-- Demoted boss/admin: boss-shaped UI, read-only, 24-hour window.
create or replace function public.is_restricted_boss() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.current_role() in ('boss','admin'), false)
$$;

create or replace function public.is_cashier() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.current_role() = 'cashier', false)
$$;

-- The rolling visibility window for a restricted boss.
create or replace function public.window_start() returns timestamptz
language sql stable set search_path = public as $$
  select now() - interval '24 hours'
$$;

-- ──────────────────────────────────────────────────────────────────────────
-- 2. USER ROLES — only the Big Boss may write
--
-- This is the keystone. Left as is_boss(), a restricted boss could simply
-- UPDATE their own row to 'superboss' and undo everything below.
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists ur_self_read  on public.user_roles;
create policy ur_self_read on public.user_roles for select
  using ((select auth.uid()) = user_id or (select public.is_boss()));

drop policy if exists ur_boss_write on public.user_roles;
drop policy if exists ur_superboss_write on public.user_roles;
create policy ur_superboss_write on public.user_roles for all
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

-- ──────────────────────────────────────────────────────────────────────────
-- 3. INVOICES
--   read   superboss: all · restricted boss: last 24h only · cashier: own
--   write  superboss, plus cashier inserting their own
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists inv_read on public.invoices;
create policy inv_read on public.invoices for select
  using (
    (select public.is_superboss())
    or ((select public.is_restricted_boss()) and issued_at >= (select public.window_start()))
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists inv_insert on public.invoices;
create policy inv_insert on public.invoices for insert
  with check (
    (select public.is_superboss())
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists inv_update on public.invoices;
create policy inv_update on public.invoices for update
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists inv_delete on public.invoices;
create policy inv_delete on public.invoices for delete
  using ((select public.is_superboss()));

-- invoice_items follow their parent invoice's visibility exactly.
drop policy if exists inv_items_read on public.invoice_items;
create policy inv_items_read on public.invoice_items for select
  using (exists (
    select 1 from public.invoices i
    where i.id = invoice_id and (
      (select public.is_superboss())
      or ((select public.is_restricted_boss()) and i.issued_at >= (select public.window_start()))
      or ((select public.is_cashier()) and i.created_by = (select auth.uid()))
    )));

drop policy if exists inv_items_write on public.invoice_items;
create policy inv_items_write on public.invoice_items for all
  using (exists (
    select 1 from public.invoices i
    where i.id = invoice_id
      and ((select public.is_superboss()) or ((select public.is_cashier()) and i.created_by = (select auth.uid())))))
  with check (exists (
    select 1 from public.invoices i
    where i.id = invoice_id
      and ((select public.is_superboss()) or ((select public.is_cashier()) and i.created_by = (select auth.uid())))));

-- ──────────────────────────────────────────────────────────────────────────
-- 4. EXPENSES — replaces exp_boss / exp_cashier_* (policies OR together, so
--    the old permissive ones must be dropped, not merely shadowed)
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists exp_boss              on public.expenses;
drop policy if exists exp_cashier_insert    on public.expenses;
drop policy if exists exp_cashier_select_own on public.expenses;

drop policy if exists exp_read on public.expenses;
create policy exp_read on public.expenses for select
  using (
    (select public.is_superboss())
    or ((select public.is_restricted_boss()) and incurred_at >= (select public.window_start()))
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists exp_insert on public.expenses;
create policy exp_insert on public.expenses for insert
  with check (
    (select public.is_superboss())
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists exp_modify on public.expenses;
create policy exp_modify on public.expenses for update
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists exp_delete on public.expenses;
create policy exp_delete on public.expenses for delete
  using ((select public.is_superboss()));

-- ──────────────────────────────────────────────────────────────────────────
-- 5. DELIVERIES
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists del_read on public.deliveries;
create policy del_read on public.deliveries for select
  using (
    (select public.is_superboss())
    or ((select public.is_restricted_boss()) and delivered_at >= (select public.window_start()))
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists del_insert on public.deliveries;
create policy del_insert on public.deliveries for insert
  with check (
    (select public.is_superboss())
    or ((select public.is_cashier()) and created_by = (select auth.uid()))
  );

drop policy if exists del_update on public.deliveries;
create policy del_update on public.deliveries for update
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists del_delete on public.deliveries;
create policy del_delete on public.deliveries for delete
  using ((select public.is_superboss()));

-- ──────────────────────────────────────────────────────────────────────────
-- 6. AUDIT LOG — Big Boss only. The restricted boss must not be able to read
--    the trail that would show the role change itself.
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists audit_boss_read on public.audit_log;
drop policy if exists audit_superboss_read on public.audit_log;
create policy audit_superboss_read on public.audit_log for select
  using ((select public.is_superboss()));

-- ──────────────────────────────────────────────────────────────────────────
-- 7. WATCHES
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists pw_boss on public.product_watches;
drop policy if exists pw_superboss on public.product_watches;
create policy pw_superboss on public.product_watches for all
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists wa_boss on public.watch_alerts;
drop policy if exists wa_superboss on public.watch_alerts;
create policy wa_superboss on public.watch_alerts for all
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

-- ──────────────────────────────────────────────────────────────────────────
-- 8. PRICELIST — these inlined role lists would otherwise LOCK OUT the
--    superboss, since 'superboss' is not in ('boss','admin').
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists "write pricelist_categories" on public.pricelist_categories;
create policy "write pricelist_categories" on public.pricelist_categories
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists "write pricelist_items" on public.pricelist_items;
create policy "write pricelist_items" on public.pricelist_items
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

-- ──────────────────────────────────────────────────────────────────────────
-- 9. DAHUA — same inlined-role-list problem, plus the restricted boss must
--    lose write access and lose invoice visibility beyond the window.
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists "boss write dahua_warehouses" on public.dahua_warehouses;
create policy "boss write dahua_warehouses" on public.dahua_warehouses
  for all to authenticated
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

drop policy if exists "boss insert dahua_stock" on public.dahua_stock;
create policy "boss insert dahua_stock" on public.dahua_stock
  for insert to authenticated with check ((select public.is_superboss()));

drop policy if exists "boss delete dahua_stock" on public.dahua_stock;
create policy "boss delete dahua_stock" on public.dahua_stock
  for delete to authenticated using ((select public.is_superboss()));

-- Stock UPDATE stays open to cashiers (invoice save deducts quantities), but
-- the restricted boss is excluded so their view is genuinely read-only.
drop policy if exists "staff update dahua_stock" on public.dahua_stock;
create policy "staff update dahua_stock" on public.dahua_stock
  for update to authenticated
  using ((select public.is_superboss()) or (select public.is_cashier()))
  with check ((select public.is_superboss()) or (select public.is_cashier()));

drop policy if exists "read dahua_invoices" on public.dahua_invoices;
create policy "read dahua_invoices" on public.dahua_invoices
  for select to authenticated
  using (
    (select public.is_superboss())
    or ((select public.is_restricted_boss()) and issued_at >= (select public.window_start()))
    or (select public.is_cashier())
  );

drop policy if exists "write dahua_invoices" on public.dahua_invoices;
create policy "write dahua_invoices" on public.dahua_invoices
  for insert to authenticated
  with check ((select public.is_superboss()) or (select public.is_cashier()));

drop policy if exists "boss update dahua_invoices" on public.dahua_invoices;
create policy "boss update dahua_invoices" on public.dahua_invoices
  for update to authenticated using ((select public.is_superboss()));

drop policy if exists "boss delete dahua_invoices" on public.dahua_invoices;
create policy "boss delete dahua_invoices" on public.dahua_invoices
  for delete to authenticated using ((select public.is_superboss()));

drop policy if exists "read dahua_invoice_items" on public.dahua_invoice_items;
create policy "read dahua_invoice_items" on public.dahua_invoice_items
  for select to authenticated
  using (exists (
    select 1 from public.dahua_invoices di
    where di.id = invoice_id and (
      (select public.is_superboss())
      or ((select public.is_restricted_boss()) and di.issued_at >= (select public.window_start()))
      or (select public.is_cashier())
    )));

drop policy if exists "write dahua_invoice_items" on public.dahua_invoice_items;
create policy "write dahua_invoice_items" on public.dahua_invoice_items
  for insert to authenticated
  with check ((select public.is_superboss()) or (select public.is_cashier()));

drop policy if exists "boss update dahua_invoice_items" on public.dahua_invoice_items;
create policy "boss update dahua_invoice_items" on public.dahua_invoice_items
  for update to authenticated using ((select public.is_superboss()));

drop policy if exists "boss delete dahua_invoice_items" on public.dahua_invoice_items;
create policy "boss delete dahua_invoice_items" on public.dahua_invoice_items
  for delete to authenticated using ((select public.is_superboss()));

-- ──────────────────────────────────────────────────────────────────────────
-- 10. WAREHOUSE STOCK & PRODUCT CODES — read stays open, writes exclude the
--     restricted boss. (Scanning by cashiers is preserved.)
-- ──────────────────────────────────────────────────────────────────────────
drop policy if exists warehouse_stock_staff_update on public.warehouse_stock;
create policy warehouse_stock_staff_update on public.warehouse_stock
  for update to authenticated
  using ((select public.is_superboss()) or (select public.is_cashier()))
  with check ((select public.is_superboss()) or (select public.is_cashier()));

drop policy if exists "write product_codes" on public.product_codes;
create policy "write product_codes" on public.product_codes
  for all to authenticated
  using ((select public.is_superboss()) or (select public.is_cashier()))
  with check ((select public.is_superboss()) or (select public.is_cashier()));

-- ──────────────────────────────────────────────────────────────────────────
-- 11. PRODUCTS — catalogue writes are Big-Boss-only.
-- ──────────────────────────────────────────────────────────────────────────
alter table public.products enable row level security;

drop policy if exists products_public_read on public.products;
create policy products_public_read on public.products for select using (true);

drop policy if exists products_superboss_write on public.products;
create policy products_superboss_write on public.products for all
  using ((select public.is_superboss())) with check ((select public.is_superboss()));

-- ──────────────────────────────────────────────────────────────────────────
-- 12. REPORTING VIEW — a plain view runs with the OWNER's rights, which would
--     hand the restricted boss all-time totals straight past inv_read.
--     security_invoker makes it respect the caller's RLS.
-- ──────────────────────────────────────────────────────────────────────────
alter view public.sales_by_day set (security_invoker = on);

-- ──────────────────────────────────────────────────────────────────────────
-- 13. CREATE THE BIG BOSS  ← REQUIRED, DO NOT SKIP
--
-- Until a superboss exists, NOBODY can manage staff or write anything: the
-- restricted boss has lost those rights and no account has gained them yet.
-- Run this in the Supabase SQL editor, which connects as the table owner and
-- so is not blocked by the ur_superboss_write policy above.
--
-- Step 1 — create the login. Supabase Dashboard → Authentication → Users →
--          "Add user", email `bigboss@qbnettech.com`, set a password, and tick
--          "Auto Confirm User". (Any email works; the sign-in form on
--          /teamqtech accepts a bare handle and appends @qbnettech.com, so
--          `bigboss` + password is enough to sign in.)
--
-- Step 2 — grant the role. Uncomment, set the email to match, and run:
--
-- insert into public.user_roles (user_id, role, full_name, staff_id)
-- select id, 'superboss', 'Big Boss', email
--   from auth.users where email = 'bigboss@qbnettech.com'
-- on conflict (user_id) do update set role = 'superboss';
--
-- Step 3 — confirm exactly one superboss exists before signing out:
--
-- select u.email, r.role from public.user_roles r
--   join auth.users u on u.id = r.user_id order by r.role;
--
-- To hand the top tier to an EXISTING account instead of a new one:
-- update public.user_roles set role = 'superboss'
--   where user_id = (select id from auth.users where email = 'you@example.com');
