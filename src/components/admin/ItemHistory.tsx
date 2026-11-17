'use client'

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { GHS } from '@/lib/sales'

/**
 * Item history — "who bought 2TB drives, how many, and when".
 *
 * Searches the description on every invoice line rather than the tracked
 * stock models, so it also finds items sold before they were ever put in a
 * warehouse and lines a cashier typed by hand. That is the whole point: the
 * question is what actually went out of the door.
 *
 * Boss sees every sale; a cashier sees their own. That is not enforced here —
 * `inv_read` in 20260417_sales_system.sql decides it, and this just renders
 * whatever comes back.
 */

const TEAL = '#0a7cff'
const AMBER = '#f59e0b'

interface Theme {
  card: string; border: string; text: string; sub: string; muted: string
  input: string; inputBorder: string; headerBg: string; rowHover: string
}
// Colours come from the --qb-* tokens (src/app/qb-ios.css): <html data-qb-theme>
// picks light or dark, so both palettes point at the same values.
const DARK: Theme = {
  card: 'var(--qb-card)', border: 'var(--qb-border)', text: 'var(--qb-text)', sub: 'var(--qb-sub)',
  muted: 'var(--qb-muted)', input: 'var(--qb-input)', inputBorder: 'var(--qb-input-border)',
  headerBg: 'var(--qb-header)', rowHover: 'var(--qb-row-hover)',
}
const LIGHT: Theme = DARK

/** One invoice line, flattened with the details of the invoice it sat on. */
interface Sale {
  description: string
  quantity: number
  unit_price: number
  line_total: number
  invoice_number: string
  customer_name: string
  customer_loc: string | null
  issued_at: string
}

interface InvoiceHead {
  invoice_number: string
  customer_name: string
  customer_loc: string | null
  issued_at: string
}

/**
 * The row shape PostgREST returns for the embedded-invoice select below. The
 * embedded invoice sits under its table's name, `invoices`.
 */
type SaleRow = {
  description: string
  quantity: number
  unit_price: number
  line_total: number
} & Record<string, unknown>

/** PostgREST caps a single request at 1000 rows and truncates silently. */
const PAGE = 1000
/** Ceiling on one search, so a loose term cannot drag down the whole table. */
const CAP = 5000

type Period = 'day' | 'week' | 'month' | 'year' | 'all'

const PERIODS: { key: Period; label: string }[] = [
  { key: 'day',   label: 'Today' },
  { key: 'week',  label: 'This week' },
  { key: 'month', label: 'This month' },
  { key: 'year',  label: 'This year' },
  { key: 'all',   label: 'All time' },
]

type Grain = 'day' | 'week' | 'month' | 'year'
const GRAINS: { key: Grain; label: string }[] = [
  { key: 'day',   label: 'Day' },
  { key: 'week',  label: 'Week' },
  { key: 'month', label: 'Month' },
  { key: 'year',  label: 'Year' },
]

/** Local midnight at the start of the chosen period. null means no lower bound. */
function periodStart(p: Period): Date | null {
  const d = new Date()
  d.setHours(0, 0, 0, 0)
  if (p === 'day')  return d
  if (p === 'week') {
    // Monday-first, matching how the shop talks about a week.
    const dow = (d.getDay() + 6) % 7
    d.setDate(d.getDate() - dow)
    return d
  }
  if (p === 'month') { d.setDate(1); return d }
  if (p === 'year')  { d.setMonth(0, 1); return d }
  return null
}

/** The bucket a sale falls in, as a sortable key plus how to show it. */
function bucketOf(iso: string, grain: Grain): { key: string; label: string } {
  const d = new Date(iso)
  const y = d.getFullYear()
  if (grain === 'year') return { key: String(y), label: String(y) }
  if (grain === 'month') {
    const m = String(d.getMonth() + 1).padStart(2, '0')
    return { key: `${y}-${m}`, label: d.toLocaleDateString('en-GB', { month: 'long', year: 'numeric' }) }
  }
  if (grain === 'week') {
    const s = new Date(d)
    s.setHours(0, 0, 0, 0)
    s.setDate(s.getDate() - ((s.getDay() + 6) % 7))
    const e = new Date(s); e.setDate(e.getDate() + 6)
    const fmt = (x: Date) => x.toLocaleDateString('en-GB', { day: '2-digit', month: 'short' })
    return { key: s.toISOString().slice(0, 10), label: `${fmt(s)} – ${fmt(e)} ${e.getFullYear()}` }
  }
  const key = `${y}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
  return { key, label: d.toLocaleDateString('en-GB', { weekday: 'short', day: '2-digit', month: 'short', year: 'numeric' }) }
}

export default function ItemHistory({ dark, accent }: { dark: boolean; accent?: string }) {
  const T = dark ? DARK : LIGHT
  const A = accent ?? TEAL
  const itemTable = 'invoice_items'
  const invTable  = 'invoices'

  const [query, setQuery]     = useState('')
  const [period, setPeriod]   = useState<Period>('all')
  const [grain, setGrain]     = useState<Grain>('month')
  const [sales, setSales]     = useState<Sale[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError]     = useState<string | null>(null)
  /** The term the results on screen belong to, so the summary can't lie. */
  const [searched, setSearched] = useState('')
  const [openBucket, setOpenBucket] = useState<string | null>(null)
  /** True when the search hit CAP and the figures below are a partial count. */
  const [capped, setCapped] = useState(false)

  // Every keystroke would otherwise be a full-table ILIKE.
  const debounce = useRef<ReturnType<typeof setTimeout> | null>(null)

  const run = useCallback(async (term: string, p: Period) => {
    const q = term.trim()
    if (q.length < 2) { setSales([]); setSearched(''); setError(null); return }

    setLoading(true)
    setError(null)
    try {
      const since = periodStart(p)

      // Paged by hand rather than through fetchAllRows so the sweep can be
      // capped. A two-letter term like "ca" matches every camera ever sold,
      // and pulling the entire line-item table into the browser to count it is
      // not worth it — CAP rows is far more than anyone reads, and hitting it
      // is reported rather than silently truncating the totals.
      const rows: SaleRow[] = []
      let capped = false
      for (let from = 0; ; from += PAGE) {
        // !inner is what lets the date filter apply to the embedded invoice —
        // with a left join PostgREST would not filter on it at all.
        let sel = supabase.from(itemTable)
          .select(`description,quantity,unit_price,line_total,${invTable}!inner(invoice_number,customer_name,customer_loc,issued_at)`)
          .ilike('description', `%${q}%`)
        if (since) sel = sel.gte(`${invTable}.issued_at`, since.toISOString())
        // Ordered by a stable unique column: without one, LIMIT/OFFSET can
        // skip or repeat rows across page boundaries.
        const { data, error: err } = await sel.order('id', { ascending: true }).range(from, from + PAGE - 1)
        if (err) throw new Error(err.message)
        rows.push(...((data as unknown as SaleRow[]) || []))
        if (!data || data.length < PAGE) break
        if (rows.length >= CAP) { capped = true; break }
      }

      const flat: Sale[] = rows
        .filter(r => r[invTable])
        .map(r => {
          const inv = r[invTable] as InvoiceHead
          return {
            description: r.description,
            quantity:    Number(r.quantity) || 0,
            unit_price:  Number(r.unit_price) || 0,
            line_total:  Number(r.line_total) || 0,
            invoice_number: inv.invoice_number,
            customer_name:  inv.customer_name,
            customer_loc:   inv.customer_loc,
            issued_at:      inv.issued_at,
          }
        })
        .sort((a, b) => +new Date(b.issued_at) - +new Date(a.issued_at))

      setSales(flat)
      setSearched(q)
      setCapped(capped)
    } catch (e: any) {
      setError(e.message || 'Search failed')
      setSales([])
    } finally {
      setLoading(false)
    }
  }, [itemTable, invTable])

  useEffect(() => {
    if (debounce.current) clearTimeout(debounce.current)
    debounce.current = setTimeout(() => run(query, period), 350)
    return () => { if (debounce.current) clearTimeout(debounce.current) }
  }, [query, period, run])

  // ── Totals ───────────────────────────────────────────────
  const totals = useMemo(() => ({
    units:     sales.reduce((s, x) => s + x.quantity, 0),
    revenue:   sales.reduce((s, x) => s + x.line_total, 0),
    invoices:  new Set(sales.map(s => s.invoice_number)).size,
    customers: new Set(sales.map(s => s.customer_name.trim().toLowerCase())).size,
  }), [sales])

  /** Distinct descriptions behind the results — "2tb" can match several models. */
  const variants = useMemo(() => {
    const m = new Map<string, number>()
    for (const s of sales) m.set(s.description, (m.get(s.description) || 0) + s.quantity)
    return Array.from(m.entries()).sort((a, b) => b[1] - a[1])
  }, [sales])

  const buckets = useMemo(() => {
    const m = new Map<string, { label: string; units: number; revenue: number; sales: Sale[] }>()
    for (const s of sales) {
      const { key, label } = bucketOf(s.issued_at, grain)
      const b = m.get(key) || { label, units: 0, revenue: 0, sales: [] }
      b.units += s.quantity
      b.revenue += s.line_total
      b.sales.push(s)
      m.set(key, b)
    }
    return Array.from(m.entries()).sort((a, b) => (a[0] < b[0] ? 1 : -1))
  }, [sales, grain])

  // ── Styles ───────────────────────────────────────────────
  const th: React.CSSProperties = {
    padding: '9px 10px', textAlign: 'left', fontSize: 10, fontWeight: 800,
    letterSpacing: '0.12em', color: T.sub, borderBottom: `1px solid ${T.border}`,
    whiteSpace: 'nowrap',
  }
  const td: React.CSSProperties = { padding: '9px 10px', fontSize: 13, color: T.text }
  const pill = (active: boolean): React.CSSProperties => ({
    padding: '7px 13px', borderRadius: 8, cursor: 'pointer', fontSize: 12, fontWeight: 700,
    border: `1px solid ${active ? `${A}59` : T.inputBorder}`,
    background: active ? `${A}26` : 'transparent',
    color: active ? A : T.sub,
  })

  return (
    <div style={{ maxWidth: 1000 }}>

      {/* ── Search ──────────────────────────────────────────── */}
      <div style={{ padding: 18, borderRadius: 12, background: T.card, border: `1px solid ${T.border}`, marginBottom: 18 }}>
        <div style={{ fontWeight: 900, fontSize: 17, color: T.text, marginBottom: 4 }}>Item history</div>
        <div style={{ fontSize: 12, color: T.sub, marginBottom: 14 }}>
          <>Search any part of an item — &ldquo;2tb&rdquo;, &ldquo;DS-7208&rdquo;, &ldquo;junction box&rdquo; — to see how many went out, when, and to whom.</>
        </div>

        <input
          value={query}
          onChange={e => setQuery(e.target.value)}
          placeholder="Search an item…"
          autoComplete="off"
          style={{
            width: '100%', padding: '11px 14px', borderRadius: 9, fontSize: 15, outline: 'none',
            border: `1px solid ${T.inputBorder}`, background: T.input, color: T.text, marginBottom: 12,
          }} />

        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {PERIODS.map(p => (
            <button key={p.key} onClick={() => setPeriod(p.key)} style={pill(period === p.key)}>{p.label}</button>
          ))}
        </div>
      </div>

      {loading && <div style={{ color: T.sub, fontSize: 13, padding: '0 2px 14px' }}>Searching…</div>}
      {error && <div style={{ color: '#ef4444', fontSize: 13, padding: '0 2px 14px' }}>{error}</div>}

      {!loading && !error && query.trim().length >= 2 && sales.length === 0 && searched && (
        <div style={{ padding: 18, borderRadius: 12, background: T.card, border: `1px solid ${T.border}`, color: T.sub, fontSize: 13 }}>
          Nothing matching <strong style={{ color: T.text }}>{searched}</strong> was sold in this period.
        </div>
      )}

      {sales.length > 0 && (
        <>
          {/* ── Totals ──────────────────────────────────────── */}
          <div style={{
            display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(150px,1fr))', gap: 12,
            padding: 16, borderRadius: 12, background: T.card, border: `1px solid ${T.border}`, marginBottom: 14,
          }}>
            {[
              { label: 'Units sold', value: totals.units.toLocaleString(), color: A },
              { label: 'Revenue',    value: GHS(totals.revenue),           color: T.text },
              { label: 'Invoices',   value: totals.invoices.toLocaleString(),  color: T.text },
              { label: 'Customers',  value: totals.customers.toLocaleString(), color: T.text },
            ].map(s => (
              <div key={s.label}>
                <div style={{ fontSize: 10, color: T.sub, letterSpacing: '0.12em', fontWeight: 800, marginBottom: 4 }}>{s.label.toUpperCase()}</div>
                <div style={{ fontSize: 22, fontWeight: 900, color: s.color, fontVariantNumeric: 'tabular-nums' }}>{s.value}</div>
              </div>
            ))}
          </div>

          {capped && (
            <div style={{ padding: '10px 14px', borderRadius: 10, marginBottom: 14, fontSize: 12.5,
              background: `${AMBER}14`, border: `1px solid ${AMBER}40`, color: AMBER }}>
              Showing the first {CAP.toLocaleString()} matching sales — the totals above cover only those.
              Narrow the search or pick a shorter period for an exact figure.
            </div>
          )}

          {/* A loose search term matches several models — say which. */}
          {variants.length > 1 && (
            <div style={{ padding: '12px 16px', borderRadius: 12, background: T.card, border: `1px solid ${T.border}`, marginBottom: 14 }}>
              <div style={{ fontSize: 10, color: T.sub, letterSpacing: '0.12em', fontWeight: 800, marginBottom: 8 }}>
                {variants.length} ITEMS MATCHED
              </div>
              <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                {variants.map(([desc, qty]) => (
                  <span key={desc} style={{
                    padding: '4px 10px', borderRadius: 7, fontSize: 12,
                    background: T.headerBg, color: T.text, border: `1px solid ${T.border}`,
                  }}>
                    {desc} <span style={{ color: A, fontWeight: 800, fontVariantNumeric: 'tabular-nums' }}>×{qty.toLocaleString()}</span>
                  </span>
                ))}
              </div>
            </div>
          )}

          {/* ── Per-period breakdown ────────────────────────── */}
          <div style={{ padding: 16, borderRadius: 12, background: T.card, border: `1px solid ${T.border}`, marginBottom: 14 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap', marginBottom: 12 }}>
              <div style={{ fontWeight: 800, fontSize: 13, color: T.text }}>Broken down by</div>
              {GRAINS.map(g => (
                <button key={g.key} onClick={() => { setGrain(g.key); setOpenBucket(null) }} style={pill(grain === g.key)}>{g.label}</button>
              ))}
            </div>
            <div style={{ overflowX: 'auto' }}>
              <table style={{ width: '100%', borderCollapse: 'collapse' }}>
                <thead><tr>
                  <th style={th}>PERIOD</th>
                  <th style={{ ...th, textAlign: 'right' }}>UNITS</th>
                  <th style={{ ...th, textAlign: 'right' }}>REVENUE</th>
                  <th style={{ ...th, textAlign: 'right' }}>CUSTOMERS</th>
                </tr></thead>
                <tbody>
                  {buckets.map(([key, b]) => {
                    const open = openBucket === key
                    const names = Array.from(new Set(b.sales.map(x => x.customer_name.trim())))
                    return (
                      <tr key={key} onClick={() => setOpenBucket(open ? null : key)}
                        style={{ cursor: 'pointer', borderBottom: `1px solid ${T.border}`, background: open ? T.headerBg : 'transparent' }}>
                        <td style={td}>
                          {b.label}
                          {open && (
                            <div style={{ marginTop: 8, fontSize: 12, color: T.sub, lineHeight: 1.7 }}>
                              {names.join(' · ')}
                            </div>
                          )}
                        </td>
                        <td style={{ ...td, textAlign: 'right', fontVariantNumeric: 'tabular-nums', fontWeight: 800, color: A }}>{b.units.toLocaleString()}</td>
                        <td style={{ ...td, textAlign: 'right', fontVariantNumeric: 'tabular-nums' }}>{GHS(b.revenue)}</td>
                        <td style={{ ...td, textAlign: 'right', fontVariantNumeric: 'tabular-nums', color: T.sub }}>{names.length}</td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          </div>

          {/* ── Every sale ──────────────────────────────────── */}
          <div style={{ padding: 16, borderRadius: 12, background: T.card, border: `1px solid ${T.border}` }}>
            <div style={{ fontWeight: 800, fontSize: 13, color: T.text, marginBottom: 12 }}>
              {sales.length.toLocaleString()} sale{sales.length === 1 ? '' : 's'}, newest first
            </div>
            <div style={{ overflowX: 'auto' }}>
              <table style={{ width: '100%', borderCollapse: 'collapse' }}>
                <thead><tr>
                  <th style={th}>DATE</th>
                  <th style={th}>CUSTOMER</th>
                  <th style={th}>ITEM</th>
                  <th style={{ ...th, textAlign: 'right' }}>QTY</th>
                  <th style={{ ...th, textAlign: 'right' }}>UNIT</th>
                  <th style={{ ...th, textAlign: 'right' }}>TOTAL</th>
                  <th style={th}>INVOICE</th>
                </tr></thead>
                <tbody>
                  {sales.map((s, i) => (
                    <tr key={`${s.invoice_number}-${i}`} style={{ borderBottom: `1px solid ${T.border}` }}>
                      <td style={{ ...td, color: T.sub, whiteSpace: 'nowrap' }}>
                        {new Date(s.issued_at).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })}
                      </td>
                      <td style={{ ...td, fontWeight: 700 }}>
                        {s.customer_name}
                        {s.customer_loc && <div style={{ fontSize: 11, color: T.muted, fontWeight: 400 }}>{s.customer_loc}</div>}
                      </td>
                      <td style={{ ...td, color: T.sub, fontSize: 12 }}>{s.description}</td>
                      <td style={{ ...td, textAlign: 'right', fontVariantNumeric: 'tabular-nums', fontWeight: 800, color: A }}>{s.quantity.toLocaleString()}</td>
                      <td style={{ ...td, textAlign: 'right', fontVariantNumeric: 'tabular-nums', color: T.sub }}>{s.unit_price.toFixed(2)}</td>
                      <td style={{ ...td, textAlign: 'right', fontVariantNumeric: 'tabular-nums', fontWeight: 700 }}>{s.line_total.toFixed(2)}</td>
                      <td style={{ ...td, fontVariantNumeric: 'tabular-nums', fontSize: 11, color: AMBER, whiteSpace: 'nowrap' }}>{s.invoice_number}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </>
      )}
    </div>
  )
}
