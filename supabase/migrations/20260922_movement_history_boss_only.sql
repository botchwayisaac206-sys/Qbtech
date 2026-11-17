-- ─────────────────────────────────────────────────────────────
-- Movement history is boss-only — 2026-09-22
--
-- 20260920_store_stock_transfers.sql let every signed-in user read the
-- whole transfer history, on the reasoning that it is the record staff
-- check when a count looks wrong. In practice it is a running account of
-- what the shop moves, receives, returns and writes off, and that is not
-- counter staff's to browse.
--
-- Cashiers keep the ability to RECORD movements. transfer_stock,
-- receive_stock and return_stock are all SECURITY DEFINER, so they write
-- and return the new row without the caller needing read access to the
-- table — the tab still confirms "TRF-2026-0007 — 12 units moved ✓" after
-- saving, it just no longer lists everything anyone else has done.
--
-- The Transfers tab hides the history panel for the same audience, but that
-- is presentation. This policy is the boundary: without it the rows are
-- still one API call away.
--
-- Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────

drop policy if exists stock_transfers_read on public.stock_transfers;
create policy stock_transfers_read on public.stock_transfers
  for select to authenticated
  using ((select public.is_boss()));

drop policy if exists stock_transfer_items_read on public.stock_transfer_items;
create policy stock_transfer_items_read on public.stock_transfer_items
  for select to authenticated
  using ((select public.is_boss()));

-- ── Verification ──────────────────────────────────────────────
-- As a cashier, this should return nothing; as the boss, the full history:
--
-- select transfer_number, kind, to_warehouse, staff_id, transferred_at
--   from public.stock_transfers order by transferred_at desc limit 10;
--
-- Recording still works for a cashier, because the function is definer:
--
-- select * from public.transfer_stock(
--   'FISHPONG-1', 'STORE STOCK',
--   '[{"model":"DS-2CD1023G2-LIU","quantity":1}]'::jsonb);
