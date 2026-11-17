-- ============================================================================
-- Add daily-quantity "sections" to Dahua warehouses, mirroring the main
-- warehouse stock tab. Each section (e.g. a new month) keeps its own day
-- values; in dahua_stock.daily_taken the keys are namespaced as
-- "sectionIdx:day" (legacy bare keys = section 0), so months don't collide.
--
-- Safe to run multiple times.
-- ============================================================================

alter table public.dahua_warehouses
  add column if not exists section_labels text[] not null default '{}';
