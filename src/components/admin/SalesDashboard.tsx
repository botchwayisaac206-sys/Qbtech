'use client'

import { useEffect, useMemo, useState } from 'react'
import {
  ResponsiveContainer, XAxis, YAxis, Tooltip,
  CartesianGrid, AreaChart, Area, BarChart, Bar,
} from 'recharts'
import { GHS, withinWindow, paymentBuckets } from '@/lib/sales'
import { useQbDark } from '@/lib/qbTheme'
import { loadCreditLedger, emptyLedger, type CreditLedger } from '@/lib/debts'
import { fetchInvoices, fetchInvoiceItems, fetchExpenses, fetchDeliveries, invalidate, peek, scopedKey, getScope, setScope, type DataScope, type InvRow, type ItemRow, type ExpRow, type DelRow, deliveredInvoiceNumbers } from '@/lib/adminCache'

const TEAL = '#0a7cff'

type Period = 'today' | 'week' | 'weeks' | 'months' | 'years'

const startOfDay = (d: Date) => { const x = new Date(d); x.setHours(0,0,0,0); return x }
const startOfWeek = (d: Date) => { const x = startOfDay(d); x.setDate(x.getDate() - x.getDay()); return x }
const startOfYear  = (d: Date) => new Date(d.getFullYear(), 0, 1)
const addDays = (d: Date, n: number) => { const x = new Date(d); x.setDate(x.getDate() + n); return x }

const DAY_SHORT = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat']
const DAY_LONG  = ['SUNDAY','MONDAY','TUESDAY','WEDNESDAY','THURSDAY','FRIDAY','SATURDAY']

interface Range { from: Date; to: Date }

/**
 * The half-open window [from, to) the current selection covers.
 *
 * Every period now has a real upper bound. The previous code tested only
 * d >= from, so an invoice dated in the future — the invoice form's date
 * picker has no max — counted toward TODAY.
 *
 * weekDay is the day-of-week chip under THIS WEEK: null = the whole week,
 * 0-6 = that single day of the current week.
 */
function periodRange(p: Period, weekDay: number | null, now: Date): Range {
  if (p === 'today') { const f = startOfDay(now); return { from: f, to: addDays(f, 1) } }
  if (p === 'week') {
    const ws = startOfWeek(now)
    if (weekDay === null) return { from: ws, to: addDays(ws, 7) }
    const f = addDays(ws, weekDay)
    return { from: f, to: addDays(f, 1) }
  }
  if (p === 'weeks') { const ws = startOfWeek(now); return { from: addDays(ws, -21), to: addDays(ws, 7) } }
  if (p === 'months') return { from: startOfYear(now), to: new Date(now.getFullYear() + 1, 0, 1) }
  return { from: new Date(now.getFullYear() - 3, 0, 1), to: new Date(now.getFullYear() + 1, 0, 1) }
}

const inRange = (ts: string, r: Range) => { const d = new Date(ts); return d >= r.from && d < r.to }

/** Compact money for the day chips, where there is no room for full precision. */
const shortGHS = (n: number) =>
  n >= 1000 ? `${(n / 1000).toFixed(n >= 10000 ? 0 : 1)}k` : n.toFixed(0)

export default function SalesDashboard({ isBoss, windowed = false }: { isBoss: boolean; windowed?: boolean }) {
  // Charts write SVG attributes, which need real colours rather than CSS variables.
  const chartDark = useQbDark()
  const CH = chartDark
    ? { red: '#ff453a', grid: 'rgba(84,84,88,0.42)', tick: 'rgba(235,235,245,0.55)' }
    : { red: '#d70015', grid: 'rgba(60,60,67,0.12)', tick: 'rgba(60,60,67,0.6)' }
  // A windowed viewer only ever has 24h of data, so anything but TODAY would
  // render an empty chart — default and pin them to the daily view.
  const [period, setPeriod] = useState<Period>(windowed ? 'today' : 'months')
  // Day-of-week chip under THIS WEEK. null = whole week.
  const [weekDay, setWeekDay] = useState<number | null>(null)
  // How much history to pull. Persisted in localStorage by the cache.
  const [scope, setScopeState] = useState<DataScope>(() => getScope())
  const [scopeBusy, setScopeBusy] = useState(false)
  // Seed state from cache synchronously so a tab switch with warm cache paints
  // instantly — no "Loading sales…" flash.
  // The warm-cache seed bypasses the effect below, so it needs the same clamp.
  const clampInv = (rows: InvRow[]) => windowed ? rows.filter(i => withinWindow(i.issued_at)) : rows
  const [invoices, setInvoices] = useState<InvRow[]>(() => clampInv(peek<InvRow[]>(scopedKey('invoices')) || []))
  // invoice_items feeds ONLY the top/least-selling panels, which are hidden for
  // a windowed viewer — so they never need the (large) items table at all.
  const [items, setItems]       = useState<ItemRow[]>(() => windowed ? [] : (peek<ItemRow[]>(scopedKey('invoice_items')) || []))
  const [expenses, setExpenses] = useState<ExpRow[]>(() => {
    const ex = peek<ExpRow[]>(scopedKey('expenses')) || []
    return windowed ? ex.filter(e => withinWindow(e.incurred_at)) : ex
  })
  const [ledger, setLedger] = useState<CreditLedger>(emptyLedger)
  const [deliveries, setDeliveries] = useState<DelRow[]>(() => {
    const del = peek<DelRow[]>(scopedKey('deliveries')) || []
    return windowed ? del.filter(d => withinWindow(d.delivered_at)) : del
  })
  const hasWarmCache = peek<InvRow[]>(scopedKey('invoices')) !== undefined
  const [loading, setLoading]   = useState(!hasWarmCache)
  const [error, setError]       = useState<string | null>(null)
  const [reloadKey, setReloadKey] = useState(0)

  useEffect(() => {
    let cancelled = false
    setError(null)
    // Read the cache here rather than from render, so the effect depends on nothing stale.
    if (peek<InvRow[]>(scopedKey('invoices')) === undefined) setLoading(true)
    // Cache is stale-while-revalidate: first load awaits, subsequent loads
    // return cached data instantly and refresh in the background. A failed
    // background refresh surfaces via console, never as a blocking error.
    ;(async () => {
      try {
        const [inv, it, ex, del] = await Promise.all([
          fetchInvoices(),
          // Skipped for windowed viewers — this is the largest table in the
          // panel (9k+ rows) and nothing they can see is derived from it.
          windowed ? Promise.resolve([] as ItemRow[]) : fetchInvoiceItems(),
          fetchExpenses(),
          fetchDeliveries(),
        ])
        if (cancelled) return
        // Staff only see expenses logged in the last 8 hours
        const EIGHT_HOURS = 8 * 60 * 60 * 1000
        let visibleEx = isBoss
          ? ex
          : ex.filter(e => Date.now() - new Date(e.incurred_at).getTime() < EIGHT_HOURS)
        let visibleInv = inv, visibleIt = it, visibleDel = del
        // Windowed viewers are clamped to the last 24 hours. RLS already does
        // this server-side; repeating it here keeps a warm cache left over from
        // another session on the same browser from leaking older rows.
        if (windowed) {
          visibleInv = inv.filter(i => withinWindow(i.issued_at))
          visibleIt  = []
          visibleEx  = visibleEx.filter(e => withinWindow(e.incurred_at))
          visibleDel = del.filter(d => withinWindow(d.delivered_at))
        }
        // A sale with Delivery switched on is counted under Delivery, at the
        // invoice's total. Its invoice is left out here so it is not counted
        // a second time as an ordinary sale.
        const delivered = deliveredInvoiceNumbers(del)
        visibleInv = visibleInv.filter(i => !i.invoice_number || !delivered.has(i.invoice_number))

        // A sale on credit is not money in until it is paid. Its invoice is
        // left out, and each payment on it stands in as income on the day it
        // was received — so every total, chart and payment split below
        // counts what actually came in, with no other change.
        const credit = await loadCreditLedger('main')
        if (cancelled) return
        setLedger(credit)
        visibleInv = visibleInv.filter(i => !i.invoice_number || !credit.numbers.has(i.invoice_number))
        visibleDel = visibleDel.filter(d => !d.invoice_number || !credit.numbers.has(d.invoice_number))
        const paidIn: InvRow[] = credit.payments
          .filter(p => !windowed || withinWindow(p.paid_at))
          .map(p => ({ id: `debt-${p.id}`, total: p.amount, subtotal: p.amount, issued_at: p.paid_at, customer_name: p.customer_name, payment_method: p.payment_method, invoice_number: p.invoice_number, debt_payment: true }))
        visibleInv = [...visibleInv, ...paidIn].sort((a, b) => +new Date(b.issued_at) - +new Date(a.issued_at))
        setInvoices(visibleInv); setItems(visibleIt); setExpenses(visibleEx); setDeliveries(visibleDel)
      } catch (e: any) {
        if (cancelled) return
        console.error('Sales first-load failed:', e)
        setError(e?.message || 'Failed to load dashboard data')
      } finally {
        if (!cancelled) { setLoading(false); setScopeBusy(false) }
      }
    })()
    return () => { cancelled = true }
  }, [isBoss, windowed, reloadKey, scope])

  // ── Totals & chart data by period ───────────────────────────────
  const { chartData, periodTotal, periodLabel } = useMemo(() => {
    const now = new Date()
    // The window this render covers. Recomputed here rather than shared, so
    // `now` is always current without faking a dependency on the data.
    const range = periodRange(period, weekDay, now)
    const invIn = invoices.filter(i => inRange(i.issued_at, range))
    const delIn = deliveries.filter(d => inRange(d.delivered_at, range))
    const expIn = expenses.filter(e => inRange(e.incurred_at, range))
    const totalOf = (bs: { value: number }[]) => bs.reduce((sm, x) => sm + x.value, 0)

    // A single day — TODAY, or one day chip inside THIS WEEK — plots by hour.
    if (period === 'today' || (period === 'week' && weekDay !== null)) {
      const buckets = Array.from({ length: 24 }, (_, h) => ({ label: `${h}:00`, value: 0, expense: 0 }))
      invIn.forEach(i => { buckets[new Date(i.issued_at).getHours()].value   += Number(i.total) })
      delIn.forEach(d => { buckets[new Date(d.delivered_at).getHours()].value += Number(d.amount) })
      expIn.forEach(e => { buckets[new Date(e.incurred_at).getHours()].expense += Number(e.amount) })
      return {
        chartData: buckets,
        periodTotal: totalOf(buckets),
        periodLabel: period === 'today' ? 'TODAY' : DAY_LONG[weekDay as number],
      }
    }
    if (period === 'week') {
      const buckets = DAY_SHORT.map(n => ({ label: n, value: 0, expense: 0 }))
      invIn.forEach(i => { buckets[new Date(i.issued_at).getDay()].value   += Number(i.total) })
      delIn.forEach(d => { buckets[new Date(d.delivered_at).getDay()].value += Number(d.amount) })
      expIn.forEach(e => { buckets[new Date(e.incurred_at).getDay()].expense += Number(e.amount) })
      return { chartData: buckets, periodTotal: totalOf(buckets), periodLabel: 'THIS WEEK' }
    }
    if (period === 'weeks') {
      const buckets = Array.from({ length: 4 }, (_, idx) => {
        const from = addDays(startOfWeek(now), -(3 - idx) * 7)
        return { label: `W-${3 - idx}`, value: 0, expense: 0, from, to: addDays(from, 7) }
      })
      const find = (d: Date) => buckets.find(x => d >= x.from && d < x.to)
      invIn.forEach(i => { const bk = find(new Date(i.issued_at));    if (bk) bk.value   += Number(i.total) })
      delIn.forEach(d => { const bk = find(new Date(d.delivered_at)); if (bk) bk.value   += Number(d.amount) })
      expIn.forEach(e => { const bk = find(new Date(e.incurred_at));  if (bk) bk.expense += Number(e.amount) })
      return { chartData: buckets, periodTotal: totalOf(buckets), periodLabel: 'LAST 4 WEEKS' }
    }
    if (period === 'months') {
      const names = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec']
      const buckets = names.map(n => ({ label: n, value: 0, expense: 0 }))
      invIn.forEach(i => { buckets[new Date(i.issued_at).getMonth()].value   += Number(i.total) })
      delIn.forEach(d => { buckets[new Date(d.delivered_at).getMonth()].value += Number(d.amount) })
      expIn.forEach(e => { buckets[new Date(e.incurred_at).getMonth()].expense += Number(e.amount) })
      return { chartData: buckets, periodTotal: totalOf(buckets), periodLabel: `${now.getFullYear()}` }
    }
    // years — last 4
    const thisYr = now.getFullYear()
    const buckets = Array.from({ length: 4 }, (_, i) => ({ label: String(thisYr - 3 + i), value: 0, expense: 0 }))
    const byYear = (d: Date) => buckets.find(x => x.label === String(d.getFullYear()))
    invIn.forEach(i => { const bk = byYear(new Date(i.issued_at));    if (bk) bk.value   += Number(i.total) })
    delIn.forEach(d => { const bk = byYear(new Date(d.delivered_at)); if (bk) bk.value   += Number(d.amount) })
    expIn.forEach(e => { const bk = byYear(new Date(e.incurred_at));  if (bk) bk.expense += Number(e.amount) })
    return { chartData: buckets, periodTotal: totalOf(buckets), periodLabel: 'LAST 4 YEARS' }
  }, [invoices, expenses, deliveries, period, weekDay])

  // ── Per-day totals for the day chips under THIS WEEK ────────────
  const weekDayTotals = useMemo(() => {
    const ws = startOfWeek(new Date())
    const wk: Range = { from: ws, to: addDays(ws, 7) }
    const totals = Array<number>(7).fill(0)
    invoices.forEach(i => { if (inRange(i.issued_at, wk))    totals[new Date(i.issued_at).getDay()]    += Number(i.total) })
    deliveries.forEach(d => { if (inRange(d.delivered_at, wk)) totals[new Date(d.delivered_at).getDay()] += Number(d.amount) })
    return totals
  }, [invoices, deliveries])

  // ── Top customers: ranked by invoice count ──────────────────────
  const customerRanks = useMemo(() => {
    const now = new Date()
    const yearStart = new Date(now.getFullYear(), 0, 1)
    const fourMonthsAgo = new Date(now); fourMonthsAgo.setMonth(fourMonthsAgo.getMonth() - 4)

    const build = (from: Date) => {
      const map = new Map<string, { name: string; phone: string; count: number; total: number }>()
      invoices.forEach(i => {
        if (new Date(i.issued_at) < from) return
        const name = (i.customer_name || '—').trim()
        const key = name.toUpperCase()
        const cur = map.get(key) || { name, phone: '', count: 0, total: 0 }
        cur.count += 1
        cur.total += Number(i.total)
        if (!cur.phone && i.customer_num) cur.phone = i.customer_num
        map.set(key, cur)
      })
      // Rank by invoice count — most invoices = most loyal customer
      return Array.from(map.values()).sort((a, b) => b.count - a.count)
    }
    return { year: build(yearStart), fourMonths: build(fourMonthsAgo) }
  }, [invoices])

  // ── Top / Least selling products — ranked by invoice count ──────
  const productStats = useMemo(() => {
    const map = new Map<string, { desc: string; qty: number; total: number; invoices: Set<string> }>()
    items.forEach(it => {
      const key = it.product_id || it.description
      const cur = map.get(key) || { desc: it.description, qty: 0, total: 0, invoices: new Set() }
      cur.qty += Number(it.quantity)
      cur.total += Number(it.line_total)
      cur.invoices.add(it.invoice_id)
      map.set(key, cur)
    })
    const arr = Array.from(map.values())
      .map(p => ({ ...p, invoiceCount: p.invoices.size }))
      .sort((a, b) => b.invoiceCount - a.invoiceCount)
    return { top: arr.slice(0, 40), least: arr.filter(p => p.qty > 0).slice(-10).reverse() }
  }, [items])

  // ── Period-scoped stats (income, expenses, net, payment split) ──
  const periodStats = useMemo(() => {
    const range = periodRange(period, weekDay, new Date())
    const invs = invoices.filter(i => inRange(i.issued_at, range))
    const exps = expenses.filter(e => inRange(e.incurred_at, range))
    const dels = deliveries.filter(d => inRange(d.delivered_at, range))
    const invoiceIncome  = invs.reduce((s, i) => s + Number(i.total), 0)
    const deliveryIncome = dels.reduce((s, d) => s + Number(d.amount), 0)
    const income         = invoiceIncome + deliveryIncome   // deliveries count toward Total Sales
    const expenseTotal   = exps.reduce((s, e) => s + Number(e.amount), 0)

    // Parse payment method — handles both plain ("Cash") and split
    // ("Cash (GH₵ 500.00) + Mobile Money (GH₵ 300.00)") formats.
    let cash = 0, momo = 0, bank = 0, other = 0
    invs.forEach(inv => {
      const pm    = inv.payment_method || ''
      const total = Number(inv.total)
      if (pm.includes(' + ')) {
        // Split payment: format is "Cash (GH₵ 500.00) + Mobile Money (GH₵ 300.00)"
        pm.split(' + ').forEach(part => {
          const amtMatch = part.match(/GH[₵¢C]\s*([\d.]+)/)
          const amt = amtMatch ? parseFloat(amtMatch[1]) : 0
          if      (part.startsWith('Cash'))          cash += amt
          else if (part.startsWith('Mobile Money'))  momo += amt
          else if (part.startsWith('Bank Transfer')) bank += amt
          else                                        other += amt
        })
      } else {
        if      (pm === 'Cash')          cash  += total
        else if (pm === 'Mobile Money')  momo  += total
        else if (pm === 'Bank Transfer') bank  += total
        else                              other += total
      }
    })
    // Deliveries flow into the matching payment bucket. One logged from an
    // invoice carries that invoice's payment, split or not; one with no
    // method recorded is taken as cash, as it always was.
    dels.forEach(d => {
      const b = paymentBuckets(d.payment_method || 'Cash', Number(d.amount))
      cash += b.cash; momo += b.momo; bank += b.bank; other += b.other
    })

    // Net is now Cash − Expenses (physical cash on hand, including cash deliveries).
    const net = cash - expenseTotal

    const debtIncome = invs.filter(i => i.debt_payment).reduce((s, i) => s + Number(i.total), 0)
    return { income, expenseTotal, net, cash, momo, bank, other, deliveryIncome, debtIncome, count: invs.filter(i => !i.debt_payment).length, deliveryCount: dels.length }
  }, [invoices, expenses, deliveries, period, weekDay])

  // Income vs expense by month (current year)
  const incomeVsExpense = useMemo(() => {
    const yr = new Date().getFullYear()
    const names = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec']
    const b = names.map(n => ({ label: n, income: 0, expense: 0 }))
    invoices.forEach(i => {
      const d = new Date(i.issued_at)
      if (d.getFullYear() === yr) b[d.getMonth()].income += Number(i.total)
    })
    deliveries.forEach(de => {
      const d = new Date(de.delivered_at)
      if (d.getFullYear() === yr) b[d.getMonth()].income += Number(de.amount)
    })
    expenses.forEach(e => {
      const d = new Date(e.incurred_at)
      if (d.getFullYear() === yr) b[d.getMonth()].expense += Number(e.amount)
    })
    return b
  }, [invoices, expenses, deliveries])

  const topInvoiceCount = productStats.top[0]?.invoiceCount || 1

  if (error) return (
    <div style={{ padding: 48, textAlign: 'center', color: 'var(--qb-red)', fontVariantNumeric: 'tabular-nums', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14 }}>
      <div>⚠️ {error}</div>
      <button
        onClick={() => { invalidate('invoices', 'invoice_items', 'expenses'); setReloadKey(k => k + 1) }}
        style={{ padding: '10px 20px', borderRadius: 10, background: TEAL, color: '#ffffff', fontWeight: 800, border: 'none', cursor: 'pointer', fontSize: 12, letterSpacing: '0.1em' }}>
        RETRY
      </button>
    </div>
  )

  if (loading) return (
    <div style={{ padding: 48, textAlign: 'center', color: 'var(--qb-muted)', fontVariantNumeric: 'tabular-nums', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14 }}>
      <div>Loading sales…</div>
      <button
        onClick={() => { invalidate('invoices', 'invoice_items', 'expenses'); setReloadKey(k => k + 1) }}
        style={{ padding: '6px 14px', borderRadius: 8, background: 'transparent', color: 'var(--qb-muted)', border: '1px solid #334155', cursor: 'pointer', fontSize: 11 }}>
        taking too long? retry
      </button>
    </div>
  )

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>

      {/* ── Period tabs ─────────────────────────────────────────── */}
      <div style={{
        display: 'flex', gap: 6, background: 'var(--qb-card)',
        border: '1px solid var(--qb-border)', borderRadius: 12, padding: 4, width: 'fit-content', flexWrap: 'wrap'
      }}>
        {(windowed
          ? [['today', 'TODAY']] as [Period, string][]
          : ([
            ['today',  'TODAY'],
            ['week',   'THIS WEEK'],
            ['weeks',  'WEEKS'],
            ['months', 'MONTHS'],
            ['years',  'YEARS'],
          ] as [Period, string][])
        ).map(([k, l]) => (
          <button key={k} onClick={() => { setPeriod(k); if (k !== 'week') setWeekDay(null) }} style={{
            padding: '10px 18px', borderRadius: 8, fontWeight: 800, fontSize: 11, letterSpacing: '0.12em',
            border: 'none', cursor: 'pointer',
            background: period === k ? TEAL : 'transparent',
            color: period === k ? '#ffffff' : 'var(--qb-sub)',
          }}>{l}</button>
        ))}
      </div>

      {/* ── Day-of-week chips (THIS WEEK only) ───────────────────── */}
      {period === 'week' && (
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', alignItems: 'stretch' }}>
          <button onClick={() => setWeekDay(null)} style={{
            padding: '8px 14px', borderRadius: 10, border: '1px solid rgba(10,124,255,0.25)',
            cursor: 'pointer', fontSize: 11, fontWeight: 800, letterSpacing: '0.1em',
            background: weekDay === null ? TEAL : 'transparent',
            color: weekDay === null ? '#ffffff' : 'var(--qb-sub)',
          }}>ALL WEEK</button>
          {DAY_SHORT.map((name, i) => {
            const isFuture = i > new Date().getDay()
            const active = weekDay === i
            const amount = weekDayTotals[i]
            return (
              <button key={name} disabled={isFuture} onClick={() => setWeekDay(i)} style={{
                padding: '6px 14px', borderRadius: 10, cursor: isFuture ? 'not-allowed' : 'pointer',
                border: `1px solid ${active ? TEAL : 'rgba(10,124,255,0.18)'}`,
                background: active ? TEAL : 'transparent',
                opacity: isFuture ? 0.35 : 1,
                display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2, minWidth: 62,
              }}>
                <span style={{
                  fontSize: 11, fontWeight: 800, letterSpacing: '0.1em',
                  color: active ? '#ffffff' : 'var(--qb-sub)',
                }}>{name.toUpperCase()}</span>
                <span style={{
                  fontSize: 10, fontVariantNumeric: 'tabular-nums', fontWeight: 700,
                  color: active ? '#ffffff' : amount > 0 ? TEAL : 'var(--qb-faint)',
                }}>{amount > 0 ? shortGHS(amount) : '—'}</span>
              </button>
            )
          })}
        </div>
      )}

      {/* ── Load scope ───────────────────────────────────────────── */}
      {!windowed && (
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
        <button
          disabled={scopeBusy}
          onClick={() => {
            const next: DataScope = scope === 'all' ? 'recent' : 'all'
            setScope(next)
            setScopeBusy(true)
            setScopeState(next)   // effect deps include scope → refetches
          }}
          style={{
            display: 'flex', alignItems: 'center', gap: 8, padding: '7px 12px', borderRadius: 999,
            border: `1px solid ${scope === 'all' ? 'rgba(251,191,36,0.4)' : 'rgba(10,124,255,0.2)'}`,
            background: 'transparent', cursor: scopeBusy ? 'wait' : 'pointer',
            opacity: scopeBusy ? 0.6 : 1,
          }}>
          <span style={{
            width: 30, height: 16, borderRadius: 999, position: 'relative', flexShrink: 0,
            background: scope === 'all' ? 'var(--qb-orange)' : 'rgba(100,116,139,0.35)',
            transition: 'background 0.15s',
          }}>
            <span style={{
              position: 'absolute', top: 2, left: scope === 'all' ? 16 : 2,
              width: 12, height: 12, borderRadius: '50%', background: 'var(--qb-bg)',
              transition: 'left 0.15s',
            }} />
          </span>
          <span style={{
            fontSize: 11, fontWeight: 800, letterSpacing: '0.1em',
            color: scope === 'all' ? 'var(--qb-orange)' : 'var(--qb-sub)',
          }}>{scope === 'all' ? 'ALL HISTORY' : 'LAST MONTH'}</span>
        </button>
        <span style={{ color: scopeBusy ? TEAL : 'var(--qb-faint)', fontSize: 11, fontVariantNumeric: 'tabular-nums' }}>
          {scopeBusy
            ? 'Reloading…'
            : scope === 'all'
              ? 'Every invoice loaded — slower, but MONTHS and YEARS are complete.'
              : 'Last month only. Turn on for full-year totals.'}
        </span>
      </div>
      )}

      {/* ── Incomplete-range notice ──────────────────────────────── */}
      {!windowed && scope === 'recent' && (period === 'months' || period === 'years') && (
        <div style={{
          display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap',
          padding: '12px 16px', borderRadius: 12,
          border: '1px solid rgba(251,191,36,0.35)', background: 'rgba(251,191,36,0.07)',
        }}>
          <span style={{ fontSize: 13, color: 'var(--qb-orange)', fontWeight: 700 }}>
            Showing last month only
          </span>
          <span style={{ fontSize: 12, color: 'var(--qb-sub)', flex: 1, minWidth: 220 }}>
            {periodLabel} needs the full history, so these totals are incomplete.
          </span>
          <button
            disabled={scopeBusy}
            onClick={() => { setScope('all'); setScopeBusy(true); setScopeState('all') }}
            style={{
              padding: '8px 14px', borderRadius: 8, border: 'none',
              background: scopeBusy ? 'var(--qb-fill)' : 'var(--qb-orange)',
              color: scopeBusy ? 'var(--qb-muted)' : '#ffffff',
              fontWeight: 800, fontSize: 11, letterSpacing: '0.1em',
              cursor: scopeBusy ? 'wait' : 'pointer', whiteSpace: 'nowrap',
            }}>
            {scopeBusy ? 'LOADING…' : 'LOAD ALL HISTORY'}
          </button>
        </div>
      )}

      {/* ── Top KPI row ──────────────────────────────────────────── */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(260px,1fr))', gap: 14 }}>
        {/* Sales card — split by payment method, period-aware */}
        <div style={{ padding: 18, borderRadius: 14, border: '1px solid var(--qb-border)', background: 'var(--qb-card)' }}>
          <div style={{ color: 'var(--qb-sub)', fontSize: 10, fontWeight: 800, letterSpacing: '0.18em' }}>TOTAL SALES · {periodLabel}</div>
          <div style={{ color: 'var(--qb-text)', fontSize: 16, fontWeight: 700, marginTop: 8 }}>{GHS(periodStats.income)}</div>
          <div style={{ display: 'flex', height: 6, borderRadius: 3, overflow: 'hidden', marginTop: 12, background: 'var(--qb-separator)' }}>
            {periodStats.income > 0 && <>
              <div style={{ width: `${(periodStats.cash / periodStats.income) * 100}%`, background: TEAL }} />
              <div style={{ width: `${(periodStats.momo  / periodStats.income) * 100}%`, background: '#a78bfa' }} />
              <div style={{ width: `${(periodStats.bank  / periodStats.income) * 100}%`, background: '#38bdf8' }} />
            </>}
          </div>
          <div style={{ display: 'flex', gap: 16, marginTop: 10, flexWrap: 'wrap' }}>
            <div><div style={{ color: TEAL,      fontWeight: 700, fontSize: 11 }}>Cash</div><div style={{ color: 'var(--qb-text)', fontVariantNumeric: 'tabular-nums', fontSize: 12 }}>{GHS(periodStats.cash)}</div></div>
            <div><div style={{ color: '#a78bfa', fontWeight: 700, fontSize: 11 }}>MoMo</div><div style={{ color: 'var(--qb-text)', fontVariantNumeric: 'tabular-nums', fontSize: 12 }}>{GHS(periodStats.momo)}</div></div>
            {periodStats.bank  > 0 && <div><div style={{ color: '#38bdf8', fontWeight: 700, fontSize: 11 }}>Bank</div> <div style={{ color: 'var(--qb-text)', fontVariantNumeric: 'tabular-nums', fontSize: 12 }}>{GHS(periodStats.bank)}</div></div>}
            {periodStats.other > 0 && <div><div style={{ color: 'var(--qb-muted)', fontWeight: 700, fontSize: 11 }}>Other</div><div style={{ color: 'var(--qb-text)', fontVariantNumeric: 'tabular-nums', fontSize: 12 }}>{GHS(periodStats.other)}</div></div>}
            {periodStats.deliveryIncome > 0 && <div><div style={{ color: 'var(--qb-orange)', fontWeight: 700, fontSize: 11 }}>🚚 Delivery</div><div style={{ color: 'var(--qb-text)', fontVariantNumeric: 'tabular-nums', fontSize: 12 }}>{GHS(periodStats.deliveryIncome)}</div></div>}
            {periodStats.debtIncome > 0 && <div><div style={{ color: '#f59e0b', fontWeight: 700, fontSize: 11 }}>🧾 Debts paid</div><div style={{ color: 'var(--qb-text)', fontVariantNumeric: 'tabular-nums', fontSize: 12 }}>{GHS(periodStats.debtIncome)}</div></div>}
            {ledger.outstanding > 0 && <div title="Sold on credit and not yet paid. Not part of the sales figure."><div style={{ color: 'var(--qb-sub)', fontWeight: 700, fontSize: 11 }}>Still owed</div><div style={{ color: '#f59e0b', fontVariantNumeric: 'tabular-nums', fontSize: 12 }}>{GHS(ledger.outstanding)}</div></div>}
          </div>
        </div>
        {/* Net card — period-aware */}
        <div style={{ padding: 18, borderRadius: 14, border: '1px solid var(--qb-border)', background: 'var(--qb-card)' }}>
          <div style={{ color: 'var(--qb-sub)', fontSize: 10, fontWeight: 800, letterSpacing: '0.18em' }}>NET PROFIT · {periodLabel}</div>
          <div style={{ color: 'var(--qb-text)', fontSize: 16, fontWeight: 700, marginTop: 8 }}>Cash − Expenses</div>
          <div style={{ display: 'flex', height: 6, borderRadius: 3, overflow: 'hidden', marginTop: 12, background: 'var(--qb-separator)' }}>
            {periodStats.cash > 0 && <div style={{ width: `${Math.min(100, (periodStats.expenseTotal / periodStats.cash) * 100)}%`, background: 'var(--qb-red)' }} />}
          </div>
          <div style={{ display: 'flex', gap: 16, marginTop: 10 }}>
            <div><div style={{ color: TEAL,      fontWeight: 700, fontSize: 11 }}>Cash</div>    <div style={{ color: 'var(--qb-text)', fontVariantNumeric: 'tabular-nums', fontSize: 12 }}>{GHS(periodStats.cash)}</div></div>
            <div><div style={{ color: 'var(--qb-red)', fontWeight: 700, fontSize: 11 }}>Expenses</div><div style={{ color: 'var(--qb-text)', fontVariantNumeric: 'tabular-nums', fontSize: 12 }}>{GHS(periodStats.expenseTotal)}</div></div>
            <div><div style={{ color: periodStats.net >= 0 ? TEAL : 'var(--qb-red)', fontWeight: 700, fontSize: 11 }}>Net</div><div style={{ color: periodStats.net >= 0 ? TEAL : 'var(--qb-red)', fontVariantNumeric: 'tabular-nums', fontSize: 13, fontWeight: 900 }}>{GHS(periodStats.net)}</div></div>
          </div>
        </div>
      </div>

      {/* ── Period total ─────────────────────────────────────────── */}
      <div style={{
        padding: 24, borderRadius: 16,
        border: '1px solid rgba(10,124,255,0.18)',
        background: 'linear-gradient(135deg, var(--qb-header), var(--qb-card))',
      }}>
        <div style={{ color: TEAL, fontSize: 11, fontWeight: 800, letterSpacing: '0.2em', marginBottom: 6 }}>SALES · {periodLabel}</div>
        <div style={{ color: 'var(--qb-text)', fontSize: 44, fontWeight: 900, lineHeight: 1.1 }}>{GHS(periodStats.income)}</div>
        <div style={{ color: 'var(--qb-muted)', fontSize: 12, fontVariantNumeric: 'tabular-nums', marginTop: 4 }}>
          {periodStats.count} {periodStats.count === 1 ? 'invoice' : 'invoices'}
        </div>
        {/* NET — income minus expenses for the same period */}
        <div style={{ marginTop: 12, display: 'flex', alignItems: 'baseline', gap: 8 }}>
          <span style={{ fontSize: 10, fontWeight: 800, letterSpacing: '0.15em', color: 'var(--qb-muted)' }}>NET REVENUE</span>
          <span style={{
            fontSize: 22, fontWeight: 900, fontVariantNumeric: 'tabular-nums',
            color: periodStats.net >= 0 ? TEAL : 'var(--qb-red)',
          }}>{GHS(periodStats.net)}</span>
          {periodStats.expenseTotal > 0 && (
            <span style={{ fontSize: 11, color: 'var(--qb-faint)', fontVariantNumeric: 'tabular-nums' }}>
              − {GHS(periodStats.expenseTotal)} expenses
            </span>
          )}
        </div>
      </div>

      {/* ── Cash Flow Line Chart ────────────────────────────────── */}
      <div style={{ padding: 20, borderRadius: 14, border: '1px solid var(--qb-border)', background: 'var(--qb-card)' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 12, flexWrap: 'wrap', gap: 10, alignItems: 'center' }}>
          <div style={{ color: 'var(--qb-sub)', fontSize: 11, fontWeight: 800, letterSpacing: '0.18em' }}>CASH FLOW</div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 18 }}>
            <span style={{ display: 'flex', alignItems: 'center', gap: 5, fontSize: 11, color: TEAL, fontWeight: 700 }}>
              <span style={{ width: 18, height: 2, background: TEAL, display: 'inline-block', borderRadius: 1 }} />
              INCOME
            </span>
            <span style={{ display: 'flex', alignItems: 'center', gap: 5, fontSize: 11, color: 'var(--qb-red)', fontWeight: 700 }}>
              <span style={{ width: 18, height: 0, display: 'inline-block', borderTop: '2px dashed #f87171' }} />
              EXPENSE
            </span>
            <div style={{ color: TEAL, fontSize: 13, fontWeight: 700, fontVariantNumeric: 'tabular-nums' }}>{GHS(periodTotal)}</div>
          </div>
        </div>
        <div style={{ width: '100%', height: 260 }}>
          <ResponsiveContainer>
            <AreaChart data={chartData}>
              <defs>
                <linearGradient id="cf" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="0%" stopColor={TEAL} stopOpacity={0.35} />
                  <stop offset="100%" stopColor={TEAL} stopOpacity={0} />
                </linearGradient>
                <linearGradient id="exp" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="0%" stopColor={CH.red} stopOpacity={0.2} />
                  <stop offset="100%" stopColor={CH.red} stopOpacity={0} />
                </linearGradient>
              </defs>
              <CartesianGrid stroke={CH.grid} vertical={false} />
              <XAxis dataKey="label" tick={{ fill: CH.tick, fontSize: 11 }} axisLine={false} tickLine={false} />
              <YAxis tick={{ fill: CH.tick, fontSize: 11 }} axisLine={false} tickLine={false}
                     tickFormatter={(v) => v >= 1000 ? `${(v/1000).toFixed(0)}K` : String(v)} />
              <Tooltip
                contentStyle={{ background: 'var(--qb-card-strong)', backdropFilter: 'blur(20px)', border: '1px solid var(--qb-border)', borderRadius: 12, color: 'var(--qb-text)' }}
                formatter={(v: any, name: any) => [GHS(Number(v)), name === 'value' ? 'Income' : 'Expense']}
              />
              <Area type="monotone" dataKey="value"   name="Income"  stroke={TEAL}     strokeWidth={2} fill="url(#cf)"  />
              <Area type="monotone" dataKey="expense" name="Expense" stroke={CH.red} strokeWidth={2} strokeDasharray="5 3" fill="url(#exp)" />
            </AreaChart>
          </ResponsiveContainer>
        </div>
      </div>

      {/* ── Income vs Expense & Top products ──────────────────────
          All three are year-scoped rollups, so they're withheld from a
          windowed viewer rather than rendered as empty charts. */}
      {!windowed && (
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(320px,1fr))', gap: 14 }}>
        <Card title="INCOME VS EXPENSE">
          <div style={{ width: '100%', height: 220 }}>
            <ResponsiveContainer>
              <BarChart data={incomeVsExpense}>
                <CartesianGrid stroke={CH.grid} vertical={false} />
                <XAxis dataKey="label" tick={{ fill: CH.tick, fontSize: 11 }} axisLine={false} tickLine={false} />
                <YAxis tick={{ fill: CH.tick, fontSize: 10 }} axisLine={false} tickLine={false}
                       tickFormatter={(v) => v >= 1000 ? `${(v/1000).toFixed(0)}K` : String(v)} />
                <Tooltip contentStyle={{ background: 'var(--qb-card-strong)', backdropFilter: 'blur(20px)', border: '1px solid var(--qb-border)', borderRadius: 12 }}
                         formatter={(v: any) => GHS(Number(v))} />
                <Bar dataKey="income"  fill={TEAL} radius={[4,4,0,0]} />
                <Bar dataKey="expense" fill={CH.red} radius={[4,4,0,0]} />
              </BarChart>
            </ResponsiveContainer>
          </div>
        </Card>

        <Card title="TOP SELLING PRODUCTS">
          <ul style={{ listStyle: 'none', padding: 0, margin: 0, display: 'flex', flexDirection: 'column', gap: 10, maxHeight: 420, overflowY: 'auto' }}>
            {productStats.top.map(p => {
              const pct = Math.round((p.invoiceCount / topInvoiceCount) * 100)
              return (
                <li key={p.desc} style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, color: 'var(--qb-text)', gap: 8 }}>
                    <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}>{p.desc}</span>
                    <span style={{ color: TEAL, fontWeight: 700, whiteSpace: 'nowrap' }}>
                      {p.invoiceCount} {p.invoiceCount === 1 ? 'invoice' : 'invoices'}
                    </span>
                  </div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <div style={{ flex: 1, height: 6, background: 'var(--qb-header)', borderRadius: 3, overflow: 'hidden' }}>
                      <div style={{ width: `${pct}%`, height: '100%', background: TEAL }} />
                    </div>
                    <span style={{ color: 'var(--qb-muted)', fontSize: 10, fontVariantNumeric: 'tabular-nums', minWidth: 56, textAlign: 'right' }}>{p.qty} units</span>
                  </div>
                </li>
              )
            })}
            {productStats.top.length === 0 && <li style={{ color: 'var(--qb-muted)', fontSize: 12 }}>No sales yet.</li>}
          </ul>
        </Card>

        <Card title="LEAST SELLING PRODUCTS">
          <ul style={{ listStyle: 'none', padding: 0, margin: 0, display: 'flex', flexDirection: 'column', gap: 10 }}>
            {productStats.least.map(p => (
              <li key={p.desc} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, color: 'var(--qb-text)' }}>
                <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', maxWidth: 220 }}>{p.desc}</span>
                <span style={{ color: '#f59e0b', fontWeight: 700 }}>{p.qty} units</span>
              </li>
            ))}
            {productStats.least.length === 0 && <li style={{ color: 'var(--qb-muted)', fontSize: 12 }}>—</li>}
          </ul>
        </Card>
      </div>
      )}

      {/* ── Top customers: year + 4 months ───────────────────────── */}
      {!windowed && (
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(360px,1fr))', gap: 14 }}>
        <TopCustomersCard title={`🏆 BEST CUSTOMERS · ${new Date().getFullYear()}`} rows={customerRanks.year} />
        <TopCustomersCard title="⭐ BEST CUSTOMERS · LAST 4 MONTHS" rows={customerRanks.fourMonths} />
      </div>
      )}
    </div>
  )
}

function TopCustomersCard({ title, rows }: { title: string; rows: { name: string; phone: string; count: number; total: number }[] }) {
  const [q, setQ] = useState('')
  const topCount  = rows[0]?.count || 1
  const visible   = q.trim()
    ? rows.filter(c =>
        c.name.toLowerCase().includes(q.toLowerCase()) ||
        c.phone.includes(q)
      )
    : rows

  return (
    <div style={{ padding: 18, borderRadius: 14, border: '1px solid var(--qb-border)', background: 'var(--qb-card)' }}>
      <div style={{ color: 'var(--qb-sub)', fontSize: 11, fontWeight: 800, letterSpacing: '0.18em', marginBottom: 12 }}>{title}</div>

      {/* Search bar */}
      <div style={{ position: 'relative', marginBottom: 12 }}>
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke='var(--qb-faint)' strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"
          style={{ position: 'absolute', left: 10, top: '50%', transform: 'translateY(-50%)', pointerEvents: 'none' }}>
          <circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/>
        </svg>
        <input
          value={q} onChange={e => setQ(e.target.value)}
          placeholder={`Search ${rows.length} customers…`}
          style={{
            width: '100%', boxSizing: 'border-box',
            padding: '7px 10px 7px 30px', borderRadius: 8,
            background: 'rgba(0,0,0,0.2)', border: '1px solid var(--qb-border)',
            color: 'var(--qb-text)', fontSize: 12, outline: 'none',
          }}
        />
        {q && (
          <button onClick={() => setQ('')}
            style={{ position: 'absolute', right: 8, top: '50%', transform: 'translateY(-50%)', background: 'none', border: 'none', color: 'var(--qb-muted)', cursor: 'pointer', fontSize: 14, lineHeight: 1, padding: 0 }}>
            ×
          </button>
        )}
      </div>

      {visible.length === 0 && (
        <div style={{ color: 'var(--qb-muted)', fontSize: 12, fontVariantNumeric: 'tabular-nums', padding: '8px 0' }}>
          {rows.length === 0 ? 'No invoices in this period.' : `No match for "${q}"`}
        </div>
      )}

      <ol style={{ listStyle: 'none', padding: 0, margin: 0, display: 'flex', flexDirection: 'column', gap: 10, maxHeight: 480, overflowY: 'auto' }}>
        {visible.map((c, i) => {
          const globalRank = rows.indexOf(c)
          const pct   = Math.round((c.count / topCount) * 100)
          const medal = globalRank === 0 ? '🥇' : globalRank === 1 ? '🥈' : globalRank === 2 ? '🥉' : `${globalRank + 1}`
          return (
            <li key={c.name + i} style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10, fontSize: 12, color: 'var(--qb-text)', alignItems: 'baseline' }}>
                <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}>
                  <span style={{ color: 'var(--qb-muted)', fontVariantNumeric: 'tabular-nums', marginRight: 6 }}>{medal}</span>
                  <span style={{ color: 'var(--qb-text)', fontWeight: 700 }}>{c.name}</span>
                  {c.phone && <span style={{ color: 'var(--qb-muted)', fontVariantNumeric: 'tabular-nums', fontSize: 11, marginLeft: 8 }}>· {c.phone}</span>}
                </span>
                <span style={{ color: TEAL, fontVariantNumeric: 'tabular-nums', fontWeight: 900, whiteSpace: 'nowrap' }}>
                  {c.count} {c.count === 1 ? 'invoice' : 'invoices'}
                </span>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <div style={{ flex: 1, height: 4, background: 'var(--qb-header)', borderRadius: 2, overflow: 'hidden' }}>
                  <div style={{ width: `${pct}%`, height: '100%', background: TEAL }} />
                </div>
                <span style={{ color: 'var(--qb-faint)', fontSize: 10, fontVariantNumeric: 'tabular-nums', minWidth: 80, textAlign: 'right' }}>
                  {GHS(c.total)}
                </span>
              </div>
            </li>
          )
        })}
      </ol>
    </div>
  )
}


function Card({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div style={{ padding: 18, borderRadius: 14, border: '1px solid var(--qb-border)', background: 'var(--qb-card)' }}>
      <div style={{ color: 'var(--qb-sub)', fontSize: 11, fontWeight: 800, letterSpacing: '0.18em', marginBottom: 14 }}>{title}</div>
      {children}
    </div>
  )
}
