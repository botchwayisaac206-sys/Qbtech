import { useCallback, useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import type { StockLine } from '@/lib/storeStock'

/**
 * Stock movements by staff wait for the Big Boss's approval — on both lines
 * (20261017_dahua_movement_approval.sql, 20261023_stock_approval_everywhere.sql).
 *
 * Staff file a REQUEST (REQ-… for the main shop, DH-REQ-… when Dahua is
 * involved); the stock changes only when he approves it, and then as the
 * ordinary numbered movement it would have been, credited to the person who
 * asked and dated when they asked. A rejected request changes nothing. An
 * approved one can be reversed, which books a REV-… movement undoing it.
 *
 * Auto-accept: when the Big Boss switches it on, a request approves itself
 * 45 seconds after it reached the server unless he has rejected it. The
 * database has no timer, so every screen that shows requests asks it to
 * settle whatever is due (settleDue).
 */

export type RequestStatus = 'pending' | 'approved' | 'rejected' | 'reversed'

export interface StockRequest {
  id: string
  request_number: string
  kind: 'move' | 'receive' | 'return'
  from_line: StockLine | null
  from_warehouse: string | null
  to_line: StockLine
  to_warehouse: string
  items: { model: string; quantity: number; to_model?: string; condition?: string }[]
  party: string | null
  note: string | null
  requested_at: string
  /** When it reached the server — what the auto-accept clock runs from. */
  filed_at?: string
  requested_name: string | null
  requested_staff_id: string | null
  status: RequestStatus
  decided_at: string | null
  auto_approved?: boolean
  reject_reason: string | null
  transfer_number: string | null
  reversed_at?: string | null
  reversal_number?: string | null
  reverse_reason?: string | null
}
/** The older name, kept for the pages that still say it. */
export type DahuaRequest = StockRequest

/** Does this movement need approval for this login? Everyone's but the Big Boss's. */
export const needsApproval = (isSuperBoss: boolean) => !isSuperBoss

/** Fired on window when a request is filed or decided, so open lists and badges reload. */
export const STOCK_REQUESTS_CHANGED = 'qbnet:dahua-requests-changed'
/** Fired when the auto-accept switch changes. */
export const AUTO_ACCEPT_CHANGED = 'qbnet:auto-accept-changed'
const changed = () => window.dispatchEvent(new CustomEvent(STOCK_REQUESTS_CHANGED))

/** A function the database does not have yet — the migration has not been run. */
const missingFn = (e: { code?: string; message?: string } | null) =>
  !!e && (e.code === 'PGRST202' || /could not find the function/i.test(e.message || ''))

export async function requestStockMovement(args: {
  kind: StockRequest['kind']
  fromLine: StockLine | null; from: string | null
  toLine: StockLine; to: string
  items: StockRequest['items']
  party?: string; note?: string; when?: string
}): Promise<StockRequest> {
  const params = {
    p_kind: args.kind,
    p_from_line: args.fromLine, p_from: args.from,
    p_to_line: args.toLine, p_to: args.to,
    p_items: args.items,
    p_party: args.party || null, p_note: args.note || null,
    p_when: args.when ?? new Date().toISOString(),
  }
  let { data, error } = await supabase.rpc('request_stock_movement', params)
  // Before 20261023 only Dahua movements could be asked for, under the old name.
  if (missingFn(error)) ({ data, error } = await supabase.rpc('request_dahua_movement', params))
  if (error) throw error
  changed()
  return (Array.isArray(data) ? data[0] : data) as StockRequest
}

const COLS = 'id,request_number,kind,from_line,from_warehouse,to_line,to_warehouse,items,party,note,requested_at,filed_at,requested_name,requested_staff_id,status,decided_at,auto_approved,reject_reason,transfer_number,reversed_at,reversal_number,reverse_reason'
const OLD_COLS = 'id,request_number,kind,from_line,from_warehouse,to_line,to_warehouse,items,party,note,requested_at,requested_name,requested_staff_id,status,decided_at,reject_reason,transfer_number'

/** Pending ones first, then the most recent decided. RLS shows staff only their own. */
export async function fetchStockRequests(limit = 150): Promise<StockRequest[]> {
  const read = (cols: string) => supabase.from('dahua_movement_requests').select(cols)
    .order('requested_at', { ascending: false }).limit(limit)
  let { data, error } = await read(COLS)
  if (error) ({ data, error } = await read(OLD_COLS))
  if (error) throw error
  return ((data as unknown as StockRequest[]) || []).sort((a, b) =>
    (a.status === 'pending' ? 0 : 1) - (b.status === 'pending' ? 0 : 1) || b.requested_at.localeCompare(a.requested_at))
}

const call = async <T,>(fn: string, old: string | null, params: Record<string, unknown>): Promise<T> => {
  let { data, error } = await supabase.rpc(fn, params)
  if (old && missingFn(error)) ({ data, error } = await supabase.rpc(old, params))
  if (error) throw error
  changed()
  return data as T
}

export const approveStockRequest = (id: string) =>
  call<{ transfer_number: string }>('approve_stock_request', 'approve_dahua_movement', { p_id: id })
export const rejectStockRequest = (id: string, reason: string) =>
  call<void>('reject_stock_request', 'reject_dahua_movement', { p_id: id, p_reason: reason || null })
export const reverseStockRequest = (id: string, reason: string) =>
  call<{ reversal_number: string; transfer_number: string }>('reverse_stock_request', null, { p_id: id, p_reason: reason || null })

/** Approve whatever auto-accept has made due. Quiet: 0 when it is off, or not set up yet. */
export async function settleDue(): Promise<number> {
  const { data, error } = await supabase.rpc('settle_stock_requests')
  if (error) return 0
  const n = Number(data) || 0
  if (n > 0) changed()
  return n
}

export interface AutoAccept { on: boolean; seconds: number }

export async function fetchAutoAccept(): Promise<AutoAccept> {
  const { data, error } = await supabase.from('stock_approval_settings').select('auto_accept,delay_seconds').eq('id', 1).maybeSingle()
  if (error || !data) return { on: false, seconds: 45 }
  return { on: !!data.auto_accept, seconds: Number(data.delay_seconds) || 45 }
}

export async function setAutoAccept(on: boolean): Promise<AutoAccept> {
  const { data, error } = await supabase.rpc('set_stock_auto_accept', { p_on: on })
  if (error) throw error
  const row = (Array.isArray(data) ? data[0] : data) as { auto_accept: boolean; delay_seconds: number }
  const out = { on: !!row?.auto_accept, seconds: Number(row?.delay_seconds) || 45 }
  window.dispatchEvent(new CustomEvent(AUTO_ACCEPT_CHANGED, { detail: out }))
  return out
}

/** The auto-accept switch, kept current across the page. */
export function useAutoAccept() {
  const [state, setState] = useState<AutoAccept>({ on: false, seconds: 45 })
  const reload = useCallback(() => { fetchAutoAccept().then(setState) }, [])
  useEffect(() => {
    reload()
    const onSet = (e: Event) => setState((e as CustomEvent<AutoAccept>).detail)
    window.addEventListener(AUTO_ACCEPT_CHANGED, onSet)
    const timer = setInterval(() => { if (document.visibilityState === 'visible') reload() }, 60_000)
    return () => { window.removeEventListener(AUTO_ACCEPT_CHANGED, onSet); clearInterval(timer) }
  }, [reload])
  return state
}

/**
 * How many requests are waiting — for the badge on the Transfers tab.
 * Checked when the page opens, whenever a request is filed or decided on
 * this screen, and while the page is in view: every 15 seconds when
 * auto-accept is on (so the count falls as they settle), else every minute.
 * 0 for anyone who is not the Big Boss.
 */
export function usePendingCount(enabled: boolean) {
  const [n, setN] = useState(0)
  const auto = useAutoAccept()
  useEffect(() => {
    if (!enabled) { setN(0); return }
    let alive = true
    const check = async () => {
      if (auto.on) await settleDue()
      const { count, error } = await supabase.from('dahua_movement_requests')
        .select('id', { count: 'exact', head: true }).eq('status', 'pending')
      if (alive && !error) setN(count ?? 0)
    }
    check()
    const onChange = () => { check() }
    window.addEventListener(STOCK_REQUESTS_CHANGED, onChange)
    const timer = setInterval(() => { if (document.visibilityState === 'visible') check() }, auto.on ? 15_000 : 60_000)
    return () => { alive = false; window.removeEventListener(STOCK_REQUESTS_CHANGED, onChange); clearInterval(timer) }
  }, [enabled, auto.on])
  return n
}
export const usePendingDahuaCount = usePendingCount

/**
 * After a staff member files a request: if auto-accept is on, settle it
 * once its time is up, from their own screen — so it goes through even
 * when no boss has the app open.
 */
export function settleAfterDelay() {
  fetchAutoAccept().then(a => {
    if (a.on) setTimeout(() => { settleDue() }, (a.seconds + 1) * 1000)
  })
}

/**
 * The Big Boss's switch on "no stock, no sale" (20261025_no_stock_sales_switch.sql).
 * Off: the invoice forms refuse a stocked product the shop does not have.
 * On: they warn, and let the sale through. Read fresh before each save.
 */
export const NO_STOCK_SALES_CHANGED = 'qbnet:no-stock-sales-changed'

export async function fetchNoStockSales(): Promise<boolean> {
  const { data, error } = await supabase.from('stock_approval_settings').select('allow_no_stock_sales').eq('id', 1).maybeSingle()
  if (error || !data) return false
  return !!(data as { allow_no_stock_sales?: boolean }).allow_no_stock_sales
}

export async function setNoStockSales(on: boolean): Promise<boolean> {
  const { data, error } = await supabase.rpc('set_no_stock_sales', { p_on: on })
  if (error) throw error
  const row = (Array.isArray(data) ? data[0] : data) as { allow_no_stock_sales: boolean }
  const out = !!row?.allow_no_stock_sales
  window.dispatchEvent(new CustomEvent(NO_STOCK_SALES_CHANGED, { detail: out }))
  return out
}

export function useNoStockSales() {
  const [on, setOn] = useState(false)
  useEffect(() => {
    fetchNoStockSales().then(setOn)
    const onSet = (e: Event) => setOn(!!(e as CustomEvent<boolean>).detail)
    window.addEventListener(NO_STOCK_SALES_CHANGED, onSet)
    const timer = setInterval(() => { if (document.visibilityState === 'visible') fetchNoStockSales().then(setOn) }, 60_000)
    return () => { window.removeEventListener(NO_STOCK_SALES_CHANGED, onSet); clearInterval(timer) }
  }, [])
  return on
}
