'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import { Plus, Trash2, X } from 'lucide-react'
import { GHS } from '@/lib/sales'
import { fetchLineStock, fetchLocations, modelKey, STORE, SPOILT, type StockRow } from '@/lib/storeStock'
import {
  fetchSupplierBalances, fetchSupplierDocs, fetchProductCosts, saveSupplier, receiveFromSupplier,
  paySupplier, returnToSupplier, voidSupplierDoc, setProductCost, KIND_LABEL,
  type SupplierBalance, type SupplierDoc, type ProductCost,
} from '@/lib/suppliers'

const ACCENT = '#0a7cff'
type View = 'suppliers' | 'receive' | 'pay' | 'return' | 'costs'
const VIEWS: { key: View; label: string; write?: boolean }[] = [
  { key: 'suppliers', label: 'Suppliers' },
  { key: 'receive',   label: 'Receive goods', write: true },
  { key: 'pay',       label: 'Pay supplier',  write: true },
  { key: 'return',    label: 'Return spoilt', write: true },
  { key: 'costs',     label: 'Costs' },
]

const today = () => new Date().toISOString().slice(0, 10)
const fmtDate = (d: string) => new Date(d + (d.length === 10 ? 'T12:00:00' : '')).toLocaleDateString('en-GB')

const fld: React.CSSProperties = {
  width: '100%', padding: '9px 12px', borderRadius: 8, fontSize: 14, outline: 'none',
  border: '1px solid var(--qb-input-border)', background: 'var(--qb-input)', color: 'var(--qb-text)',
}
const lbl: React.CSSProperties = { fontSize: 10, fontWeight: 800, color: ACCENT, letterSpacing: '0.18em', textTransform: 'uppercase', display: 'block', marginBottom: 5 }
const card: React.CSSProperties = { padding: 18, borderRadius: 14, border: '1px solid var(--qb-border)', background: 'var(--qb-card)' }
const btn = (primary = true, disabled = false): React.CSSProperties => ({
  padding: '10px 16px', borderRadius: 10, border: primary ? 'none' : '1px solid var(--qb-border)', fontWeight: 700, fontSize: 14,
  background: disabled ? 'var(--qb-fill)' : primary ? ACCENT : 'var(--qb-fill)',
  color: disabled ? 'var(--qb-muted)' : primary ? '#fff' : 'var(--qb-text)', cursor: disabled ? 'not-allowed' : 'pointer',
})
const tnum: React.CSSProperties = { fontVariantNumeric: 'tabular-nums' }

interface Line { key: number; model: string; quantity: string; unit_cost: string }
let lineKey = 0
const newLine = (): Line => ({ key: ++lineKey, model: '', quantity: '1', unit_cost: '' })

export default function Suppliers({ canWrite, notify }: { canWrite: boolean; notify: (text: string, type?: 'ok' | 'err') => void }) {
  const [view, setView] = useState<View>('suppliers')
  const [balances, setBalances] = useState<SupplierBalance[]>([])
  const [docs, setDocs] = useState<SupplierDoc[]>([])
  const [costs, setCosts] = useState<ProductCost[]>([])
  const [stock, setStock] = useState<StockRow[]>([])
  const [locations, setLocations] = useState<string[]>([])
  const [loading, setLoading] = useState(true)
  const [open, setOpen] = useState<string | null>(null) // supplier whose statement is shown

  const reload = useCallback(async () => {
    try {
      const [b, d, c, s, l] = await Promise.all([
        fetchSupplierBalances(), fetchSupplierDocs(), fetchProductCosts(), fetchLineStock('main'), fetchLocations('main'),
      ])
      setBalances(b); setDocs(d); setCosts(c); setStock(s); setLocations(l)
    } catch (e: any) {
      notify(e.message?.includes('supplier') || e.code === '42P01'
        ? 'Supplier tables are missing — run 20261117_suppliers_and_costs.sql in Supabase.'
        : e.message || 'Could not load suppliers', 'err')
    } finally { setLoading(false) }
  }, [notify])
  useEffect(() => { reload() }, [reload])

  const costByKey = useMemo(() => new Map(costs.map(c => [c.model_key, c.unit_cost])), [costs])
  const modelNames = useMemo(() => Array.from(new Set(stock.map(r => r.model))).sort(), [stock])
  const totals = balances.reduce((t, b) => ({ owed: t.owed + Math.max(b.balance, 0), received: t.received + b.received, paid: t.paid + b.paid }), { owed: 0, received: 0, paid: 0 })

  const views = VIEWS.filter(v => canWrite || !v.write)

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 18, maxWidth: 1100 }}>
      <datalist id="qb-supplier-models">{modelNames.map(m => <option key={m} value={m} />)}</datalist>

      {/* Summary */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(200px,1fr))', gap: 12 }}>
        {[
          { label: 'We owe suppliers', value: totals.owed, strong: true },
          { label: 'Goods received (all time)', value: totals.received },
          { label: 'Paid to suppliers', value: totals.paid },
        ].map(s => (
          <div key={s.label} style={card}>
            <div style={{ color: 'var(--qb-sub)', fontSize: 12, fontWeight: 600 }}>{s.label}</div>
            <div style={{ ...tnum, marginTop: 4, fontSize: 22, fontWeight: 800, color: s.strong && s.value > 0 ? 'var(--qb-orange)' : 'var(--qb-text)' }}>{GHS(s.value)}</div>
          </div>
        ))}
      </div>

      {/* Sections */}
      <div role="tablist" style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
        {views.map(v => (
          <button key={v.key} role="tab" aria-selected={view === v.key} onClick={() => setView(v.key)}
            style={{ padding: '8px 14px', borderRadius: 999, fontSize: 14, fontWeight: 600, cursor: 'pointer',
              border: '1px solid ' + (view === v.key ? ACCENT : 'var(--qb-border)'),
              background: view === v.key ? ACCENT : 'var(--qb-card)', color: view === v.key ? '#fff' : 'var(--qb-text)' }}>
            {v.label}
          </button>
        ))}
      </div>

      {loading && <div style={{ ...card, textAlign: 'center', color: 'var(--qb-muted)' }}>Loading…</div>}

      {!loading && view === 'suppliers' && (
        <SupplierList balances={balances} docs={docs} canWrite={canWrite} open={open} setOpen={setOpen} notify={notify} reload={reload} />
      )}
      {!loading && view === 'receive' && canWrite && (
        <ItemsForm mode="receive" balances={balances} locations={locations} costByKey={costByKey} stock={stock} notify={notify}
          onDone={() => { reload(); setView('suppliers') }} />
      )}
      {!loading && view === 'return' && canWrite && (
        <ItemsForm mode="return" balances={balances} locations={locations} costByKey={costByKey} stock={stock} notify={notify}
          onDone={() => { reload(); setView('suppliers') }} />
      )}
      {!loading && view === 'pay' && canWrite && (
        <PaymentForm balances={balances} notify={notify} onDone={() => { reload(); setView('suppliers') }} />
      )}
      {!loading && view === 'costs' && (
        <CostsView costs={costs} stock={stock} canWrite={canWrite} notify={notify} reload={reload} />
      )}
    </div>
  )
}

// ── Supplier list and statements ─────────────────────────────
function SupplierList({ balances, docs, canWrite, open, setOpen, notify, reload }: {
  balances: SupplierBalance[]; docs: SupplierDoc[]; canWrite: boolean; open: string | null
  setOpen: (id: string | null) => void; notify: (t: string, k?: 'ok' | 'err') => void; reload: () => Promise<void>
}) {
  const [name, setName] = useState('')
  const [phone, setPhone] = useState('')
  const [saving, setSaving] = useState(false)

  async function add(e: React.FormEvent) {
    e.preventDefault()
    if (!name.trim()) return
    setSaving(true)
    try { await saveSupplier(null, name, phone); setName(''); setPhone(''); notify(`${name.trim()} added`); await reload() }
    catch (err: any) { notify(err.message, 'err') }
    finally { setSaving(false) }
  }

  const supplier = balances.find(b => b.id === open)

  return (
    <>
      {canWrite && (
        <form onSubmit={add} style={{ ...card, display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(200px,1fr))', gap: 12, alignItems: 'end' }}>
          <div><label style={lbl}>New supplier</label><input style={fld} value={name} onChange={e => setName(e.target.value)} placeholder="Company name" /></div>
          <div><label style={lbl}>Phone</label><input style={fld} value={phone} onChange={e => setPhone(e.target.value)} placeholder="Optional" /></div>
          <button type="submit" disabled={saving || !name.trim()} style={btn(true, saving || !name.trim())}>{saving ? 'Adding…' : 'Add supplier'}</button>
        </form>
      )}

      <div style={{ ...card, padding: 0, overflow: 'hidden' }}>
        <div style={{ overflowX: 'auto' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 14, minWidth: 640 }}>
            <thead>
              <tr style={{ background: 'var(--qb-header)', color: ACCENT, fontSize: 10, letterSpacing: '0.15em', textAlign: 'left' }}>
                <th style={{ padding: '10px 14px' }}>SUPPLIER</th>
                <th style={{ padding: '10px 14px', textAlign: 'right' }}>RECEIVED</th>
                <th style={{ padding: '10px 14px', textAlign: 'right' }}>RETURNED</th>
                <th style={{ padding: '10px 14px', textAlign: 'right' }}>PAID</th>
                <th style={{ padding: '10px 14px', textAlign: 'right' }}>BALANCE</th>
              </tr>
            </thead>
            <tbody>
              {balances.length === 0 && (
                <tr><td colSpan={5} style={{ padding: 30, textAlign: 'center', color: 'var(--qb-muted)' }}>No suppliers yet.</td></tr>
              )}
              {balances.map(b => (
                <tr key={b.id} onClick={() => setOpen(open === b.id ? null : b.id)}
                  style={{ borderTop: '1px solid var(--qb-separator)', cursor: 'pointer', background: open === b.id ? 'var(--qb-row-hover)' : undefined }}>
                  <td style={{ padding: '11px 14px', color: 'var(--qb-text)', fontWeight: 600 }}>
                    {b.name}
                    <div style={{ color: 'var(--qb-muted)', fontSize: 12, fontWeight: 400 }}>
                      {[b.phone, b.last_activity && `last ${fmtDate(b.last_activity)}`].filter(Boolean).join(' · ') || '—'}
                    </div>
                  </td>
                  <td style={{ ...tnum, padding: '11px 14px', textAlign: 'right' }}>{GHS(b.received)}</td>
                  <td style={{ ...tnum, padding: '11px 14px', textAlign: 'right' }}>{GHS(b.returned)}</td>
                  <td style={{ ...tnum, padding: '11px 14px', textAlign: 'right' }}>{GHS(b.paid)}</td>
                  <td style={{ ...tnum, padding: '11px 14px', textAlign: 'right', fontWeight: 800,
                    color: b.balance > 0 ? 'var(--qb-orange)' : b.balance < 0 ? 'var(--qb-green)' : 'var(--qb-text)' }}>
                    {GHS(Math.abs(b.balance))}
                    <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--qb-muted)' }}>{b.balance > 0 ? 'we owe' : b.balance < 0 ? 'in credit' : 'settled'}</div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {supplier && (
        <Statement supplier={supplier} docs={docs.filter(d => d.supplier_id === supplier.id)} canWrite={canWrite}
          onClose={() => setOpen(null)} notify={notify} reload={reload} />
      )}
    </>
  )
}

function Statement({ supplier, docs, canWrite, onClose, notify, reload }: {
  supplier: SupplierBalance; docs: SupplierDoc[]; canWrite: boolean; onClose: () => void
  notify: (t: string, k?: 'ok' | 'err') => void; reload: () => Promise<void>
}) {
  // Oldest first, so the running balance reads down the page.
  const rows = useMemo(() => {
    let run = 0
    return [...docs].reverse().map(d => {
      if (!d.voided_at) run += d.kind === 'received' ? d.amount : -d.amount
      return { d, run }
    })
  }, [docs])

  async function voidDoc(d: SupplierDoc) {
    const reason = window.prompt(`Void ${d.number}? It stays on the statement, struck out.${d.stock_booked ? ' Its stock change is undone.' : ''}\n\nReason:`)
    if (reason === null) return
    try { await voidSupplierDoc(d.id, reason); notify(`${d.number} voided`); await reload() }
    catch (e: any) { notify(e.message, 'err') }
  }

  return (
    <div style={{ ...card, display: 'flex', flexDirection: 'column', gap: 12 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 12 }}>
        <div>
          <div style={{ fontSize: 18, fontWeight: 700, color: 'var(--qb-text)' }}>{supplier.name} — statement</div>
          <div style={{ color: 'var(--qb-sub)', fontSize: 13 }}>Balance {GHS(supplier.balance)} {supplier.balance > 0 ? '(we owe)' : ''}</div>
        </div>
        <button onClick={onClose} aria-label="Close statement" className="qb-icon-btn"><X size={17} /></button>
      </div>
      {rows.length === 0 && <div style={{ color: 'var(--qb-muted)', padding: 12 }}>Nothing recorded for this supplier yet.</div>}
      {rows.length > 0 && (
        <div style={{ overflowX: 'auto' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13.5, minWidth: 720 }}>
            <thead>
              <tr style={{ color: ACCENT, fontSize: 10, letterSpacing: '0.15em', textAlign: 'left' }}>
                <th style={{ padding: 8 }}>DATE</th><th style={{ padding: 8 }}>NUMBER</th><th style={{ padding: 8 }}>DETAILS</th>
                <th style={{ padding: 8, textAlign: 'right' }}>OWED +</th><th style={{ padding: 8, textAlign: 'right' }}>PAID / CREDIT −</th>
                <th style={{ padding: 8, textAlign: 'right' }}>BALANCE</th>{canWrite && <th />}
              </tr>
            </thead>
            <tbody>
              {rows.map(({ d, run }) => {
                const struck: React.CSSProperties = d.voided_at ? { textDecoration: 'line-through', opacity: 0.5 } : {}
                return (
                  <tr key={d.id} style={{ borderTop: '1px solid var(--qb-separator)', verticalAlign: 'top' }}>
                    <td style={{ ...tnum, ...struck, padding: 8, whiteSpace: 'nowrap' }}>{fmtDate(d.doc_date)}</td>
                    <td style={{ ...struck, padding: 8, whiteSpace: 'nowrap', fontWeight: 600 }}>{d.number}</td>
                    <td style={{ padding: 8 }}>
                      <div style={struck}>
                        <b>{KIND_LABEL[d.kind]}</b>
                        {d.location && <> · {d.kind === 'returned' ? 'from' : 'into'} {d.location}</>}
                        {d.ref && <> · ref {d.ref}</>}
                        {d.transfer_number && <> · {d.transfer_number}</>}
                      </div>
                      {d.items.length > 0 && (
                        <div style={{ ...struck, color: 'var(--qb-sub)', marginTop: 2 }}>
                          {d.items.map(i => `${i.quantity} × ${i.model} @ ${GHS(i.unit_cost)}`).join(' · ')}
                        </div>
                      )}
                      {d.note && <div style={{ ...struck, color: 'var(--qb-muted)' }}>{d.note}</div>}
                      {d.voided_at && <div style={{ color: 'var(--qb-red)', fontSize: 12 }}>Voided {fmtDate(d.voided_at.slice(0, 10))}{d.void_reason ? ` — ${d.void_reason}` : ''}</div>}
                    </td>
                    <td style={{ ...tnum, ...struck, padding: 8, textAlign: 'right' }}>{d.kind === 'received' ? GHS(d.amount) : ''}</td>
                    <td style={{ ...tnum, ...struck, padding: 8, textAlign: 'right' }}>{d.kind !== 'received' ? GHS(d.amount) : ''}</td>
                    <td style={{ ...tnum, padding: 8, textAlign: 'right', fontWeight: 700 }}>{GHS(run)}</td>
                    {canWrite && (
                      <td style={{ padding: 8 }}>
                        {!d.voided_at && <button onClick={() => voidDoc(d)} title="Void this record" style={{ ...btn(false), padding: '4px 10px', fontSize: 12 }}>Void</button>}
                      </td>
                    )}
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}

// ── Receiving goods, and returning spoilt goods ──────────────
function ItemsForm({ mode, balances, locations, costByKey, stock, notify, onDone }: {
  mode: 'receive' | 'return'; balances: SupplierBalance[]; locations: string[]; costByKey: Map<string, number>
  stock: StockRow[]; notify: (t: string, k?: 'ok' | 'err') => void; onDone: () => void
}) {
  const receiving = mode === 'receive'
  const [supplierId, setSupplierId] = useState('')
  const [date, setDate] = useState(today)
  const [place, setPlace] = useState(() => receiving ? STORE : (locations.includes(SPOILT) ? SPOILT : STORE))
  const [bookStock, setBookStock] = useState(true)
  const [ref, setRef] = useState('')
  const [note, setNote] = useState('')
  const [lines, setLines] = useState<Line[]>(() => [newLine()])
  const [saving, setSaving] = useState(false)

  const placeOptions = receiving ? locations.filter(l => l !== SPOILT) : locations
  // What the chosen location holds, for the return form.
  const held = useMemo(() => {
    const m = new Map<string, number>()
    for (const r of stock) if (r.warehouse === place) m.set(modelKey(r.model), (m.get(modelKey(r.model)) || 0) + r.closing_stock)
    return m
  }, [stock, place])
  const heldModels = useMemo(() => stock.filter(r => r.warehouse === place && r.closing_stock > 0).map(r => r.model).sort(), [stock, place])

  const setLine = (key: number, patch: Partial<Line>) => setLines(ls => ls.map(l => {
    if (l.key !== key) return l
    const next = { ...l, ...patch }
    // Fill in the known cost when a product is picked and no cost typed yet.
    if (patch.model !== undefined && !l.unit_cost) {
      const c = costByKey.get(modelKey(patch.model))
      if (c !== undefined) next.unit_cost = String(c)
    }
    return next
  }))

  const valid = lines.filter(l => l.model.trim() && Number(l.quantity) > 0)
  const total = valid.reduce((s, l) => s + Number(l.quantity) * (Number(l.unit_cost) || 0), 0)

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    if (!supplierId) return notify('Pick a supplier', 'err')
    if (!valid.length) return notify('Add at least one item', 'err')
    if (!receiving) {
      const short = valid.find(l => (held.get(modelKey(l.model)) || 0) < Number(l.quantity))
      if (short) return notify(`${place} holds only ${held.get(modelKey(short.model)) || 0} × ${short.model}`, 'err')
    }
    setSaving(true)
    try {
      const items = valid.map(l => ({
        model: l.model.trim(), quantity: Math.floor(Number(l.quantity)),
        ...(l.unit_cost !== '' ? { unit_cost: Number(l.unit_cost) } : {}),
      }))
      const doc = receiving
        ? await receiveFromSupplier({ supplierId, items, date, to: place, bookStock, ref, note })
        : await returnToSupplier({ supplierId, items, from: place, date, ref, note })
      notify(`${doc.number} saved — ${GHS(Number(doc.amount))}`)
      onDone()
    } catch (err: any) { notify(err.message, 'err') }
    finally { setSaving(false) }
  }

  return (
    <form onSubmit={submit} style={{ ...card, display: 'flex', flexDirection: 'column', gap: 14 }}>
      <div>
        <div style={{ fontSize: 18, fontWeight: 700, color: 'var(--qb-text)' }}>{receiving ? 'Goods received from a supplier' : 'Spoilt goods back to the supplier'}</div>
        <div style={{ color: 'var(--qb-sub)', fontSize: 13, marginTop: 2 }}>
          {receiving
            ? 'Adds the cost to what you owe the supplier and, if ticked, books the units into stock. The unit cost becomes the product\'s cost price.'
            : 'Takes the units out of the chosen location and credits the supplier at cost.'}
        </div>
      </div>

      {balances.length === 0 && <div style={{ color: 'var(--qb-orange)', fontSize: 14 }}>Add a supplier on the Suppliers section first.</div>}

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(180px,1fr))', gap: 12 }}>
        <div>
          <label style={lbl}>Supplier *</label>
          <select style={fld} value={supplierId} onChange={e => setSupplierId(e.target.value)}>
            <option value="">Choose…</option>
            {balances.map(b => <option key={b.id} value={b.id}>{b.name}</option>)}
          </select>
        </div>
        <div><label style={lbl}>Date</label><input type="date" style={fld} value={date} onChange={e => setDate(e.target.value)} /></div>
        <div>
          <label style={lbl}>{receiving ? 'Into location' : 'Take from'}</label>
          <select style={fld} value={place} onChange={e => setPlace(e.target.value)} disabled={receiving && !bookStock}>
            {placeOptions.map(l => <option key={l} value={l}>{l}</option>)}
          </select>
        </div>
        <div><label style={lbl}>Supplier ref</label><input style={fld} value={ref} onChange={e => setRef(e.target.value)} placeholder="Invoice / waybill no." /></div>
      </div>

      {receiving && (
        <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 14, color: 'var(--qb-text)' }}>
          <input type="checkbox" checked={bookStock} onChange={e => setBookStock(e.target.checked)} />
          Also add these units to stock (untick if they were already received on the Transfers tab)
        </label>
      )}

      <datalist id={`qb-held-${mode}`}>{heldModels.map(m => <option key={m} value={m} />)}</datalist>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 90px 130px 120px 36px', gap: 8, ...lbl, marginBottom: 0 }}>
          <span>Product</span><span>Qty</span><span>Unit cost GH₵</span><span style={{ textAlign: 'right' }}>Line total</span><span />
        </div>
        {lines.map(l => {
          const have = held.get(modelKey(l.model))
          return (
            <div key={l.key} style={{ display: 'grid', gridTemplateColumns: '1fr 90px 130px 120px 36px', gap: 8, alignItems: 'center' }}>
              <div>
                <input style={fld} value={l.model} onChange={e => setLine(l.key, { model: e.target.value })}
                  list={receiving ? 'qb-supplier-models' : `qb-held-${mode}`} placeholder="Model / product name" />
                {!receiving && l.model.trim() && (
                  <div style={{ fontSize: 11.5, color: have ? 'var(--qb-muted)' : 'var(--qb-red)', marginTop: 2 }}>
                    {have ? `${place} holds ${have}` : `Not in ${place}`}
                  </div>
                )}
              </div>
              <input style={fld} type="number" min="1" step="1" value={l.quantity} onChange={e => setLine(l.key, { quantity: e.target.value })} />
              <input style={fld} type="number" min="0" step="0.01" value={l.unit_cost} onChange={e => setLine(l.key, { unit_cost: e.target.value })}
                placeholder={receiving ? '0.00' : 'cost price'} />
              <div style={{ ...tnum, textAlign: 'right', color: 'var(--qb-text)', fontWeight: 600 }}>
                {GHS((Number(l.quantity) || 0) * (Number(l.unit_cost) || 0))}
              </div>
              <button type="button" aria-label="Remove line" className="qb-icon-btn" disabled={lines.length === 1}
                onClick={() => setLines(ls => ls.filter(x => x.key !== l.key))}><Trash2 size={15} /></button>
            </div>
          )
        })}
        <button type="button" onClick={() => setLines(ls => [...ls, newLine()])} style={{ ...btn(false), width: 'fit-content', display: 'inline-flex', alignItems: 'center', gap: 6 }}>
          <Plus size={15} /> Add line
        </button>
      </div>

      <div><label style={lbl}>Note</label><input style={fld} value={note} onChange={e => setNote(e.target.value)} placeholder="Optional" /></div>

      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
        <div style={{ ...tnum, fontSize: 18, fontWeight: 800, color: 'var(--qb-text)' }}>
          {receiving ? 'Total cost' : 'Credit from supplier'}: {GHS(total)}
        </div>
        <button type="submit" disabled={saving || !supplierId || !valid.length} style={btn(true, saving || !supplierId || !valid.length)}>
          {saving ? 'Saving…' : receiving ? 'Save goods received' : 'Save return'}
        </button>
      </div>
    </form>
  )
}

// ── Payments ─────────────────────────────────────────────────
function PaymentForm({ balances, notify, onDone }: { balances: SupplierBalance[]; notify: (t: string, k?: 'ok' | 'err') => void; onDone: () => void }) {
  const [supplierId, setSupplierId] = useState('')
  const [amount, setAmount] = useState('')
  const [date, setDate] = useState(today)
  const [ref, setRef] = useState('')
  const [note, setNote] = useState('')
  const [saving, setSaving] = useState(false)
  const owed = balances.find(b => b.id === supplierId)?.balance

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    const amt = Number(amount)
    if (!supplierId || !(amt > 0)) return notify('Pick a supplier and enter the amount', 'err')
    setSaving(true)
    try { const d = await paySupplier({ supplierId, amount: amt, date, ref, note }); notify(`${d.number} saved — ${GHS(amt)} paid`); onDone() }
    catch (err: any) { notify(err.message, 'err') }
    finally { setSaving(false) }
  }

  return (
    <form onSubmit={submit} style={{ ...card, display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(180px,1fr))', gap: 12, alignItems: 'end' }}>
      <div>
        <label style={lbl}>Supplier *</label>
        <select style={fld} value={supplierId} onChange={e => setSupplierId(e.target.value)}>
          <option value="">Choose…</option>
          {balances.map(b => <option key={b.id} value={b.id}>{b.name}</option>)}
        </select>
        {owed !== undefined && <div style={{ ...tnum, fontSize: 12, color: 'var(--qb-muted)', marginTop: 3 }}>Balance {GHS(owed)}</div>}
      </div>
      <div><label style={lbl}>Amount GH₵ *</label><input style={fld} type="number" min="0" step="0.01" value={amount} onChange={e => setAmount(e.target.value)} placeholder="0.00" /></div>
      <div><label style={lbl}>Date</label><input type="date" style={fld} value={date} onChange={e => setDate(e.target.value)} /></div>
      <div><label style={lbl}>Receipt / ref</label><input style={fld} value={ref} onChange={e => setRef(e.target.value)} placeholder="MoMo / cheque / receipt no." /></div>
      <div style={{ gridColumn: '1 / -1' }}><label style={lbl}>Note</label><input style={fld} value={note} onChange={e => setNote(e.target.value)} placeholder="Optional" /></div>
      <button type="submit" disabled={saving} style={{ ...btn(true, saving), gridColumn: '1 / -1' }}>{saving ? 'Saving…' : 'Record payment'}</button>
    </form>
  )
}

// ── Costs: cost price per product, and what the stock is worth ─
function CostsView({ costs, stock, canWrite, notify, reload }: {
  costs: ProductCost[]; stock: StockRow[]; canWrite: boolean; notify: (t: string, k?: 'ok' | 'err') => void; reload: () => Promise<void>
}) {
  const [search, setSearch] = useState('')
  const [editing, setEditing] = useState<string | null>(null)
  const [draft, setDraft] = useState('')
  const [newModel, setNewModel] = useState('')
  const [newCost, setNewCost] = useState('')

  // On hand per product across every sellable location (SPOILT left out).
  const rows = useMemo(() => {
    const onHand = new Map<string, { model: string; qty: number }>()
    for (const r of stock) {
      if (r.warehouse === SPOILT) continue
      const k = modelKey(r.model)
      const cur = onHand.get(k)
      onHand.set(k, { model: cur?.model || r.model, qty: (cur?.qty || 0) + Math.max(r.closing_stock, 0) })
    }
    const out = costs.map(c => ({ ...c, qty: onHand.get(c.model_key)?.qty || 0 }))
    const costed = new Set(costs.map(c => c.model_key))
    const uncosted = Array.from(onHand.entries()).filter(([k, v]) => !costed.has(k) && v.qty > 0).map(([, v]) => v)
    return { out, uncosted }
  }, [costs, stock])

  const q = search.trim().toLowerCase()
  const shown = rows.out.filter(r => !q || r.model.toLowerCase().includes(q))
  const value = rows.out.reduce((s, r) => s + r.qty * r.unit_cost, 0)

  async function save(model: string, cost: string) {
    const n = Number(cost)
    if (cost === '' || !(n >= 0)) return notify('Enter a cost of 0 or more', 'err')
    try { await setProductCost(model, n); notify(`Cost of ${model} set to ${GHS(n)}`); setEditing(null); setNewModel(''); setNewCost(''); await reload() }
    catch (e: any) { notify(e.message, 'err') }
  }

  return (
    <>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(200px,1fr))', gap: 12 }}>
        <div style={card}>
          <div style={{ color: 'var(--qb-sub)', fontSize: 12, fontWeight: 600 }}>Stock value at cost</div>
          <div style={{ ...tnum, marginTop: 4, fontSize: 22, fontWeight: 800, color: 'var(--qb-text)' }}>{GHS(value)}</div>
          <div style={{ color: 'var(--qb-muted)', fontSize: 12 }}>All locations except SPOILT</div>
        </div>
        <div style={card}>
          <div style={{ color: 'var(--qb-sub)', fontSize: 12, fontWeight: 600 }}>Products with a cost price</div>
          <div style={{ ...tnum, marginTop: 4, fontSize: 22, fontWeight: 800, color: 'var(--qb-text)' }}>{rows.out.length}</div>
          <div style={{ color: rows.uncosted.length ? 'var(--qb-orange)' : 'var(--qb-muted)', fontSize: 12 }}>
            {rows.uncosted.length} in stock with no cost yet
          </div>
        </div>
      </div>

      {canWrite && (
        <div style={{ ...card, display: 'grid', gridTemplateColumns: '1fr 160px auto', gap: 10, alignItems: 'end' }}>
          <div>
            <label style={lbl}>Set a cost price</label>
            <input style={fld} value={newModel} onChange={e => setNewModel(e.target.value)} list="qb-supplier-models" placeholder="Model / product name" />
          </div>
          <div><label style={lbl}>Cost GH₵</label><input style={fld} type="number" min="0" step="0.01" value={newCost} onChange={e => setNewCost(e.target.value)} /></div>
          <button type="button" style={btn(true, !newModel.trim())} disabled={!newModel.trim()} onClick={() => save(newModel.trim(), newCost)}>Save</button>
        </div>
      )}

      <input value={search} onChange={e => setSearch(e.target.value)} placeholder="Search products…" style={{ ...fld, maxWidth: 420 }} />
      <div style={{ ...card, padding: 0, overflow: 'hidden' }}>
        <div style={{ overflowX: 'auto' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 14, minWidth: 620 }}>
            <thead>
              <tr style={{ background: 'var(--qb-header)', color: ACCENT, fontSize: 10, letterSpacing: '0.15em', textAlign: 'left' }}>
                <th style={{ padding: '10px 14px' }}>PRODUCT</th>
                <th style={{ padding: '10px 14px', textAlign: 'right' }}>COST GH₵</th>
                <th style={{ padding: '10px 14px', textAlign: 'right' }}>ON HAND</th>
                <th style={{ padding: '10px 14px', textAlign: 'right' }}>VALUE</th>
                <th style={{ padding: '10px 14px' }}>FROM</th>
              </tr>
            </thead>
            <tbody>
              {shown.length === 0 && <tr><td colSpan={5} style={{ padding: 30, textAlign: 'center', color: 'var(--qb-muted)' }}>No cost prices yet. They are filled in when goods are received.</td></tr>}
              {shown.slice(0, 300).map(r => (
                <tr key={r.model_key} style={{ borderTop: '1px solid var(--qb-separator)' }}>
                  <td style={{ padding: '10px 14px', color: 'var(--qb-text)' }}>{r.model}</td>
                  <td style={{ ...tnum, padding: '10px 14px', textAlign: 'right' }}>
                    {editing === r.model_key ? (
                      <span style={{ display: 'inline-flex', gap: 6 }}>
                        <input autoFocus style={{ ...fld, width: 110, padding: '5px 8px' }} type="number" min="0" step="0.01" value={draft}
                          onChange={e => setDraft(e.target.value)} onKeyDown={e => { if (e.key === 'Enter') save(r.model, draft); if (e.key === 'Escape') setEditing(null) }} />
                        <button type="button" style={{ ...btn(), padding: '4px 10px' }} onClick={() => save(r.model, draft)}>OK</button>
                      </span>
                    ) : (
                      <button type="button" disabled={!canWrite} onClick={() => { setEditing(r.model_key); setDraft(String(r.unit_cost)) }}
                        title={canWrite ? 'Change cost price' : undefined}
                        style={{ background: 'none', border: 'none', color: 'var(--qb-text)', cursor: canWrite ? 'pointer' : 'default', font: 'inherit', ...tnum }}>
                        {GHS(r.unit_cost)}
                      </button>
                    )}
                  </td>
                  <td style={{ ...tnum, padding: '10px 14px', textAlign: 'right' }}>{r.qty}</td>
                  <td style={{ ...tnum, padding: '10px 14px', textAlign: 'right', fontWeight: 700 }}>{GHS(r.qty * r.unit_cost)}</td>
                  <td style={{ padding: '10px 14px', color: 'var(--qb-muted)', fontSize: 12.5 }}>{r.source === 'manual' ? 'Set by hand' : r.source}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {rows.uncosted.length > 0 && (
        <details style={card}>
          <summary style={{ cursor: 'pointer', color: 'var(--qb-text)', fontWeight: 600 }}>In stock with no cost price ({rows.uncosted.length})</summary>
          <div style={{ marginTop: 10, color: 'var(--qb-sub)', fontSize: 13.5, lineHeight: 1.7 }}>
            {rows.uncosted.slice(0, 400).map(u => `${u.model} (${u.qty})`).join(' · ')}
          </div>
        </details>
      )}
    </>
  )
}
