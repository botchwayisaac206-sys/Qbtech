'use client'

import { useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { GHS, withinWindow } from '@/lib/sales'
import { fetchExpenses, invalidate, peek, scopedKey, type ExpRow } from '@/lib/adminCache'
import ListPager, { usePaged } from '@/components/admin/ListPager'

const DEFAULT_ACCENT = '#0a7cff'

export default function Expenses({ canSeeAmounts, userId, windowed = false, accent = DEFAULT_ACCENT }: { canSeeAmounts: boolean; userId: string | null; windowed?: boolean; accent?: string }) {
  const table    = 'expenses'
  const fetcher  = fetchExpenses
  const [reveal, setReveal] = useState(canSeeAmounts)

  // Windowed viewers see the last 24 hours only. RLS enforces this server-side;
  // the same clamp here keeps a warm cache from showing anything older.
  const clamp = (rs: ExpRow[]) => windowed ? rs.filter(r => withinWindow(r.incurred_at)) : rs
  const warmRows = peek<ExpRow[]>(scopedKey('expenses'))
  const [rows, setRows]     = useState<ExpRow[]>(clamp(warmRows || []))
  const [loading, setLoading] = useState(warmRows === undefined)

  const [description, setDescription] = useState('')
  const [amount, setAmount] = useState('')
  const [incurredAt, setIncurredAt] = useState(() => new Date().toISOString().slice(0, 10))
  const [saving, setSaving] = useState(false)
  const [search, setSearch] = useState('')

  useEffect(() => {
    let cancelled = false
    ;(async () => {
      try {
        const data = await fetcher()
        if (!cancelled) setRows(clamp(data))
      } catch (err) {
        if (!cancelled) console.warn('Expenses load failed:', err)
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()
    return () => { cancelled = true }
  }, [windowed])

  async function save(e: React.FormEvent) {
    e.preventDefault()
    const amt = parseFloat(amount)
    if (!amt || amt <= 0) return alert('Enter a valid amount')
    setSaving(true)
    try {
      const { data: inserted, error } = await supabase.from(table).insert({
        category: 'General',
        description: description.trim() || null,
        amount: amt,
        incurred_at: new Date(incurredAt + 'T12:00:00').toISOString(),
        created_by: userId,
      }).select().single()
      if (error) throw error
      setDescription(''); setAmount('')
      setRows(prev => [inserted as ExpRow, ...prev])
      invalidate(table)
    } catch (err: any) {
      alert(err.message || 'Failed to save expense')
    } finally { setSaving(false) }
  }

  const fld: React.CSSProperties = {
    width: '100%', padding: '9px 12px', borderRadius: 8, fontSize: 14, outline: 'none',
    border: '1px solid var(--qb-input-border)', background: 'var(--qb-input)', color: 'var(--qb-text)',
  }
  const lbl: React.CSSProperties = { fontSize: 10, fontWeight: 800, color: accent, letterSpacing: '0.18em', textTransform: 'uppercase', display: 'block', marginBottom: 5 }

  const Money = ({ n }: { n: number }) => (
    <span style={{
      fontVariantNumeric: 'tabular-nums',
      filter: reveal ? 'none' : 'blur(6px)',
      userSelect: reveal ? 'auto' : 'none',
      transition: 'filter 0.15s',
    }}>{GHS(n)}</span>
  )

  const EIGHT_HOURS = 8 * 60 * 60 * 1000
  const visibleRows = canSeeAmounts
    ? rows
    : rows.filter(r => Date.now() - new Date(r.incurred_at).getTime() < EIGHT_HOURS)
  const total = visibleRows.reduce((s, r) => s + Number(r.amount), 0)

  const searched = search.trim()
    ? visibleRows.filter(r => (r.description || '').toLowerCase().includes(search.trim().toLowerCase()))
    : visibleRows
  // Paged, so the list never turns into an endless scroll.
  const pager = usePaged(searched, search)
  const shownRows = pager.shown

  return (
    <div style={{ maxWidth: 980, display: 'flex', flexDirection: 'column', gap: 18 }}>

      {/* Header with privacy toggle */}
      <div style={{
        display: 'flex', justifyContent: 'space-between', alignItems: 'center',
        padding: 14, borderRadius: 12,
        background: 'linear-gradient(135deg, var(--qb-header), var(--qb-card))',
        border: '1px solid rgba(10,124,255,0.2)',
      }}>
        <div>
          <div style={{ color: accent, fontSize: 11, fontWeight: 800, letterSpacing: '0.2em' }}>EXPENSES</div>
          <div style={{ color: 'var(--qb-sub)', fontSize: 12, fontVariantNumeric: 'tabular-nums', marginTop: 2 }}>
            Private — amounts blurred by default
          </div>
        </div>
        <button
          onClick={() => setReveal(r => !r)}
          style={{
            padding: '8px 14px', borderRadius: 10,
            background: reveal ? 'rgba(239,68,68,0.1)' : 'rgba(10,124,255,0.1)',
            color: reveal ? 'var(--qb-red)' : accent,
            border: `1px solid ${reveal ? 'rgba(239,68,68,0.3)' : 'rgba(10,124,255,0.3)'}`,
            fontWeight: 700, fontSize: 12, cursor: 'pointer', letterSpacing: '0.1em',
          }}>
          {reveal ? '🙈 HIDE AMOUNTS' : '👁 SHOW AMOUNTS'}
        </button>
      </div>

      {/* Add expense form */}
      <form onSubmit={save} style={{
        padding: 18, borderRadius: 14,
        border: '1px solid var(--qb-border)', background: 'var(--qb-card)',
        display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(180px,1fr))', gap: 12,
      }}>
        <div style={{ gridColumn: 'span 2' }}>
          <label style={lbl}>Description</label>
          <input style={fld} value={description} onChange={e => setDescription(e.target.value)} placeholder="Optional note" />
        </div>
        <div>
          <label style={lbl}>Amount (GH₵) *</label>
          <input
            type={reveal ? 'number' : 'password'}
            step="0.01" min="0"
            style={fld}
            value={amount}
            onChange={e => setAmount(e.target.value)}
            placeholder={reveal ? '0.00' : '••••••'}
          />
        </div>
        <div>
          <label style={lbl}>Date</label>
          <input type="date" style={fld} value={incurredAt} onChange={e => setIncurredAt(e.target.value)} />
        </div>
        <div style={{ gridColumn: '1 / -1' }}>
          <button type="submit" disabled={saving} style={{
            width: '100%', padding: 13, borderRadius: 10,
            background: saving ? 'var(--qb-fill)' : accent,
            color: saving ? 'var(--qb-muted)' : '#ffffff',
            fontWeight: 900, fontSize: 13, letterSpacing: '0.12em',
            border: 'none', cursor: saving ? 'not-allowed' : 'pointer',
          }}>
            {saving ? 'SAVING…' : '+ ADD EXPENSE'}
          </button>
        </div>
      </form>

      {/* Totals */}
      <div style={{
        padding: 14, borderRadius: 12,
        border: '1px solid var(--qb-border)', background: 'var(--qb-card)',
        display: 'flex', justifyContent: 'space-between', alignItems: 'center',
      }}>
        <div style={{ color: 'var(--qb-sub)', fontSize: 11, fontWeight: 800, letterSpacing: '0.18em' }}>TOTAL ({visibleRows.length})</div>
        <div style={{ color: 'var(--qb-text)', fontSize: 20, fontWeight: 900 }}><Money n={total} /></div>
      </div>

      {/* Recent list */}
      <input value={search} onChange={e => setSearch(e.target.value)} placeholder="Search description…"
        style={{ width: '100%', maxWidth: 420, padding: '9px 12px', borderRadius: 8, fontSize: 13, outline: 'none', border: '1px solid var(--qb-input-border)', background: 'var(--qb-input)', color: 'var(--qb-text)' }} />
      <div style={{
        borderRadius: 14, border: '1px solid var(--qb-border)',
        background: 'var(--qb-card)', overflow: 'hidden',
      }}>
        <div style={{
          display: 'grid', gridTemplateColumns: '110px 1fr 140px',
          padding: '10px 14px', background: 'var(--qb-header)',
          color: accent, fontSize: 10, fontWeight: 800, letterSpacing: '0.15em',
        }}>
          <div>DATE</div><div>DESCRIPTION</div><div style={{ textAlign: 'right' }}>AMOUNT</div>
        </div>
        {loading && <div style={{ padding: 30, textAlign: 'center', color: 'var(--qb-muted)', fontVariantNumeric: 'tabular-nums' }}>Loading…</div>}
        {!loading && searched.length === 0 && <div style={{ padding: 30, textAlign: 'center', color: 'var(--qb-muted)', fontVariantNumeric: 'tabular-nums' }}>{canSeeAmounts ? 'No expenses yet.' : 'No expenses in the last 8 hours.'}</div>}
        {shownRows.map(r => (
          <div key={r.id} style={{
            display: 'grid', gridTemplateColumns: '110px 1fr 140px',
            padding: '10px 14px', borderTop: '1px solid var(--qb-separator)',
            fontSize: 13, color: 'var(--qb-text)', alignItems: 'center',
          }}>
            <div style={{ fontVariantNumeric: 'tabular-nums', fontSize: 12, color: 'var(--qb-sub)' }}>
              {new Date(r.incurred_at).toLocaleDateString('en-GB')}
            </div>
            <div style={{ color: 'var(--qb-sub)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {r.description || '—'}
            </div>
            <div style={{ textAlign: 'right', color: 'var(--qb-text)', fontWeight: 700 }}>
              <Money n={Number(r.amount)} />
            </div>
          </div>
        ))}
        <ListPager {...pager} accent={accent} border="var(--qb-separator)" />
      </div>
    </div>
  )
}
