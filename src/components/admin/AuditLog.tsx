'use client'

import { useEffect, useMemo, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { fetchStaffNames, fetchAllRows } from '@/lib/adminCache'

const TEAL = '#0a7cff'

// ─────────────────────────────────────────────────────────────
// AuditLog — read-only view of public.audit_log (see migration
// 20260417_sales_system.sql). Every insert/update/delete on invoices,
// expenses, deliveries, warehouse_stock, and product_codes — and their
// dahua_* counterparts (20260913_dahua_expenses_deliveries_codes.sql) — lands here via
// the shared fn_audit() trigger, so a revenue number that moves without a
// matching action here means the trigger coverage has a gap, not that the
// change didn't happen.
// ─────────────────────────────────────────────────────────────

interface AuditRow {
  id: string
  actor_id: string | null
  actor_role: string | null
  action: 'insert' | 'update' | 'delete' | 'override'
  table_name: string
  row_id: string | null
  diff: Record<string, any> | null
  created_at: string
}

type RangeKey = '24h' | '7d' | '30d' | 'all'
const RANGE_MS: Record<RangeKey, number | null> = {
  '24h': 24 * 3600_000, '7d': 7 * 24 * 3600_000, '30d': 30 * 24 * 3600_000, all: null,
}

const TABLES = [
  'invoices', 'expenses', 'deliveries', 'warehouse_stock', 'product_codes', 'stock_transfers',
  'dahua_invoices', 'dahua_expenses', 'dahua_deliveries', 'dahua_stock', 'dahua_product_codes',
  'dahua_stock_transfers', 'dahua_price_override',
] as const
type Table = typeof TABLES[number]
const TABLE_LABEL: Record<string, string> = {
  invoices: 'Invoices', expenses: 'Expenses', deliveries: 'Deliveries',
  warehouse_stock: 'Stock', product_codes: 'Codes', stock_transfers: 'Transfers',
  dahua_invoices: 'Dahua Invoices', dahua_expenses: 'Dahua Expenses', dahua_deliveries: 'Dahua Deliveries',
  dahua_stock: 'Dahua Stock', dahua_product_codes: 'Dahua Codes',
  dahua_stock_transfers: 'Dahua Transfers', dahua_price_override: 'Dahua Price Overrides',
}
const isDahuaTable = (t: string) => t.startsWith('dahua_')

// Sales-tracked tables — a delete here removes money from the dashboard totals.
const REVENUE_TABLES = new Set(['invoices', 'deliveries', 'dahua_invoices', 'dahua_deliveries'])

function amountOf(diff: Record<string, any> | null): number | null {
  if (!diff) return null
  if (diff.total != null) return Number(diff.total)
  if (diff.amount != null) return Number(diff.amount)
  return null
}

function summaryOf(row: AuditRow): string {
  const d = row.diff || {}
  switch (row.table_name) {
    case 'invoices':
    case 'dahua_invoices':   return `${d.invoice_number || row.row_id} · ${d.customer_name || '—'}`
    case 'expenses':
    case 'dahua_expenses':   return d.description || '—'
    case 'deliveries':
    case 'dahua_deliveries': return `${d.customer_name || 'Delivery'}${d.location ? ' · ' + d.location : ''}`
    case 'warehouse_stock':
    case 'dahua_stock':      return `${d.model || '—'} · ${d.warehouse || ''}`
    case 'product_codes':
    case 'dahua_product_codes': return `${d.material_code || '—'} → ${d.model || '—'}`
    case 'stock_transfers':
    case 'dahua_stock_transfers':
      return `${d.transfer_number || row.row_id} · ${d.from_warehouse || d.supplier || (d.kind === 'return' ? 'Returned' : 'Outside')} → ${d.to_warehouse || '—'}`
    // Written by trg_dahua_log_price_override — a line sold at other than the
    // product's fixed price. The figures are the ones stored on the line, not
    // today's price, so a later repricing does not rewrite history.
    case 'dahua_price_override':
      return `${d.model || '—'} · ${Number(d.list_price).toFixed(2)} → ${Number(d.unit_price).toFixed(2)}`
             + ` (${Number(d.total_effect) > 0 ? '+' : ''}${Number(d.total_effect).toFixed(2)})`
             + ` · ${d.invoice_number || ''}`
    default: return row.row_id || ''
  }
}

const GHS = (n: number) => 'GH₵ ' + n.toLocaleString('en-GH', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

/**
 * `dahua` narrows the log to the Dahua line's tables, for the Dahua portal.
 * The main panel keeps the full log, both lines included.
 */
export default function AuditLog({ darkMode = true, dahua = false }: { darkMode?: boolean; dahua?: boolean }) {
  const tables = dahua ? TABLES.filter(isDahuaTable) : TABLES
  // Colours come from the --qb-* tokens (src/app/qb-ios.css).
  const T = {
    pageBg: 'var(--qb-bg)',
    cardBg: 'var(--qb-card)',
    border: 'var(--qb-border)',
    text:   'var(--qb-text)',
    sub:    'var(--qb-sub)',
    input:  'var(--qb-input)',
  }

  const [rows, setRows]           = useState<AuditRow[]>([])
  const [staffNames, setStaffNames] = useState<Record<string, string>>({})
  const [loading, setLoading]     = useState(true)
  const [error, setError]         = useState<string | null>(null)
  const [range, setRange]         = useState<RangeKey>('24h')
  const [table, setTable]         = useState<'all' | Table>('all')
  const [action, setAction]       = useState<'all' | 'insert' | 'update' | 'delete' | 'override'>('all')

  useEffect(() => {
    let cancelled = false
    ;(async () => {
      setLoading(true); setError(null)
      try {
        // Filter by range server-side before paginating — audit_log has grown
        // past PostgREST's 1000-row response cap, so "all time" with no date
        // filter would silently come back truncated to the newest 1000 rows.
        const ms = RANGE_MS[range]
        const cutoff = ms ? new Date(Date.now() - ms).toISOString() : null
        const [data, names] = await Promise.all([
          fetchAllRows<AuditRow>((from, to) => {
            let q = supabase.from('audit_log').select('*').order('id', { ascending: true }).range(from, to)
            if (cutoff) q = q.gte('created_at', cutoff)
            if (dahua) q = q.like('table_name', 'dahua\\_%')
            return q
          }),
          fetchStaffNames(),
        ])
        if (cancelled) return
        setRows(data.sort((a, b) => +new Date(b.created_at) - +new Date(a.created_at)))
        setStaffNames(names)
      } catch (e: any) {
        if (!cancelled) setError(e.message || 'Failed to load audit log')
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()
    return () => { cancelled = true }
  }, [range, dahua])

  const filtered = useMemo(() => {
    const ms = RANGE_MS[range]
    const cutoff = ms ? Date.now() - ms : null
    return rows.filter(r => {
      if (cutoff && new Date(r.created_at).getTime() < cutoff) return false
      if (table !== 'all' && r.table_name !== table) return false
      if (action !== 'all' && r.action !== action) return false
      return true
    })
  }, [rows, range, table, action])

  const revenueDeleted = useMemo(() => {
    return filtered
      .filter(r => r.action === 'delete' && REVENUE_TABLES.has(r.table_name))
      .reduce((s, r) => s + (amountOf(r.diff) || 0), 0)
  }, [filtered])

  const CAP = 200 // avoid rendering hundreds of rows — narrow the range/table/action instead
  const shown = filtered.slice(0, CAP)
  const hiddenCount = filtered.length - shown.length

  const label: React.CSSProperties = { fontSize: 10, fontWeight: 800, color: TEAL, letterSpacing: '0.16em', textTransform: 'uppercase', display: 'block', marginBottom: 5 }
  const field: React.CSSProperties = { padding: '9px 12px', borderRadius: 9, border: `1px solid ${T.border}`, background: T.input, color: T.text, fontSize: 13, outline: 'none', width: '100%', boxSizing: 'border-box' }

  if (loading) return <div style={{ padding: 48, textAlign: 'center', color: T.sub }}>Loading activity log…</div>
  if (error) return <div style={{ padding: 48, textAlign: 'center', color: '#ef4444' }}>{error}</div>

  return (
    <div style={{ color: T.text }}>
      <h2 style={{ fontSize: 17, fontWeight: 900, letterSpacing: '0.04em', margin: '0 0 12px' }}>
        Activity Log <span style={{ color: T.sub, fontWeight: 500, fontSize: 12, marginLeft: 8 }}>{dahua
          ? 'every insert/update/delete on Dahua invoices, stock, expenses, deliveries, codes and transfers, and every price override'
          : 'every insert/update/delete on money-moving tables, and every Dahua price override'}</span>
      </h2>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))', gap: 12, marginBottom: 14, background: T.cardBg, border: `1px solid ${T.border}`, borderRadius: 12, padding: 14 }}>
        <div>
          <label style={label}>Time range</label>
          <select style={field} value={range} onChange={e => setRange(e.target.value as RangeKey)}>
            <option value="24h">Last 24 hours</option>
            <option value="7d">Last 7 days</option>
            <option value="30d">Last 30 days</option>
            <option value="all">All time</option>
          </select>
        </div>
        <div>
          <label style={label}>Table</label>
          <select style={field} value={table} onChange={e => setTable(e.target.value as any)}>
            <option value="all">All tables</option>
            {tables.map(t => <option key={t} value={t}>{TABLE_LABEL[t]}</option>)}
          </select>
        </div>
        <div>
          <label style={label}>Action</label>
          <select style={field} value={action} onChange={e => setAction(e.target.value as any)}>
            <option value="all">All actions</option>
            <option value="insert">Insert</option>
            <option value="update">Update</option>
            <option value="delete">Delete</option>
            <option value="override">Price override</option>
          </select>
        </div>
      </div>

      {revenueDeleted > 0 && (
        <div style={{ marginBottom: 14, padding: '12px 16px', borderRadius: 10, background: 'rgba(239,68,68,0.1)', border: '1px solid rgba(239,68,68,0.35)', color: '#ef4444', fontSize: 13, fontWeight: 700 }}>
          ⚠ {GHS(revenueDeleted)} of invoices/deliveries were deleted in this window
        </div>
      )}

      <div style={{ background: T.cardBg, border: `1px solid ${T.border}`, borderRadius: 12, overflow: 'hidden' }}>
        <div style={{ padding: '11px 16px', borderBottom: `1px solid ${T.border}`, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <span style={{ fontWeight: 800, fontSize: 12, letterSpacing: '0.1em', color: T.sub }}>{filtered.length} EVENT(S)</span>
        </div>
        {filtered.length === 0
          ? <div style={{ padding: 40, textAlign: 'center', color: T.sub, fontSize: 13 }}>No activity in this window.</div>
          : shown.map(r => {
            const amt = amountOf(r.diff)
            const isRevenueDelete = r.action === 'delete' && REVENUE_TABLES.has(r.table_name)
            const actionColor = r.action === 'delete' ? '#ef4444' : r.action === 'override' ? '#f5b400' : r.action === 'update' ? '#f59e0b' : TEAL
            return (
              <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '11px 18px', borderBottom: `1px solid ${T.border}`, gap: 12 }}>
                <div style={{ minWidth: 0, display: 'flex', flexDirection: 'column', gap: 2 }}>
                  <div>
                    <span style={{ padding: '2px 8px', borderRadius: 6, fontSize: 10, fontWeight: 800, background: `${actionColor}18`, color: actionColor, border: `1px solid ${actionColor}30`, marginRight: 8 }}>
                      {r.action.toUpperCase()}
                    </span>
                    <span style={{ fontSize: 11, color: T.sub, fontWeight: 700 }}>{TABLE_LABEL[r.table_name] || r.table_name}</span>
                  </div>
                  <span style={{ fontSize: 13, color: T.text, fontVariantNumeric: 'tabular-nums' }}>{summaryOf(r)}</span>
                  <span style={{ fontSize: 11, color: T.sub }}>
                    {new Date(r.created_at).toLocaleString('en-GB')} · {r.actor_id ? (staffNames[r.actor_id] || 'unknown staff') : 'system'}
                  </span>
                </div>
                {amt != null && (
                  <span style={{ fontVariantNumeric: 'tabular-nums', fontWeight: 800, fontSize: 13, color: isRevenueDelete ? '#ef4444' : T.sub, whiteSpace: 'nowrap' }}>
                    {isRevenueDelete ? '−' : ''}{GHS(amt)}
                  </span>
                )}
              </div>
            )
          })}
        {hiddenCount > 0 && (
          <div style={{ padding: '12px 16px', textAlign: 'center', color: T.sub, fontSize: 12, borderTop: `1px solid ${T.border}` }}>
            +{hiddenCount} more — narrow the range, table, or action to see them.
          </div>
        )}
      </div>
    </div>
  )
}
