/**
 * Joins every migration into supabase/ALL_MIGRATIONS.sql, in dependency order,
 * for a fresh database. Run:  node scripts/build-all-migrations.mjs
 *
 * Files sharing a date are NOT in alphabetical order on purpose: several of
 * them say "Requires X" where X sorts after them.
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'supabase')

const ORDER = [
  '../00_base_tables.sql',
  '20260417_sales_system.sql',
  '20260417_seed_ablekuma_stock.sql',
  '20260421_staff_and_vat.sql',
  '20260422_order_number_daily.sql',
  '20260423_staff_id_email.sql',
  '20260515_pricelist.sql',
  '20260521_dahua_stock.sql',
  '20260522_pricelist_revamp.sql',
  '20260528_warehouse_sections.sql',
  '20260603_deliveries.sql',
  '20260603_server_invoice_numbers.sql',
  '20260604_dahua_section_labels.sql',
  '20260707_product_codes.sql',
  '20260708_scan_staff_access.sql',
  '20260720_audit_deliveries.sql',
  '20260807_superboss.sql',
  '20260807_perf_last_sold.sql',
  '20260810_dahua_stock_recount.sql',
  '20260810_ezviz_pricelist.sql',
  '20260906_dahua_pricing.sql',
  '20260906_dahua_price_list.sql',
  '20260906_dahua_new_products.sql',
  '20260906_dahua_price_override.sql',
  '20260913_dahua_expenses_deliveries_codes.sql',
  '20260920_store_stock_transfers.sql',
  '20260921_deduct_store_stock_match.sql',
  '20260921_store_stock_opening_count.sql',
  '20260921_store_stock_second_count.sql',
  '20260921_store_stock_third_count.sql',
  '20260921_store_stock_fourth_count.sql',
  '20260921_resync_store_invoice_taken.sql',
  '20260921_merge_digital_multimeter.sql',
  '20260921_main_fixed_pricing.sql',
  '20260921_receive_stock_and_signatures.sql',
  '20260922_returns_and_staff_id.sql',
  '20260922_spoilt_location.sql',
  '20260922_movement_history_boss_only.sql',
  '20260922_store_stock_fifth_count.sql',
  '20260922_trace_missed_store_sales.sql',
  '20260930_dahua_transfers.sql',
  '20260930_lock_stock_writes.sql',
  '20261005_cross_line_transfers.sql',
  '20261005_stock_handlers.sql',
  '20261005_no_duplicate_names_on_moves.sql',
  '20261005_merge_product_names.sql',
  '20261005_model_key_keeps_decimals.sql',
  '20261005_uniform_names.sql',
  '20261006_stock_staff_passwords.sql',
  '20261007_delivery_from_invoice.sql',
  '20261007_store_stock_lists_everything.sql',
  '20261010_delivery_is_the_sale.sql',
  '20261011_clear_back_warehouse.sql',
  '20261013_debtors.sql',
  '20261014_fishpong2_tenda_stock.sql',
  '20261017_dahua_movement_approval.sql',
  '20261023_stock_approval_everywhere.sql',
  '20261024_stock_accuracy.sql',
  '20261025_no_stock_sales_switch.sql',
  '20261026_invoice_order_numbers.sql',
  '20261117_suppliers_and_costs.sql',
]

let out = `-- ============================================================================
-- QBNET TECH — ALL MIGRATIONS IN ONE FILE (generated, do not edit by hand)
-- Built by scripts/build-all-migrations.mjs from ${ORDER.length} files.
-- For a FRESH Supabase project: paste into SQL Editor and run once.
-- ============================================================================\n`
for (const f of ORDER) {
  // Precede every CREATE POLICY with a DROP POLICY IF EXISTS so the whole
  // file can be re-run if a first attempt stops partway (three migrations
  // create policies bare). A no-op on a fresh database.
  const sql = readFileSync(resolve(root, 'migrations', f), 'utf8').replace(/^﻿/, '')
    .replace(/^(\s*)create policy\s+("[^"]+"|\w+)\s+on\s+([\w."]+)/gim,
      (m, ind, name, table) => `${ind}drop policy if exists ${name} on ${table};\n${m}`)
  out += `\n\n-- ############################################################################\n-- ## ${f.replace('../', '')}\n-- ############################################################################\n\n${sql.trimEnd()}\n`
}
writeFileSync(resolve(root, 'ALL_MIGRATIONS.sql'), out)
console.log(`wrote supabase/ALL_MIGRATIONS.sql (${ORDER.length} files, ${out.split('\n').length} lines)`)
