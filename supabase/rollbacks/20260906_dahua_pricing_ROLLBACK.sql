-- ─────────────────────────────────────────────────────────────
-- ROLLBACK for 20260906_dahua_pricing.sql
--
-- Drops the three pricing triggers and their functions, returning invoice
-- lines to "whatever price the client sent" and reopening dahua_stock's
-- price column to anyone who can update the table.
--
-- WHAT THIS DOES NOT UNDO
--   * Invoices already saved keep the prices they were written with. Header
--     totals stay as the resync trigger last computed them (they match their
--     own line items, which is correct either way).
--   * dahua_stock.unit_price is KEPT by default — dropping it throws away
--     every price that was entered by hand. Uncomment step 3 only if you
--     genuinely want the column and its data gone.
--
-- Run once, in the Supabase SQL editor, as the Big Boss.
-- ─────────────────────────────────────────────────────────────

begin;

-- ── 1. Triggers ───────────────────────────────────────────────
drop trigger if exists trg_dahua_stock_lock_price      on public.dahua_stock;
drop trigger if exists trg_dahua_item_apply_price      on public.dahua_invoice_items;
drop trigger if exists trg_dahua_invoice_resync_totals on public.dahua_invoice_items;

-- ── 2. Functions ──────────────────────────────────────────────
drop function if exists public.dahua_stock_lock_price();
drop function if exists public.dahua_item_apply_price();
drop function if exists public.dahua_invoice_resync_totals();

-- ── 3. The column itself — DESTRUCTIVE, opt in ────────────────
-- alter table public.dahua_stock drop column if exists unit_price;

-- ── 4. Indexes (harmless to keep; drop only if you want them gone) ──
-- drop index if exists public.dahua_invoices_issued_at_idx;
-- drop index if exists public.dahua_invoice_items_invoice_id_idx;

commit;
