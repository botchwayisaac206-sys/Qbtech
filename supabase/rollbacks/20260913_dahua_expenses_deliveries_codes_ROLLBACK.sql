-- ─────────────────────────────────────────────────────────────
-- ROLLBACK for 20260913_dahua_expenses_deliveries_codes.sql
--
-- Removes the Dahua activity-log triggers. The three tables are KEPT by
-- default — dropping them deletes every Dahua expense, delivery and barcode
-- link that staff have entered. Uncomment step 2 only if you genuinely want
-- the tables and their data gone.
--
-- Rows already written to audit_log stay there.
--
-- Run once, in the Supabase SQL editor, as the Big Boss.
-- ─────────────────────────────────────────────────────────────

begin;

-- ── 1. Triggers ───────────────────────────────────────────────
drop trigger if exists trg_audit_dahua_expenses      on public.dahua_expenses;
drop trigger if exists trg_audit_dahua_deliveries    on public.dahua_deliveries;
drop trigger if exists trg_audit_dahua_product_codes on public.dahua_product_codes;
drop trigger if exists trg_audit_dahua_stock         on public.dahua_stock;
drop trigger if exists trg_audit_dahua_invoices      on public.dahua_invoices;
drop trigger if exists trg_audit_dahua_invoices_upd  on public.dahua_invoices;

-- ── 2. Tables (DESTROYS DATA) ─────────────────────────────────
-- drop table if exists public.dahua_expenses;
-- drop table if exists public.dahua_deliveries;
-- drop table if exists public.dahua_product_codes;

commit;
