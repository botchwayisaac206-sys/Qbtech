'use client'

import { useState, useEffect, useRef, useCallback, useMemo } from 'react'
import { supabase } from '@/lib/supabase'
import { loadCodes } from '@/lib/productCodes'
import { fetchAllRows, invalidate } from '@/lib/adminCache'
import { modelKey } from '@/lib/storeStock'

// ─────────────────────────────────────────────────────────────
// THEME
// ─────────────────────────────────────────────────────────────
interface Theme {
  bg: string; card: string; border: string; text: string; sub: string;
  muted: string; input: string; inputBorder: string; headerBg: string;
  rowHover: string; tag: string; teal: string; shadow: string;
}
// Colours come from the --qb-* tokens (src/app/qb-ios.css): <html data-qb-theme>
// picks light or dark, so both palettes point at the same values.
const DARK: Theme = {
  bg: 'var(--qb-bg)', card: 'var(--qb-card)', border: 'var(--qb-border)',
  text: 'var(--qb-text)', sub: 'var(--qb-sub)', muted: 'var(--qb-muted)',
  input: 'var(--qb-input)', inputBorder: 'var(--qb-input-border)', headerBg: 'var(--qb-header)',
  rowHover: 'var(--qb-row-hover)', tag: 'var(--qb-tag)',
  teal: '#0a7cff', shadow: 'var(--qb-shadow)',
}
const LIGHT: Theme = DARK

// ─────────────────────────────────────────────────────────────
// TYPES
// ─────────────────────────────────────────────────────────────
interface Warehouse {
  id: string
  name: string
  color: string
  date_columns: string[]
  section_labels: string[]
}

interface StockItem {
  id: string
  warehouse: string
  model: string
  opening_stock: number
  daily_taken: Record<string, number>
  /** Units sold on a main invoice. Only ever non-zero in STORE STOCK. */
  invoice_taken: number
  /** Units received from another location on a transfer. */
  transfer_in: number
  /** Units sent to another location on a transfer. */
  transfer_out: number
  total_taken: number
  closing_stock: number
  min_level: number | null
  stock_status: string
}

/** A row straight from the table, before the movement columns are defaulted. */
type StockRow = Partial<StockItem> & { id: string; warehouse: string; model: string }

/**
 * Rows written before 20260920_store_stock_transfers.sql have no movement columns, so every read is normalised
 * rather than sprinkling `?? 0` across the render path.
 */
const normalise = (r: StockRow): StockItem => ({
  ...r,
  opening_stock: r.opening_stock ?? 0,
  daily_taken:   r.daily_taken   ?? {},
  invoice_taken: r.invoice_taken ?? 0,
  transfer_in:   r.transfer_in   ?? 0,
  transfer_out:  r.transfer_out  ?? 0,
  total_taken:   r.total_taken   ?? 0,
  closing_stock: r.closing_stock ?? 0,
  min_level:     r.min_level     ?? null,
  stock_status:  r.stock_status  ?? '',
})

// ─────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────
/**
 * The same arithmetic as fn_warehouse_stock_derive() in
 * 20260920_store_stock_transfers.sql. The database has the last word on what
 * is stored — this exists so the edit form can preview a figure before it is
 * saved, and must be kept in step with the trigger.
 *
 *   taken   = hand-entered on the day sheet + invoiced + transferred away
 *   closing = opening + transferred in - taken
 */
function computeTotals(item: {
  opening_stock: number
  daily_taken: Record<string, number>
  invoice_taken?: number
  transfer_in?: number
  transfer_out?: number
}) {
  const manual = Object.values(item.daily_taken).reduce((s, v) => s + (v || 0), 0)
  const total_taken = manual + (item.invoice_taken || 0) + (item.transfer_out || 0)
  return {
    total_taken,
    closing_stock: item.opening_stock + (item.transfer_in || 0) - total_taken,
  }
}
function computeStatus(item: { closing_stock: number; min_level: number | null }) {
  if (!item.min_level) return ''
  return item.closing_stock < item.min_level ? 'LOW' : 'OK'
}
function statusColor(item: StockItem, teal: string) {
  if (item.closing_stock <= 0) return '#ef4444'
  if (item.stock_status === 'LOW') return '#f59e0b'
  if (item.stock_status === 'OK') return teal
  return '#64748b'
}
/**
 * What the location has ever had in — the denominator for the "% remaining"
 * bar. STORE STOCK opens at 0 and is filled entirely by transfers, so
 * opening_stock alone would leave its bar permanently empty.
 */
function stockedIn(item: { opening_stock: number; transfer_in: number }) {
  return item.opening_stock + item.transfer_in
}
function statusLabel(item: StockItem) {
  if (item.closing_stock <= 0) return 'EMPTY'
  if (item.stock_status === 'LOW') return 'LOW'
  if (item.stock_status === 'OK') return 'OK'
  return '–'
}

// ─────────────────────────────────────────────────────────────
// SECTION-AWARE DAILY KEYS
// Each daily_taken key is "sectionIdx:day" so that different
// sections (e.g. an old month and a new June & July month) keep
// separate values for the same day-of-month instead of colliding.
// Legacy bare keys ("2") are treated as section 0, so existing
// rows keep working unchanged.
// ─────────────────────────────────────────────────────────────
function parseKey(key: string): { section: number; day: string } {
  const idx = key.indexOf(':')
  if (idx === -1) return { section: 0, day: key }
  return { section: parseInt(key.slice(0, idx)) || 0, day: key.slice(idx + 1) }
}
function makeKey(section: number, day: string) {
  return section === 0 ? day : `${section}:${day}`
}
// Collapse section-namespaced keys into a per-day total, used by
// every flat view (table day columns, detail breakdown, export).
function dayTotals(daily: Record<string, number>): Record<string, number> {
  const out: Record<string, number> = {}
  for (const [k, v] of Object.entries(daily)) {
    const { day } = parseKey(k)
    out[day] = (out[day] || 0) + (v || 0)
  }
  return out
}

// ─────────────────────────────────────────────────────────────
// ATOMS
// ─────────────────────────────────────────────────────────────
const Badge = ({ label, color }: { label: string; color: string }) => (
  <span style={{
    display: 'inline-flex', alignItems: 'center', padding: '2px 8px',
    borderRadius: '6px', fontSize: '10px', fontWeight: 800, letterSpacing: '0.12em',
    background: `${color}18`, color, border: `1px solid ${color}30`, whiteSpace: 'nowrap',
  }}>{label}</span>
)
const StockBar = ({ pct, color }: { pct: number; color: string }) => (
  <div style={{ width: '100%', height: '3px', background: 'rgba(128,128,128,0.15)', borderRadius: '4px', overflow: 'hidden' }}>
    <div style={{ width: `${Math.min(100, Math.max(0, pct))}%`, height: '100%', background: color, transition: 'width 0.3s' }} />
  </div>
)
const Spinner = ({ color }: { color: string }) => (
  <div style={{ width: 24, height: 24, border: `3px solid ${color}30`, borderTopColor: color, borderRadius: '50%', animation: 'spin 0.7s linear infinite' }} />
)

// ─────────────────────────────────────────────────────────────
// WAREHOUSE MODAL
// ─────────────────────────────────────────────────────────────
function WarehouseModal({ wh, onSave, onClose, T, dark }: {
  wh: Partial<Warehouse> & { id?: string }
  onSave: (w: Omit<Warehouse, 'id'> & { id?: string }) => void
  onClose: () => void
  T: Theme
  dark: boolean
}) {
  const [name,     setName]     = useState(wh.name || '')
  const [color,    setColor]    = useState(wh.color || '#0a7cff')
  const [datesRaw, setDatesRaw] = useState((wh.date_columns || []).join(', '))
  const [sections, setSections] = useState<string[]>(
    wh.section_labels?.length ? wh.section_labels : ['Daily Quantities Taken (by day of month)']
  )
  const [err,      setErr]      = useState('')

  const inp: React.CSSProperties = {
    width: '100%', padding: '9px 12px', borderRadius: '8px', fontSize: '16px',
    border: `1px solid ${T.inputBorder}`, background: T.input, color: T.text,
    outline: 'none', boxSizing: 'border-box',
  }
  const lbl: React.CSSProperties = {
    fontSize: '10px', fontWeight: 800, color: T.teal, letterSpacing: '0.15em',
    textTransform: 'uppercase', display: 'block', marginBottom: '5px',
  }

  return (
    <div style={{ position: 'fixed', top: 0, left: 0, right: 0, bottom: 0, zIndex: 9100, background: 'var(--qb-scrim)', backdropFilter: 'blur(2px)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 16 }}
      onClick={e => e.target === e.currentTarget && onClose()}>
      <div style={{ background: 'var(--qb-solid)', borderRadius: 18, border: `1px solid ${T.border}`, width: '100%', maxWidth: 480, padding: 28, boxShadow: T.shadow }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 20 }}>
          <h2 style={{ color: T.text, fontWeight: 900, fontSize: 17, margin: 0 }}>{wh.id ? '✏️ Edit Warehouse' : '🏭 Add New Warehouse'}</h2>
          <button onClick={onClose} style={{ background: 'none', border: 'none', color: T.sub, cursor: 'pointer', fontSize: 20 }}>✕</button>
        </div>

        {err && <div style={{ padding: '10px 14px', borderRadius: 8, background: 'rgba(239,68,68,0.1)', color: '#ef4444', fontSize: 13, marginBottom: 14 }}>{err}</div>}

        <div style={{ marginBottom: 16 }}>
          <label style={lbl}>Warehouse Name *</label>
          <input value={name} onChange={e => setName(e.target.value)} placeholder="e.g. MAIN STORE" style={inp} />
        </div>

        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(180px,1fr))', gap: 14, marginBottom: 16 }}>
          <div>
            <label style={lbl}>Color</label>
            <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
              <input type="color" value={color} onChange={e => setColor(e.target.value)}
                style={{ width: 42, height: 38, borderRadius: 8, border: `1px solid ${T.inputBorder}`, background: T.input, cursor: 'pointer', padding: 2 }} />
              <input value={color} onChange={e => setColor(e.target.value)} style={{ ...inp, fontVariantNumeric: 'tabular-nums' }} />
            </div>
          </div>
          <div>
            <label style={lbl}>Badge Preview</label>
            <div style={{ padding: '10px 12px', borderRadius: 8, border: `1px solid ${T.inputBorder}`, display: 'flex', alignItems: 'center' }}>
              <Badge label={name || 'PREVIEW'} color={color} />
            </div>
          </div>
        </div>

        <div style={{ marginBottom: 22 }}>
          <label style={lbl}>Day columns (comma-separated day numbers)</label>
          <input value={datesRaw} onChange={e => setDatesRaw(e.target.value)} placeholder="e.g. 1, 2, 3, ... 31" style={inp} />
          <p style={{ color: T.sub, fontSize: 11, margin: '5px 0 0', fontVariantNumeric: 'tabular-nums' }}>Enter the day-of-month numbers that will appear as columns in the stock table</p>
        </div>

        <div style={{ marginBottom: 22 }}>
          <label style={lbl}>Daily Quantity Sections</label>
          {sections.map((label, i) => (
            <div key={i} style={{ display: 'flex', gap: 8, alignItems: 'center', marginBottom: 6 }}>
              <input
                value={label}
                onChange={e => setSections(ss => ss.map((s, j) => j === i ? e.target.value : s))}
                placeholder={`Section ${i + 1} name`}
                style={inp}
              />
              {sections.length > 1 && (
                <button type="button"
                  onClick={() => setSections(ss => ss.filter((_, j) => j !== i))}
                  style={{
                    background: 'transparent', border: '1px solid #ef4444',
                    borderRadius: 7, color: '#ef4444', cursor: 'pointer',
                    fontSize: 13, fontWeight: 800, padding: '7px 10px', whiteSpace: 'nowrap',
                  }}>✕</button>
              )}
            </div>
          ))}
          <button type="button"
            onClick={() => setSections(ss => [...ss, ''])}
            style={{
              width: '100%', padding: '7px', borderRadius: 8, background: 'transparent',
              border: `1px dashed ${T.teal}60`, color: T.teal, cursor: 'pointer',
              fontSize: 11, fontWeight: 800, letterSpacing: '0.1em', marginTop: 2,
            }}>
            + ADD SECTION
          </button>
        </div>

        <div style={{ display: 'flex', gap: 10 }}>
          <button onClick={() => {
            if (!name.trim()) return setErr('Warehouse name is required')
            const date_columns = datesRaw.split(',').map(s => s.trim()).filter(Boolean)
            const section_labels = sections.map(s => s.trim()).filter(Boolean)
            onSave({ id: wh.id, name: name.trim().toUpperCase(), color, date_columns, section_labels })
          }} style={{ flex: 1, padding: 12, borderRadius: 10, background: T.teal, color: '#fff', fontWeight: 900, fontSize: 14, border: 'none', cursor: 'pointer' }}>
            {wh.id ? 'UPDATE WAREHOUSE' : 'ADD WAREHOUSE'}
          </button>
          <button onClick={onClose} style={{ padding: '12px 20px', borderRadius: 10, background: 'transparent', color: T.sub, fontWeight: 700, border: `1px solid ${T.inputBorder}`, cursor: 'pointer' }}>Cancel</button>
        </div>
      </div>
    </div>
  )
}

// ─────────────────────────────────────────────────────────────
// STOCK ITEM MODAL
// ─────────────────────────────────────────────────────────────
interface DailyGroup { id: string; label: string; open: boolean; taken: Record<string, number> }

function StockModal({ item, warehouses, onSave, onClose, T, dark }: {
  item: Partial<StockItem> & { id?: string }
  warehouses: Warehouse[]
  onSave: (item: StockItem) => void
  onClose: () => void
  T: Theme
  dark: boolean
}) {
  const [form, setForm] = useState<Partial<StockItem>>({
    warehouse: item.warehouse || warehouses[0]?.name || '',
    model: item.model || '',
    opening_stock: item.opening_stock ?? 0,
    daily_taken: { ...(item.daily_taken ?? {}) },
    min_level: item.min_level ?? null,
    ...item,
  })
  const [saving, setSaving] = useState(false)

  const warehouseSections = (warehouses.find(w => w.name === (item.warehouse || warehouses[0]?.name))?.section_labels ?? [])
  const defaultSections   = warehouseSections.length ? warehouseSections : ['Daily Quantities Taken (by day of month)']
  const [groups, setGroups] = useState<DailyGroup[]>(
    defaultSections.map((label, i) => ({
      id: `g${i}`,
      label,
      open: false,
      // Pull only this section's own day values; key them by bare
      // day inside the group (the inputs read group.taken[day]).
      taken: Object.fromEntries(
        Object.entries(item.daily_taken ?? {})
          .filter(([k]) => parseKey(k).section === i)
          .map(([k, v]) => [parseKey(k).day, v]),
      ),
    }))
  )

  const activeDates = warehouses.find(w => w.name === form.warehouse)?.date_columns || []

  const mergedTaken = useMemo(
    () => groups.reduce((acc, g, i) => {
      for (const [day, v] of Object.entries(g.taken)) acc[makeKey(i, day)] = v
      return acc
    }, {} as Record<string, number>),
    [groups],
  )
  // Movements are never edited here — they are the record of what invoices
  // and transfers already did. They are carried through the form untouched so
  // that saving an opening count or a min level cannot silently erase them.
  const moves = {
    invoice_taken: item.invoice_taken ?? 0,
    transfer_in:   item.transfer_in   ?? 0,
    transfer_out:  item.transfer_out  ?? 0,
  }
  const tots = computeTotals({ opening_stock: form.opening_stock || 0, daily_taken: mergedTaken, ...moves })

  useEffect(() => {
    setForm(f => ({ ...f, daily_taken: mergedTaken }))
  }, [mergedTaken])

  const updateGroupDay = (groupId: string, day: string, val: string) => {
    const n = parseInt(val) || 0
    setGroups(gs => gs.map(g => {
      if (g.id !== groupId) return g
      const taken = { ...g.taken }
      if (n > 0) taken[day] = n; else delete taken[day]
      return { ...g, taken }
    }))
  }

  const resetGroupsForWarehouse = (warehouseName: string) => {
    const wh = warehouses.find(w => w.name === warehouseName)
    const labels = wh?.section_labels?.length ? wh.section_labels : ['Daily Quantities Taken (by day of month)']
    setGroups(labels.map((label, i) => ({ id: `g${i}`, label, open: false, taken: {} })))
  }

  const inp: React.CSSProperties = {
    width: '100%', padding: '9px 12px', borderRadius: '8px', fontSize: '16px',
    border: `1px solid ${T.inputBorder}`, background: T.input, color: T.text,
    outline: 'none', boxSizing: 'border-box',
  }
  const lbl: React.CSSProperties = {
    fontSize: '10px', fontWeight: 800, color: T.teal, letterSpacing: '0.15em',
    textTransform: 'uppercase', display: 'block', marginBottom: '5px',
  }

  return (
    <div style={{ position: 'fixed', top: 0, left: 0, right: 0, bottom: 0, zIndex: 9000, background: 'var(--qb-scrim)', backdropFilter: 'blur(2px)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 16 }}
      onClick={e => e.target === e.currentTarget && onClose()}>
      <div style={{ background: 'var(--qb-solid)', borderRadius: 18, border: `1px solid ${T.border}`, width: '100%', maxWidth: 680, maxHeight: '90vh', overflow: 'auto', boxShadow: T.shadow, padding: 28 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 24 }}>
          <h2 style={{ color: T.text, fontWeight: 900, fontSize: 18, margin: 0 }}>{item.id ? '✏️ Edit Stock Item' : '➕ Add New Stock Item'}</h2>
          <button onClick={onClose} style={{ background: 'none', border: 'none', color: T.sub, cursor: 'pointer', fontSize: 20 }}>✕</button>
        </div>

        <div style={{ marginBottom: 16 }}>
          <label style={lbl}>Warehouse</label>
          <select value={form.warehouse} onChange={e => { setForm(f => ({ ...f, warehouse: e.target.value, daily_taken: {} })); resetGroupsForWarehouse(e.target.value) }} style={inp}>
            {warehouses.map(w => <option key={w.id} value={w.name}>{w.name}</option>)}
          </select>

        </div>

        <div style={{ marginBottom: 16 }}>
          <label style={lbl}>Model / Product Name *</label>
          <input value={form.model} onChange={e => setForm(f => ({ ...f, model: e.target.value }))} placeholder="e.g. DS-7208HGHI-M1" style={inp} />
        </div>

        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(160px,1fr))', gap: 14, marginBottom: 16 }}>
          <div>
            <label style={lbl}>Opening Stock</label>
            <input type="number" min="0" value={form.opening_stock}
              onChange={e => setForm(f => ({ ...f, opening_stock: parseInt(e.target.value) || 0 }))} style={inp} />
          </div>
          <div>
            <label style={lbl}>Min Level (alert threshold)</label>
            <input type="number" min="0" value={form.min_level ?? ''}
              onChange={e => setForm(f => ({ ...f, min_level: e.target.value ? parseInt(e.target.value) : null }))}
              placeholder="Leave blank = no alert" style={inp} />
          </div>
        </div>

        {activeDates.length > 0 && (
          <div style={{ marginBottom: 20 }}>
            {groups.map(group => (
              <div key={group.id} style={{ marginBottom: 8 }}>
                {/* Header row */}
                <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
                  <span style={{
                    flex: 1, fontSize: 10, fontWeight: 800, color: T.teal,
                    letterSpacing: '0.15em', textTransform: 'uppercase',
                  }}>
                    {group.label}
                  </span>
                  <button type="button"
                    onClick={() => setGroups(gs => gs.map(g => g.id === group.id ? { ...g, open: !g.open } : g))}
                    style={{
                      background: group.open ? `${T.teal}20` : T.input,
                      border: `1px solid ${group.open ? T.teal : T.inputBorder}`,
                      borderRadius: 7, color: group.open ? T.teal : T.sub,
                      cursor: 'pointer', fontSize: 11, fontWeight: 800,
                      padding: '4px 10px', whiteSpace: 'nowrap', letterSpacing: '0.05em',
                    }}>
                    {group.open ? '▲ HIDE' : '▼ SHOW'}
                  </button>
                </div>
                {/* Day inputs */}
                {group.open && (
                  <div style={{
                    display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(68px, 1fr))', gap: 8,
                    padding: 14, borderRadius: 10,
                    background: dark ? 'rgba(0,0,0,0.2)' : 'rgba(0,0,0,0.04)',
                    border: `1px solid ${T.inputBorder}`,
                  }}>
                    {activeDates.map(day => (
                      <div key={day}>
                        <div style={{ fontSize: 10, color: T.teal, fontWeight: 700, textAlign: 'center', marginBottom: 3 }}>Day {day}</div>
                        <input type="number" min="0"
                          value={group.taken[day] || ''}
                          onChange={e => updateGroupDay(group.id, day, e.target.value)}
                          placeholder="0"
                          style={{
                            ...inp, padding: '6px 4px', textAlign: 'center',
                            background: group.taken[day] ? `${T.teal}15` : T.input,
                            borderColor: group.taken[day] ? T.teal : T.inputBorder,
                          }} />
                      </div>
                    ))}
                  </div>
                )}
              </div>
            ))}
          </div>
        )}

        {/* Live totals */}
        <div style={{
          display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(100px,1fr))', gap: 10, marginBottom: 24,
          padding: 14, borderRadius: 10,
          background: dark ? 'rgba(10,124,255,0.05)' : 'rgba(10,124,255,0.06)',
          border: `1px solid ${T.teal}25`,
        }}>
          {[
            { label: 'Opening',     value: form.opening_stock || 0, color: T.sub },
            // Only shown once they carry something, so an ordinary warehouse
            // item keeps the three-figure summary it has always had.
            ...(moves.transfer_in  ? [{ label: 'Transferred In',  value: moves.transfer_in,  color: T.teal   }] : []),
            ...(moves.transfer_out ? [{ label: 'Transferred Out', value: moves.transfer_out, color: '#38bdf8' }] : []),
            ...(moves.invoice_taken ? [{ label: 'Invoiced',       value: moves.invoice_taken, color: '#a78bfa' }] : []),
            { label: 'Total Taken', value: tots.total_taken,        color: '#f59e0b' },
            { label: 'Closing',     value: tots.closing_stock,      color: tots.closing_stock < 0 ? '#ef4444' : T.teal },
          ].map(s => (
            <div key={s.label} style={{ textAlign: 'center' }}>
              <div style={{ fontSize: 10, color: T.sub, letterSpacing: '0.1em', marginBottom: 3 }}>{s.label.toUpperCase()}</div>
              <div style={{ fontSize: 22, fontWeight: 900, color: s.color, fontVariantNumeric: 'tabular-nums' }}>{s.value}</div>
            </div>
          ))}
        </div>

        <div style={{ display: 'flex', gap: 10 }}>
          <button disabled={saving} onClick={async () => {
            if (!form.model?.trim()) return alert('Model name is required')
            setSaving(true)
            const tots2  = computeTotals({ opening_stock: form.opening_stock || 0, daily_taken: mergedTaken, ...moves })
            const status = computeStatus({ closing_stock: tots2.closing_stock, min_level: form.min_level ?? null })
            onSave({
              id: item.id || '',
              warehouse:     form.warehouse     || '',
              model:         form.model         || '',
              opening_stock: form.opening_stock || 0,
              daily_taken:   mergedTaken,
              ...moves,
              total_taken:   tots2.total_taken,
              closing_stock: tots2.closing_stock,
              min_level:     form.min_level ?? null,
              stock_status:  status,
            })
          }} style={{
            flex: 1, padding: 12, borderRadius: 10,
            background: saving ? T.inputBorder : T.teal,
            color: '#fff', fontWeight: 900, fontSize: 14, border: 'none',
            cursor: saving ? 'not-allowed' : 'pointer',
            display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
          }}>
            {saving ? <><Spinner color="#fff" /> Saving…</> : (item.id ? 'UPDATE ITEM' : 'ADD ITEM')}
          </button>
          <button onClick={onClose} style={{ padding: '12px 20px', borderRadius: 10, background: 'transparent', color: T.sub, fontWeight: 700, border: `1px solid ${T.inputBorder}`, cursor: 'pointer' }}>Cancel</button>
        </div>
      </div>
    </div>
  )
}

// ─────────────────────────────────────────────────────────────
// MAIN COMPONENT
// ─────────────────────────────────────────────────────────────
/**
 * A model's price key. price_for_model() in the database matches on
 * upper(btrim(model)), so the client map has to agree or the price shown
 * here and the price an invoice is written at would disagree.
 */
// The same product key the database files and finds prices under.
const priceKey = (model: string) => modelKey(model)

export default function StockTab({ darkMode, onToggleDark, isSuperBoss = false }: {
  darkMode: boolean
  onToggleDark: () => void
  /** Only the Big Boss may set a selling price — set_model_price() rejects anyone else. */
  isSuperBoss?: boolean
}) {
  const T = darkMode ? DARK : LIGHT

  const [warehouses,  setWarehouses]  = useState<Warehouse[]>([])
  const [data,        setData]        = useState<StockItem[]>([])
  // model → linked scan/material codes, so the search box can match by code too.
  const [modelCodes,  setModelCodes]  = useState<Map<string, string[]>>(new Map())
  const [loading,     setLoading]     = useState(true)
  const [warehouse,   setWarehouse]   = useState('ALL')
  const [filter,      setFilter]      = useState<'all'|'low'|'zero'>('all')
  // STORE STOCK carries a row for every product the shop stocks anywhere
  // (20261007_store_stock_lists_everything.sql), most of them rows that have
  // never held a unit. Hidden unless asked for, or they bury the rest.
  const [hideNever,   setHideNever]   = useState(true)
  const [query,       setQuery]       = useState('')
  const [sortKey,     setSortKey]     = useState<keyof StockItem>('model')
  const [sortDir,     setSortDir]     = useState<'asc'|'desc'>('asc')
  const [page,        setPage]        = useState(1)
  const [selected,    setSelected]    = useState<StockItem|null>(null)
  const [stockModal,  setStockModal]  = useState<(Partial<StockItem> & { id?: string })|null>(null)
  const [whModal,     setWhModal]     = useState<(Partial<Warehouse> & { id?: string })|null>(null)
  const [viewDates,   setViewDates]   = useState(false)
  const [manageWh,    setManageWh]    = useState(false)
  // ── Prices ──
  // One price per MODEL, held in pricelist_items — not per stock row. The
  // same model sits in several warehouses at once, and a price per row would
  // be several prices for one product to keep in step by hand.
  const [prices,      setPrices]      = useState<Map<string, number>>(new Map())
  const [pricePanel,  setPricePanel]  = useState(false)
  // Drafts are kept as the raw string so a half-typed "12." is not coerced
  // to a number on every keystroke. Keyed by model, like the prices are.
  const [priceDraft,  setPriceDraft]  = useState<Record<string, string>>({})
  const [priceQuery,  setPriceQuery]  = useState('')
  const [priceOnlyUnpriced, setPriceOnlyUnpriced] = useState(false)
  const [savingPrices, setSavingPrices] = useState(false)
  // The one price being typed straight into the stock table, if any.
  const [priceEdit, setPriceEdit] = useState<{ id: string; model: string; value: string } | null>(null)
  const [savingPrice, setSavingPrice] = useState(false)
  const savingPriceRef = useRef(false)
  const [toast,       setToast]       = useState<{ msg: string; ok: boolean }|null>(null)
  const PER_PAGE = 20

  const showToast = (msg: string, ok = true) => {
    setToast({ msg, ok })
    setTimeout(() => setToast(null), 3000)
  }

  // ── Fetch warehouses ─────────────────────────────────────
  const fetchWarehouses = useCallback(async () => {
    const { data: rows, error } = await supabase.from('warehouses').select('*').order('created_at')
    if (error) { showToast('Failed to load warehouses', false); return [] }
    // Locations are created by the database setup (supabase/00_base_tables.sql),
    // never invented here.
    return rows || []
  }, [])

  // ── Fetch stock ──────────────────────────────────────────
  // Paged through fetchAllRows, not a bare select. PostgREST caps a single
  // request at 1000 rows and truncates SILENTLY — no error, just a short
  // list — so once the table passed that mark the newest rows (a freshly
  // counted location, say) simply stopped appearing in this tab. Paging
  // orders by id: a non-unique ORDER BY can skip or repeat rows across page
  // boundaries. Display order is decided client-side by sortKey anyway.
  const fetchStock = useCallback(async () => {
    let rows: StockRow[]
    try {
      rows = await fetchAllRows<StockRow>((from, to) =>
        supabase.from('warehouse_stock').select('*').order('id', { ascending: true }).range(from, to))
    } catch {
      showToast('Failed to load stock data', false); setLoading(false); return []
    }
    // An empty list is shown as empty.
    return rows.map(normalise)
  }, [])

  // ── Fetch prices ─────────────────────────────────────────
  const fetchPrices = useCallback(async () => {
    try {
      const rows = await fetchAllRows<{ model: string; ghs_price: number; created_at: string }>((from, to) =>
        supabase.from('pricelist_items').select('model, ghs_price, created_at')
          .order('id', { ascending: true }).range(from, to))
      // Most recently entered priced row wins, matching price_for_model().
      const byModel = new Map<string, { price: number; at: string }>()
      for (const r of rows) {
        const key = priceKey(r.model || '')
        const price = Number(r.ghs_price) || 0
        if (!key || price <= 0) continue
        const seen = byModel.get(key)
        if (!seen || r.created_at > seen.at) byModel.set(key, { price, at: r.created_at })
      }
      return new Map(Array.from(byModel, ([k, v]) => [k, v.price] as [string, number]))
    } catch {
      // The Prices panel is a bonus; a stock list that loads is the priority.
      showToast('Could not load prices', false)
      return new Map<string, number>()
    }
  }, [])

  useEffect(() => {
    const init = async () => {
      const [whs, stock, codes, priceMap] = await Promise.all([
        fetchWarehouses(), fetchStock(), loadCodes(), fetchPrices(),
      ])
      setPrices(priceMap)
      setWarehouses(whs)
      setData(stock)
      const byModel = new Map<string, string[]>()
      for (const c of codes) {
        const arr = byModel.get(c.model)
        if (arr) arr.push(c.material_code)
        else byModel.set(c.model, [c.material_code])
      }
      setModelCodes(byModel)
      setLoading(false)
    }
    init()
    // The three fetchers are stable (useCallback with no dependencies), so this still runs once.
  }, [fetchWarehouses, fetchStock, fetchPrices])

  // ── Save stock item (insert or update) ───────────────────
  const handleSaveStock = async (item: StockItem) => {
    // A new name is a RENAME of the product: in every location, with its
    // price and barcodes, through the same merge Product names uses. Writing
    // it onto this one row left the price behind under the old name (shown
    // as GH¢ 0) and the other locations under the old name. The database
    // now refuses that write (20261024_stock_accuracy.sql).
    const before = item.id ? data.find(x => x.id === item.id) : undefined
    const renamed = !!before && before.model !== item.model.trim()
    if (renamed) {
      if (!confirm(`Rename "${before!.model}" to "${item.model.trim()}"?\n\nIt is renamed in every location, and keeps its price and barcodes.`)) return
      const { error } = await supabase.rpc('merge_stock_model', { p_line: 'main', p_from: before!.model, p_into: item.model.trim() })
      if (error) { showToast('Rename failed: ' + error.message, false); return }
      item = { ...item, model: item.model.trim() }
    }
    // The movement columns (invoice_taken / transfer_in / transfer_out) are
    // deliberately absent: they belong to the invoice and transfer flows, and
    // on an UPDATE the row keeps whatever they already hold. total_taken,
    // closing_stock and stock_status are sent for older databases, but
    // trg_warehouse_stock_derive recomputes them and has the last word.
    const payload = {
      warehouse:     item.warehouse,
      model:         item.model,
      opening_stock: item.opening_stock,
      daily_taken:   item.daily_taken,
      total_taken:   item.total_taken,
      closing_stock: item.closing_stock,
      min_level:     item.min_level,
      stock_status:  item.stock_status,
    }
    if (item.id) {
      const { error } = await supabase.from('warehouse_stock')
        .update({ ...payload, updated_at: new Date().toISOString() })
        .eq('id', item.id)
      if (error) { showToast('Update failed: ' + error.message, false); return }
      if (renamed) {
        // Every location, its price and its barcodes changed: read them back.
        const [rows, priceMap] = await Promise.all([fetchStock(), fetchPrices()])
        setData(rows); setPrices(priceMap)
        invalidate('stock_models'); invalidate('pricelist_map')
        const fresh = rows.find(x => x.id === item.id)
        if (selected?.id === item.id) setSelected(fresh ?? item)
        showToast(`Renamed to ${item.model} everywhere ✓`)
      } else {
        setData(d => d.map(x => x.id === item.id ? item : x))
        if (selected?.id === item.id) setSelected(item)
        showToast('Item updated ✓')
      }
    } else {
      const { data: inserted, error } = await supabase.from('warehouse_stock')
        .insert(payload).select().single()
      if (error) { showToast('Insert failed: ' + error.message, false); return }
      setData(d => [normalise(inserted), ...d])
      showToast('Item added ✓')
    }
    setStockModal(null)
  }

  // ── Delete stock item ────────────────────────────────────
  const handleDeleteStock = async (id: string, model: string) => {
    if (!confirm(`Delete "${model}"?`)) return
    const { error } = await supabase.from('warehouse_stock').delete().eq('id', id)
    if (error) { showToast('Delete failed', false); return }
    setData(d => d.filter(x => x.id !== id))
    if (selected?.id === id) setSelected(null)
    showToast('Item deleted')
  }

  // ── Save warehouse ───────────────────────────────────────
  const handleSaveWarehouse = async (wh: Omit<Warehouse,'id'> & { id?: string }) => {
    if (wh.id) {
      const { error } = await supabase.from('warehouses')
        .update({ name: wh.name, color: wh.color, date_columns: wh.date_columns, section_labels: wh.section_labels })
        .eq('id', wh.id)
      if (error) { showToast('Update failed: ' + error.message, false); return }
      setWarehouses(ws => ws.map(w => w.id === wh.id ? { ...w, ...wh, id: w.id } : w))
      showToast('Warehouse updated ✓')
    } else {
      const { data: inserted, error } = await supabase.from('warehouses')
        .insert({ name: wh.name, color: wh.color, date_columns: wh.date_columns, section_labels: wh.section_labels })
        .select().single()
      if (error) { showToast('Failed: ' + error.message, false); return }
      setWarehouses(ws => [...ws, inserted])
      showToast('Warehouse added ✓')
    }
    setWhModal(null)
  }

  // ── Delete warehouse ─────────────────────────────────────
  const handleDeleteWarehouse = async (wh: Warehouse) => {
    const count = data.filter(x => x.warehouse === wh.name).length
    if (!confirm(`Delete "${wh.name}"? This will also remove all ${count} stock items inside it.`)) return
    await supabase.from('warehouse_stock').delete().eq('warehouse', wh.name)
    const { error } = await supabase.from('warehouses').delete().eq('id', wh.id)
    if (error) { showToast('Delete failed', false); return }
    setWarehouses(ws => ws.filter(w => w.id !== wh.id))
    setData(d => d.filter(x => x.warehouse !== wh.name))
    if (warehouse === wh.name) setWarehouse('ALL')
    showToast('Warehouse deleted')
  }

  // ── Bulk price save ──────────────────────────────────────
  // Only rows whose value actually differs from the saved one are written.
  // Each goes through set_model_price(), which finds or creates the price
  // list row so this screen never has to know about categories. One call per
  // model because the function rejects per-model, and a single failure
  // should be able to name the product it refused.
  const handleSavePrices = async () => {
    const changed = Object.entries(priceDraft)
      .map(([model, raw]) => ({ model, price: Math.max(0, Math.round((parseFloat(raw) || 0) * 100) / 100) }))
      .filter(({ model, price }) => price !== (prices.get(priceKey(model)) ?? 0))

    if (changed.length === 0) { showToast('No price changes to save', false); return }

    setSavingPrices(true)
    const failed: string[] = []
    const saved = new Map(prices)
    for (const { model, price } of changed) {
      const { error } = await supabase.rpc('set_model_price', { p_model: model, p_price: price })
      if (error) { failed.push(model); continue }
      if (price > 0) saved.set(priceKey(model), price)
      else saved.delete(priceKey(model))
    }
    setPrices(saved)
    setSavingPrices(false)
    setPriceDraft({})
    // The invoice form reads the price list through the admin cache.
    invalidate('pricelist_map')

    if (failed.length) {
      showToast(`${changed.length - failed.length} saved · ${failed.length} rejected (Big Boss only)`, false)
    } else {
      showToast(`${changed.length} price${changed.length === 1 ? '' : 's'} saved ✓`)
    }
  }

  // ── One price, from the row ──────────────────────────────
  // The same set_model_price() the Prices panel uses, so there is still one
  // price per MODEL: changing it on a BACK WAREHOUSE row changes it on that
  // model's STORE STOCK row too, and on the next invoice. 0 or blank clears it.
  const savePriceEdit = async () => {
    // Enter saves, and the field losing focus as it closes would save again.
    if (!priceEdit || savingPriceRef.current) return
    savingPriceRef.current = true
    const { model, value } = priceEdit
    const price = Math.max(0, Math.round((parseFloat(value) || 0) * 100) / 100)
    if (price === (prices.get(priceKey(model)) ?? 0)) { savingPriceRef.current = false; setPriceEdit(null); return }

    setSavingPrice(true)
    const { error } = await supabase.rpc('set_model_price', { p_model: model, p_price: price })
    setSavingPrice(false)
    savingPriceRef.current = false
    if (error) { showToast(error.message || 'Could not save that price', false); return }

    setPrices(prev => {
      const next = new Map(prev)
      if (price > 0) next.set(priceKey(model), price); else next.delete(priceKey(model))
      return next
    })
    setPriceEdit(null)
    // The invoice form reads the price list through the admin cache.
    invalidate('pricelist_map')
    showToast(price > 0 ? `${model} — GH¢ ${price.toLocaleString('en-GH', { minimumFractionDigits: 2 })} ✓` : `${model} — price cleared`)
  }

  // ── Export to CSV ────────────────────────────────────────
  const handleExport = () => {
    const rows = warehouse === 'ALL' ? data : data.filter(x => x.warehouse === warehouse)
    const allDates = rows
      .flatMap(r => Object.keys(dayTotals(r.daily_taken)))
      .filter((value, index, self) => self.indexOf(value) === index)
      .sort((a, b) => parseInt(a) - parseInt(b))
    const headers = [
      'Warehouse', 'Model / Product', 'Opening Stock',
      ...allDates.map(d => `Day ${d}`),
      'Transferred In', 'Transferred Out', 'Invoiced',
      'Total Taken', 'Closing Stock', 'Min Level', 'Stock Status',
    ]
    const csvRows = rows.map(item => {
      const dt = dayTotals(item.daily_taken)
      return [
      `"${item.warehouse}"`,
      `"${item.model.replace(/"/g, '""')}"`,
      item.opening_stock,
      ...allDates.map(d => dt[d] || 0),
      item.transfer_in,
      item.transfer_out,
      item.invoice_taken,
      item.total_taken,
      item.closing_stock,
      item.min_level ?? '',
      item.stock_status,
    ]
    })
    const csv = [headers.join(','), ...csvRows.map(r => r.join(','))].join('\n')
    const blob = new Blob(['\uFEFF' + csv], { type: 'text/csv;charset=utf-8;' })
    const url  = URL.createObjectURL(blob)
    const a    = document.createElement('a')
    a.href     = url
    const label = warehouse === 'ALL' ? 'ALL_WAREHOUSES' : warehouse.replace(/ /g, '_')
    a.download  = `QBNET_Stock_${label}_${new Date().toISOString().slice(0, 10)}.csv`
    document.body.appendChild(a); a.click(); document.body.removeChild(a)
    URL.revokeObjectURL(url)
    showToast(`Exported ${rows.length} items ✓`)
  }

  // ── Sort / filter ────────────────────────────────────────
  const handleSort = (key: keyof StockItem) => {
    if (sortKey === key) setSortDir(d => d === 'asc' ? 'desc' : 'asc')
    else { setSortKey(key); setSortDir('asc') }
  }

  /**
   * A row that has never held or moved a unit: nothing counted in, nothing
   * transferred in, nothing taken. Not the same as "out of stock" — a row
   * that sold down to 0 has a history and stays in view, as does one that
   * went negative.
   */
  //
  // STORE STOCK only. That is the one location filled with placeholder rows
  // for every product the shop carries; anywhere else a row at zero is a
  // product that warehouse stocks and has run out of — or, after a warehouse
  // has been cleared for a restock, every product in it. Hiding those made a
  // freshly cleared BACK WAREHOUSE look as if its product list had been wiped.
  const neverStocked = (x: StockItem) =>
    x.warehouse === 'STORE STOCK' &&
    x.opening_stock === 0 && x.transfer_in === 0 && x.total_taken === 0 && x.closing_stock === 0
  const visible = useMemo(() => (hideNever ? data.filter(x => !neverStocked(x)) : data), [data, hideNever])
  const neverCount = useMemo(
    () => data.filter(x => (warehouse === 'ALL' || x.warehouse === warehouse) && neverStocked(x)).length,
    [data, warehouse],
  )

  const filtered = useMemo(() => {
    // A search looks through everything: a never-stocked product still has
    // to be findable by name, to price it or to see that it is listed.
    let d = [...(query ? data : visible)]
    if (warehouse !== 'ALL') d = d.filter(x => x.warehouse === warehouse)
    if (filter === 'low')  d = d.filter(x => x.stock_status === 'LOW' || x.closing_stock <= 0)
    if (filter === 'zero') d = d.filter(x => x.closing_stock <= 0)
    if (query) {
      const q = query.toLowerCase()
      d = d.filter(x =>
        x.model.toLowerCase().includes(q) ||
        modelCodes.get(x.model)?.some(c => c.toLowerCase().includes(q)))
    }
    d.sort((a, b) => {
      let va: any = a[sortKey], vb: any = b[sortKey]
      if (typeof va === 'string') va = va.toLowerCase()
      if (typeof vb === 'string') vb = vb.toLowerCase()
      if (va < vb) return sortDir === 'asc' ? -1 : 1
      if (va > vb) return sortDir === 'asc' ? 1 : -1
      return 0
    })
    return d
  }, [data, visible, warehouse, filter, query, sortKey, sortDir, modelCodes])

  const pages     = Math.ceil(filtered.length / PER_PAGE)
  const pageItems = filtered.slice((page - 1) * PER_PAGE, page * PER_PAGE)

  const stats = useMemo(() => {
    // Counted over what is in view, so 800 never-stocked rows do not read
    // as 800 products that have run out.
    const src = warehouse === 'ALL' ? visible : visible.filter(x => x.warehouse === warehouse)
    return {
      total: src.length,
      low:   src.filter(x => x.stock_status === 'LOW' || x.closing_stock <= 0).length,
      ok:    src.filter(x => x.stock_status === 'OK').length,
      taken: src.reduce((s, x) => s + x.total_taken, 0),
      // Counted over distinct MODELS, not rows: one unpriced model sitting in
      // three warehouses is one price to enter, not three.
      unpriced: new Set(
        src.filter(x => x.warehouse !== 'SPOILT' && !(prices.get(priceKey(x.model)) ?? 0))
           .map(x => priceKey(x.model)),
      ).size,
      // What the shelves are worth at the current prices.
      value: src.reduce((s, x) =>
        s + Math.max(0, x.closing_stock) * (prices.get(priceKey(x.model)) ?? 0), 0),
    }
  }, [visible, warehouse, prices])

  const activeDates = warehouse !== 'ALL' ? (warehouses.find(w => w.name === warehouse)?.date_columns || []) : []
  const wColor = (name: string) => warehouses.find(w => w.name === name)?.color || T.teal

  // ── Style helpers ────────────────────────────────────────
  const inp: React.CSSProperties = {
    padding: '10px 14px', borderRadius: '10px', fontSize: '16px',
    border: `1px solid ${T.inputBorder}`, background: T.input, color: T.text, outline: 'none',
  }
  const thStyle: React.CSSProperties = {
    color: T.sub, fontSize: '10px', fontWeight: 800, letterSpacing: '0.12em',
    cursor: 'pointer', userSelect: 'none', padding: '10px 12px', whiteSpace: 'nowrap',
    borderBottom: `1px solid ${T.border}`, background: T.headerBg,
  }
  const tdStyle: React.CSSProperties = {
    padding: '10px 12px', fontSize: '12px', borderBottom: `1px solid ${T.border}`,
    color: T.text, verticalAlign: 'middle',
  }
  const SortArrow = ({ k }: { k: keyof StockItem }) =>
    sortKey === k ? <span style={{ color: T.teal, marginLeft: 3 }}>{sortDir === 'asc' ? '↑' : '↓'}</span> : null

  // ── Loading screen ───────────────────────────────────────
  if (loading) return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '80px 0', gap: 16 }}>
      <style>{`@keyframes spin { to { transform: rotate(360deg) } }`}</style>
      <Spinner color={T.teal} />
      <p style={{ color: T.sub, fontVariantNumeric: 'tabular-nums', fontSize: 13 }}>
        Loading warehouse stock…
      </p>
    </div>
  )

  return (
    <div style={{ paddingBottom: 48, transition: 'all 0.3s ease' }}>
      <style>{`@keyframes spin { to { transform: rotate(360deg) } }`}</style>

      {/* Toast */}
      {toast && (
        <div style={{
          position: 'fixed', bottom: 24, right: 24, zIndex: 9999,
          padding: '12px 20px', borderRadius: 12,
          background: toast.ok ? T.teal : '#ef4444',
          color: '#fff', fontWeight: 700, fontSize: 13,
          boxShadow: '0 8px 24px rgba(0,0,0,0.3)',
        }}>{toast.msg}</div>
      )}

      {/* ── Header ── */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 24, flexWrap: 'wrap', gap: 12 }}>
        <div>
          <h2 style={{ color: T.text, fontWeight: 900, fontSize: 20, margin: 0 }}>📦 Warehouse Stock</h2>
          <p style={{ color: T.sub, fontSize: 12, fontVariantNumeric: 'tabular-nums', margin: '4px 0 0' }}>
            Live inventory · {warehouses.map(w => w.name).join(' · ')}
          </p>
        </div>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
          {/* Dark/Light toggle */}
          <button onClick={onToggleDark} style={{
            display: 'flex', alignItems: 'center', gap: 8, padding: '8px 14px',
            borderRadius: 10, border: `1px solid ${T.inputBorder}`, background: T.input,
            color: T.text, cursor: 'pointer', fontSize: 12, fontWeight: 700, transition: 'all 0.3s',
          }}>
            <span style={{ fontSize: 16, display: 'inline-block', transition: 'transform 0.4s', transform: darkMode ? 'rotate(0deg)' : 'rotate(180deg)' }}>
              {darkMode ? '🌙' : '☀️'}
            </span>
            {darkMode ? 'Dark' : 'Light'}
          </button>

          {/* Manage warehouses */}
          <button onClick={() => setManageWh(v => !v)} style={{
            padding: '8px 14px', borderRadius: 10, fontSize: 12, fontWeight: 700,
            border: `1px solid ${T.inputBorder}`,
            background: manageWh ? '#7c3aed' : T.input,
            color: manageWh ? '#fff' : T.text, cursor: 'pointer', transition: 'all 0.2s',
          }}>🏭 Warehouses</button>

          {/* Prices — Big Boss only, since set_model_price() rejects anyone else */}
          {isSuperBoss && (
            <button onClick={() => { setPricePanel(v => !v); setManageWh(false) }} style={{
              padding: '8px 14px', borderRadius: 10, fontSize: 12, fontWeight: 700,
              border: `1px solid ${pricePanel ? '#34d399' : T.inputBorder}`,
              background: pricePanel ? '#34d399' : T.input,
              color: pricePanel ? '#052e1a' : T.text, cursor: 'pointer', transition: 'all 0.2s',
            }}>
              💰 Prices
              {stats.unpriced > 0 && (
                <span style={{ marginLeft: 6, padding: '1px 6px', borderRadius: 20, background: '#f59e0b', color: '#3b2200', fontSize: 10, fontWeight: 900 }}>
                  {stats.unpriced}
                </span>
              )}
            </button>
          )}

          {/* Export CSV */}
          <button onClick={handleExport} style={{
            display: 'flex', alignItems: 'center', gap: 6,
            padding: '8px 14px', borderRadius: 10, fontSize: 12, fontWeight: 700,
            border: `1px solid ${T.inputBorder}`, background: T.input,
            color: T.text, cursor: 'pointer', transition: 'all 0.2s',
          }}>⬇ Export CSV</button>

          {/* Add item */}
          <button onClick={() => setStockModal({ warehouse: warehouse === 'ALL' ? (warehouses[0]?.name || '') : warehouse })} style={{
            padding: '9px 18px', borderRadius: 10, background: T.teal,
            color: '#fff', fontWeight: 900, fontSize: 12, border: 'none', cursor: 'pointer', letterSpacing: '0.08em',
          }}>+ ADD ITEM</button>
        </div>
      </div>

      {/* ── Prices panel ──
          Lists MODELS, not stock rows: one price covers a model wherever it
          sits, so a model held in three warehouses appears once. */}
      {pricePanel && isSuperBoss && (() => {
        const q   = priceQuery.trim().toLowerCase()
        // Written-off goods are not for sale, so they would only inflate the
        // unpriced count with models nobody needs to price.
        const src = warehouse === 'ALL'
          ? data.filter(x => x.warehouse !== 'SPOILT')
          : data.filter(x => x.warehouse === warehouse)

        const byModel = new Map<string, { model: string; qty: number; places: number }>()
        for (const x of src) {
          const k = priceKey(x.model)
          const e = byModel.get(k)
          if (e) { e.qty += Math.max(0, x.closing_stock); e.places += 1 }
          else byModel.set(k, { model: x.model, qty: Math.max(0, x.closing_stock), places: 1 })
        }

        const rows = Array.from(byModel.values())
          .filter(r => !q || r.model.toLowerCase().includes(q))
          .filter(r => !priceOnlyUnpriced || !(prices.get(priceKey(r.model)) ?? 0))
          .sort((a, b) => a.model.localeCompare(b.model))

        const norm = (raw: string) => Math.max(0, Math.round((parseFloat(raw) || 0) * 100) / 100)
        const changedCount = Object.entries(priceDraft)
          .filter(([model, raw]) => norm(raw) !== (prices.get(priceKey(model)) ?? 0)).length

        return (
          <div style={{ marginBottom: 20, padding: 20, borderRadius: 14, border: '1px solid #34d39940', background: T.card, boxShadow: T.shadow }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6, flexWrap: 'wrap', gap: 10 }}>
              <div>
                <span style={{ color: T.text, fontWeight: 800, fontSize: 14 }}>💰 Set Prices</span>
                <div style={{ color: T.sub, fontSize: 11, fontVariantNumeric: 'tabular-nums', marginTop: 3 }}>
                  One price per model, wherever it is stocked. It fills in automatically on every invoice line.
                </div>
              </div>
              <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                {changedCount > 0 && (
                  <button onClick={() => setPriceDraft({})} disabled={savingPrices}
                    style={{ padding: '8px 14px', borderRadius: 8, background: 'transparent', border: `1px solid ${T.inputBorder}`, color: T.sub, fontWeight: 700, fontSize: 11, cursor: savingPrices ? 'not-allowed' : 'pointer' }}>
                    Discard
                  </button>
                )}
                <button onClick={handleSavePrices} disabled={savingPrices || changedCount === 0}
                  style={{ padding: '8px 18px', borderRadius: 8, background: changedCount ? '#34d399' : T.input, color: changedCount ? '#052e1a' : T.sub, fontWeight: 900, fontSize: 11, letterSpacing: '0.08em', border: changedCount ? 'none' : `1px solid ${T.inputBorder}`, cursor: (savingPrices || !changedCount) ? 'not-allowed' : 'pointer', display: 'flex', alignItems: 'center', gap: 8 }}>
                  {savingPrices ? <><Spinner color={T.sub} /> SAVING…</> : `SAVE ${changedCount || ''} PRICE${changedCount === 1 ? '' : 'S'}`}
                </button>
              </div>
            </div>

            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', margin: '14px 0' }}>
              <input value={priceQuery} onChange={e => setPriceQuery(e.target.value)} placeholder="Search model…"
                style={{ ...inp, flex: '1 1 240px', minWidth: 0, fontSize: 14 }} />
              <button onClick={() => setPriceOnlyUnpriced(v => !v)}
                style={{ padding: '9px 14px', borderRadius: 8, fontSize: 11, fontWeight: 800, letterSpacing: '0.06em', border: 'none', cursor: 'pointer', background: priceOnlyUnpriced ? '#f59e0b' : 'rgba(245,158,11,0.12)', color: priceOnlyUnpriced ? '#3b2200' : '#f59e0b', whiteSpace: 'nowrap' }}>
                ⚠ UNPRICED ONLY ({stats.unpriced})
              </button>
            </div>

            <div style={{ maxHeight: 460, overflowY: 'auto', borderRadius: 10, border: `1px solid ${T.border}` }}>
              <table style={{ width: '100%', borderCollapse: 'collapse' }}>
                <thead>
                  <tr>
                    <th style={{ ...thStyle, cursor: 'default', position: 'sticky', top: 0, zIndex: 1, textAlign: 'left' }}>Model</th>
                    <th style={{ ...thStyle, cursor: 'default', position: 'sticky', top: 0, zIndex: 1, textAlign: 'center', width: 90 }}>In Stock</th>
                    <th style={{ ...thStyle, cursor: 'default', position: 'sticky', top: 0, zIndex: 1, textAlign: 'right', width: 150 }}>Price GH¢</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map(r => {
                    const saved = prices.get(priceKey(r.model)) ?? 0
                    const raw   = priceDraft[r.model]
                    const shown = raw !== undefined ? raw : (saved ? String(saved) : '')
                    const dirty = raw !== undefined && norm(raw) !== saved
                    return (
                      <tr key={priceKey(r.model)}>
                        <td style={{ ...tdStyle, fontVariantNumeric: 'tabular-nums' }}>
                          {r.model}
                          {r.places > 1 && (
                            <span style={{ marginLeft: 8, fontSize: 10, color: T.muted }}>in {r.places} locations</span>
                          )}
                        </td>
                        <td style={{ ...tdStyle, textAlign: 'center', fontVariantNumeric: 'tabular-nums', color: r.qty > 0 ? T.sub : '#ef4444' }}>
                          {r.qty.toLocaleString()}
                        </td>
                        <td style={{ ...tdStyle, textAlign: 'right' }}>
                          <input type="number" min="0" step="0.01" value={shown} placeholder="0.00"
                            onChange={e => setPriceDraft(d => ({ ...d, [r.model]: e.target.value }))}
                            style={{
                              ...inp, width: 120, padding: '6px 10px', fontSize: 13, textAlign: 'right',
                              fontVariantNumeric: 'tabular-nums',
                              borderColor: dirty ? '#34d399' : saved > 0 ? T.inputBorder : '#f59e0b',
                            }} />
                        </td>
                      </tr>
                    )
                  })}
                  {rows.length === 0 && (
                    <tr><td colSpan={3} style={{ ...tdStyle, textAlign: 'center', color: T.sub }}>No models match.</td></tr>
                  )}
                </tbody>
              </table>
            </div>

            <div style={{ marginTop: 12, fontSize: 11, color: T.sub, fontVariantNumeric: 'tabular-nums' }}>
              {rows.length.toLocaleString()} model{rows.length === 1 ? '' : 's'} shown ·
              stock on hand worth GH¢ {stats.value.toLocaleString('en-GH', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
            </div>
          </div>
        )
      })()}

      {/* ── Warehouse management panel ── */}
      {manageWh && (
        <div style={{ marginBottom: 20, padding: 20, borderRadius: 14, border: '1px solid #7c3aed40', background: T.card, boxShadow: T.shadow }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
            <span style={{ color: T.text, fontWeight: 800, fontSize: 14 }}>🏭 Manage Warehouses</span>
            <button onClick={() => setWhModal({})} style={{
              padding: '7px 14px', borderRadius: 8, background: '#7c3aed',
              color: '#fff', fontWeight: 700, fontSize: 11, border: 'none', cursor: 'pointer',
            }}>+ NEW WAREHOUSE</button>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(240px,1fr))', gap: 10 }}>
            {warehouses.map(wh => (
              <div key={wh.id} style={{
                padding: '14px 16px', borderRadius: 12,
                border: `1px solid ${wh.color}30`,
                background: darkMode ? 'rgba(0,0,0,0.2)' : 'rgba(0,0,0,0.03)',
                display: 'flex', justifyContent: 'space-between', alignItems: 'center',
              }}>
                <div>
                  <Badge label={wh.name} color={wh.color} />
                  <div style={{ color: T.sub, fontSize: 10, marginTop: 6, fontVariantNumeric: 'tabular-nums' }}>
                    {data.filter(x => x.warehouse === wh.name).length} items · {wh.date_columns.length} day columns
                  </div>
                </div>
                <div style={{ display: 'flex', gap: 6 }}>
                  <button onClick={() => setWhModal(wh)} style={{
                    padding: '5px 10px', borderRadius: 6, background: `${T.teal}18`,
                    color: T.teal, fontSize: 11, fontWeight: 700, border: `1px solid ${T.teal}30`, cursor: 'pointer',
                  }}>Edit</button>
                  <button onClick={() => handleDeleteWarehouse(wh)} style={{
                    padding: '5px 10px', borderRadius: 6, background: 'rgba(239,68,68,0.1)',
                    color: '#ef4444', fontSize: 11, fontWeight: 700, border: '1px solid rgba(239,68,68,0.2)', cursor: 'pointer',
                  }}>Del</button>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* ── Stats ── */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(120px,1fr))', gap: 10, marginBottom: 24 }}>
        {[
          { label: 'Total SKUs',   value: stats.total,                    color: T.teal },
          { label: 'Healthy',      value: stats.ok,                       color: '#34d399' },
          { label: 'Low / Empty',  value: stats.low,                      color: '#f87171' },
          { label: 'Units Moved',  value: stats.taken.toLocaleString(),    color: '#38bdf8' },
        ].map(s => (
          <div key={s.label} style={{ padding: 16, borderRadius: 12, border: `1px solid ${s.color}25`, background: T.card, boxShadow: T.shadow, transition: 'all 0.3s' }}>
            <div style={{ color: s.color, fontSize: 24, fontWeight: 900, lineHeight: 1 }}>{s.value}</div>
            <div style={{ color: T.sub, fontSize: 10, fontVariantNumeric: 'tabular-nums', marginTop: 4, letterSpacing: '0.1em' }}>{s.label.toUpperCase()}</div>
          </div>
        ))}
      </div>

      {/* ── Warehouse pills + status filters ── */}
      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 14, alignItems: 'center' }}>
        {['ALL', ...warehouses.map(w => w.name)].map(w => (
          <button key={w} onClick={() => { setWarehouse(w); setPage(1); setViewDates(false) }} style={{
            padding: '7px 14px', borderRadius: 8, fontSize: 11, fontWeight: 700,
            letterSpacing: '0.08em', border: 'none', cursor: 'pointer', transition: 'all 0.2s',
            background: warehouse === w ? (wColor(w) || T.teal) : T.tag,
            color: warehouse === w ? '#ffffff' : T.sub,
            outline: warehouse === w ? 'none' : `1px solid ${T.border}`,
          }}>{w}</button>
        ))}
        <div style={{ marginLeft: 'auto', display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {([['all','ALL'],['low','⚠ LOW'],['zero','✕ EMPTY']] as const).map(([val, label]) => (
            <button key={val} onClick={() => { setFilter(val); setPage(1) }} style={{
              padding: '7px 12px', borderRadius: 8, fontSize: 11, fontWeight: 700,
              letterSpacing: '0.06em', border: 'none', cursor: 'pointer', transition: 'all 0.2s',
              background: filter === val ? (val === 'zero' ? '#ef4444' : val === 'low' ? '#f59e0b' : T.teal) : T.tag,
              color: filter === val ? '#ffffff' : T.sub,
              outline: filter === val ? 'none' : `1px solid ${T.border}`,
            }}>{label}</button>
          ))}
          {neverCount > 0 && (
            <button onClick={() => { setHideNever(v => !v); setPage(1) }}
              title="Products listed here that have never held or moved a unit in this location"
              style={{
                padding: '7px 12px', borderRadius: 8, fontSize: 11, fontWeight: 700,
                border: 'none', cursor: 'pointer', transition: 'all 0.2s',
                background: hideNever ? T.tag : T.teal, color: hideNever ? T.sub : '#ffffff',
                outline: hideNever ? `1px solid ${T.border}` : 'none',
              }}>
              {hideNever ? `+ SHOW ${neverCount.toLocaleString()} NEVER STOCKED` : `HIDE ${neverCount.toLocaleString()} NEVER STOCKED`}
            </button>
          )}
          {warehouse !== 'ALL' && (
            <button onClick={() => setViewDates(d => !d)} style={{
              padding: '7px 12px', borderRadius: 8, fontSize: 11, fontWeight: 700,
              border: 'none', cursor: 'pointer', transition: 'all 0.2s',
              background: viewDates ? '#7c3aed' : T.tag,
              color: viewDates ? '#fff' : T.sub,
              outline: viewDates ? 'none' : `1px solid ${T.border}`,
            }}>📅 {viewDates ? 'HIDE DATES' : 'SHOW DATES'}</button>
          )}
        </div>
      </div>

      {/* ── Search ── */}
      <div style={{ position: 'relative', maxWidth: 480, marginBottom: 20 }}>
        <span style={{ position: 'absolute', left: 12, top: '50%', transform: 'translateY(-50%)', color: T.sub, pointerEvents: 'none' }}>⌕</span>
        <input value={query} onChange={e => { setQuery(e.target.value); setPage(1) }}
          placeholder="Search model or scan number…"
          style={{ ...inp, width: '100%', paddingLeft: 32, paddingRight: query ? 32 : 14, boxSizing: 'border-box' }} />
        {query && (
          <button onClick={() => setQuery('')} style={{ position: 'absolute', right: 10, top: '50%', transform: 'translateY(-50%)', background: 'none', border: 'none', color: T.sub, cursor: 'pointer', fontSize: 14 }}>✕</button>
        )}
      </div>

      {/* ── Selected item detail card ── */}
      {selected && (
        <div style={{ marginBottom: 20, padding: 20, borderRadius: 14, border: `1px solid ${statusColor(selected, T.teal)}40`, background: T.card, boxShadow: T.shadow, transition: 'all 0.3s' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', flexWrap: 'wrap', gap: 12 }}>
            <div>
              <div style={{ fontVariantNumeric: 'tabular-nums', fontWeight: 900, color: T.text, fontSize: 15, marginBottom: 6 }}>{selected.model}</div>
              <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                <Badge label={selected.warehouse} color={wColor(selected.warehouse)} />
                <Badge label={statusLabel(selected)} color={statusColor(selected, T.teal)} />
              </div>
            </div>
            <div style={{ display: 'flex', gap: 8 }}>
              <button onClick={() => { setStockModal({ ...selected }); setSelected(null) }}
                style={{ padding: '7px 14px', borderRadius: 8, background: T.teal, color: '#fff', fontSize: 11, fontWeight: 700, border: 'none', cursor: 'pointer' }}>✏️ Edit</button>
              <button onClick={() => setSelected(null)}
                style={{ background: 'none', border: 'none', color: T.sub, cursor: 'pointer', fontSize: 18 }}>✕</button>
            </div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(110px,1fr))', gap: 10, marginTop: 16 }}>
            {[
              { label: 'Opening',    value: selected.opening_stock, color: T.sub },
              // The three ways a unit moves, shown only where they apply, so
              // a closing figure can be read back to its cause.
              ...(selected.transfer_in   ? [{ label: 'Transferred In',  value: selected.transfer_in,   color: T.teal    }] : []),
              ...(selected.transfer_out  ? [{ label: 'Transferred Out', value: selected.transfer_out,  color: '#38bdf8' }] : []),
              ...(selected.invoice_taken ? [{ label: 'Invoiced',        value: selected.invoice_taken, color: '#a78bfa' }] : []),
              { label: 'Total Taken',value: selected.total_taken,   color: '#f59e0b' },
              { label: 'Closing',    value: selected.closing_stock, color: statusColor(selected, T.teal) },
              { label: 'Min Level',  value: selected.min_level ?? '—', color: T.muted },
            ].map(f => (
              <div key={f.label} style={{ padding: 12, background: darkMode ? 'rgba(0,0,0,0.2)' : 'rgba(0,0,0,0.04)', borderRadius: 10 }}>
                <div style={{ color: T.sub, fontSize: 10, letterSpacing: '0.1em', marginBottom: 4 }}>{f.label.toUpperCase()}</div>
                <div style={{ color: f.color, fontWeight: 900, fontSize: 20, fontVariantNumeric: 'tabular-nums' }}>
                  {typeof f.value === 'number' ? f.value.toLocaleString() : f.value}
                </div>
              </div>
            ))}
          </div>
          {Object.keys(selected.daily_taken).length > 0 && (
            <div style={{ marginTop: 14 }}>
              <div style={{ color: T.sub, fontSize: 10, letterSpacing: '0.1em', marginBottom: 8 }}>DAILY BREAKDOWN</div>
              <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                {Object.entries(dayTotals(selected.daily_taken))
                  .sort((a, b) => parseInt(a[0]) - parseInt(b[0]))
                  .map(([day, qty]) => (
                  <div key={day} style={{ padding: '6px 10px', borderRadius: 8, textAlign: 'center', background: `${T.teal}15`, border: `1px solid ${T.teal}30` }}>
                    <div style={{ color: T.sub, fontSize: 9, letterSpacing: '0.1em' }}>DAY {day}</div>
                    <div style={{ color: T.teal, fontWeight: 900, fontSize: 14, fontVariantNumeric: 'tabular-nums' }}>{qty}</div>
                  </div>
                ))}
              </div>
            </div>
          )}
          {stockedIn(selected) > 0 && (
            <div style={{ marginTop: 14 }}>
              <div style={{ color: T.sub, fontSize: 10, marginBottom: 6, letterSpacing: '0.1em' }}>
                STOCK LEVEL — {Math.round((selected.closing_stock / stockedIn(selected)) * 100)}% remaining
              </div>
              <StockBar pct={(selected.closing_stock / stockedIn(selected)) * 100} color={statusColor(selected, T.teal)} />
            </div>
          )}
        </div>
      )}

      {/* ── Table ── */}
      <div style={{ borderRadius: 14, border: `1px solid ${T.border}`, overflow: 'auto', background: T.card, boxShadow: T.shadow, transition: 'all 0.3s' }}>
        <table style={{ width: '100%', borderCollapse: 'collapse', minWidth: viewDates ? '900px' : '600px' }}>
          <thead>
            <tr>
              <th onClick={() => handleSort('model')}         style={{ ...thStyle, textAlign: 'left', minWidth: 220 }}>MODEL / PRODUCT <SortArrow k="model" /></th>
              <th onClick={() => handleSort('warehouse')}     style={{ ...thStyle, textAlign: 'center' }}>WAREHOUSE <SortArrow k="warehouse" /></th>
              <th onClick={() => handleSort('opening_stock')} style={{ ...thStyle, textAlign: 'right'  }}>OPENING <SortArrow k="opening_stock" /></th>
              {viewDates && activeDates.map(day => (
                <th key={day} style={{ ...thStyle, textAlign: 'center', minWidth: 44, color: '#7c3aed', fontWeight: 900 }}>{day}</th>
              ))}
              <th onClick={() => handleSort('total_taken')}   style={{ ...thStyle, textAlign: 'right'  }}>TAKEN <SortArrow k="total_taken" /></th>
              <th onClick={() => handleSort('closing_stock')} style={{ ...thStyle, textAlign: 'right'  }}>CLOSING <SortArrow k="closing_stock" /></th>
              <th style={{ ...thStyle, textAlign: 'right', cursor: 'default' }}>PRICE GH¢</th>
              <th style={{ ...thStyle, textAlign: 'center', cursor: 'default' }}>STATUS</th>
              <th style={{ ...thStyle, textAlign: 'center', cursor: 'default' }}>ACTIONS</th>
            </tr>
          </thead>
          <tbody>
            {pageItems.length === 0 ? (
              <tr>
                <td colSpan={9 + (viewDates ? activeDates.length : 0)}
                  style={{ ...tdStyle, textAlign: 'center', padding: 56, color: T.muted, fontVariantNumeric: 'tabular-nums' }}>
                  No items match your filters
                </td>
              </tr>
            ) : pageItems.map(item => {
              const sc  = statusColor(item, T.teal)
              const pct = stockedIn(item) > 0 ? (item.closing_stock / stockedIn(item)) * 100 : 0
              const dt  = dayTotals(item.daily_taken)
              return (
                <tr key={item.id}
                  onClick={() => setSelected(s => s?.id === item.id ? null : item)}
                  style={{ cursor: 'pointer', transition: 'background 0.1s' }}
                  onMouseEnter={e => (e.currentTarget.style.background = T.rowHover)}
                  onMouseLeave={e => (e.currentTarget.style.background = 'transparent')}>
                  <td style={tdStyle}>
                    <div style={{ fontVariantNumeric: 'tabular-nums', fontSize: 12, fontWeight: 600, marginBottom: 4, color: T.text }}>{item.model}</div>
                    <StockBar pct={pct} color={sc} />
                  </td>
                  <td style={{ ...tdStyle, textAlign: 'center' }}>
                    <Badge label={item.warehouse} color={wColor(item.warehouse)} />
                  </td>
                  <td style={{ ...tdStyle, textAlign: 'right', fontVariantNumeric: 'tabular-nums', color: T.sub }}>{item.opening_stock.toLocaleString()}</td>
                  {viewDates && activeDates.map(day => (
                    <td key={day} style={{ ...tdStyle, textAlign: 'center', fontVariantNumeric: 'tabular-nums', padding: '10px 4px' }}>
                      {dt[day]
                        ? <span style={{ color: '#f59e0b', fontWeight: 700, fontSize: 11 }}>{dt[day]}</span>
                        : <span style={{ color: T.border, fontSize: 11 }}>·</span>}
                    </td>
                  ))}
                  <td style={{ ...tdStyle, textAlign: 'right', fontVariantNumeric: 'tabular-nums', color: '#f59e0b', fontWeight: 700 }}>{item.total_taken.toLocaleString()}</td>
                  <td style={{ ...tdStyle, textAlign: 'right', fontVariantNumeric: 'tabular-nums', fontWeight: 900, color: sc, fontSize: 13 }}>{item.closing_stock.toLocaleString()}</td>
                  {/* The model's selling price. The Big Boss clicks it to set or
                      change it; everyone else just reads it. SPOILT is not for
                      sale, so it carries no price. */}
                  <td style={{ ...tdStyle, textAlign: 'right', fontVariantNumeric: 'tabular-nums', whiteSpace: 'nowrap' }} onClick={e => e.stopPropagation()}>
                    {(() => {
                      const price = prices.get(priceKey(item.model)) ?? 0
                      if (item.warehouse === 'SPOILT') return <span style={{ color: T.muted }}>—</span>
                      if (priceEdit?.id === item.id) return (
                        <input
                          autoFocus type="number" min="0" step="0.01" inputMode="decimal"
                          value={priceEdit.value} disabled={savingPrice}
                          onChange={e => setPriceEdit({ ...priceEdit, value: e.target.value })}
                          onKeyDown={e => { if (e.key === 'Enter') savePriceEdit(); if (e.key === 'Escape') setPriceEdit(null) }}
                          onBlur={savePriceEdit}
                          title="Enter to save · Esc to cancel · this price applies to this model in every warehouse"
                          style={{ width: 96, padding: '5px 7px', borderRadius: 6, textAlign: 'right', fontVariantNumeric: 'tabular-nums', fontSize: 12,
                            border: `1px solid ${T.teal}`, background: T.input, color: T.text, outline: 'none' }} />
                      )
                      if (!isSuperBoss) return price > 0
                        ? <span style={{ color: T.text }}>{price.toLocaleString('en-GH', { minimumFractionDigits: 2 })}</span>
                        : <span style={{ color: '#f59e0b', fontSize: 10, fontWeight: 800 }}>UNPRICED</span>
                      return (
                        <button
                          onClick={() => setPriceEdit({ id: item.id, model: item.model, value: price > 0 ? String(price) : '' })}
                          title="Click to change. Applies to this model in every warehouse."
                          style={{ padding: '4px 8px', borderRadius: 6, cursor: 'pointer', fontVariantNumeric: 'tabular-nums', fontSize: 12,
                            border: `1px dashed ${price > 0 ? T.inputBorder : '#f59e0b'}`, background: 'transparent',
                            color: price > 0 ? T.text : '#f59e0b', fontWeight: price > 0 ? 600 : 800 }}>
                          {price > 0 ? price.toLocaleString('en-GH', { minimumFractionDigits: 2 }) : '+ Set price'}
                        </button>
                      )
                    })()}
                  </td>
                  <td style={{ ...tdStyle, textAlign: 'center' }}><Badge label={statusLabel(item)} color={sc} /></td>
                  <td style={{ ...tdStyle, textAlign: 'center' }} onClick={e => e.stopPropagation()}>
                    <div style={{ display: 'flex', gap: 6, justifyContent: 'center' }}>
                      <button onClick={() => setStockModal({ ...item })} style={{
                        padding: '5px 10px', borderRadius: 6, background: `${T.teal}18`,
                        color: T.teal, fontSize: 11, fontWeight: 700, border: `1px solid ${T.teal}30`, cursor: 'pointer',
                      }}>Edit</button>
                      <button onClick={() => handleDeleteStock(item.id, item.model)} style={{
                        padding: '5px 10px', borderRadius: 6, background: 'rgba(239,68,68,0.1)',
                        color: '#ef4444', fontSize: 11, fontWeight: 700, border: '1px solid rgba(239,68,68,0.2)', cursor: 'pointer',
                      }}>Del</button>
                    </div>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>

      {/* ── Pagination ── */}
      {pages > 1 && (
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: 16, flexWrap: 'wrap', gap: 10 }}>
          <span style={{ color: T.sub, fontSize: 12, fontVariantNumeric: 'tabular-nums' }}>{filtered.length} items · page {page}/{pages}</span>
          <div style={{ display: 'flex', gap: 4 }}>
            <button onClick={() => setPage(p => Math.max(1, p-1))} disabled={page===1} style={{
              padding: '7px 14px', borderRadius: 8, fontSize: 12, fontWeight: 700, border: 'none',
              cursor: page===1 ? 'not-allowed' : 'pointer', background: T.tag, color: page===1 ? T.muted : T.text,
            }}>← Prev</button>
            {Array.from({ length: Math.min(5, pages) }, (_, idx) => {
              const pg = page <= 3 ? idx+1 : page >= pages-2 ? pages-4+idx : page-2+idx
              if (pg < 1 || pg > pages) return null
              return (
                <button key={pg} onClick={() => setPage(pg)} style={{
                  padding: '7px 12px', borderRadius: 8, fontSize: 12, fontWeight: 700, border: 'none', cursor: 'pointer',
                  background: page===pg ? T.teal : T.tag, color: page===pg ? '#ffffff' : T.text,
                }}>{pg}</button>
              )
            })}
            <button onClick={() => setPage(p => Math.min(pages, p+1))} disabled={page===pages} style={{
              padding: '7px 14px', borderRadius: 8, fontSize: 12, fontWeight: 700, border: 'none',
              cursor: page===pages ? 'not-allowed' : 'pointer', background: T.tag, color: page===pages ? T.muted : T.text,
            }}>Next →</button>
          </div>
        </div>
      )}

      {/* ── Modals ── */}
      {stockModal && (
        <StockModal item={stockModal} warehouses={warehouses} T={T} dark={darkMode}
          onClose={() => setStockModal(null)} onSave={handleSaveStock} />
      )}
      {whModal && (
        <WarehouseModal wh={whModal} T={T} dark={darkMode}
          onClose={() => setWhModal(null)} onSave={handleSaveWarehouse} />
      )}
    </div>
  )
}