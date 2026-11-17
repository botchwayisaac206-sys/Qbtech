import { supabase } from '@/lib/supabase'

/**
 * The shop floor, as a stock location.
 *
 * STORE STOCK is a warehouse row like any other — it is NOT a roll-up of the
 * back warehouses. It holds its own counted quantities, units arrive by
 * transfer, and main-shop invoices are deducted from it.
 *
 * The name is the key: the whole schema identifies a location by
 * `warehouse_stock.warehouse`, not by a foreign key. Renaming the row in the
 * Stock tab would therefore orphan the store, so this constant and that row
 * have to stay in step (see 20260920_store_stock_transfers.sql).
 */
export const STORE = 'STORE STOCK'

/**
 * Where written-off goods pile up.
 *
 * Filled only by marking a line spoilt on a return, so it is never offered
 * as a destination. Stock CAN be moved out of it — that is how a repaired
 * unit goes back into circulation, or a disposal is recorded as leaving.
 * Nothing here is sellable: invoices deduct from STORE alone.
 */
export const SPOILT = 'SPOILT'

/** A location's on-hand figure per model. */
export type Levels = Map<string, number>

/**
 * Which stock pool a movement belongs to. There is one: the shop's. The
 * database still has a `line` column on movements and requests from when a
 * second pool existed; the app only ever writes and shows 'main'.
 */
export type StockLine = 'main'

const TABLES: Record<StockLine, { stock: string; transfers: string; items: string; rpc: (fn: string) => string }> = {
  main:  { stock: 'warehouse_stock', transfers: 'stock_transfers', items: 'stock_transfer_items', rpc: fn => fn },
}

/** Where a line's stock and movement history live — for the tables the UI reads directly. */
export const tablesFor = (line: StockLine) => TABLES[line]

/** Options every movement takes: when it happened, and which line it is on. */
export interface MoveOptions { when?: string; line?: StockLine }

/** How the pool is named to staff. */
export const LINE_LABEL: Record<StockLine, string> = { main: 'Main shop' }

/** A stock location. */
export interface Location { line: StockLine; name: string }

/** Every location on a line, in the order its Stock tab lists them. */
export async function fetchLocations(line: StockLine): Promise<string[]> {
  const { data, error } = await supabase
    .from('warehouses')
    .select('name').order('created_at')
  if (error) throw error
  return (data || []).map(w => w.name as string)
}

/**
 * A model name reduced to what identifies it: letters and digits, upper-cased.
 *
 * "DS-J1421/7208HGHI/M1" and "ds-j1421 7208hghi-m1" come out the same.
 *
 * A decimal point between two digits is kept (as "~"): "1.5M PATCH CORD"
 * and "15M PATCH CORD" are different products, and both are on the shelf.
 *
 * Must stay in step with stock_model_key() in the database
 * (20261005_model_key_keeps_decimals.sql), which is what actually decides
 * whether a movement joins an existing row.
 */
export const modelKey = (model: string) =>
  model.toUpperCase().replace(/(\d)\.(?=\d)/g, '$1~').replace(/[^A-Z0-9~]/g, '')

/**
 * Names that are probably the same product as `model` but not certainly:
 * one is the start of the other ("EAP225" / "EAP225 Wireless ceiling mount").
 *
 * Names with the SAME key are not returned — those are one product and the
 * database joins them by itself (20261005_no_duplicate_names_on_moves.sql).
 * These are the ones only a person can settle, because a bare code is
 * sometimes a different pack, lens or kit. Five characters is the floor:
 * below that "DS-2" would claim half the catalogue.
 */
export function similarNames(model: string, candidates: Iterable<string>): string[] {
  const key = modelKey(model)
  if (key.length < 5) return []
  const out: string[] = []
  for (const c of Array.from(candidates)) {
    const k = modelKey(c)
    if (k.length < 5 || k === key) continue
    if (k.startsWith(key) || key.startsWith(k)) out.push(c)
  }
  return out.sort((a, b) => a.localeCompare(b))
}

export interface StockRow { warehouse: string; model: string; closing_stock: number }

/** Every stock row on a line: what each location calls each product, and how many. */
export async function fetchLineStock(line: StockLine): Promise<StockRow[]> {
  const rows: StockRow[] = []
  const PAGE = 1000
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await supabase
      .from(TABLES[line].stock)
      .select('warehouse, model, closing_stock')
      .order('id', { ascending: true })
      .range(from, from + PAGE - 1)
    if (error) throw error
    for (const r of data || []) {
      rows.push({ warehouse: r.warehouse, model: r.model, closing_stock: Number(r.closing_stock) || 0 })
    }
    if (!data || data.length < PAGE) break
  }
  return rows
}

/**
 * model → closing_stock for one location. Used by the invoice form to show
 * what the store actually has before a line is committed, and by the
 * transfer form to stop staff sending units the source does not hold.
 *
 * Not routed through adminCache: an on-hand figure that is a few minutes
 * stale is worse than useless, it is misleading.
 */
export async function fetchLevels(warehouse: string = STORE, line: StockLine = 'main'): Promise<Levels> {
  const levels: Levels = new Map()
  const PAGE = 1000
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await supabase
      .from(TABLES[line].stock)
      .select('model, closing_stock')
      .eq('warehouse', warehouse)
      .order('model', { ascending: true })
      .range(from, from + PAGE - 1)
    if (error) throw error
    // Summed, in case a model sits on more than one row in the same place.
    for (const r of data || []) levels.set(r.model, (levels.get(r.model) || 0) + (Number(r.closing_stock) || 0))
    if (!data || data.length < PAGE) break
  }
  return levels
}

export interface MoveLine { model: string; quantity: number }

export interface TransferResult {
  id: string
  transfer_number: string
  /** A move between locations, a delivery in, or goods back from a buyer. */
  kind: 'move' | 'receive' | 'return'
  /** Null on a receive — a delivery has no source location. */
  from_warehouse: string | null
  to_warehouse: string
  /** Who it came from: the supplier on a receive, the buyer on a return. */
  supplier: string | null
  note: string | null
  /** Name and login ID of whoever recorded it, copied in at the time. */
  signed_by: string | null
  staff_id: string | null
  transferred_at: string
  from_line?: StockLine | null
  to_line?: StockLine | null
  /** True when the phone app re-sent a movement the database already had. */
  duplicate?: boolean
  /**
   * A movement by staff: filed as a request for the Big Boss, not yet made
   * (20261023_stock_approval_everywhere.sql). transfer_number then holds the
   * request's number.
   */
  pending?: boolean
  request_number?: string
}

/**
 * A line on a move, with the name it takes at the destination when that
 * differs — a similar name the destination already stocks that staff chose
 * to add it to.
 */
export interface CrossLine extends MoveLine { to_model?: string }

/** Everything the phone app needs to send a movement, and to send it again. */
export interface MovementRequest {
  /** Made up on the phone. The database acts on each ID once. */
  requestId: string
  kind: TransferResult['kind']
  /** Null on a receive or a return — nothing leaves a location. */
  from: Location | null
  to: Location
  items: (CrossLine & { condition?: 'good' | 'spoilt' })[]
  /** The supplier on a receive, the buyer on a return. */
  party?: string
  note?: string
  /** When it was recorded on the phone, which may be well before it is sent. */
  when: string
  /**
   * The person who tapped their name on the phone. Must be on the stock
   * staff list; recorded as signed_by, beside the login the phone is using.
   */
  doneBy?: string
  /**
   * The key the phone was given when that person entered their password.
   * The database refuses the movement without it once they have set one.
   */
  doneToken?: string
}

/**
 * Record a movement exactly once, however many times it is sent.
 *
 * A phone that loses signal mid-save cannot know whether the save landed.
 * With a request ID it does not need to: sending again is harmless, and
 * comes back with `duplicate: true` and the original reference.
 */
export async function recordMovement(m: MovementRequest): Promise<TransferResult> {
  const { data, error } = await supabase.rpc('record_stock_movement', {
    p_request_id: m.requestId,
    p_kind: m.kind,
    p_from_line: m.from?.line ?? null,
    p_from: m.from?.name ?? null,
    p_to_line: m.to.line,
    p_to: m.to.name,
    p_items: m.items,
    p_party: m.party || null,
    p_note: m.note || null,
    p_when: m.when,
    p_done_by: m.doneBy ?? null,
    // Left out entirely when there is none, so a phone that has not been
    // given a key sends exactly what it always sent.
    ...(m.doneToken ? { p_done_token: m.doneToken } : {}),
  })
  if (error) throw error
  return data as TransferResult
}

/**
 * The stock staff list — the names the phone app offers, kept by the Big
 * Boss (20261005_stock_handlers.sql). The database refuses a movement signed
 * with a name that is not on it.
 */
export interface StockHandler { name: string; hasPassword: boolean }

export async function fetchStockHandlers(): Promise<StockHandler[]> {
  const { data, error } = await supabase.rpc('stock_handlers_list')
  if (error) throw error
  return ((data as { name: string; has_password: boolean }[]) || []).map(h => ({ name: h.name, hasPassword: !!h.has_password }))
}

/** What entering or setting a password comes back with: a key for that person, or why not. */
export type HandlerKey =
  | { ok: true; name: string; token: string }
  | { ok: false; error: string; no_password?: boolean }

/**
 * Check a stock staff member's password (20261006_stock_staff_passwords.sql).
 * A wrong password is an answer, not an error — only a failed request throws.
 */
export async function signInHandler(name: string, password: string): Promise<HandlerKey> {
  const { data, error } = await supabase.rpc('stock_handler_sign_in', { p_name: name, p_password: password })
  if (error) throw error
  return data as HandlerKey
}

/** Set a first password, or change one (which needs the current one). */
export async function setHandlerPassword(name: string, next: string, current?: string): Promise<HandlerKey> {
  const { data, error } = await supabase.rpc('stock_handler_set_password', { p_name: name, p_new: next, p_old: current ?? null })
  if (error) throw error
  return data as HandlerKey
}

/** Big Boss only: clear a forgotten password, so the person sets a new one. */
export async function resetHandlerPassword(name: string): Promise<void> {
  const { error } = await supabase.rpc('stock_handler_reset_password', { p_name: name })
  if (error) throw error
}

export async function addStockHandler(name: string): Promise<void> {
  const { error } = await supabase.from('stock_handlers').insert({ name: name.trim() })
  if (error) throw new Error(error.code === '23505' ? `${name.trim()} is already on the list` : error.message)
}

/** Past movements keep the name: it was copied onto each record when it was made. */
export async function removeStockHandler(name: string): Promise<void> {
  const { error } = await supabase.from('stock_handlers').delete().eq('name', name)
  if (error) throw error
}

/**
 * Fold one product name into another, across every warehouse on a line.
 * Big Boss only (20261005_merge_product_names.sql).
 */
export async function mergeStockModel(line: StockLine, from: string, into: string): Promise<{ warehouses: number; rows_absorbed: number }> {
  const { data, error } = await supabase.rpc('merge_stock_model', { p_line: line, p_from: from, p_into: into })
  if (error) throw error
  return data as { warehouses: number; rows_absorbed: number }
}

/**
 * Move units between two locations. One call, one transaction — a transfer
 * that half-applied because the connection dropped between the two updates
 * is the exact failure this is here to avoid, so the whole thing lives in
 * the `transfer_stock` function rather than in a loop on this side.
 */
export async function transferStock(
  from: string,
  to: string,
  items: CrossLine[],
  note?: string,
  opts: MoveOptions = {},
): Promise<TransferResult> {
  const line = opts.line ?? 'main'
  const { data, error } = await supabase.rpc(TABLES[line].rpc('transfer_stock'), {
    p_from: from,
    p_to: to,
    p_items: items,
    p_note: note ?? null,
    p_when: opts.when ?? new Date().toISOString(),
  })
  if (error) throw error
  return (Array.isArray(data) ? data[0] : data) as TransferResult
}

/**
 * Book in stock that arrived from outside — a supplier delivery.
 *
 * Not a transfer: nothing is deducted from anywhere, units enter the
 * system. Shares the same record and the same numbered history so that
 * "where did this stock come from" has one answer, with its own RCV
 * series so a delivery note is never mistaken for an internal move.
 *
 * Units land in transfer_in, leaving opening_stock as whatever the last
 * physical count actually found. A model the destination has never carried
 * is created there — that is the ordinary case for a delivery.
 */
export async function receiveStock(
  to: string,
  items: MoveLine[],
  supplier?: string,
  note?: string,
  opts: MoveOptions = {},
): Promise<TransferResult> {
  const line = opts.line ?? 'main'
  const { data, error } = await supabase.rpc(TABLES[line].rpc('receive_stock'), {
    p_to: to,
    p_items: items,
    p_supplier: supplier ?? null,
    p_note: note ?? null,
    p_when: opts.when ?? new Date().toISOString(),
  })
  if (error) throw error
  return (Array.isArray(data) ? data[0] : data) as TransferResult
}

/** A returned line, and whether it can go back on the shelf. */
export interface ReturnLine extends MoveLine {
  condition: 'good' | 'spoilt'
}

/**
 * Goods back from a buyer.
 *
 * Lines marked good go back into stock at `to` — normally STORE STOCK.
 * Spoilt lines are recorded in full and restock nothing: putting damaged
 * goods back on the shelf as sellable is how a shop ends up invoicing
 * something it cannot supply. Both are logged on the same RNA record.
 */
export async function returnStock(
  to: string,
  items: ReturnLine[],
  customer?: string,
  note?: string,
  opts: MoveOptions = {},
): Promise<TransferResult> {
  const line = opts.line ?? 'main'
  const { data, error } = await supabase.rpc(TABLES[line].rpc('return_stock'), {
    p_to: to,
    p_items: items,
    p_customer: customer ?? null,
    p_note: note ?? null,
    p_when: opts.when ?? new Date().toISOString(),
  })
  if (error) throw error
  return (Array.isArray(data) ? data[0] : data) as TransferResult
}

/** A line the store could not cover. Reported, never blocking. */
export interface Shortfall {
  model: string
  requested: number
  available: number
  /** false when the store has no row for this model at all. */
  tracked: boolean
}

/**
 * Deduct invoiced units from the store.
 *
 * Called after the invoice is already saved, and deliberately cannot fail
 * the sale: the shop's rule is that a bad count must never stop a customer.
 * Shortfalls come back so the cashier can be told what to go and check.
 *
 * Only the invoice is sent. The database reads its saved lines itself and
 * deducts once per invoice (20260930_lock_stock_writes.sql), so the store
 * cannot be run down with a list of items no invoice stands behind.
 */
export async function deductInvoiceStore(invoiceId: string): Promise<Shortfall[]> {
  const { data, error } = await supabase.rpc('deduct_invoice_store_stock', { p_invoice_id: invoiceId })
  if (error) throw error
  return (data as Shortfall[]) || []
}

/** "STORE STOCK is short 3 × DS-7208 (has 2, invoiced 5)" — one line per model. */
export function describeShortfalls(rows: Shortfall[]): string {
  return rows.map(r => r.tracked
    ? `${r.model} — store has ${r.available}, invoiced ${r.requested}`
    : `${r.model} — not stocked in ${STORE}`,
  ).join('\n')
}
