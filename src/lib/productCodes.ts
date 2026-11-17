'use client'

import { supabase } from '@/lib/supabase'
import { fetchAllRows } from '@/lib/adminCache'

// ─────────────────────────────────────────────────────────────
// product_codes: material-code → model lookup (see migration
// 20260707_product_codes.sql). Powers barcode scanning in both the
// Stock and Price List tabs. Populated "learn as you scan".
//
// The Dahua line keeps its own directory in dahua_product_codes
// (20260913_dahua_expenses_deliveries_codes.sql), whose models are
// dahua_stock models. Every helper takes the table, defaulting to the
// main one so existing callers are unchanged.
// ─────────────────────────────────────────────────────────────

export type CodeTable = 'product_codes' | 'dahua_product_codes'

export interface ProductCode {
  id: string
  material_code: string
  model: string
}

/** Normalize a raw scanner string: trim, strip stray control chars. */
export function cleanCode(raw: string): string {
  return raw.replace(/[\x00-\x1f\x7f]/g, '').trim()
}

/**
 * Look up the model a material code maps to.
 * Returns null when the code has never been linked (caller should prompt to link).
 */
export async function resolveCode(rawCode: string, table: CodeTable = 'product_codes'): Promise<string | null> {
  const material_code = cleanCode(rawCode)
  if (!material_code) return null
  const { data } = await supabase
    .from(table)
    .select('model')
    .eq('material_code', material_code)
    .maybeSingle()
  return (data?.model as string) ?? null
}

/**
 * Link a material code to a model. Upserts on material_code so re-linking a
 * mistyped mapping just overwrites it.
 */
export async function linkCode(rawCode: string, model: string, table: CodeTable = 'product_codes'): Promise<{ error: string | null }> {
  const material_code = cleanCode(rawCode)
  const m = model.trim()
  if (!material_code) return { error: 'Empty barcode' }
  if (!m)             return { error: 'Pick a product to link to' }
  const { error } = await supabase
    .from(table)
    .upsert(
      { material_code, model: m, updated_at: new Date().toISOString() },
      { onConflict: 'material_code' },
    )
  return { error: error?.message ?? null }
}

/** Load the whole map once (material_code → model) for fast in-memory lookups. */
export async function loadCodeMap(table: CodeTable = 'product_codes'): Promise<Map<string, string>> {
  // Paged: this table grows a row per barcode ever scanned, and a bare
  // select is capped at 1000 rows and truncated silently. Past that, a box
  // whose code WAS linked would start scanning as an unknown barcode.
  const rows = await fetchAllRows<{ material_code: string; model: string }>((from, to) =>
    supabase.from(table).select('material_code, model')
      .order('material_code', { ascending: true }).range(from, to))
  const map = new Map<string, string>()
  for (const row of rows) map.set(row.material_code, row.model)
  return map
}

/** Load every code→model mapping as rows, for the manage-codes screen. */
export async function loadCodes(table: CodeTable = 'product_codes'): Promise<ProductCode[]> {
  // Paged for the same reason as loadCodeMap. Ordered by id, the unique
  // column — paging on a non-unique ORDER BY can skip or repeat rows — then
  // sorted by model for display.
  const rows = await fetchAllRows<ProductCode>((from, to) =>
    supabase.from(table).select('id, material_code, model')
      .order('id', { ascending: true }).range(from, to))
  return rows.sort((a, b) => a.model.localeCompare(b.model))
}

/** Remove a code↔model mapping (by material_code). */
export async function deleteCode(rawCode: string, table: CodeTable = 'product_codes'): Promise<{ error: string | null }> {
  const material_code = cleanCode(rawCode)
  if (!material_code) return { error: 'Empty barcode' }
  const { error } = await supabase.from(table).delete().eq('material_code', material_code)
  return { error: error?.message ?? null }
}
