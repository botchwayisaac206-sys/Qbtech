'use client'

/**
 * Stale-while-revalidate cache for admin-panel data.
 *
 * Behaviour:
 *  - First call for a key → awaits the fetch, then caches.
 *  - Subsequent call within TTL → returns cached data instantly (no await).
 *  - Subsequent call past TTL → returns cached data instantly AND triggers a
 *    background refetch. The component sees the stale value immediately and
 *    React re-renders with the fresh value when subscribers fire.
 *  - This means tab switches and slow-network refetches NEVER show "Loading…"
 *    or block the UI after the first successful load.
 *
 * The previous design awaited the refetch on every TTL expiry, so any slow
 * or hanging Supabase request would freeze the tab — exactly the
 * "after some time it pulls data and never shows until I refresh" bug.
 */

import { supabase } from '@/lib/supabase'

/**
 * Supabase's PostgREST hard-caps any single request at 1000 rows
 * (the project's `db-max-rows` setting) and silently truncates — a
 * `.range(0, 9999)` request just comes back with rows 0-999 and no error.
 * Every table here can grow past that (invoices, invoice_items already have),
 * so "fetch everything" must page through in a loop keyed on a stable,
 * unique `id` order — LIMIT/OFFSET without a deterministic ORDER BY can
 * skip or repeat rows across page boundaries.
 */
const PAGE_SIZE = 1000
/**
 * How many pages to request concurrently. Measured against live data
 * (9,029 invoice_items = 10 pages): each page costs ~450ms almost entirely in
 * request overhead and transfer, not in the offset scan — so the pages were
 * never CPU-bound, just serialised. Fetching them one at a time cost
 * 10 x 450ms; four at a time costs 3 waves. 4 keeps us well under Supabase's
 * connection limits while removing most of the latency.
 */
const PAGE_CONCURRENCY = 4

export async function fetchAllRows<T>(
  page: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }>,
): Promise<T[]> {
  const out: T[] = []
  let from = 0
  for (;;) {
    // Request a wave of pages at once rather than awaiting each in turn.
    const wave = await Promise.all(
      Array.from({ length: PAGE_CONCURRENCY }, (_, i) => {
        const start = from + i * PAGE_SIZE
        return page(start, start + PAGE_SIZE - 1)
      }),
    )
    for (const { data, error } of wave) {
      if (error) throw new Error(error.message)
      out.push(...(data ?? []))
    }
    // A short page means we've reached the end. Any later pages in the same
    // wave came back empty and have already been appended harmlessly, so the
    // result is identical to the sequential version.
    if (wave.some(w => (w.data ?? []).length < PAGE_SIZE)) return out
    from += PAGE_CONCURRENCY * PAGE_SIZE
  }
}

type Subscriber<T> = (data: T) => void

interface Entry<T> {
  data: T | undefined
  at: number                  // 0 means "no successful fetch yet"
  inflight?: Promise<T>
  subs: Set<Subscriber<T>>
}

const TTL_MS = 5 * 60_000           // 5 minutes — generous because SWR keeps UI fresh
const FETCH_TIMEOUT_MS = 25_000     // hard ceiling for any single Supabase request
const store = new Map<string, Entry<any>>()

// ── Load scope ────────────────────────────────────────────────
/**
 * How much history the admin panel pulls.
 *
 *   'recent'  (default)  only the last RECENT_MONTHS month of rows
 *   'all'                every row, as the panel used to do unconditionally
 *
 * Invoices alone are already 4,400+ rows and invoice_items 12,000+, so the
 * full load is several thousand rows across four tables on every sign-in.
 * Most of the dashboard only ever looks at the current day, week or month,
 * so 'recent' is enough for normal use and the toggle is there for the
 * year/4-year views and long-range customer rankings.
 *
 * Cache keys are suffixed with the scope, so flipping the toggle does not
 * throw away the other scope's rows — flip back and they are still warm.
 */
export type DataScope = 'recent' | 'all'
const SCOPE_STORAGE_KEY = 'qbnet.dataScope'
const RECENT_MONTHS = 1

let scope: DataScope = 'recent'
if (typeof window !== 'undefined') {
  try {
    const saved = window.localStorage.getItem(SCOPE_STORAGE_KEY)
    if (saved === 'all' || saved === 'recent') scope = saved
  } catch { /* private mode — stay on the default */ }
}

export function getScope(): DataScope { return scope }

/** Switch scope. Callers refetch afterwards; keys differ so nothing is lost. */
export function setScope(next: DataScope) {
  scope = next
  try { window.localStorage.setItem(SCOPE_STORAGE_KEY, next) } catch { /* ignore */ }
}

/** Cache key for the active scope. Exported so components can peek(). */
export const scopedKey = (base: string) => `${base}:${scope}`

/** Oldest timestamp to load, or null when the scope is 'all'. */
export function recentCutoff(): string | null {
  if (scope === 'all') return null
  const d = new Date()
  d.setMonth(d.getMonth() - RECENT_MONTHS)
  d.setHours(0, 0, 0, 0)
  return d.toISOString()
}

function getEntry<T>(key: string): Entry<T> {
  let e = store.get(key) as Entry<T> | undefined
  if (!e) { e = { data: undefined, at: 0, subs: new Set() }; store.set(key, e) }
  return e
}

function isFresh(e: Entry<any>) { return e.at > 0 && Date.now() - e.at < TTL_MS }

function startFetch<T>(key: string, fetcher: () => Promise<T>): Promise<T> {
  const e = getEntry<T>(key)
  if (e.inflight) return e.inflight

  const fetchPromise = fetcher()
  const timeoutPromise = new Promise<T>((_, rej) =>
    setTimeout(() => rej(new Error(`${key} request timed out`)), FETCH_TIMEOUT_MS)
  )

  const p = Promise.race([fetchPromise, timeoutPromise])
    .then(data => {
      e.data = data; e.at = Date.now(); e.inflight = undefined
      e.subs.forEach(fn => { try { fn(data) } catch {} })
      return data
    })
    .catch(err => {
      e.inflight = undefined          // free the slot so the next call can retry
      throw err
    })

  e.inflight = p
  return p
}

/**
 * Returns cached data immediately if any exists, kicking off a background
 * refetch when stale. If no cached data exists, awaits the first fetch.
 * Background refetch errors are swallowed (logged only) — they should never
 * crash the UI; the worst case is the user keeps seeing the previous data.
 */
export async function cached<T>(key: string, fetcher: () => Promise<T>): Promise<T> {
  const e = getEntry<T>(key)

  // First-ever load → must wait
  if (e.data === undefined) return startFetch(key, fetcher)

  // Have cached data + still fresh → return it, no fetch
  if (isFresh(e)) return e.data

  // Have cached data but stale → return stale immediately, refresh in background
  if (!e.inflight) {
    startFetch(key, fetcher).catch(err => {
      console.warn(`[cache] background refresh failed for ${key}:`, err?.message || err)
    })
  }
  return e.data
}

/** Subscribe to fresh data for a key. Returns unsubscribe. */
export function subscribe<T>(key: string, fn: Subscriber<T>): () => void {
  const e = getEntry<T>(key)
  e.subs.add(fn)
  return () => { e.subs.delete(fn) }
}

/**
 * Synchronous peek — returns cached data (possibly stale) or undefined.
 * Components use this to render immediately on mount with NO loading flash,
 * then call `cached()` / subscribe to receive any background refresh.
 */
export function peek<T>(key: string): T | undefined {
  return (store.get(key) as Entry<T> | undefined)?.data
}

/**
 * Fire-and-forget: warm every cache key that the admin panel needs. Called
 * on sign-in so that every tab's first click hits warm cache. Silently
 * swallows errors — any failure just means one more round trip when the
 * relevant tab actually mounts.
 */
export async function prefetchAdminData() {
  const jobs: Promise<unknown>[] = [
    fetchInvoices(),
    fetchInvoiceItems(),
    fetchExpenses(),
    fetchProductsLite(),
    fetchStockModels(),
    fetchStaffNames(),
    fetchDeliveries(),
    fetchLastSoldPrices(),
  ]
  await Promise.allSettled(jobs)
}

/** Drop one or all keys — call after inserts/updates/deletes. */
export function invalidate(...keys: string[]) {
  if (keys.length === 0) { store.clear(); return }
  // Callers pass the bare name ('invoices'); drop every scoped variant so a
  // write is not left visible in one scope and stale in the other.
  for (const key of keys) {
    store.delete(key)
    store.delete(`${key}:recent`)
    store.delete(`${key}:all`)
  }
}

// ── Typed helpers for the admin panel ──────────────────────────
export interface InvRow { id: string; total: number; subtotal: number; issued_at: string; customer_name?: string; customer_num?: string | null; payment_method?: string | null; invoice_number?: string
  /** A payment on a credit sale, standing in the list as the money that came in that day. */
  debt_payment?: boolean }
export interface ItemRow { invoice_id: string; product_id: string | null; description: string; quantity: number; line_total: number }
export interface ExpRow { id: string; amount: number; incurred_at: string; category: string; description: string | null }

export const fetchInvoices = () => cached<InvRow[]>(scopedKey('invoices'), async () => {
  const cutoff = recentCutoff()
  const rows = await fetchAllRows<InvRow>((from, to) => {
    let q = supabase.from('invoices')
      .select('id,invoice_number,total,subtotal,issued_at,customer_name,customer_num,payment_method')
    if (cutoff) q = q.gte('issued_at', cutoff)
    return q.order('id', { ascending: true }).range(from, to)
  })
  return rows.sort((a, b) => +new Date(b.issued_at) - +new Date(a.issued_at))
})

export const fetchInvoiceItems = () => cached<ItemRow[]>(scopedKey('invoice_items'), async () => {
  const cutoff = recentCutoff()
  if (!cutoff) {
    return fetchAllRows<ItemRow>((from, to) =>
      supabase.from('invoice_items')
        .select('invoice_id,product_id,description,quantity,line_total')
        .order('id', { ascending: true })
        .range(from, to))
  }
  // invoice_items has no date of its own, so scope it by the parent invoice.
  // `!inner` makes the embed a real INNER JOIN, which is what lets the filter
  // prune rows rather than just null out the embedded object.
  type Joined = ItemRow & { invoices?: unknown }
  const rows = await fetchAllRows<Joined>((from, to) =>
    supabase.from('invoice_items')
      .select('invoice_id,product_id,description,quantity,line_total,invoices!inner(issued_at)')
      .gte('invoices.issued_at', cutoff)
      .order('id', { ascending: true })
      .range(from, to) as unknown as PromiseLike<{ data: Joined[] | null; error: { message: string } | null }>)
  return rows.map(({ invoices: _drop, ...rest }) => rest as ItemRow)
})

export const fetchExpenses = () => cached<ExpRow[]>(scopedKey('expenses'), async () => {
  const cutoff = recentCutoff()
  const rows = await fetchAllRows<ExpRow>((from, to) => {
    let q = supabase.from('expenses').select('id,amount,incurred_at,category,description')
    if (cutoff) q = q.gte('incurred_at', cutoff)
    return q.order('id', { ascending: true }).range(from, to)
  })
  return rows.sort((a, b) => +new Date(b.incurred_at) - +new Date(a.incurred_at))
})

export interface DelRow {
  id: string; customer_name: string | null; location: string | null; amount: number; payment_method: string | null; delivered_at: string; note: string | null
  /** Set when the delivery was logged from an invoice (20261007_delivery_from_invoice.sql). */
  customer_num?: string | null
  invoice_number?: string | null
}
/**
 * The invoices that are deliveries: the ones a delivery was logged from.
 *
 * A sale with Delivery switched on is ONE sale. It is saved as an invoice
 * (that is the receipt) and as a delivery carrying the invoice's total. The
 * dashboards count it under Delivery, so its invoice must be left out of the
 * ordinary sales figure or the same money is counted twice.
 *
 * The link is the invoice number on the delivery row — or in its note, for
 * deliveries logged before the column existed.
 */
export function deliveredInvoiceNumbers(deliveries: DelRow[]): Set<string> {
  const out = new Set<string>()
  for (const d of deliveries) {
    const n = d.invoice_number || d.note?.match(/(?:DH-)?INV-\d{4}-\d+/)?.[0]
    if (n) out.add(n)
  }
  return out
}

const DEL_COLS = 'id,customer_name,location,amount,payment_method,delivered_at,note'
/** With the invoice columns; without them on a database the migration has not reached yet. */
async function loadDeliveries(table: 'deliveries', cutoff: string | null): Promise<DelRow[]> {
  const read = (cols: string) => fetchAllRows<DelRow>((from, to) => {
    let q = supabase.from(table).select(cols)
    if (cutoff) q = q.gte('delivered_at', cutoff)
    return q.order('id', { ascending: true }).range(from, to) as unknown as PromiseLike<{ data: DelRow[] | null; error: { message: string } | null }>
  })
  let rows: DelRow[]
  try { rows = await read(`${DEL_COLS},customer_num,invoice_number`) } catch { rows = await read(DEL_COLS) }
  return rows.sort((a, b) => +new Date(b.delivered_at) - +new Date(a.delivered_at))
}
export const fetchDeliveries = () => cached<DelRow[]>(scopedKey('deliveries'), () => loadDeliveries('deliveries', recentCutoff()))

export interface ProductRow { id: string; title: string; model_number: string; price: number | null }
export const fetchProductsLite = () => cached<ProductRow[]>('products_lite', async () => {
  // Paged. The catalogue is curated and well short of 1000 today, but a bare
  // select truncates silently at that point, and a product missing from the
  // invoice picker with no error to explain it is a nasty way to find out.
  const rows = await fetchAllRows<ProductRow>((from, to) =>
    supabase.from('products').select('id,title,model_number,price')
      .order('id', { ascending: true }).range(from, to))
  return rows.sort((a, b) => (a.title || '').localeCompare(b.title || ''))
})

/** Map from user_id → full_name, for tagging invoices with the staff who created them. */
export const fetchStaffNames = () => cached<Record<string, string>>('staff_names', async () => {
  const { data } = await supabase.from('user_roles')
    .select('user_id, full_name, role')
    .range(0, 999)
  const map: Record<string, string> = {}
  for (const r of (data as { user_id: string; full_name: string | null; role: string }[]) || []) {
    map[r.user_id] = r.full_name || r.role
  }
  return map
})

/** Distinct stock models across all warehouses — used for invoice autocomplete. */
export const fetchStockModels = () => cached<string[]>('stock_models', async () => {
  const rows = await fetchAllRows<{ id: string; model: string }>((from, to) =>
    supabase.from('warehouse_stock')
      .select('id, model')
      .order('id', { ascending: true })
      .range(from, to))
  const seen = new Set<string>()
  const out: string[] = []
  for (const r of rows) {
    const m = (r.model || '').trim()
    if (m && !seen.has(m)) { seen.add(m); out.push(m) }
  }
  return out.sort()
})

/**
 * model → GH¢ price, for filling a scanned line's unit price.
 * Keys are UPPER-CASED AND TRIMMED — look up with the same normalisation.
 */
export const fetchPricelistMap = () => cached<Map<string, number>>('pricelist_map', async () => {
  // Paged — a bare select stops at 1000 rows without saying so, which would
  // quietly leave later models with no price on a scanned invoice line.
  const rows = await fetchAllRows<{ model: string; ghs_price: number; created_at: string }>((from, to) =>
    supabase.from('pricelist_items').select('model, ghs_price, created_at')
      .order('id', { ascending: true }).range(from, to))
  // Keyed and resolved exactly as price_for_model() does in the database
  // (see 20260921_main_fixed_pricing.sql): upper/trimmed model, most recently
  // entered priced row wins. If these two disagreed, the price previewed on
  // an invoice line would not be the price the line was saved at.
  const latest = new Map<string, { price: number; at: string }>()
  for (const r of rows) {
    const key = (r.model || '').trim().toUpperCase()
    const price = Number(r.ghs_price) || 0
    if (!key || price <= 0) continue
    const seen = latest.get(key)
    if (!seen || r.created_at > seen.at) latest.set(key, { price, at: r.created_at })
  }
  const map = new Map<string, number>()
  for (const [key, v] of Array.from(latest)) map.set(key, v.price)
  return map
})

export interface LastSold { price: number; issued_at: string; description: string }
/**
 * lowercased line description → most recent unit price it sold for + when
 * (description keeps its original casing, for display). Keyed on
 * invoice_items.description because that's the only identity every line
 * (product-picker, stock autocomplete, or scanned) shares consistently —
 * there's no universal product_id across all three entry paths. This is
 * also the authoritative "every product we've ever invoiced" list — the
 * Price List tab builds its rows from these keys, not just from the
 * separately curated pricelist_items table.
 */
export const fetchLastSoldPrices = () => cached<Map<string, LastSold>>('last_sold_prices', async () => {
  // Reduced server-side by the last_sold_prices view (see
  // supabase/migrations/20260807_perf_last_sold.sql). Previously this pulled
  // every invoice_items row with an embedded invoices join and collapsed them
  // here — a second full scan of the largest table on every sign-in.
  try {
    const rows = await fetchAllRows<{ key: string; description: string; price: number; issued_at: string }>(
      (from, to) => supabase.from('last_sold_prices')
        .select('key,description,price,issued_at')
        .order('key', { ascending: true })
        .range(from, to))
    const map = new Map<string, LastSold>()
    for (const r of rows) {
      if (!r.key) continue
      map.set(r.key, { price: Number(r.price) || 0, issued_at: r.issued_at, description: r.description })
    }
    return map
  } catch (err) {
    // The view won't exist until 20260807_perf_last_sold.sql has been applied.
    // Fall back to the old client-side reduction so that deploying the app
    // before running the migration degrades to "slow" rather than "broken".
    console.warn('[cache] last_sold_prices view unavailable, using slow path:', err)
    return legacyLastSoldPrices()
  }
})

/** Pre-view implementation: full scan of invoice_items, reduced client-side. */
async function legacyLastSoldPrices(): Promise<Map<string, LastSold>> {
  const rows = await fetchAllRows<any>((from, to) =>
    supabase.from('invoice_items')
      .select('id, description, unit_price, invoices(issued_at)')
      .order('id', { ascending: true })
      .range(from, to))
  const map = new Map<string, LastSold>()
  for (const row of rows) {
    const description = (row.description || '').trim()
    const key = description.toLowerCase()
    const issued_at = row.invoices?.issued_at
    if (!key || !issued_at) continue
    const existing = map.get(key)
    if (!existing || issued_at > existing.issued_at) {
      map.set(key, { price: Number(row.unit_price) || 0, issued_at, description })
    }
  }
  return map
}
