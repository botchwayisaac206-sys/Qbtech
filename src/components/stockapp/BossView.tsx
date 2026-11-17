'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import Link from 'next/link'
import {
  ArrowLeftRight, BarChart3, Boxes, ChevronDown, ClipboardList, FileDown, RefreshCw, Search, Tag, TrendingDown, TrendingUp,
} from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { GHS, paymentBuckets } from '@/lib/sales'
import { fetchAllRows, deliveredInvoiceNumbers, type DelRow } from '@/lib/adminCache'
import { LINE_LABEL, SPOILT, modelKey, type StockLine } from '@/lib/storeStock'
import { loadCreditLedger } from '@/lib/debts'
import {
  approveStockRequest, rejectStockRequest, reverseStockRequest, fetchStockRequests, usePendingCount, settleDue,
  useAutoAccept, STOCK_REQUESTS_CHANGED, type StockRequest,
} from '@/lib/stockApproval'
import { downloadDahuaTransfersPdf } from '@/lib/transfersPdf'

/**
 * The boss's side of the phone app: how the shop is doing, at a glance.
 *
 * Shown instead of the stock-moves screen when the phone is signed in with a
 * boss login. A tab bar along the bottom, as on any phone app, with one
 * question per tab:
 *
 *   Overview  how much was sold, against the period before, and on what
 *   Stock     what each warehouse holds of any product — and, for the Big
 *             Boss, correcting a count
 *   Prices    what each product sells for — and, for the Big Boss, changing it
 *   Activity  what stock was moved, received or returned, and by whom — and,
 *             first, the staff moves waiting for the Big Boss to approve
 *   Moves     over to the stock-moves screen the staff use
 *
 * It reads straight from the same tables the admin panel does, a date range
 * at a time, so it stays quick on a phone. Nothing here is kept for use with
 * no signal: these are live figures, and yesterday's would mislead.
 *
 * What a login may see is decided by the database, not here. A restricted
 * boss gets the last 24 hours and no more, whatever range is picked — the
 * screen says so rather than showing a short total as if it were the whole.
 */

// One palette, used the same way everywhere: ink on paper, one brand colour
// for what can be tapped or is selected, and red / amber / green only for
// what they mean.
const C = {
  bg: '#f5f6f8', card: '#ffffff', ink: '#0f172a', sub: '#64748b', faint: '#94a3b8',
  line: '#e6e9ed', brand: '#0f766e', brandDark: '#115e59', tint: '#e7f5f2',
  good: '#15803d', goodTint: '#e8f6ec', bad: '#b91c1c', badTint: '#fdecec', warn: '#b45309', warnTint: '#fef4e2',
}
const NUM: React.CSSProperties = { fontVariantNumeric: 'tabular-nums' }

type Tab = 'overview' | 'stock' | 'prices' | 'activity'
type Period = 'today' | 'yesterday' | 'week' | 'month'
type Scope = 'both' | StockLine

const PERIODS: { key: Period; label: string; before: string }[] = [
  { key: 'today', label: 'Today', before: 'yesterday' },
  { key: 'yesterday', label: 'Yesterday', before: 'the day before' },
  { key: 'week', label: '7 days', before: 'the 7 days before' },
  { key: 'month', label: 'This month', before: 'the same days last month' },
]

const dayStart = (d = new Date()) => { const x = new Date(d); x.setHours(0, 0, 0, 0); return x }
const addDays = (d: Date, n: number) => { const x = new Date(d); x.setDate(x.getDate() + n); return x }

/** [from, to) in the phone's own time, which is the shop's — and the equal stretch before it. */
function rangeOf(p: Period) {
  const start = dayStart(), next = addDays(start, 1)
  if (p === 'today') return { from: start, to: next, prevFrom: addDays(start, -1), prevTo: start }
  if (p === 'yesterday') return { from: addDays(start, -1), to: start, prevFrom: addDays(start, -2), prevTo: addDays(start, -1) }
  if (p === 'week') return { from: addDays(start, -6), to: next, prevFrom: addDays(start, -13), prevTo: addDays(start, -6) }
  const first = new Date(start.getFullYear(), start.getMonth(), 1)
  const prevFirst = new Date(start.getFullYear(), start.getMonth() - 1, 1)
  // The same number of days into last month, so a half-finished month is not
  // measured against a whole one.
  const prevTo = new Date(Math.min(addDays(prevFirst, Math.round((next.getTime() - first.getTime()) / 86_400_000)).getTime(), first.getTime()))
  return { from: first, to: next, prevFrom: prevFirst, prevTo }
}

interface Invoice { id: string; line: StockLine; invoice_number: string; customer_name: string; payment_method: string | null; total: number; issued_at: string }
interface SoldItem { invoice_id: string; description: string; quantity: number; line_total: number }
interface Movement {
  transfer_number: string; kind: 'move' | 'receive' | 'return' | 'reversal'; from_warehouse: string | null; to_warehouse: string
  supplier: string | null; signed_by: string | null; staff_id: string | null; transferred_at: string
  items: { model: string; quantity: number }[]
}
interface Product {
  line: StockLine; model: string; places: { warehouse: string; qty: number }[]; total: number; price: number
  /** Every stock row of the product, empty ones too — what the Big Boss corrects a count on. */
  rows: StockRow[]
}
interface StockRow { id: string; warehouse: string; qty: number; opening: number }

// The same product key the database files and finds prices under.
const priceKey = (model: string) => modelKey(model)
const chunk = <T,>(list: T[], n: number) => Array.from({ length: Math.ceil(list.length / n) }, (_, i) => list.slice(i * n, i * n + n))
const timeOf = (iso: string) => new Date(iso).toLocaleString('en-GB', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })
const tablesOf = (l: StockLine) => l === 'dahua'
  ? { inv: 'dahua_invoices', items: 'dahua_invoice_items', exp: 'dahua_expenses', del: 'dahua_deliveries' }
  : { inv: 'invoices', items: 'invoice_items', exp: 'expenses', del: 'deliveries' }

/** A line's deliveries in a date range. */
const deliveriesIn = (table: string, a: string, b: string) => fetchAllRows<DelRow>((f, e) => supabase.from(table)
  .select('id,customer_name,location,amount,payment_method,delivered_at,note,invoice_number')
  .gte('delivered_at', a).lt('delivered_at', b).order('id').range(f, e))

// ── Small pieces ─────────────────────────────────────────────
const card: React.CSSProperties = { background: C.card, border: `1px solid ${C.line}`, borderRadius: 16, padding: 16 }
const label: React.CSSProperties = { fontSize: 12, fontWeight: 600, color: C.sub }
const sectionTitle: React.CSSProperties = { fontSize: 15, fontWeight: 700, color: C.ink, margin: '0 0 12px' }
const field: React.CSSProperties = {
  width: '100%', padding: '12px 14px', borderRadius: 12, outline: 'none',
  fontSize: 16, border: `1px solid ${C.line}`, background: C.card, color: C.ink,
}

/** A row of choices where exactly one is on — period, shop, warehouse. */
function Segmented<T extends string>({ value, options, onChange, scroll = false }: {
  value: T; options: { key: T; label: string }[]; onChange: (v: T) => void; scroll?: boolean
}) {
  return (
    <div className="tb-noscroll" style={{ display: 'flex', gap: 4, padding: 4, borderRadius: 12, background: '#e9ecf0', overflowX: scroll ? 'auto' : 'visible' }}>
      {options.map(o => {
        const on = o.key === value
        return (
          <button key={o.key} type="button" onClick={() => onChange(o.key)}
            style={{
              flex: scroll ? '0 0 auto' : 1, padding: '8px 12px', borderRadius: 9, border: 'none', whiteSpace: 'nowrap',
              fontSize: 13, fontWeight: 600, background: on ? C.card : 'transparent', color: on ? C.ink : C.sub,
              boxShadow: on ? '0 1px 2px rgba(15,23,42,0.12)' : 'none',
            }}>
            {o.label}
          </button>
        )
      })}
    </div>
  )
}

function Kpi({ title, value, tone = C.ink, note }: { title: string; value: string; tone?: string; note?: string }) {
  return (
    <div style={{ ...card, padding: 14 }}>
      <div style={label}>{title}</div>
      <div style={{ ...NUM, fontSize: 19, fontWeight: 700, color: tone, marginTop: 4, lineHeight: 1.2, wordBreak: 'break-word' }}>{value}</div>
      {note && <div style={{ fontSize: 11.5, color: C.faint, marginTop: 3 }}>{note}</div>}
    </div>
  )
}

function Pill({ text, color, bg }: { text: string; color: string; bg: string }) {
  return <span style={{ ...NUM, padding: '3px 9px', borderRadius: 999, fontSize: 12, fontWeight: 700, color, background: bg, whiteSpace: 'nowrap' }}>{text}</span>
}

const isoDay = (d = new Date()) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`

/**
 * Stock moves staff have entered, waiting for the Big Boss — main shop and
 * Dahua, the same queue as on the admin panel's Transfers tab. He approves
 * or rejects each here and reverses one already approved. Auto-accept is
 * switched from the admin panel (right-click the Transfers tab). Other bosses see what is waiting. The list keeps a fixed
 * height and scrolls inside. Below it, the Dahua movements as a PDF.
 */
function Approvals({ isSuperBoss, tick }: { isSuperBoss: boolean; tick: number }) {
  const [rows, setRows] = useState<StockRequest[]>([])
  const [state, setState] = useState<'loading' | 'ready' | 'failed'>('loading')
  const [view, setView] = useState<'pending' | 'approved'>('pending')
  const [busy, setBusy] = useState<string | null>(null)
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const [printing, setPrinting] = useState<'today' | 'all' | null>(null)
  const [now, setNow] = useState(() => Date.now())
  const auto = useAutoAccept()

  const load = useCallback(async (quiet = false) => {
    if (!quiet) setState('loading')
    try { setRows(await fetchStockRequests(80)); setState('ready') }
    catch { if (!quiet) setState('failed') }
  }, [])
  useEffect(() => { load() }, [load, tick])
  useEffect(() => {
    const again = () => load(true)
    window.addEventListener(STOCK_REQUESTS_CHANGED, again)
    const timer = setInterval(() => { if (document.visibilityState === 'visible') again() }, 60_000)
    return () => { window.removeEventListener(STOCK_REQUESTS_CHANGED, again); clearInterval(timer) }
  }, [load])

  const pending = rows.filter(r => r.status === 'pending')
  // Reversible: approved in the last week.
  const approved = rows.filter(r => r.status === 'approved' && Date.now() - new Date(r.decided_at || r.requested_at).getTime() < 7 * 86_400_000)
  const shown = view === 'pending' ? pending : approved

  // Auto-accept, unseen: a quiet tick so a due request is settled on time.
  useEffect(() => {
    if (!auto.on || pending.length === 0) return
    const timer = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(timer)
  }, [auto.on, pending.length])
  const leftOf = (r: StockRequest) => Math.max(0, auto.seconds - Math.floor((now - new Date(r.filed_at || r.requested_at).getTime()) / 1000))
  const due = auto.on && pending.some(r => leftOf(r) === 0)
  useEffect(() => { if (due) settleDue().finally(() => load(true)) }, [due, load])

  const act = async (r: StockRequest, what: 'approve' | 'reject' | 'reverse') => {
    let reason = ''
    if (what !== 'approve') {
      const asked = prompt(what === 'reject'
        ? `Reject ${r.request_number} from ${r.requested_name || 'staff'}? The stock will not change.\n\nReason (optional):`
        : `Reverse ${r.transfer_number}? The units go back where they were.\n\nWhy (optional):`)
      if (asked === null) return
      reason = asked
    }
    setBusy(r.id); setMsg(null)
    try {
      if (what === 'approve') { const res = await approveStockRequest(r.id); setMsg({ ok: true, text: `Approved — stock updated as ${res.transfer_number}.` }) }
      else if (what === 'reject') { await rejectStockRequest(r.id, reason); setMsg({ ok: true, text: `${r.request_number} rejected. Nothing changed.` }) }
      else { const res = await reverseStockRequest(r.id, reason); setMsg({ ok: true, text: `${r.transfer_number} reversed as ${res.reversal_number}.` }) }
    } catch (e: any) { setMsg({ ok: false, text: `${r.request_number}: ${e.message || 'that did not go through'}` }) }
    finally { setBusy(null) }
  }
  const pdf = async (which: 'today' | 'all') => {
    setPrinting(which); setMsg(null)
    try {
      const r = await downloadDahuaTransfersPdf(which === 'all' ? 'all' : isoDay())
      setMsg({ ok: true, text: `PDF downloaded: ${r.movements} movement${r.movements === 1 ? '' : 's'}${r.pending ? `, ${r.pending} waiting` : ''}.` })
    } catch (e: any) { setMsg({ ok: false, text: e.message || 'Could not make the PDF' }) }
    finally { setPrinting(null) }
  }

  // Before the approval migration there is nothing to show — not even an error.
  if (state === 'failed') return null
  const place = (line: string | null, wh: string | null, other: string | null) =>
    `${wh}${line && other && line !== other ? ` (${LINE_LABEL[line as StockLine]})` : ''}`
  const route = (r: StockRequest) => r.kind === 'move'
    ? `${place(r.from_line, r.from_warehouse, r.to_line)} → ${place(r.to_line, r.to_warehouse, r.from_line)}`
    : `${r.party ? `${r.party} → ` : ''}${r.to_warehouse}`
  const pdfBtn: React.CSSProperties = { flex: 1, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 6, padding: '10px 8px', borderRadius: 10, border: `1px solid ${C.line}`, background: C.card, color: C.brand, fontWeight: 600, fontSize: 13 }

  return (
    <div style={{ ...card, padding: 0, marginBottom: 12, overflow: 'hidden', borderColor: pending.length ? '#f1dcb5' : C.line }}>
      <div style={{ padding: '14px 14px 4px', display: 'flex', alignItems: 'center', gap: 8 }}>
        <div style={{ ...sectionTitle, margin: 0, flex: 1 }}>{isSuperBoss ? 'Waiting for your approval' : 'Waiting for the Big Boss'}</div>
        {pending.length > 0 && <Pill text={String(pending.length)} color="#1f1300" bg="#f59e0b" />}
      </div>
      <div style={{ padding: '0 14px 10px', fontSize: 12, color: C.sub }}>Moves, deliveries and returns staff entered, main shop and Dahua. The stock changes only when approved.</div>
      <div style={{ padding: '0 14px 10px' }}>
        <Segmented value={view} onChange={setView}
          options={[{ key: 'pending', label: `Waiting · ${pending.length}` }, { key: 'approved', label: `Approved · ${approved.length}` }]} />
      </div>
      {msg && <div style={{ margin: '0 14px 10px', padding: '9px 12px', borderRadius: 10, fontSize: 13, fontWeight: 600, color: msg.ok ? C.good : C.bad, background: msg.ok ? C.goodTint : C.badTint }}>{msg.text}</div>}
      {/* A fixed height: the page never grows with the queue. */}
      <div style={{ maxHeight: 360, overflowY: 'auto', overscrollBehavior: 'contain', borderTop: `1px solid ${C.line}` }}>
        {state === 'loading' && <div style={{ padding: '14px', fontSize: 13, color: C.sub }}>Loading…</div>}
        {state === 'ready' && shown.length === 0 && <div style={{ padding: '14px', fontSize: 13, color: C.sub }}>{view === 'pending' ? 'Nothing waiting.' : 'Nothing approved this week.'}</div>}
        {state === 'ready' && shown.map((r, n) => {
          return (
            <div key={r.id} style={{ padding: '12px 14px', borderTop: n ? `1px solid ${C.line}` : 'none', position: 'relative' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                <Pill text={r.kind === 'move' ? 'Move' : r.kind === 'receive' ? 'Delivery' : 'Return'} color={r.status === 'pending' ? C.warn : C.good} bg={r.status === 'pending' ? C.warnTint : C.goodTint} />
                <span style={{ fontSize: 14, fontWeight: 600, wordBreak: 'break-word' }}>{route(r)}</span>
              </div>
              <div style={{ fontSize: 12, color: C.sub, marginTop: 3 }}>
                {r.requested_name || r.requested_staff_id || 'Staff'} · {timeOf(r.requested_at)}
                {r.status === 'approved' ? ` · ${r.transfer_number}` : ''}{r.note ? ` · ${r.note}` : ''}
              </div>
              <div style={{ marginTop: 6, fontSize: 13 }}>
                {(r.items || []).map((i, k) => (
                  <div key={k} style={{ wordBreak: 'break-word', padding: '1px 0' }}>
                    <strong style={NUM}>{Number(i.quantity).toLocaleString()}</strong> × {i.model}
                    {i.to_model && i.to_model !== i.model ? <span style={{ color: C.sub }}> (arrives as {i.to_model})</span> : null}
                    {i.condition === 'spoilt' ? <span style={{ color: C.bad }}> · spoilt</span> : null}
                  </div>
                ))}
              </div>
              {isSuperBoss && r.status === 'pending' && (
                <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
                  <button type="button" disabled={busy === r.id} onClick={() => act(r, 'approve')}
                    style={{ flex: 2, padding: 11, borderRadius: 10, border: 'none', background: C.brand, color: '#fff', fontWeight: 700, fontSize: 14, opacity: busy === r.id ? 0.6 : 1 }}>
                    {busy === r.id ? '…' : 'Approve'}
                  </button>
                  <button type="button" disabled={busy === r.id} onClick={() => act(r, 'reject')}
                    style={{ flex: 1, padding: 11, borderRadius: 10, border: '1px solid #f3c4c4', background: C.card, color: C.bad, fontWeight: 700, fontSize: 14 }}>
                    Reject
                  </button>
                </div>
              )}
              {isSuperBoss && r.status === 'approved' && (
                <button type="button" disabled={busy === r.id} onClick={() => act(r, 'reverse')}
                  style={{ width: '100%', marginTop: 10, padding: 10, borderRadius: 10, border: `1px solid ${C.line}`, background: C.card, color: C.ink, fontWeight: 700, fontSize: 13.5 }}>
                  {busy === r.id ? '…' : '↶ Reverse'}
                </button>
              )}
            </div>
          )
        })}
      </div>
      <div style={{ display: 'flex', gap: 8, padding: 12, borderTop: `1px solid ${C.line}`, background: C.bg }}>
        <button type="button" disabled={!!printing} onClick={() => pdf('today')} style={pdfBtn}><FileDown size={15} />{printing === 'today' ? 'Making…' : "Today's PDF"}</button>
        <button type="button" disabled={!!printing} onClick={() => pdf('all')} style={pdfBtn}><FileDown size={15} />{printing === 'all' ? 'Making…' : 'All-time PDF'}</button>
      </div>
    </div>
  )
}

const stockTone = (qty: number) => qty < 0 ? { color: C.bad, bg: C.badTint } : qty === 0 ? { color: C.sub, bg: '#eef1f4' } : { color: C.good, bg: C.goodTint }

export default function BossView({ isSuperBoss, windowed, onMoves, onSignOut }: {
  /** May change prices. Everyone else on this screen only reads. */
  isSuperBoss: boolean
  /** A restricted boss: the database gives this login the last 24 hours only. */
  windowed: boolean
  onMoves: () => void
  onSignOut: () => void
}) {
  const [tab, setTab] = useState<Tab>('overview')
  const [period, setPeriod] = useState<Period>('today')
  const [scope, setScope] = useState<Scope>('both')
  const [tick, setTick] = useState(0)
  const waiting = usePendingCount(isSuperBoss)
  const [spinning, setSpinning] = useState(false)
  const refresh = () => { setTick(t => t + 1); setSpinning(true); setTimeout(() => setSpinning(false), 700) }

  // ── Overview ─────────────────────────────────────────────
  const [invoices, setInvoices] = useState<Invoice[]>([])
  const [sold, setSold] = useState<SoldItem[]>([])
  const [spent, setSpent] = useState(0)
  const [dels, setDels] = useState<(DelRow & { line: StockLine })[]>([])
  // Sales on credit: which invoices they are, what was paid against them in
  // this period, and what is still owed in all.
  const [credit, setCredit] = useState<{ numbers: Set<string>; paid: { line: StockLine; amount: number; method: string; at: string }[]; owed: number; debtors: number }>(
    { numbers: new Set(), paid: [], owed: 0, debtors: 0 })
  const [before, setBefore] = useState<number | null>(null)
  const [salesState, setSalesState] = useState<'loading' | 'ready' | 'failed'>('loading')
  const [openInvoice, setOpenInvoice] = useState<string | null>(null)
  const [allInvoices, setAllInvoices] = useState(false)

  useEffect(() => {
    if (tab !== 'overview') return
    let cancelled = false
    setSalesState('loading')
    const r = rangeOf(period)
    const a = r.from.toISOString(), b = r.to.toISOString()
    ;(async () => {
      try {
        const lines: StockLine[] = scope === 'both' ? ['main', 'dahua'] : [scope]
        const inv: Invoice[] = [], items: SoldItem[] = [], del: (DelRow & { line: StockLine })[] = []
        const cr = { numbers: new Set<string>(), paid: [] as { line: StockLine; amount: number; method: string; at: string }[], owed: 0, debtors: 0 }
        let exp = 0, prev = 0
        for (const l of lines) {
          const t = tablesOf(l)
          const rows = await fetchAllRows<Omit<Invoice, 'line'>>((f, e) => supabase.from(t.inv)
            .select('id,invoice_number,customer_name,payment_method,total,issued_at')
            .gte('issued_at', a).lt('issued_at', b).order('issued_at', { ascending: false }).order('id').range(f, e))
          inv.push(...rows.map(x => ({ ...x, line: l, total: Number(x.total) || 0 })))
          for (const ids of chunk(rows.map(x => x.id), 80)) {
            const { data, error } = await supabase.from(t.items).select('invoice_id,description,quantity,line_total').in('invoice_id', ids).limit(5000)
            if (error) throw error
            items.push(...(data || []).map(i => ({ ...i, quantity: Number(i.quantity) || 0, line_total: Number(i.line_total) || 0 })))
          }
          const ex = await fetchAllRows<{ amount: number }>((f, e) => supabase.from(t.exp)
            .select('id,amount').gte('incurred_at', a).lt('incurred_at', b).order('id').range(f, e))
          exp += ex.reduce((s, x) => s + (Number(x.amount) || 0), 0)
          del.push(...(await deliveriesIn(t.del, a, b)).map(d => ({ ...d, line: l })))
          // Credit sales: never throws — with no Debtors table yet it is simply empty.
          const ledger = await loadCreditLedger(l)
          ledger.numbers.forEach(n => cr.numbers.add(n))
          cr.owed += ledger.outstanding; cr.debtors += ledger.debtors
          cr.paid.push(...ledger.payments.filter(x => x.paid_at >= a && x.paid_at < b).map(x => ({ line: l, amount: x.amount, method: x.payment_method, at: x.paid_at })))
          // Only the totals are needed from the stretch before — worked out
          // the same way: counter sales, plus deliveries.
          const pa = r.prevFrom.toISOString(), pb = r.prevTo.toISOString()
          const [pr, pd] = await Promise.all([
            fetchAllRows<{ total: number; invoice_number: string }>((f, e) => supabase.from(t.inv)
              .select('id,invoice_number,total').gte('issued_at', pa).lt('issued_at', pb).order('id').range(f, e)),
            deliveriesIn(t.del, pa, pb),
          ])
          const prevDelivered = deliveredInvoiceNumbers(pd)
          prev += pr.filter(x => !prevDelivered.has(x.invoice_number) && !ledger.numbers.has(x.invoice_number)).reduce((s, x) => s + (Number(x.total) || 0), 0)
                + pd.filter(x => !x.invoice_number || !ledger.numbers.has(x.invoice_number)).reduce((s, x) => s + (Number(x.amount) || 0), 0)
                + ledger.payments.filter(x => x.paid_at >= pa && x.paid_at < pb).reduce((s, x) => s + x.amount, 0)
        }
        if (cancelled) return
        inv.sort((x, y) => y.issued_at.localeCompare(x.issued_at))
        setInvoices(inv); setSold(items); setSpent(exp); setDels(del.filter(d => !d.invoice_number || !cr.numbers.has(d.invoice_number))); setCredit(cr); setBefore(prev); setSalesState('ready')
      } catch {
        if (!cancelled) setSalesState('failed')
      }
    })()
    return () => { cancelled = true }
  }, [tab, period, scope, tick])

  // A sale with Delivery switched on is one sale: counted under deliveries,
  // at its invoice's total, and left out of counter sales.
  const delivered = useMemo(() => deliveredInvoiceNumbers(dels), [dels])

  const sales = useMemo(() => {
    // A credit sale is not money in until it is paid: its invoice is left
    // out, and what was paid against debts in this period is counted instead.
    const counterInv = invoices.filter(i => !delivered.has(i.invoice_number) && !credit.numbers.has(i.invoice_number))
    const counter = counterInv.reduce((s, i) => s + i.total, 0)
    const delivery = dels.reduce((s, d) => s + (Number(d.amount) || 0), 0)
    const debtPaid = credit.paid.reduce((s, x) => s + x.amount, 0)
    const total = counter + delivery + debtPaid
    const byItem = new Map<string, { qty: number; amount: number }>()
    let units = 0
    for (const i of sold) {
      const k = i.description.trim() || 'Unnamed item'
      const v = byItem.get(k) || { qty: 0, amount: 0 }
      v.qty += i.quantity; v.amount += i.line_total; units += i.quantity
      byItem.set(k, v)
    }
    const paid = { cash: 0, momo: 0, bank: 0, other: 0 }
    const addPaid = (method: string | null, amount: number) => {
      const b = paymentBuckets(method, amount)
      paid.cash += b.cash; paid.momo += b.momo; paid.bank += b.bank; paid.other += b.other
    }
    for (const i of counterInv) addPaid(i.payment_method, i.total)
    for (const d of dels) addPaid(d.payment_method || 'Cash', Number(d.amount) || 0)
    for (const x of credit.paid) addPaid(x.method, x.amount)

    // One bar per day, for the ranges long enough to have a shape.
    const days: { key: string; label: string; total: number }[] = []
    if (period === 'week' || period === 'month') {
      const r = rangeOf(period)
      for (let d = new Date(r.from); d < r.to; d = addDays(d, 1)) {
        days.push({ key: d.toDateString(), label: period === 'week' ? d.toLocaleDateString('en-GB', { weekday: 'short' }) : String(d.getDate()), total: 0 })
      }
      const at = new Map(days.map((d, n) => [d.key, n]))
      for (const i of counterInv) { const n = at.get(new Date(i.issued_at).toDateString()); if (n !== undefined) days[n].total += i.total }
      for (const d of dels) { const n = at.get(new Date(d.delivered_at).toDateString()); if (n !== undefined) days[n].total += Number(d.amount) || 0 }
      for (const x of credit.paid) { const n = at.get(new Date(x.at).toDateString()); if (n !== undefined) days[n].total += x.amount }
    }
    const main = counterInv.filter(i => i.line === 'main').reduce((s, i) => s + i.total, 0)
               + dels.filter(d => d.line === 'main').reduce((s, d) => s + (Number(d.amount) || 0), 0)
               + credit.paid.filter(x => x.line === 'main').reduce((s, x) => s + x.amount, 0)
    return {
      total, units, counter, delivery, debtPaid, count: counterInv.length, deliveryCount: dels.length, days, main, dahua: total - main,
      top: Array.from(byItem, ([name, v]) => ({ name, ...v })).sort((a, b) => b.amount - a.amount).slice(0, 8),
      pay: [{ method: 'Cash', amount: paid.cash }, { method: 'Mobile Money', amount: paid.momo }, { method: 'Bank Transfer', amount: paid.bank }, { method: 'Other', amount: paid.other }]
        .filter(x => x.amount > 0).sort((a, b) => b.amount - a.amount),
    }
  }, [invoices, sold, dels, delivered, credit, period])

  // ── Activity ─────────────────────────────────────────────
  const [moves, setMoves] = useState<Movement[]>([])
  const [movesState, setMovesState] = useState<'loading' | 'ready' | 'failed'>('loading')
  const [openMove, setOpenMove] = useState<string | null>(null)

  useEffect(() => {
    if (tab !== 'activity') return
    let cancelled = false
    setMovesState('loading')
    const { from, to } = rangeOf(period)
    ;(async () => {
      try {
        const all: Movement[] = []
        for (const t of [{ head: 'stock_transfers', items: 'stock_transfer_items' }, { head: 'dahua_stock_transfers', items: 'dahua_stock_transfer_items' }]) {
          const { data, error } = await supabase.from(t.head)
            .select(`transfer_number,kind,from_warehouse,to_warehouse,supplier,signed_by,staff_id,transferred_at,items:${t.items}(model,quantity)`)
            .gte('transferred_at', from.toISOString()).lt('transferred_at', to.toISOString())
            .order('transferred_at', { ascending: false }).limit(500)
          if (error) throw error
          all.push(...((data as unknown as Movement[]) || []))
        }
        if (cancelled) return
        // A move between the main shop and Dahua is recorded on both sides under one number.
        const seen = new Set<string>()
        setMoves(all.filter(m => !seen.has(m.transfer_number) && seen.add(m.transfer_number))
          .sort((x, y) => y.transferred_at.localeCompare(x.transferred_at)))
        setMovesState('ready')
      } catch {
        if (!cancelled) setMovesState('failed')
      }
    })()
    return () => { cancelled = true }
  }, [tab, period, tick])

  const unitsOf = (m: Movement) => (m.items || []).reduce((n, i) => n + i.quantity, 0)
  const activity = useMemo(() => {
    const people = new Map<string, { entries: number; units: number }>()
    for (const m of moves) {
      const who = m.signed_by || m.staff_id || 'Unknown'
      const p = people.get(who) || { entries: 0, units: 0 }
      p.entries++; p.units += (m.items || []).reduce((n, i) => n + i.quantity, 0)
      people.set(who, p)
    }
    return {
      units: moves.reduce((n, m) => n + (m.items || []).reduce((k, i) => k + i.quantity, 0), 0),
      people: Array.from(people, ([name, v]) => ({ name, ...v })).sort((a, b) => b.entries - a.entries),
      kinds: (['move', 'receive', 'return', 'reversal'] as const).map(k => ({ kind: k, n: moves.filter(m => m.kind === k).length })),
    }
  }, [moves])

  // ── Stock and prices (one list, two ways of looking at it) ──
  const [stockLine, setStockLine] = useState<StockLine>('main')
  const [products, setProducts] = useState<Product[]>([])
  const [stockState, setStockState] = useState<'loading' | 'ready' | 'failed'>('loading')
  const [query, setQuery] = useState('')
  const [searching, setSearching] = useState(false)
  const [warehouse, setWarehouse] = useState('ALL')
  const [stockFilter, setStockFilter] = useState<'all' | 'in' | 'out' | 'negative'>('in')
  const [openProduct, setOpenProduct] = useState<string | null>(null)
  const [unpricedOnly, setUnpricedOnly] = useState(false)
  const [editing, setEditing] = useState<string | null>(null)
  const [draft, setDraft] = useState('')
  const [saving, setSaving] = useState(false)
  const [priceMsg, setPriceMsg] = useState<{ ok: boolean; text: string } | null>(null)

  const loadProducts = useCallback(async (line: StockLine) => {
    setStockState('loading')
    try {
      const byModel = new Map<string, Product>()
      if (line === 'main') {
        const [stock, list] = await Promise.all([
          fetchAllRows<{ id: string; warehouse: string; model: string; closing_stock: number; opening_stock: number }>((f, e) => supabase.from('warehouse_stock')
            .select('id,warehouse,model,closing_stock,opening_stock').order('id').range(f, e)),
          fetchAllRows<{ model: string; ghs_price: number; created_at: string }>((f, e) => supabase.from('pricelist_items')
            .select('id,model,ghs_price,created_at').order('id').range(f, e)),
        ])
        // One price per model; the most recently entered priced row wins, as price_for_model() does.
        const price = new Map<string, { p: number; at: string }>()
        for (const r of list) {
          const k = priceKey(r.model || ''), p = Number(r.ghs_price) || 0
          if (!k || p <= 0) continue
          const seen = price.get(k)
          if (!seen || r.created_at > seen.at) price.set(k, { p, at: r.created_at })
        }
        for (const r of stock) {
          if (r.warehouse === SPOILT) continue
          const pr = byModel.get(r.model) || { line, model: r.model, places: [], rows: [], total: 0, price: price.get(priceKey(r.model))?.p ?? 0 }
          const qty = Number(r.closing_stock) || 0
          pr.rows.push({ id: r.id, warehouse: r.warehouse, qty, opening: Number(r.opening_stock) || 0 })
          if (qty !== 0) pr.places.push({ warehouse: r.warehouse, qty })
          pr.total += qty
          byModel.set(r.model, pr)
        }
      } else {
        const stock = await fetchAllRows<{ id: string; warehouse: string; model: string; closing_stock: number; opening_stock: number; unit_price: number }>((f, e) => supabase.from('dahua_stock')
          .select('id,warehouse,model,closing_stock,opening_stock,unit_price').order('id').range(f, e))
        for (const r of stock) {
          if (r.warehouse === SPOILT) continue
          const pr = byModel.get(r.model) || { line, model: r.model, places: [], rows: [], total: 0, price: 0 }
          const qty = Number(r.closing_stock) || 0
          pr.rows.push({ id: r.id, warehouse: r.warehouse, qty, opening: Number(r.opening_stock) || 0 })
          if (qty !== 0) pr.places.push({ warehouse: r.warehouse, qty })
          pr.total += qty
          pr.price = Math.max(pr.price, Number(r.unit_price) || 0)
          byModel.set(r.model, pr)
        }
      }
      setProducts(Array.from(byModel.values()).sort((a, b) => a.model.localeCompare(b.model)))
      setStockState('ready')
    } catch {
      setStockState('failed')
    }
  }, [])
  useEffect(() => { if (tab === 'stock' || tab === 'prices') loadProducts(stockLine) }, [tab, stockLine, tick, loadProducts])

  const warehouses = useMemo(() => Array.from(new Set(products.flatMap(p => p.places.map(x => x.warehouse)))).sort(), [products])
  /** What the chosen warehouse holds of a product — or everything, when none is chosen. */
  const qtyIn = useCallback((p: Product) => warehouse === 'ALL' ? p.total : (p.places.find(x => x.warehouse === warehouse)?.qty ?? 0), [warehouse])

  const stockShown = useMemo(() => {
    const q = query.trim().toLowerCase()
    return products.filter(p => {
      if (q && !p.model.toLowerCase().includes(q)) return false
      const n = qtyIn(p)
      if (warehouse !== 'ALL' && !p.places.some(x => x.warehouse === warehouse)) return false
      // A search looks through everything, whatever the filter says.
      if (q) return true
      return stockFilter === 'all' || (stockFilter === 'in' && n > 0) || (stockFilter === 'out' && n === 0) || (stockFilter === 'negative' && n < 0)
    })
  }, [products, query, warehouse, stockFilter, qtyIn])

  const belowZero = useMemo(() => products
    .filter(p => (warehouse === 'ALL' || p.places.some(x => x.warehouse === warehouse)) && qtyIn(p) < 0).length,
  [products, warehouse, qtyIn])

  const priceShown = useMemo(() => {
    const q = query.trim().toLowerCase()
    return products.filter(p => (!q || p.model.toLowerCase().includes(q)) && (!unpricedOnly || p.price <= 0))
  }, [products, query, unpricedOnly])
  const unpriced = useMemo(() => products.filter(p => p.price <= 0).length, [products])

  const savePrice = async (p: Product) => {
    if (saving) return
    const price = Math.max(0, Math.round((parseFloat(draft) || 0) * 100) / 100)
    if (price === p.price) { setEditing(null); return }
    setSaving(true); setPriceMsg(null)
    // The main shop keeps one price per product, in the price list. Dahua
    // keeps it on the stock row, so every row of the model is set alike.
    const { error } = p.line === 'main'
      ? await supabase.rpc('set_model_price', { p_model: p.model, p_price: price })
      : await supabase.from('dahua_stock').update({ unit_price: price, updated_at: new Date().toISOString() }).eq('model', p.model)
    setSaving(false)
    if (error) { setPriceMsg({ ok: false, text: error.message || 'Could not save that price' }); return }
    setProducts(list => list.map(x => (x.model === p.model ? { ...x, price } : x)))
    setEditing(null)
    setPriceMsg({ ok: true, text: price > 0 ? `${p.model} is now ${GHS(price)}` : `${p.model} — price cleared` })
  }

  /**
   * The Big Boss corrects a count: he types what is really on the shelf.
   * The count itself is worked out by the database (opening + moved in −
   * moved out − invoiced − taken), so the opening figure is moved by the
   * difference, exactly as editing Opening Stock in the admin does. Every
   * other figure, and the record of what invoices and moves did, is left
   * alone. The write only lands if the count is still the one he was shown:
   * a sale in between is not silently overwritten.
   */
  const [countEdit, setCountEdit] = useState<{ id: string; value: string } | null>(null)
  const [countSaving, setCountSaving] = useState(false)
  const [countMsg, setCountMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const saveCount = async (p: Product, row: StockRow) => {
    if (countSaving || !countEdit) return
    const raw = countEdit.value.trim()
    const next = Number(raw)
    if (raw === '' || !Number.isInteger(next) || next < 0) { setCountMsg({ ok: false, text: 'Type the count as a whole number, 0 or more.' }); return }
    if (next === row.qty) { setCountEdit(null); return }
    setCountSaving(true); setCountMsg(null)
    const { data, error } = await supabase.from(p.line === 'dahua' ? 'dahua_stock' : 'warehouse_stock')
      .update({ opening_stock: row.opening + (next - row.qty), updated_at: new Date().toISOString() })
      .eq('id', row.id).eq('closing_stock', row.qty).eq('opening_stock', row.opening)
      .select('closing_stock,opening_stock')
    setCountSaving(false)
    if (error) { setCountMsg({ ok: false, text: error.message || 'Could not save that count' }); return }
    const saved = (data as { closing_stock: number; opening_stock: number }[] | null)?.[0]
    if (!saved) {
      setCountEdit(null)
      setCountMsg({ ok: false, text: `${p.model} in ${row.warehouse} changed while you were typing (a sale or a move). Here is the new figure — check it and set it again.` })
      loadProducts(p.line)
      return
    }
    const qty = Number(saved.closing_stock) || 0, opening = Number(saved.opening_stock) || 0
    setProducts(list => list.map(x => {
      if (x.model !== p.model) return x
      const rows = x.rows.map(r => (r.id === row.id ? { ...r, qty, opening } : r))
      return { ...x, rows, total: rows.reduce((s, r) => s + r.qty, 0), places: rows.filter(r => r.qty !== 0).map(r => ({ warehouse: r.warehouse, qty: r.qty })) }
    }))
    setCountEdit(null)
    setCountMsg({ ok: true, text: `${p.model} in ${row.warehouse}: ${row.qty.toLocaleString()} → ${qty.toLocaleString()}` })
  }

  // ── Shared bits of screen ────────────────────────────────
  const windowNote = windowed && (
    <div style={{ fontSize: 12.5, color: C.warn, background: C.warnTint, borderRadius: 10, padding: '8px 12px', marginTop: 12 }}>
      This login sees the last 24 hours only, whatever range is picked.
    </div>
  )
  const loading = <div style={{ color: C.sub, fontSize: 14, padding: '28px 4px', textAlign: 'center' }}>Loading…</div>
  const failed = (what: string) => (
    <div style={{ ...card, marginTop: 12, borderColor: '#f3c4c4', background: C.badTint, color: C.bad, fontSize: 14 }}>
      Could not load {what}. This needs a signal.{' '}
      <button type="button" onClick={refresh} style={{ background: 'none', border: 'none', padding: 0, color: C.bad, fontWeight: 700, fontSize: 14, textDecoration: 'underline' }}>Try again</button>
    </div>
  )
  const empty = (text: string) => <div style={{ color: C.sub, fontSize: 14, padding: '24px 4px', textAlign: 'center' }}>{text}</div>
  // The search box sits right above its list. Tapping it slides it up under
  // the app bar, so the results fill the space the phone's keyboard leaves.
  // Instant: a smooth scroll is cut short by the keyboard opening and the list redrawing.
  const toTop = (el: HTMLElement) => setTimeout(() => el.scrollIntoView({ block: 'start', behavior: 'instant' }), 300)
  const searchBox = (placeholder: string) => (
    // The site already keeps 80px clear above anything scrolled to (globals.css); only the notch is added.
    <div style={{ position: 'relative', scrollMarginTop: 'env(safe-area-inset-top)' }}>
      <Search size={18} color={C.faint} style={{ position: 'absolute', left: 14, top: '50%', transform: 'translateY(-50%)', pointerEvents: 'none' }} />
      <input type="search" enterKeyHint="search" style={{ ...field, paddingLeft: 42, paddingRight: query ? 44 : 14 }} value={query} placeholder={placeholder}
        onChange={e => setQuery(e.target.value)}
        onFocus={e => { setSearching(true); toTop(e.currentTarget.parentElement!) }}
        onBlur={() => setSearching(false)}
        onKeyDown={e => { if (e.key === 'Enter') e.currentTarget.blur() }} />
      {query && (
        <button type="button" aria-label="Clear search" onClick={() => setQuery('')}
          style={{ position: 'absolute', right: 6, top: '50%', transform: 'translateY(-50%)', width: 34, height: 34, borderRadius: 999, border: 'none', background: '#eef1f4', color: C.sub, fontSize: 15, fontWeight: 700 }}>✕</button>
      )}
    </div>
  )
  // While searching, the list keeps at least a screen's height under the box,
  // so it can always be slid up to the top, however few products match.
  const roomWhileSearching: React.CSSProperties = searching || query ?{ minHeight: 'calc(100dvh - 160px)' } : {}
  const lineSwitch = (
    <Segmented value={stockLine} onChange={l => { setStockLine(l); setWarehouse('ALL'); setEditing(null); setOpenProduct(null); setPriceMsg(null); setCountEdit(null); setCountMsg(null) }}
      options={[{ key: 'main', label: 'Main shop' }, { key: 'dahua', label: 'Dahua' }]} />
  )

  const delta = before !== null && before > 0 ? ((sales.total - before) / before) * 100 : null
  const net = sales.total - spent
  const peak = Math.max(1, ...sales.days.map(d => d.total))
  const titles: Record<Tab, string> = { overview: 'Overview', stock: 'Stock', prices: 'Prices', activity: 'Stock activity' }
  const NAV: { key: Tab | 'moves'; label: string; Icon: typeof BarChart3 }[] = [
    { key: 'overview', label: 'Overview', Icon: BarChart3 },
    { key: 'stock', label: 'Stock', Icon: Boxes },
    { key: 'prices', label: 'Prices', Icon: Tag },
    { key: 'activity', label: 'Activity', Icon: ClipboardList },
    { key: 'moves', label: 'Moves', Icon: ArrowLeftRight },
  ]

  return (
    <div className="tb-app" style={{ minHeight: '100dvh', background: C.bg, color: C.ink, paddingTop: 'calc(69px + env(safe-area-inset-top))', paddingBottom: 'calc(78px + env(safe-area-inset-bottom))' }}>
      {/* The site's display font is for the shop window; figures need one made for reading. */}
      <style>{`
        .tb-app, .tb-app button, .tb-app input, .tb-app select { font-family: Inter, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; letter-spacing: 0; }
        .tb-app button { cursor: pointer; -webkit-tap-highlight-color: transparent; }
        .tb-app input[type=search] { -webkit-appearance: none; appearance: none; }
        .tb-app input[type=search]::-webkit-search-cancel-button { display: none; }
        .tb-noscroll { scrollbar-width: none; } .tb-noscroll::-webkit-scrollbar { display: none; }
        @keyframes tb-spin { to { transform: rotate(360deg); } }
      `}</style>

      {/* ── App bar ── */}
      {/* Fixed, not sticky: the site sets overflow-x on the page, and sticky does not hold under that. */}
      <div style={{ position: 'fixed', top: 0, left: 0, right: 0, zIndex: 60, background: 'rgba(245,246,248,0.92)', backdropFilter: 'blur(10px)', WebkitBackdropFilter: 'blur(10px)', borderBottom: `1px solid ${C.line}`, padding: 'calc(12px + env(safe-area-inset-top)) 16px 12px' }}>
        <div style={{ maxWidth: 640, margin: '0 auto', display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 11.5, fontWeight: 600, color: C.sub }}>QBNET TECH · {new Date().toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' })}</div>
            <div style={{ fontSize: 21, fontWeight: 700, lineHeight: 1.2 }}>{titles[tab]}</div>
          </div>
          <button type="button" onClick={refresh} aria-label="Refresh"
            style={{ width: 40, height: 40, borderRadius: 12, border: `1px solid ${C.line}`, background: C.card, display: 'grid', placeItems: 'center' }}>
            <RefreshCw size={18} color={C.brand} style={{ animation: spinning ? 'tb-spin 0.7s linear' : 'none' }} />
          </button>
        </div>
      </div>

      <div style={{ maxWidth: 640, margin: '0 auto', padding: 16 }}>
        {/* ── Overview ── */}
        {tab === 'overview' && (
          <>
            <Segmented value={period} onChange={setPeriod} options={PERIODS} />
            <div style={{ marginTop: 8 }}>
              <Segmented value={scope} onChange={setScope} options={[{ key: 'both', label: 'All' }, { key: 'main', label: 'Main shop' }, { key: 'dahua', label: 'Dahua' }]} />
            </div>
            {windowNote}
            {salesState === 'loading' ? loading : salesState === 'failed' ? failed('sales') : (
              <>
                {/* The one number that matters most, and whether it is up or down. */}
                <div style={{ marginTop: 12, borderRadius: 18, padding: 18, color: '#fff', background: `linear-gradient(135deg, ${C.brand} 0%, ${C.brandDark} 100%)` }}>
                  <div style={{ fontSize: 12.5, fontWeight: 600, opacity: 0.85 }}>Sales · {PERIODS.find(p => p.key === period)!.label.toLowerCase()}</div>
                  <div style={{ ...NUM, fontSize: 32, fontWeight: 700, margin: '4px 0 8px', lineHeight: 1.15 }}>{GHS(sales.total)}</div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', fontSize: 12.5 }}>
                    {delta !== null ? (
                      <span style={{ ...NUM, display: 'inline-flex', alignItems: 'center', gap: 4, padding: '3px 9px', borderRadius: 999, fontWeight: 700, background: 'rgba(255,255,255,0.18)' }}>
                        {delta >= 0 ? <TrendingUp size={14} /> : <TrendingDown size={14} />}
                        {delta >= 0 ? '+' : ''}{delta.toFixed(0)}%
                      </span>
                    ) : null}
                    <span style={{ opacity: 0.85 }}>
                      {before === null || before <= 0
                        ? `Nothing sold ${PERIODS.find(p => p.key === period)!.before} to compare with`
                        : `${GHS(before)} ${PERIODS.find(p => p.key === period)!.before}`}
                    </span>
                  </div>
                </div>

                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginTop: 10 }}>
                  <Kpi title="Counter sales" value={GHS(sales.counter)} note={`${sales.count.toLocaleString()} invoice${sales.count === 1 ? '' : 's'}`} />
                  <Kpi title="Deliveries" value={GHS(sales.delivery)} note={`${sales.deliveryCount.toLocaleString()} deliver${sales.deliveryCount === 1 ? 'y' : 'ies'}`} />
                  <Kpi title="Debts paid in" value={GHS(sales.debtPaid)} note={`${credit.paid.length} payment${credit.paid.length === 1 ? '' : 's'}`} />
                  <Kpi title="Still owed to you" value={GHS(credit.owed)} tone={credit.owed > 0 ? C.warn : C.ink} note={`${credit.debtors} customer${credit.debtors === 1 ? '' : 's'} · not in sales`} />
                  <Kpi title="Expenses" value={GHS(spent)} tone={spent > 0 ? C.warn : C.ink} />
                  <Kpi title="Sales less expenses" value={GHS(net)} tone={net < 0 ? C.bad : C.good} />
                </div>

                {scope === 'both' && sales.total > 0 && (
                  <div style={{ ...card, marginTop: 10 }}>
                    <div style={sectionTitle}>Where it came from</div>
                    <div style={{ display: 'flex', height: 10, borderRadius: 999, overflow: 'hidden', background: C.line }}>
                      <div style={{ width: `${(sales.main / sales.total) * 100}%`, background: C.brand }} />
                      <div style={{ flex: 1, background: '#f59e0b' }} />
                    </div>
                    <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, marginTop: 10, fontSize: 13 }}>
                      <span><span style={{ display: 'inline-block', width: 8, height: 8, borderRadius: 2, background: C.brand, marginRight: 6 }} />Main shop <strong style={NUM}>{GHS(sales.main)}</strong></span>
                      <span><span style={{ display: 'inline-block', width: 8, height: 8, borderRadius: 2, background: '#f59e0b', marginRight: 6 }} />Dahua <strong style={NUM}>{GHS(sales.dahua)}</strong></span>
                    </div>
                  </div>
                )}

                {sales.days.length > 0 && sales.total > 0 && (
                  <div style={{ ...card, marginTop: 10 }}>
                    <div style={sectionTitle}>Day by day</div>
                    <div style={{ display: 'flex', alignItems: 'flex-end', gap: period === 'week' ? 8 : 2, height: 96 }}>
                      {sales.days.map(d => (
                        <div key={d.key} title={`${d.key}: ${GHS(d.total)}`} style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end', height: '100%' }}>
                          <div style={{ height: `${Math.max(d.total > 0 ? 4 : 1, (d.total / peak) * 100)}%`, borderRadius: 4, background: d.total > 0 ? C.brand : C.line, opacity: d.total === peak ? 1 : 0.6 }} />
                        </div>
                      ))}
                    </div>
                    <div style={{ display: 'flex', gap: period === 'week' ? 8 : 2, marginTop: 6 }}>
                      {sales.days.map((d, n) => (
                        <div key={d.key} style={{ flex: 1, textAlign: 'center', fontSize: 10.5, color: C.faint }}>
                          {period === 'week' || n === 0 || (n + 1) % 5 === 0 ? d.label : ''}
                        </div>
                      ))}
                    </div>
                    <div style={{ fontSize: 12, color: C.sub, marginTop: 8 }}>Best day: <strong style={{ ...NUM, color: C.ink }}>{GHS(peak)}</strong></div>
                  </div>
                )}

                {sales.pay.length > 0 && (
                  <div style={{ ...card, marginTop: 10 }}>
                    <div style={sectionTitle}>How it was paid</div>
                    {sales.pay.map(p => (
                      <div key={p.method} style={{ marginBottom: 10 }}>
                        <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10, fontSize: 13.5, marginBottom: 5 }}>
                          <span>{p.method}</span>
                          <span style={NUM}><strong>{GHS(p.amount)}</strong> <span style={{ color: C.faint }}>· {sales.total ? Math.round((p.amount / sales.total) * 100) : 0}%</span></span>
                        </div>
                        <div style={{ height: 6, borderRadius: 999, background: C.line }}>
                          <div style={{ height: '100%', borderRadius: 999, background: C.brand, width: `${sales.total ? (p.amount / sales.total) * 100 : 0}%` }} />
                        </div>
                      </div>
                    ))}
                  </div>
                )}

                {sales.top.length > 0 && (
                  <div style={{ ...card, marginTop: 10 }}>
                    <div style={sectionTitle}>Top items sold</div>
                    {sales.top.map((i, n) => (
                      <div key={i.name} style={{ display: 'flex', gap: 12, alignItems: 'center', padding: '9px 0', borderTop: n ? `1px solid ${C.line}` : 'none' }}>
                        <span style={{ ...NUM, width: 22, height: 22, borderRadius: 7, background: C.tint, color: C.brand, fontSize: 12, fontWeight: 700, display: 'grid', placeItems: 'center', flexShrink: 0 }}>{n + 1}</span>
                        <span style={{ flex: 1, minWidth: 0 }}>
                          <span style={{ display: 'block', fontSize: 13.5, fontWeight: 600, wordBreak: 'break-word' }}>{i.name}</span>
                          <span style={{ ...NUM, fontSize: 12, color: C.sub }}>{i.qty.toLocaleString()} sold</span>
                        </span>
                        <strong style={{ ...NUM, fontSize: 13.5, whiteSpace: 'nowrap' }}>{GHS(i.amount)}</strong>
                      </div>
                    ))}
                  </div>
                )}

                <div style={{ ...card, marginTop: 10 }}>
                  <div style={sectionTitle}>Invoices</div>
                  {invoices.length === 0 && empty('Nothing sold in this period.')}
                  {invoices.slice(0, allInvoices ? 200 : 6).map((i, n) => (
                    <div key={`${i.line}-${i.id}`} style={{ borderTop: n ? `1px solid ${C.line}` : 'none', padding: '10px 0' }}>
                      <button type="button" onClick={() => setOpenInvoice(openInvoice === i.id ? null : i.id)}
                        style={{ display: 'flex', gap: 10, alignItems: 'center', width: '100%', background: 'none', border: 'none', padding: 0, textAlign: 'left', color: C.ink }}>
                        <span style={{ flex: 1, minWidth: 0 }}>
                          <span style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                            <span style={{ fontSize: 14, fontWeight: 600, wordBreak: 'break-word' }}>{i.customer_name || 'Customer'}</span>
                            {delivered.has(i.invoice_number) && <Pill text="Delivery" color={C.warn} bg={C.warnTint} />}
                            {credit.numbers.has(i.invoice_number) && <Pill text="On credit" color={C.bad} bg={C.badTint} />}
                          </span>
                          <span style={{ display: 'block', fontSize: 12, color: C.sub, marginTop: 1 }}>
                            {timeOf(i.issued_at)}{i.payment_method ? ` · ${i.payment_method}` : ''}{scope === 'both' ? ` · ${LINE_LABEL[i.line]}` : ''}
                          </span>
                        </span>
                        <strong style={{ ...NUM, fontSize: 14, whiteSpace: 'nowrap' }}>{GHS(i.total)}</strong>
                        <ChevronDown size={16} color={C.faint} style={{ transform: openInvoice === i.id ? 'rotate(180deg)' : 'none', transition: 'transform 0.15s', flexShrink: 0 }} />
                      </button>
                      {openInvoice === i.id && (
                        <div style={{ marginTop: 8, padding: 10, borderRadius: 10, background: C.bg, fontSize: 12.5, color: C.sub }}>
                          <div style={{ marginBottom: 4, color: C.faint }}>{i.invoice_number}</div>
                          {sold.filter(s => s.invoice_id === i.id).map((s, k) => (
                            <div key={k} style={{ display: 'flex', gap: 8, padding: '2px 0' }}>
                              <span style={{ flex: 1, minWidth: 0, wordBreak: 'break-word', color: C.ink }}>{s.quantity.toLocaleString()} × {s.description}</span>
                              <span style={{ ...NUM, whiteSpace: 'nowrap' }}>{GHS(s.line_total)}</span>
                            </div>
                          ))}
                        </div>
                      )}
                    </div>
                  ))}
                  {invoices.length > 6 && (
                    <button type="button" onClick={() => setAllInvoices(v => !v)}
                      style={{ width: '100%', marginTop: 6, padding: 11, borderRadius: 10, border: `1px solid ${C.line}`, background: C.card, color: C.brand, fontWeight: 600, fontSize: 13.5 }}>
                      {allInvoices ? 'Show fewer' : `Show all ${invoices.length}`}
                    </button>
                  )}
                </div>
              </>
            )}
          </>
        )}

        {/* ── Stock ── */}
        {tab === 'stock' && (
          <>
            {lineSwitch}
            {stockState === 'loading' ? loading : stockState === 'failed' ? failed('stock') : (
              <>
                {warehouses.length > 1 && (
                  <div style={{ marginTop: 8 }}>
                    <Segmented scroll value={warehouse} onChange={setWarehouse}
                      options={[{ key: 'ALL', label: 'All warehouses' }, ...warehouses.map(w => ({ key: w, label: w }))]} />
                  </div>
                )}
                {belowZero > 0 && !query && (
                  <button type="button" onClick={() => { setStockFilter('negative'); setQuery('') }}
                    style={{ width: '100%', marginTop: 10, padding: '11px 14px', borderRadius: 12, border: `1px solid #f3c4c4`, background: C.badTint, color: C.bad, fontSize: 13.5, fontWeight: 600, textAlign: 'left' }}>
                    {belowZero} product{belowZero === 1 ? ' is' : 's are'} below zero — sold or moved without being stocked. Tap to see.
                  </button>
                )}
                <div style={{ marginTop: 8 }}>
                  <Segmented value={stockFilter} onChange={setStockFilter}
                    options={[{ key: 'in', label: 'In stock' }, { key: 'out', label: 'Out' }, { key: 'negative', label: 'Below 0' }, { key: 'all', label: 'All' }]} />
                </div>
                <div style={{ marginTop: 8 }}>{searchBox('Search a product…')}</div>
                {countMsg && (
                  <div style={{ marginTop: 8, padding: '10px 12px', borderRadius: 10, fontSize: 13.5, fontWeight: 600, color: countMsg.ok ? C.good : C.bad, background: countMsg.ok ? C.goodTint : C.badTint }}>{countMsg.text}</div>
                )}

                <div style={{ ...card, ...roomWhileSearching, padding: 0, marginTop: 8, overflow: 'hidden' }}>
                  {stockShown.slice(0, 100).map((p, n) => {
                    const qty = qtyIn(p), tone = stockTone(qty), open = openProduct === p.model
                    return (
                      <div key={p.model} style={{ borderTop: n ? `1px solid ${C.line}` : 'none' }}>
                        <button type="button" onClick={() => { setOpenProduct(open ? null : p.model); setCountEdit(null) }}
                          style={{ display: 'flex', gap: 10, alignItems: 'center', width: '100%', background: open ? C.bg : 'none', border: 'none', padding: '12px 14px', textAlign: 'left', color: C.ink }}>
                          <span style={{ flex: 1, minWidth: 0 }}>
                            <span style={{ display: 'block', fontSize: 14, fontWeight: 600, wordBreak: 'break-word' }}>{p.model}</span>
                            <span style={{ ...NUM, display: 'block', fontSize: 12, color: p.price > 0 ? C.sub : C.warn, marginTop: 1 }}>{p.price > 0 ? GHS(p.price) : 'No price yet'}</span>
                          </span>
                          <Pill text={qty.toLocaleString()} color={tone.color} bg={tone.bg} />
                          <ChevronDown size={16} color={C.faint} style={{ transform: open ? 'rotate(180deg)' : 'none', transition: 'transform 0.15s', flexShrink: 0 }} />
                        </button>
                        {open && (
                          <div style={{ padding: '0 14px 12px', background: C.bg }}>
                            {!isSuperBoss && p.places.length === 0 && <div style={{ fontSize: 13, color: C.sub }}>None in any warehouse.</div>}
                            {!isSuperBoss && [...p.places].sort((a, b) => b.qty - a.qty).map(x => (
                              <div key={x.warehouse} style={{ display: 'flex', justifyContent: 'space-between', gap: 10, fontSize: 13.5, padding: '5px 0' }}>
                                <span style={{ color: x.warehouse === warehouse ? C.brand : C.ink, fontWeight: x.warehouse === warehouse ? 700 : 400 }}>{x.warehouse}</span>
                                <strong style={{ ...NUM, color: x.qty < 0 ? C.bad : C.ink }}>{x.qty.toLocaleString()}</strong>
                              </div>
                            ))}
                            {/* The Big Boss sees every warehouse the product is listed in, empty
                                ones too, and taps a count to correct it. */}
                            {isSuperBoss && [...p.rows].sort((a, b) => b.qty - a.qty || a.warehouse.localeCompare(b.warehouse)).map(r => (
                              <div key={r.id} style={{ padding: '4px 0' }}>
                                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 10, fontSize: 13.5 }}>
                                  <span style={{ color: r.warehouse === warehouse ? C.brand : C.ink, fontWeight: r.warehouse === warehouse ? 700 : 400, wordBreak: 'break-word' }}>{r.warehouse}</span>
                                  {countEdit?.id !== r.id && (
                                    <button type="button" aria-label={`Correct the count in ${r.warehouse}`}
                                      onClick={() => { setCountEdit({ id: r.id, value: String(r.qty) }); setCountMsg(null) }}
                                      style={{ ...NUM, minWidth: 64, padding: '7px 12px', borderRadius: 10, border: `1px solid ${C.line}`, background: C.card,
                                        color: r.qty < 0 ? C.bad : C.ink, fontWeight: 700, fontSize: 14, textAlign: 'right' }}>
                                      {r.qty.toLocaleString()}
                                    </button>
                                  )}
                                </div>
                                {countEdit?.id === r.id && (
                                  <form onSubmit={e => { e.preventDefault(); saveCount(p, r) }} style={{ marginTop: 8 }}>
                                    <div style={{ display: 'flex', gap: 8 }}>
                                      <input style={{ ...field, ...NUM, flex: 1, fontSize: 20, fontWeight: 700, textAlign: 'right', borderColor: C.brand }}
                                        type="number" inputMode="numeric" min="0" step="1" aria-label={`Count in ${r.warehouse}`}
                                        value={countEdit.value} onChange={e => setCountEdit({ id: r.id, value: e.target.value })} autoFocus onFocus={e => e.target.select()} />
                                      <button type="submit" disabled={countSaving}
                                        style={{ padding: '0 18px', borderRadius: 12, border: 'none', background: C.brand, color: '#fff', fontWeight: 700, fontSize: 15, opacity: countSaving ? 0.6 : 1 }}>
                                        {countSaving ? '…' : 'Save'}
                                      </button>
                                      <button type="button" onClick={() => setCountEdit(null)} aria-label="Cancel"
                                        style={{ padding: '0 14px', borderRadius: 12, border: `1px solid ${C.line}`, background: C.card, color: C.sub, fontWeight: 700, fontSize: 14 }}>✕</button>
                                    </div>
                                    <div style={{ fontSize: 12, color: C.sub, marginTop: 6 }}>What is on the shelf in {r.warehouse} now. Sales and moves already recorded are kept.</div>
                                  </form>
                                )}
                              </div>
                            ))}
                            {(isSuperBoss ? p.rows.length > 1 : p.places.length > 1) && (
                              <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10, fontSize: 13.5, padding: '7px 0 0', marginTop: 4, borderTop: `1px solid ${C.line}` }}>
                                <span style={{ color: C.sub }}>All warehouses</span><strong style={NUM}>{p.total.toLocaleString()}</strong>
                              </div>
                            )}
                          </div>
                        )}
                      </div>
                    )
                  })}
                  {stockShown.length === 0 && empty('No product matches.')}
                </div>
                {stockShown.length > 100 && <div style={{ fontSize: 12.5, color: C.sub, padding: '10px 4px' }}>Showing 100 of {stockShown.length.toLocaleString()}. Search to narrow it down.</div>}
              </>
            )}
          </>
        )}

        {/* ── Prices ── */}
        {tab === 'prices' && (
          <>
            {lineSwitch}
            {unpriced > 0 && stockState === 'ready' && !query && (
              <button type="button" onClick={() => setUnpricedOnly(v => !v)}
                style={{ width: '100%', marginTop: 10, padding: '11px 14px', borderRadius: 12, fontSize: 13.5, fontWeight: 600, textAlign: 'left',
                  border: `1px solid ${unpricedOnly ? C.warn : '#f1dcb5'}`, background: C.warnTint, color: C.warn }}>
                {unpricedOnly ? `Showing the ${unpriced.toLocaleString()} with no price · tap to show all` : `${unpriced.toLocaleString()} product${unpriced === 1 ? ' has' : 's have'} no price yet · tap to see only those`}
              </button>
            )}
            {!isSuperBoss && <div style={{ fontSize: 12.5, color: C.sub, marginTop: 10 }}>Only the Big Boss can change a price.</div>}
            {priceMsg && (
              <div style={{ marginTop: 10, padding: '10px 12px', borderRadius: 10, fontSize: 13.5, fontWeight: 600, color: priceMsg.ok ? C.good : C.bad, background: priceMsg.ok ? C.goodTint : C.badTint }}>{priceMsg.text}</div>
            )}

            {stockState === 'loading' ? loading : stockState === 'failed' ? failed('prices') : (
              <>
                <div style={{ marginTop: 10 }}>{searchBox('Search a product to price…')}</div>
                <div style={{ ...card, ...roomWhileSearching, padding: 0, marginTop: 8, overflow: 'hidden' }}>
                  {priceShown.slice(0, 80).map((p, n) => (
                    <div key={p.model} style={{ borderTop: n ? `1px solid ${C.line}` : 'none', padding: '12px 14px', background: editing === p.model ? C.tint : 'none' }}>
                      <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
                        <div style={{ flex: 1, minWidth: 0 }}>
                          <div style={{ fontSize: 14, fontWeight: 600, wordBreak: 'break-word' }}>{p.model}</div>
                          <div style={{ ...NUM, fontSize: 12, color: p.total < 0 ? C.bad : C.sub, marginTop: 1 }}>{p.total.toLocaleString()} in stock</div>
                        </div>
                        {editing !== p.model && (
                          isSuperBoss ? (
                            <button type="button" onClick={() => { setEditing(p.model); setDraft(p.price > 0 ? String(p.price) : ''); setPriceMsg(null) }}
                              style={{ ...NUM, padding: '9px 12px', borderRadius: 10, whiteSpace: 'nowrap', fontWeight: 700, fontSize: 13.5,
                                border: `1px solid ${p.price > 0 ? C.line : '#f1dcb5'}`, background: p.price > 0 ? C.card : C.warnTint, color: p.price > 0 ? C.ink : C.warn }}>
                              {p.price > 0 ? GHS(p.price) : 'Set price'}
                            </button>
                          ) : (
                            <strong style={{ ...NUM, whiteSpace: 'nowrap', fontSize: 13.5, color: p.price > 0 ? C.ink : C.warn }}>{p.price > 0 ? GHS(p.price) : 'No price'}</strong>
                          )
                        )}
                      </div>
                      {/* One field, one button. The price is per product: it applies in every warehouse. */}
                      {editing === p.model && (
                        <form onSubmit={e => { e.preventDefault(); savePrice(p) }} style={{ display: 'flex', gap: 8, marginTop: 10 }}>
                          <input style={{ ...field, ...NUM, flex: 1, fontSize: 20, fontWeight: 700, textAlign: 'right', borderColor: C.brand }} type="number" inputMode="decimal" min="0" step="0.01"
                            value={draft} onChange={e => setDraft(e.target.value)} placeholder="Price in GH¢" autoFocus onFocus={e => e.target.select()} />
                          <button type="submit" disabled={saving}
                            style={{ padding: '0 20px', borderRadius: 12, border: 'none', background: C.brand, color: '#fff', fontWeight: 700, fontSize: 15, opacity: saving ? 0.6 : 1 }}>
                            {saving ? '…' : 'Save'}
                          </button>
                          <button type="button" onClick={() => setEditing(null)} aria-label="Cancel"
                            style={{ padding: '0 14px', borderRadius: 12, border: `1px solid ${C.line}`, background: C.card, color: C.sub, fontWeight: 700, fontSize: 14 }}>✕</button>
                        </form>
                      )}
                    </div>
                  ))}
                  {priceShown.length === 0 && empty('No product matches.')}
                </div>
                {priceShown.length > 80 && <div style={{ fontSize: 12.5, color: C.sub, padding: '10px 4px' }}>Showing 80 of {priceShown.length.toLocaleString()}. Search to narrow it down.</div>}
              </>
            )}
          </>
        )}

        {/* ── Activity ── */}
        {tab === 'activity' && (
          <>
            <Approvals isSuperBoss={isSuperBoss} tick={tick} />
            <Segmented value={period} onChange={setPeriod} options={PERIODS} />
            {windowNote}
            {movesState === 'loading' ? loading : movesState === 'failed' ? failed('stock activity') : (
              <>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginTop: 12 }}>
                  <Kpi title="Entries" value={moves.length.toLocaleString()}
                    note={activity.kinds.filter(k => k.n).map(k => `${k.n} ${k.kind === 'move' ? 'moved' : k.kind === 'receive' ? 'received' : k.kind === 'return' ? 'returned' : 'reversed'}`).join(' · ') || undefined} />
                  <Kpi title="Units handled" value={activity.units.toLocaleString()} />
                </div>

                {activity.people.length > 0 && (
                  <div style={{ ...card, marginTop: 10 }}>
                    <div style={sectionTitle}>Who entered it</div>
                    {activity.people.map((p, n) => (
                      <div key={p.name} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '9px 0', borderTop: n ? `1px solid ${C.line}` : 'none' }}>
                        <span style={{ width: 34, height: 34, borderRadius: 999, background: C.tint, color: C.brand, fontWeight: 700, fontSize: 14, display: 'grid', placeItems: 'center', flexShrink: 0 }}>
                          {p.name.trim().charAt(0).toUpperCase()}
                        </span>
                        <span style={{ flex: 1, minWidth: 0, fontSize: 14, fontWeight: 600, wordBreak: 'break-word' }}>{p.name}</span>
                        <span style={{ ...NUM, fontSize: 12.5, color: C.sub, whiteSpace: 'nowrap', textAlign: 'right' }}>
                          {p.entries} entr{p.entries === 1 ? 'y' : 'ies'}<br />{p.units.toLocaleString()} units
                        </span>
                      </div>
                    ))}
                  </div>
                )}

                <div style={{ ...card, padding: 0, marginTop: 10, overflow: 'hidden' }}>
                  {moves.length === 0 && empty('Nothing was moved, received or returned in this period.')}
                  {moves.map((m, n) => {
                    const open = openMove === m.transfer_number
                    const kind = m.kind === 'move' ? { text: 'Moved', color: C.brand, bg: C.tint } : m.kind === 'receive' ? { text: 'Received', color: C.good, bg: C.goodTint } : m.kind === 'reversal' ? { text: 'Reversed', color: C.bad, bg: C.badTint } : { text: 'Returned', color: C.warn, bg: C.warnTint }
                    return (
                      <div key={m.transfer_number} style={{ borderTop: n ? `1px solid ${C.line}` : 'none' }}>
                        <button type="button" onClick={() => setOpenMove(open ? null : m.transfer_number)}
                          style={{ display: 'flex', gap: 10, alignItems: 'center', width: '100%', background: open ? C.bg : 'none', border: 'none', padding: '12px 14px', textAlign: 'left', color: C.ink }}>
                          <span style={{ flex: 1, minWidth: 0 }}>
                            <span style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                              <Pill text={kind.text} color={kind.color} bg={kind.bg} />
                              <span style={{ fontSize: 14, fontWeight: 600, wordBreak: 'break-word' }}>
                                {m.kind === 'move' || m.kind === 'reversal' ? `${m.from_warehouse} → ${m.to_warehouse}` : m.to_warehouse}
                              </span>
                            </span>
                            <span style={{ display: 'block', fontSize: 12, color: C.sub, marginTop: 3 }}>{m.signed_by || m.staff_id || 'Unknown'} · {timeOf(m.transferred_at)}</span>
                          </span>
                          <strong style={{ ...NUM, fontSize: 13.5, whiteSpace: 'nowrap' }}>{unitsOf(m).toLocaleString()}</strong>
                          <ChevronDown size={16} color={C.faint} style={{ transform: open ? 'rotate(180deg)' : 'none', transition: 'transform 0.15s', flexShrink: 0 }} />
                        </button>
                        {open && (
                          <div style={{ padding: '0 14px 12px', background: C.bg, fontSize: 13 }}>
                            <div style={{ color: C.faint, fontSize: 12, marginBottom: 4 }}>{m.transfer_number}{m.supplier ? ` · ${m.supplier}` : ''}</div>
                            {(m.items || []).map((i, k) => <div key={k} style={{ wordBreak: 'break-word', padding: '2px 0' }}><strong style={NUM}>{i.quantity.toLocaleString()}</strong> × {i.model}</div>)}
                          </div>
                        )}
                      </div>
                    )
                  })}
                </div>
              </>
            )}
          </>
        )}

        <div style={{ marginTop: 26, display: 'flex', justifyContent: 'center', gap: 18, flexWrap: 'wrap', fontSize: 13 }}>
          <Link href="/teamqtech" style={{ color: C.brand, fontWeight: 600 }}>Open the full admin panel</Link>
          <button type="button" onClick={() => { if (confirm('Sign this phone out?')) onSignOut() }}
            style={{ background: 'none', border: 'none', padding: 0, color: C.sub, fontSize: 13, textDecoration: 'underline' }}>Sign out</button>
        </div>
      </div>

      {/* ── Tab bar ── */}
      <nav style={{ position: 'fixed', left: 0, right: 0, bottom: 0, zIndex: 60, background: 'rgba(255,255,255,0.96)', backdropFilter: 'blur(12px)', WebkitBackdropFilter: 'blur(12px)', borderTop: `1px solid ${C.line}`, paddingBottom: 'env(safe-area-inset-bottom)' }}>
        <div style={{ maxWidth: 640, margin: '0 auto', display: 'grid', gridTemplateColumns: `repeat(${NAV.length}, 1fr)` }}>
          {NAV.map(({ key, label: text, Icon }) => {
            const on = key === tab
            return (
              <button key={key} type="button" aria-current={on ? 'page' : undefined}
                onClick={() => { if (key === 'moves') onMoves(); else { setTab(key); setQuery(''); window.scrollTo({ top: 0 }) } }}
                style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3, padding: '9px 2px 8px', border: 'none', background: 'none', color: on ? C.brand : C.faint }}>
                <span style={{ position: 'relative', display: 'grid', placeItems: 'center', width: 52, height: 28, borderRadius: 999, background: on ? C.tint : 'transparent', transition: 'background 0.15s' }}>
                  <Icon size={20} strokeWidth={on ? 2.4 : 2} />
                  {key === 'activity' && waiting > 0 && (
                    <span aria-label={`${waiting} waiting for approval`}
                      style={{ ...NUM, position: 'absolute', top: -4, right: 4, minWidth: 18, height: 18, padding: '0 5px', borderRadius: 999, background: '#f59e0b', color: '#1f1300', fontSize: 11, fontWeight: 800, display: 'grid', placeItems: 'center', border: '2px solid #fff', lineHeight: 1 }}>
                      {waiting}
                    </span>
                  )}
                </span>
                <span style={{ fontSize: 11, fontWeight: on ? 700 : 500 }}>{text}</span>
              </button>
            )
          })}
        </div>
      </nav>
    </div>
  )
}
