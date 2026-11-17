'use client'

import { useEffect, useState } from 'react'
import ListPager, { usePaged } from '@/components/admin/ListPager'
import { supabase } from '@/lib/supabase'
import { GHS, withinWindow } from '@/lib/sales'
import { DELIVERY_LOGGED } from '@/components/admin/InvoiceDelivery'
import { fetchDeliveries, invalidate, peek, scopedKey, type DelRow } from '@/lib/adminCache'

const DEFAULT_ACCENT = '#0a7cff'
const PAYMENT_METHODS = ['Cash', 'Mobile Money'] as const

/**
 * `dahua` switches the tab onto public.dahua_deliveries. Same form, same
 * 8-hour staff window, same RLS — only the table (and so the dashboard the
 * amounts roll into) changes.
 */
/** Windowed viewers see the last 24 hours only (RLS enforces it; this keeps a warm cache in step). */
const clampRows = (rs: DelRow[], windowed: boolean) => windowed ? rs.filter(r => withinWindow(r.delivered_at)) : rs

export default function Deliveries({ isBoss, userId, windowed = false, accent = DEFAULT_ACCENT }: { isBoss: boolean; userId: string | null; windowed?: boolean; accent?: string }) {
  const table   = 'deliveries'
  // Windowed viewers see the last 24 hours only. RLS enforces this server-side;
  // the same clamp here keeps a warm cache from showing anything older.
  const clamp = (rs: DelRow[]) => clampRows(rs, windowed)
  const warmRows = peek<DelRow[]>(scopedKey('deliveries'))
  const [rows, setRows]       = useState<DelRow[]>(clamp(warmRows || []))
  const [loading, setLoading] = useState(warmRows === undefined)

  const [customer, setCustomer]     = useState('')
  const [location, setLocation]     = useState('')
  const [amount, setAmount]         = useState('')
  const [method, setMethod]         = useState<string>('Cash')
  const [deliveredAt, setDeliveredAt] = useState(() => new Date().toISOString().slice(0, 10))
  const [saving, setSaving]         = useState(false)
  const [search, setSearch]         = useState('')

  useEffect(() => {
    let cancelled = false
    ;(async () => {
      try {
        const data = await fetchDeliveries()
        if (!cancelled) setRows(clampRows(data, windowed))
      } catch (err) {
        if (!cancelled) console.warn('Deliveries load failed:', err)
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()
    return () => { cancelled = true }
  }, [windowed])

  // A delivery switched on from an invoice is saved by the invoice form. This
  // tab stays mounted once it has been opened, so it is told to load again.
  useEffect(() => {
    const onLogged = (e: Event) => {
      if ((e as CustomEvent).detail !== table) return
      fetchDeliveries().then(data => setRows(clampRows(data, windowed))).catch(() => { /* shown on next open */ })
    }
    window.addEventListener(DELIVERY_LOGGED, onLogged)
    return () => window.removeEventListener(DELIVERY_LOGGED, onLogged)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [table, windowed])

  async function save(e: React.FormEvent) {
    e.preventDefault()
    if (!customer.trim()) return alert('Customer name is required')
    const amt = parseFloat(amount)
    if (!amt || amt <= 0) return alert('Enter a valid amount')
    setSaving(true)
    try {
      const { data: inserted, error } = await supabase.from(table).insert({
        customer_name: customer.trim(),
        location: location.trim() || null,
        amount: amt,
        payment_method: method,
        delivered_at: new Date(deliveredAt + 'T12:00:00').toISOString(),
        created_by: userId,
      }).select().single()
      if (error) throw error
      setCustomer(''); setLocation(''); setAmount(''); setMethod('Cash')
      setRows(prev => [inserted as DelRow, ...prev])
      invalidate(table)
    } catch (err: any) {
      alert(err.message || 'Failed to save delivery')
    } finally { setSaving(false) }
  }

  async function remove(r: DelRow) {
    if (!confirm(`Delete delivery for "${r.customer_name || '—'}" (${GHS(Number(r.amount))})?`)) return
    const prev = rows
    setRows(rs => rs.filter(x => x.id !== r.id))   // optimistic
    const { error } = await supabase.from(table).delete().eq('id', r.id)
    if (error) {
      setRows(prev)                                // roll back on failure
      alert(error.message || 'Failed to delete delivery')
      return
    }
    invalidate(table)
  }

  const fld: React.CSSProperties = {
    width: '100%', boxSizing: 'border-box', padding: '9px 12px', borderRadius: 8, fontSize: 14, outline: 'none',
    border: '1px solid var(--qb-input-border)', background: 'var(--qb-input)', color: 'var(--qb-text)',
  }
  const lbl: React.CSSProperties = { fontSize: 10, fontWeight: 800, color: accent, letterSpacing: '0.18em', textTransform: 'uppercase', display: 'block', marginBottom: 5 }

  // Staff only see deliveries logged in the last 8 hours; the boss sees all.
  const EIGHT_HOURS = 8 * 60 * 60 * 1000
  const visibleRows = isBoss
    ? rows
    : rows.filter(r => Date.now() - new Date(r.delivered_at).getTime() < EIGHT_HOURS)
  const total = visibleRows.reduce((s, r) => s + Number(r.amount), 0)

  const searched = search.trim()
    ? visibleRows.filter(r => `${r.customer_name || ''} ${r.location || ''} ${r.customer_num || ''} ${r.invoice_number || ''} ${r.note || ''}`.toLowerCase().includes(search.trim().toLowerCase()))
    : visibleRows
  // Paged, so the list never turns into an endless scroll.
  const pager = usePaged(searched, search)
  const shownRows = pager.shown

  return (
    <div style={{ maxWidth: 980, display: 'flex', flexDirection: 'column', gap: 18 }}>

      {/* Header */}
      <div style={{
        display: 'flex', justifyContent: 'space-between', alignItems: 'center',
        padding: 14, borderRadius: 12,
        background: 'linear-gradient(135deg, var(--qb-header), var(--qb-card))',
        border: '1px solid rgba(10,124,255,0.2)',
      }}>
        <div>
          <div style={{ color: accent, fontSize: 11, fontWeight: 800, letterSpacing: '0.2em' }}>🚚 DELIVERIES</div>
          <div style={{ color: 'var(--qb-sub)', fontSize: 12, fontVariantNumeric: 'tabular-nums', marginTop: 2 }}>
            {isBoss ? `All staff deliveries · counts toward Total Sales` : 'Your entries hide after 8 hours'}
            {' · '}deliveries switched on from an invoice appear here by themselves
          </div>
        </div>
      </div>

      {/* Add delivery form */}
      <form onSubmit={save} style={{
        padding: 18, borderRadius: 14,
        border: '1px solid var(--qb-border)', background: 'var(--qb-card)',
        display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(180px,1fr))', gap: 12,
      }}>
        <div style={{ gridColumn: 'span 2' }}>
          <label style={lbl}>Customer Name *</label>
          <input style={fld} value={customer} onChange={e => setCustomer(e.target.value)} placeholder="e.g. Kwame Mensah" />
        </div>
        <div>
          <label style={lbl}>Location</label>
          <input style={fld} value={location} onChange={e => setLocation(e.target.value)} placeholder="e.g. Tema" />
        </div>
        <div>
          <label style={lbl}>Amount (GH₵) *</label>
          <input type="number" step="0.01" min="0" style={fld} value={amount} onChange={e => setAmount(e.target.value)} placeholder="0.00" />
        </div>
        <div>
          <label style={lbl}>Payment</label>
          <select style={fld} value={method} onChange={e => setMethod(e.target.value)}>
            {PAYMENT_METHODS.map(m => <option key={m} value={m}>{m}</option>)}
          </select>
        </div>
        <div>
          <label style={lbl}>Date</label>
          <input type="date" style={fld} value={deliveredAt} onChange={e => setDeliveredAt(e.target.value)} />
        </div>
        <div style={{ gridColumn: '1 / -1' }}>
          <button type="submit" disabled={saving} style={{
            width: '100%', padding: 13, borderRadius: 10,
            background: saving ? 'var(--qb-fill)' : accent,
            color: saving ? 'var(--qb-muted)' : '#ffffff',
            fontWeight: 900, fontSize: 13, letterSpacing: '0.12em',
            border: 'none', cursor: saving ? 'not-allowed' : 'pointer',
          }}>
            {saving ? 'SAVING…' : '+ ADD DELIVERY'}
          </button>
        </div>
      </form>

      {/* Total */}
      <div style={{
        padding: 14, borderRadius: 12,
        border: '1px solid var(--qb-border)', background: 'var(--qb-card)',
        display: 'flex', justifyContent: 'space-between', alignItems: 'center',
      }}>
        <div style={{ color: 'var(--qb-sub)', fontSize: 11, fontWeight: 800, letterSpacing: '0.18em' }}>TOTAL ({visibleRows.length})</div>
        <div style={{ color: 'var(--qb-text)', fontSize: 20, fontWeight: 900, fontVariantNumeric: 'tabular-nums' }}>{GHS(total)}</div>
      </div>

      {/* List */}
      <input value={search} onChange={e => setSearch(e.target.value)} placeholder="Search customer, number, location or invoice…"
        style={{ width: '100%', maxWidth: 420, padding: '9px 12px', borderRadius: 8, fontSize: 13, outline: 'none', border: '1px solid var(--qb-input-border)', background: 'var(--qb-input)', color: 'var(--qb-text)' }} />
      <div style={{
        borderRadius: 14, border: '1px solid var(--qb-border)',
        background: 'var(--qb-card)', overflow: 'hidden',
      }}>
        <div style={{
          display: 'grid', gridTemplateColumns: isBoss ? '100px 1fr 120px 110px 120px 40px' : '100px 1fr 120px 110px 120px',
          padding: '10px 14px', background: 'var(--qb-header)',
          color: accent, fontSize: 10, fontWeight: 800, letterSpacing: '0.15em',
        }}>
          <div>DATE</div><div>CUSTOMER</div><div>LOCATION</div><div>PAYMENT</div><div style={{ textAlign: 'right' }}>AMOUNT</div>{isBoss && <div />}
        </div>
        {loading && <div style={{ padding: 30, textAlign: 'center', color: 'var(--qb-muted)', fontVariantNumeric: 'tabular-nums' }}>Loading…</div>}
        {!loading && searched.length === 0 && <div style={{ padding: 30, textAlign: 'center', color: 'var(--qb-muted)', fontVariantNumeric: 'tabular-nums' }}>{isBoss ? 'No deliveries yet.' : 'No deliveries in the last 8 hours.'}</div>}
        {shownRows.map(r => (
          <div key={r.id} style={{
            display: 'grid', gridTemplateColumns: isBoss ? '100px 1fr 120px 110px 120px 40px' : '100px 1fr 120px 110px 120px',
            padding: '10px 14px', borderTop: '1px solid var(--qb-separator)',
            fontSize: 13, color: 'var(--qb-text)', alignItems: 'center',
          }}>
            <div style={{ fontVariantNumeric: 'tabular-nums', fontSize: 12, color: 'var(--qb-sub)' }}>
              {new Date(r.delivered_at).toLocaleDateString('en-GB')}
            </div>
            <div style={{ minWidth: 0 }}>
              <div style={{ color: 'var(--qb-text)', fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {r.customer_name || '—'}
              </div>
              {/* A delivery logged from an invoice carries the customer's
                  number and the invoice it belongs to. */}
              {(r.customer_num || r.invoice_number || r.note) && (
                <div style={{ color: 'var(--qb-muted)', fontSize: 11, fontVariantNumeric: 'tabular-nums', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {[r.customer_num, r.invoice_number, !r.invoice_number && r.note].filter(Boolean).join(' · ')}
                </div>
              )}
            </div>
            <div style={{ color: 'var(--qb-sub)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {r.location || '—'}
            </div>
            <div style={{ color: r.payment_method === 'Mobile Money' ? '#a78bfa' : accent, fontSize: 12, fontWeight: 700 }}>
              {r.payment_method || 'Cash'}
            </div>
            <div style={{ textAlign: 'right', color: 'var(--qb-text)', fontWeight: 700, fontVariantNumeric: 'tabular-nums' }}>
              {GHS(Number(r.amount))}
            </div>
            {isBoss && (
              <div style={{ textAlign: 'right' }}>
                <button onClick={() => remove(r)} title="Delete delivery"
                  style={{ background: 'none', border: 'none', color: 'var(--qb-red)', cursor: 'pointer', fontSize: 16, lineHeight: 1, padding: 4 }}>
                  ✕
                </button>
              </div>
            )}
          </div>
        ))}
        <ListPager {...pager} accent={accent} border="var(--qb-separator)" />
      </div>
    </div>
  )
}
