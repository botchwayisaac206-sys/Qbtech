'use client'

import { useEffect, useMemo, useState } from 'react'
import {
  ResponsiveContainer, XAxis, YAxis, Tooltip,
  CartesianGrid, AreaChart, Area, BarChart, Bar,
} from 'recharts'
import { GHS, withinWindow, paymentBuckets } from '@/lib/sales'
import { useQbDark } from '@/lib/qbTheme'
import { Banknote, Receipt, TrendingUp, TrendingDown, HandCoins, ArrowUpRight, ArrowDownRight, Search, type LucideIcon } from 'lucide-react'
import { loadCreditLedger, emptyLedger, type CreditLedger } from '@/lib/debts'
import { fetchInvoices, fetchInvoiceItems, fetchExpenses, fetchDeliveries, invalidate, peek, scopedKey, getScope, setScope, recentCutoff, type DataScope, type InvRow, type ItemRow, type ExpRow, type DelRow, deliveredInvoiceNumbers } from '@/lib/adminCache'


type Period = 'today' | 'week' | 'weeks' | 'months' | 'years'

const startOfDay = (d: Date) => { const x = new Date(d); x.setHours(0,0,0,0); return x }
const startOfWeek = (d: Date) => { const x = startOfDay(d); x.setDate(x.getDate() - x.getDay()); return x }
const startOfYear  = (d: Date) => new Date(d.getFullYear(), 0, 1)
const addDays = (d: Date, n: number) => { const x = new Date(d); x.setDate(x.getDate() + n); return x }

const DAY_SHORT = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat']
const DAY_LONG  = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday']

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

/**
 * The window to compare the current selection against, cut at the same point
 * in time — so "today so far" is compared with "yesterday up to this hour",
 * never with the whole of yesterday. null when there is nothing fair to
 * compare with (the 4-year view).
 */
function previousRange(p: Period, weekDay: number | null, now: Date): { range: Range; label: string } | null {
  const cur = periodRange(p, weekDay, now)
  // How much of the current window has actually happened.
  const elapsed = Math.max(0, Math.min(now.getTime(), cur.to.getTime()) - cur.from.getTime())
  const back = (from: Date) => ({ from, to: new Date(from.getTime() + elapsed) })
  if (p === 'today') return { range: back(addDays(cur.from, -1)), label: 'vs yesterday, same time' }
  if (p === 'week') {
    return weekDay === null
      ? { range: back(addDays(cur.from, -7)), label: 'vs last week, same point' }
      : { range: back(addDays(cur.from, -7)), label: `vs last ${DAY_LONG[weekDay]}` }
  }
  if (p === 'weeks') return { range: back(addDays(cur.from, -28)), label: 'vs the 4 weeks before' }
  if (p === 'months') {
    const from = new Date(now.getFullYear() - 1, 0, 1)
    const to = new Date(now); to.setFullYear(now.getFullYear() - 1)
    return { range: { from, to }, label: `vs ${now.getFullYear() - 1}, same date` }
  }
  return null
}

/** Percentage change, or null when there is no base to compare with. */
const pctChange = (cur: number, prev: number) => (prev > 0 ? ((cur - prev) / prev) * 100 : null)

/** Payment-method colours: one hue each, the same everywhere on this page. */
const PAY = { cash: '#2563eb', momo: '#eab308', bank: '#7c3aed', other: '#94a3b8' }

/** Compact money for the day chips, where there is no room for full precision. */
const shortGHS = (n: number) =>
  n >= 1000 ? `${(n / 1000).toFixed(n >= 10000 ? 0 : 1)}k` : n.toFixed(0)

export default function SalesDashboard({ isBoss, windowed = false }: { isBoss: boolean; windowed?: boolean }) {
  // Charts write SVG attributes, which need real colours rather than CSS variables.
  const chartDark = useQbDark()
  const CH = chartDark
    ? { income: '#4d8dff', red: '#f87171', grid: 'rgba(148,163,184,0.16)', tick: 'rgba(203,213,225,0.7)' }
    : { income: '#1f5fd6', red: '#dc2626', grid: 'rgba(15,23,42,0.07)', tick: 'rgba(71,85,105,0.85)' }
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
        periodLabel: period === 'today' ? 'Today' : DAY_LONG[weekDay as number],
      }
    }
    if (period === 'week') {
      const buckets = DAY_SHORT.map(n => ({ label: n, value: 0, expense: 0 }))
      invIn.forEach(i => { buckets[new Date(i.issued_at).getDay()].value   += Number(i.total) })
      delIn.forEach(d => { buckets[new Date(d.delivered_at).getDay()].value += Number(d.amount) })
      expIn.forEach(e => { buckets[new Date(e.incurred_at).getDay()].expense += Number(e.amount) })
      return { chartData: buckets, periodTotal: totalOf(buckets), periodLabel: 'This week' }
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
      return { chartData: buckets, periodTotal: totalOf(buckets), periodLabel: 'Last 4 weeks' }
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
    return { chartData: buckets, periodTotal: totalOf(buckets), periodLabel: 'Last 4 years' }
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

  // ── The same figures for the comparison window ──────────────────
  // Hidden when that window reaches back past what has been loaded, so a
  // "last month only" load never shows a fake −100%.
  const comparison = useMemo(() => {
    const prev = previousRange(period, weekDay, new Date())
    if (!prev) return null
    const cutoff = scope === 'recent' ? recentCutoff() : null
    if (cutoff && prev.range.from < new Date(cutoff)) return null
    const income = invoices.filter(i => inRange(i.issued_at, prev.range)).reduce((s, i) => s + Number(i.total), 0)
      + deliveries.filter(d => inRange(d.delivered_at, prev.range)).reduce((s, d) => s + Number(d.amount), 0)
    const expense = expenses.filter(e => inRange(e.incurred_at, prev.range)).reduce((s, e) => s + Number(e.amount), 0)
    return { label: prev.label, income, expense, net: income - expense }
  }, [invoices, expenses, deliveries, period, weekDay, scope])

  const retry = () => { invalidate('invoices', 'invoice_items', 'expenses', 'deliveries'); setReloadKey(k => k + 1) }

  if (error) return (
    <div style={{ ...card, padding: 40, textAlign: 'center', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14 }}>
      <div style={{ color: 'var(--qb-red)', fontWeight: 600 }}>Couldn’t load the dashboard: {error}</div>
      <button onClick={retry} style={btnPrimary}>Try again</button>
    </div>
  )

  if (loading) return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      <div style={kpiGrid}>
        {[0, 1, 2, 3].map(i => <div key={i} style={{ ...card, height: 132, background: 'var(--qb-card)', opacity: 0.6 }} />)}
      </div>
      <div style={{ color: 'var(--qb-muted)', fontSize: 14, display: 'flex', alignItems: 'center', gap: 12 }}>
        Loading sales…
        <button onClick={retry} style={btnGhost}>Taking too long? Retry</button>
      </div>
    </div>
  )

  const s = periodStats
  const netIncome = s.income - s.expenseTotal
  const sales = s.count + s.deliveryCount
  const avgSale = sales > 0 ? (s.income - s.debtIncome) / sales : 0
  const payTotal = s.cash + s.momo + s.bank + s.other
  const payRows = ([
    ['Cash', s.cash, PAY.cash],
    ['Mobile Money', s.momo, PAY.momo],
    ['Bank transfer', s.bank, PAY.bank],
    ['Other', s.other, PAY.other],
  ] as [string, number, string][]).filter(([, v], i) => i < 2 || v > 0)
  const periods: [Period, string][] = windowed
    ? [['today', 'Today']]
    : [['today', 'Today'], ['week', 'This week'], ['weeks', '4 weeks'], ['months', 'This year'], ['years', '4 years']]

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>

      {/* ── Toolbar: which period, and how much history is loaded ── */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
        <div role="tablist" aria-label="Period" style={{ display: 'flex', gap: 2, padding: 3, borderRadius: 12, background: 'var(--qb-card)', border: '1px solid var(--qb-border)', flexWrap: 'wrap', boxShadow: 'none' }}>
          {periods.map(([k, l]) => {
            const on = period === k
            return (
              <button key={k} role="tab" aria-selected={on} onClick={() => { setPeriod(k); if (k !== 'week') setWeekDay(null) }} style={{
                padding: '8px 14px', borderRadius: 9, border: 'none', cursor: 'pointer', fontSize: 13.5, fontWeight: on ? 650 : 500,
                background: on ? ACC : 'transparent', color: on ? '#fff' : 'var(--qb-sub)',
              }}>{l}</button>
            )
          })}
        </div>

        {!windowed && (
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <span style={{ fontSize: 12.5, color: scopeBusy ? ACC : 'var(--qb-muted)' }}>
              {scopeBusy ? 'Reloading…' : scope === 'all' ? 'All history loaded' : 'Last month loaded'}
            </span>
            <button
              disabled={scopeBusy}
              onClick={() => {
                const next: DataScope = scope === 'all' ? 'recent' : 'all'
                setScope(next); setScopeBusy(true); setScopeState(next)   // effect deps include scope → refetches
              }}
              style={{ ...btnGhost, cursor: scopeBusy ? 'wait' : 'pointer', opacity: scopeBusy ? 0.6 : 1 }}>
              {scope === 'all' ? 'Load last month only' : 'Load all history'}
            </button>
          </div>
        )}
      </div>

      {/* ── Day chips (This week only) ── */}
      {period === 'week' && (
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          <DayChip active={weekDay === null} onClick={() => setWeekDay(null)} top="Whole week" bottom={shortGHS(weekDayTotals.reduce((a, b) => a + b, 0))} />
          {DAY_SHORT.map((name, i) => (
            <DayChip key={name} active={weekDay === i} disabled={i > new Date().getDay()} onClick={() => setWeekDay(i)}
              top={name} bottom={weekDayTotals[i] > 0 ? shortGHS(weekDayTotals[i]) : '—'} />
          ))}
        </div>
      )}

      {/* ── Incomplete-range notice ── */}
      {!windowed && scope === 'recent' && (period === 'months' || period === 'years') && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap', padding: '12px 16px', borderRadius: 12, background: 'var(--qb-amber-soft)', border: '1px solid color-mix(in srgb, var(--qb-amber) 30%, transparent)' }}>
          <span style={{ fontSize: 14, color: 'var(--qb-amber)', fontWeight: 700 }}>These totals are incomplete</span>
          <span style={{ fontSize: 13.5, color: 'var(--qb-sub)', flex: 1, minWidth: 220 }}>
            {periodLabel} needs the full history, but only the last month is loaded.
          </span>
          <button disabled={scopeBusy} onClick={() => { setScope('all'); setScopeBusy(true); setScopeState('all') }}
            style={{ ...btnPrimary, background: 'var(--qb-amber)', color: 'var(--qb-solid)', cursor: scopeBusy ? 'wait' : 'pointer' }}>
            {scopeBusy ? 'Loading…' : 'Load all history'}
          </button>
        </div>
      )}

      {/* ── The four numbers that matter ── */}
      <div style={kpiGrid}>
        <Kpi icon={Banknote} tone="accent" label={`Sales · ${periodLabel}`} value={GHS(s.income)}
          delta={comparison && pctChange(s.income, comparison.income)} deltaLabel={comparison?.label}
          foot={`${s.count} ${s.count === 1 ? 'invoice' : 'invoices'}${s.deliveryCount ? ` · ${s.deliveryCount} ${s.deliveryCount === 1 ? 'delivery' : 'deliveries'}` : ''}`} />
        <Kpi icon={Receipt} tone="red" label={`Expenses · ${periodLabel}`} value={GHS(s.expenseTotal)} invert
          delta={comparison && pctChange(s.expenseTotal, comparison.expense)} deltaLabel={comparison?.label}
          foot={s.income > 0 ? `${Math.round((s.expenseTotal / s.income) * 100)}% of sales` : 'No sales yet'} />
        <Kpi icon={netIncome >= 0 ? TrendingUp : TrendingDown} tone={netIncome >= 0 ? 'green' : 'red'} label={`Net · ${periodLabel}`}
          value={GHS(netIncome)} valueTone={netIncome >= 0 ? 'green' : 'red'}
          delta={comparison && comparison.net > 0 ? pctChange(netIncome, comparison.net) : null} deltaLabel={comparison?.label}
          foot={s.income > 0 ? `Sales − expenses · ${Math.round((netIncome / s.income) * 100)}% margin` : 'Sales − expenses'} />
        <Kpi icon={HandCoins} tone="amber" label="Owed by customers" value={GHS(ledger.outstanding)} valueTone={ledger.outstanding > 0 ? 'amber' : undefined}
          foot={ledger.debtors > 0 ? `${ledger.debtors} open ${ledger.debtors === 1 ? 'debt' : 'debts'} · not counted in sales` : 'Nobody owes anything'} />
      </div>

      {/* ── Supporting figures ── */}
      <div style={{ ...card, padding: 0, display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(170px, 1fr))' }}>
        <Mini label="Average sale" value={GHS(avgSale)} hint="Per invoice or delivery" />
        <Mini label="Cash in hand" value={GHS(s.net)} hint="Cash taken − expenses" tone={s.net < 0 ? 'red' : undefined} />
        <Mini label="Debts collected" value={GHS(s.debtIncome)} hint="Included in sales" />
        <Mini label="Delivery sales" value={GHS(s.deliveryIncome)} hint={`${s.deliveryCount} ${s.deliveryCount === 1 ? 'delivery' : 'deliveries'}`} last />
      </div>

      {/* ── Cash flow + how customers paid ── */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(min(100%, 340px), 1fr))', gap: 16 }}>
        <div style={{ ...card, gridColumn: 'span 2', minWidth: 0 }} className="qb-span2">
          <CardHead title="Money in and out" sub={periodLabel}>
            <Legend color={CH.income} label="Sales" />
            <Legend color={CH.red} label="Expenses" dashed />
          </CardHead>
          <div style={{ width: '100%', height: 260 }}>
            <ResponsiveContainer>
              <AreaChart data={chartData} margin={{ top: 6, right: 6, left: -8, bottom: 0 }}>
                <defs>
                  <linearGradient id="cf" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stopColor={CH.income} stopOpacity={0.28} />
                    <stop offset="100%" stopColor={CH.income} stopOpacity={0} />
                  </linearGradient>
                </defs>
                <CartesianGrid stroke={CH.grid} vertical={false} />
                <XAxis dataKey="label" tick={{ fill: CH.tick, fontSize: 11 }} axisLine={false} tickLine={false} />
                <YAxis tick={{ fill: CH.tick, fontSize: 11 }} axisLine={false} tickLine={false} width={48}
                       tickFormatter={(v) => v >= 1000 ? `${(v/1000).toFixed(0)}k` : String(v)} />
                <Tooltip contentStyle={tooltipStyle}
                  formatter={(v: any, name: any) => [GHS(Number(v)), name === 'value' ? 'Sales' : 'Expenses']} />
                <Area type="monotone" dataKey="value"   name="value"   stroke={CH.income} strokeWidth={2.2} fill="url(#cf)" />
                <Area type="monotone" dataKey="expense" name="expense" stroke={CH.red} strokeWidth={1.8} strokeDasharray="5 4" fill="none" />
              </AreaChart>
            </ResponsiveContainer>
          </div>
        </div>

        <div style={card}>
          <CardHead title="How customers paid" sub={periodLabel} />
          <div style={{ display: 'flex', height: 10, borderRadius: 999, overflow: 'hidden', background: 'var(--qb-fill)', gap: 2 }}>
            {payTotal > 0 && payRows.map(([l, v, c]) => v > 0 && <div key={l} title={l} style={{ width: `${(v / payTotal) * 100}%`, background: c }} />)}
          </div>
          <ul style={{ listStyle: 'none', margin: '14px 0 0', padding: 0, display: 'flex', flexDirection: 'column' }}>
            {payRows.map(([l, v, c]) => (
              <li key={l} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderTop: '1px solid var(--qb-separator)', fontSize: 14 }}>
                <span aria-hidden style={{ width: 10, height: 10, borderRadius: 3, background: c, flexShrink: 0 }} />
                <span style={{ flex: 1, color: 'var(--qb-sub)' }}>{l}</span>
                <span style={{ color: 'var(--qb-muted)', fontSize: 12.5, fontVariantNumeric: 'tabular-nums', minWidth: 38, textAlign: 'right' }}>
                  {payTotal > 0 ? `${Math.round((v / payTotal) * 100)}%` : '—'}
                </span>
                <span style={{ color: 'var(--qb-text)', fontWeight: 600, fontVariantNumeric: 'tabular-nums', minWidth: 110, textAlign: 'right' }}>{GHS(v)}</span>
              </li>
            ))}
          </ul>
        </div>
      </div>

      {/* ── Year-scoped rollups: withheld from a windowed viewer rather than shown empty ── */}
      {!windowed && (
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(min(100%, 320px), 1fr))', gap: 16 }}>
        <div style={card}>
          <CardHead title="Sales vs expenses by month" sub={String(new Date().getFullYear())}>
            <Legend color={CH.income} label="Sales" />
            <Legend color={CH.red} label="Expenses" />
          </CardHead>
          <div style={{ width: '100%', height: 240 }}>
            <ResponsiveContainer>
              <BarChart data={incomeVsExpense} margin={{ top: 6, right: 0, left: -14, bottom: 0 }} barGap={2}>
                <CartesianGrid stroke={CH.grid} vertical={false} />
                <XAxis dataKey="label" tick={{ fill: CH.tick, fontSize: 10.5 }} axisLine={false} tickLine={false} interval={0} />
                <YAxis tick={{ fill: CH.tick, fontSize: 10.5 }} axisLine={false} tickLine={false}
                       tickFormatter={(v) => v >= 1000 ? `${(v/1000).toFixed(0)}k` : String(v)} />
                <Tooltip contentStyle={tooltipStyle} cursor={{ fill: CH.grid }}
                  formatter={(v: any, name: any) => [GHS(Number(v)), name === 'income' ? 'Sales' : 'Expenses']} />
                <Bar dataKey="income"  fill={CH.income} radius={[4,4,0,0]} maxBarSize={18} />
                <Bar dataKey="expense" fill={CH.red} radius={[4,4,0,0]} maxBarSize={18} />
              </BarChart>
            </ResponsiveContainer>
          </div>
        </div>

        <div style={card}>
          <CardHead title="Best-selling products" sub="By number of invoices" />
          <ol style={{ listStyle: 'none', padding: 0, margin: 0, display: 'flex', flexDirection: 'column', gap: 12, maxHeight: 300, overflowY: 'auto', paddingRight: 4 }}>
            {productStats.top.map((p, i) => (
              <li key={p.desc} style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
                <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, fontSize: 13.5 }}>
                  <span style={{ color: 'var(--qb-faint)', fontVariantNumeric: 'tabular-nums', width: 18, flexShrink: 0 }}>{i + 1}</span>
                  <span style={{ flex: 1, color: 'var(--qb-text)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{p.desc}</span>
                  <span style={{ color: 'var(--qb-text)', fontWeight: 650, whiteSpace: 'nowrap', fontVariantNumeric: 'tabular-nums' }}>{p.invoiceCount}</span>
                </div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8, paddingLeft: 26 }}>
                  <div style={{ flex: 1, height: 5, background: 'var(--qb-fill)', borderRadius: 3, overflow: 'hidden' }}>
                    <div style={{ width: `${Math.round((p.invoiceCount / topInvoiceCount) * 100)}%`, height: '100%', background: ACC, borderRadius: 3 }} />
                  </div>
                  <span style={{ color: 'var(--qb-muted)', fontSize: 11.5, fontVariantNumeric: 'tabular-nums', minWidth: 120, textAlign: 'right' }}>{p.qty} units · {shortGHS(p.total)}</span>
                </div>
              </li>
            ))}
            {productStats.top.length === 0 && <li style={{ color: 'var(--qb-muted)', fontSize: 13.5 }}>No sales yet.</li>}
          </ol>
        </div>

        <div style={card}>
          <CardHead title="Slow movers" sub="Fewest invoices — consider a promotion" />
          <ul style={{ listStyle: 'none', padding: 0, margin: 0, display: 'flex', flexDirection: 'column' }}>
            {productStats.least.map(p => (
              <li key={p.desc} style={{ display: 'flex', justifyContent: 'space-between', gap: 10, fontSize: 13.5, padding: '9px 0', borderTop: '1px solid var(--qb-separator)' }}>
                <span style={{ color: 'var(--qb-text)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}>{p.desc}</span>
                <span style={{ color: 'var(--qb-amber)', fontWeight: 650, whiteSpace: 'nowrap', fontVariantNumeric: 'tabular-nums' }}>{p.qty} {p.qty === 1 ? 'unit' : 'units'}</span>
              </li>
            ))}
            {productStats.least.length === 0 && <li style={{ color: 'var(--qb-muted)', fontSize: 13.5 }}>Nothing yet.</li>}
          </ul>
        </div>
      </div>
      )}

      {/* ── Best customers: this year + last 4 months ── */}
      {!windowed && (
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(min(100%, 360px), 1fr))', gap: 16 }}>
        <TopCustomersCard title={`Best customers · ${new Date().getFullYear()}`} rows={customerRanks.year} />
        <TopCustomersCard title="Best customers · last 4 months" rows={customerRanks.fourMonths} />
      </div>
      )}

      <style>{`@media (max-width: 760px) { .qb-span2 { grid-column: auto !important; } }`}</style>
    </div>
  )
}

// ── Building blocks ─────────────────────────────────────────────

const ACC = 'var(--qb-accent)'
const card: React.CSSProperties = { padding: 18, borderRadius: 16, border: '1px solid var(--qb-border)', background: 'var(--qb-card)' }
const kpiGrid: React.CSSProperties = { display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(min(100%, 230px), 1fr))', gap: 16 }
const btnPrimary: React.CSSProperties = { padding: '9px 16px', borderRadius: 10, border: 'none', background: ACC, color: '#fff', fontWeight: 600, fontSize: 13.5, cursor: 'pointer', whiteSpace: 'nowrap' }
const btnGhost: React.CSSProperties = { padding: '7px 12px', borderRadius: 10, border: '1px solid var(--qb-border)', background: 'var(--qb-card)', color: 'var(--qb-text)', fontWeight: 600, fontSize: 13, cursor: 'pointer', whiteSpace: 'nowrap', boxShadow: 'none' }
const tooltipStyle: React.CSSProperties = { background: 'var(--qb-solid)', border: '1px solid var(--qb-border)', borderRadius: 10, color: 'var(--qb-text)', fontSize: 13, boxShadow: 'var(--qb-shadow)' }

type Tone = 'accent' | 'green' | 'red' | 'amber'
const TONE: Record<Tone, { fg: string; bg: string }> = {
  accent: { fg: 'var(--qb-accent)', bg: 'var(--qb-accent-soft)' },
  green:  { fg: 'var(--qb-green)',  bg: 'var(--qb-green-soft)' },
  red:    { fg: 'var(--qb-red)',    bg: 'var(--qb-red-soft)' },
  amber:  { fg: 'var(--qb-amber)',  bg: 'var(--qb-amber-soft)' },
}

/**
 * One headline number. `delta` is the % change against the comparison
 * window; `invert` marks figures where going up is bad (expenses).
 */
function Kpi({ icon: Icon, tone, label, value, valueTone, foot, delta, deltaLabel, invert }: {
  icon: LucideIcon; tone: Tone; label: string; value: string; valueTone?: Tone; foot?: string
  delta?: number | null; deltaLabel?: string; invert?: boolean
}) {
  const has = typeof delta === 'number' && isFinite(delta)
  const up = has && (delta as number) >= 0
  const good = has && (invert ? !up : up)
  return (
    <div style={{ ...card, display: 'flex', flexDirection: 'column', gap: 10, minWidth: 0 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <span aria-hidden style={{ width: 34, height: 34, borderRadius: 10, display: 'grid', placeItems: 'center', background: TONE[tone].bg, color: TONE[tone].fg, flexShrink: 0 }}>
          <Icon size={18} strokeWidth={2.2} />
        </span>
        <span style={{ color: 'var(--qb-sub)', fontSize: 13.5, fontWeight: 600, minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{label}</span>
      </div>
      <div style={{ color: valueTone ? TONE[valueTone].fg : 'var(--qb-text)', fontSize: 27, fontWeight: 750, letterSpacing: '-0.02em', lineHeight: 1.1, fontVariantNumeric: 'tabular-nums', overflowWrap: 'anywhere' }}>
        {value}
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', fontSize: 12.5, color: 'var(--qb-muted)' }}>
        {has && (
          <span title={deltaLabel} style={{ display: 'inline-flex', alignItems: 'center', gap: 3, padding: '2px 7px', borderRadius: 999, fontWeight: 700,
            color: good ? 'var(--qb-green)' : 'var(--qb-red)', background: good ? 'var(--qb-green-soft)' : 'var(--qb-red-soft)' }}>
            {up ? <ArrowUpRight size={13} strokeWidth={2.6} /> : <ArrowDownRight size={13} strokeWidth={2.6} />}
            {Math.abs(delta as number) >= 1000 ? '999+' : Math.abs(delta as number).toFixed(Math.abs(delta as number) < 10 ? 1 : 0)}%
          </span>
        )}
        {has && deltaLabel && <span>{deltaLabel}</span>}
        {!has && foot && <span>{foot}</span>}
      </div>
      {has && foot && <div style={{ fontSize: 12.5, color: 'var(--qb-muted)', marginTop: -4 }}>{foot}</div>}
    </div>
  )
}

function Mini({ label, value, hint, tone, last }: { label: string; value: string; hint: string; tone?: Tone; last?: boolean }) {
  return (
    <div style={{ padding: '14px 18px', borderRight: last ? 'none' : '1px solid var(--qb-separator)', minWidth: 0 }}>
      <div style={{ color: 'var(--qb-muted)', fontSize: 12.5, fontWeight: 600 }}>{label}</div>
      <div style={{ color: tone ? TONE[tone].fg : 'var(--qb-text)', fontSize: 18, fontWeight: 700, marginTop: 3, fontVariantNumeric: 'tabular-nums' }}>{value}</div>
      <div style={{ color: 'var(--qb-faint)', fontSize: 12, marginTop: 2 }}>{hint}</div>
    </div>
  )
}

function CardHead({ title, sub, children }: { title: string; sub?: string; children?: React.ReactNode }) {
  return (
    <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12, marginBottom: 14, flexWrap: 'wrap' }}>
      <div>
        <div style={{ color: 'var(--qb-text)', fontSize: 15, fontWeight: 700 }}>{title}</div>
        {sub && <div style={{ color: 'var(--qb-muted)', fontSize: 12.5, marginTop: 1 }}>{sub}</div>}
      </div>
      {children && <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>{children}</div>}
    </div>
  )
}

function Legend({ color, label, dashed }: { color: string; label: string; dashed?: boolean }) {
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontSize: 12.5, color: 'var(--qb-sub)', fontWeight: 600 }}>
      <span aria-hidden style={{ width: 16, height: 0, borderTop: `2.5px ${dashed ? 'dashed' : 'solid'} ${color}` }} />
      {label}
    </span>
  )
}

function DayChip({ active, disabled, onClick, top, bottom }: { active: boolean; disabled?: boolean; onClick: () => void; top: string; bottom: string }) {
  return (
    <button disabled={disabled} onClick={onClick} style={{
      display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 1, minWidth: 64, padding: '7px 12px', borderRadius: 10,
      border: `1px solid ${active ? 'var(--qb-accent)' : 'var(--qb-border)'}`, background: active ? 'var(--qb-accent)' : 'var(--qb-card)',
      cursor: disabled ? 'not-allowed' : 'pointer', opacity: disabled ? 0.4 : 1, boxShadow: 'none',
    }}>
      <span style={{ fontSize: 12.5, fontWeight: 650, color: active ? '#fff' : 'var(--qb-text)' }}>{top}</span>
      <span style={{ fontSize: 11.5, fontVariantNumeric: 'tabular-nums', color: active ? 'rgba(255,255,255,0.85)' : 'var(--qb-muted)' }}>{bottom}</span>
    </button>
  )
}

function TopCustomersCard({ title, rows }: { title: string; rows: { name: string; phone: string; count: number; total: number }[] }) {
  const [q, setQ] = useState('')
  const topCount  = rows[0]?.count || 1
  const visible   = q.trim()
    ? rows.filter(c => c.name.toLowerCase().includes(q.toLowerCase()) || c.phone.includes(q))
    : rows

  return (
    <div style={card}>
      <CardHead title={title} sub="Ranked by number of invoices" />
      <div style={{ position: 'relative', marginBottom: 12 }}>
        <Search size={14} aria-hidden style={{ position: 'absolute', left: 11, top: '50%', transform: 'translateY(-50%)', color: 'var(--qb-faint)', pointerEvents: 'none' }} />
        <input value={q} onChange={e => setQ(e.target.value)} placeholder={`Search ${rows.length} customers…`}
          style={{ width: '100%', boxSizing: 'border-box', padding: '9px 30px 9px 32px', borderRadius: 10, background: 'var(--qb-input)', border: '1px solid var(--qb-input-border)', color: 'var(--qb-text)', fontSize: 13.5, outline: 'none' }} />
        {q && (
          <button onClick={() => setQ('')} aria-label="Clear search"
            style={{ position: 'absolute', right: 8, top: '50%', transform: 'translateY(-50%)', background: 'none', border: 'none', color: 'var(--qb-muted)', cursor: 'pointer', fontSize: 16, lineHeight: 1, padding: 0 }}>
            ×
          </button>
        )}
      </div>

      {visible.length === 0 && (
        <div style={{ color: 'var(--qb-muted)', fontSize: 13.5, padding: '8px 0' }}>
          {rows.length === 0 ? 'No invoices in this period.' : `No match for “${q}”`}
        </div>
      )}

      <ol style={{ listStyle: 'none', padding: 0, margin: 0, display: 'flex', flexDirection: 'column', gap: 12, maxHeight: 420, overflowY: 'auto', paddingRight: 4 }}>
        {visible.map((c, i) => {
          const rank = rows.indexOf(c)
          return (
            <li key={c.name + i} style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
              <span style={{ width: 28, height: 28, borderRadius: 8, flexShrink: 0, display: 'grid', placeItems: 'center', fontSize: 12.5, fontWeight: 700, fontVariantNumeric: 'tabular-nums',
                background: rank < 3 ? 'var(--qb-amber-soft)' : 'var(--qb-fill)', color: rank < 3 ? 'var(--qb-amber)' : 'var(--qb-muted)' }}>{rank + 1}</span>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', gap: 10, fontSize: 13.5, alignItems: 'baseline' }}>
                  <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', minWidth: 0 }}>
                    <span style={{ color: 'var(--qb-text)', fontWeight: 650 }}>{c.name}</span>
                    {c.phone && <span style={{ color: 'var(--qb-muted)', fontSize: 12, marginLeft: 8, fontVariantNumeric: 'tabular-nums' }}>{c.phone}</span>}
                  </span>
                  <span style={{ color: 'var(--qb-text)', fontWeight: 650, whiteSpace: 'nowrap', fontVariantNumeric: 'tabular-nums' }}>{GHS(c.total)}</span>
                </div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 5 }}>
                  <div style={{ flex: 1, height: 4, background: 'var(--qb-fill)', borderRadius: 2, overflow: 'hidden' }}>
                    <div style={{ width: `${Math.round((c.count / topCount) * 100)}%`, height: '100%', background: ACC }} />
                  </div>
                  <span style={{ color: 'var(--qb-muted)', fontSize: 11.5, fontVariantNumeric: 'tabular-nums', whiteSpace: 'nowrap' }}>{c.count} {c.count === 1 ? 'invoice' : 'invoices'}</span>
                </div>
              </div>
            </li>
          )
        })}
      </ol>
    </div>
  )
}
