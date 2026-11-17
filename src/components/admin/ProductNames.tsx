'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import { fetchLineStock, mergeStockModel, modelKey, type StockLine, type StockRow } from '@/lib/storeStock'
import ModelPicker from '@/components/admin/ModelPicker'

/**
 * Product names — finding one product stocked under two names, and folding
 * them together.
 *
 * Stock is keyed on the model name, per warehouse. The same product under
 * two spellings is, to the system, two products: the piles cannot be moved
 * into each other, a sale comes off one and never the other, and neither
 * figure is the count. This is where the Big Boss puts that right.
 *
 * It SUGGESTS and never decides. Two lists, by how sure the match is:
 *
 *   same code       identical once case, spaces and punctuation are ignored
 *                   ("DS-7208HGHI-M1" / "ds-7208hghi m1").
 *   possibly same   one name is the start of the other ("EAP225" /
 *                   "EAP225 Wireless ceiling mount"). Often the same thing
 *                   with a description added — but a bare code can also be a
 *                   different pack or lens, so these are never pre-selected.
 *
 * A third list shows where this line and the other one spell a shared
 * product differently, which is what makes a cross-line move open a new row.
 *
 * The merge itself is `merge_stock_model` (20261005_merge_product_names.sql):
 * one transaction, quantities added, barcodes carried over.
 */

const TEAL = '#0a7cff'
const AMBER = '#f59e0b'

interface NameInfo {
  model: string
  places: { warehouse: string; qty: number }[]
  total: number
}

interface Group {
  /** 'same' = identical code; 'maybe' = one name starts the other. */
  kind: 'same' | 'maybe'
  names: NameInfo[]
}

function summarise(rows: StockRow[]): Map<string, NameInfo> {
  const out = new Map<string, NameInfo>()
  for (const r of rows) {
    let info = out.get(r.model)
    if (!info) { info = { model: r.model, places: [], total: 0 }; out.set(r.model, info) }
    const place = info.places.find(p => p.warehouse === r.warehouse)
    if (place) place.qty += r.closing_stock
    else info.places.push({ warehouse: r.warehouse, qty: r.closing_stock })
    info.total += r.closing_stock
  }
  return out
}

/** The name most of the shop already uses: most locations, then most units, then the fuller name. */
const byWeight = (a: NameInfo, b: NameInfo) =>
  b.places.length - a.places.length || b.total - a.total || b.model.length - a.model.length

function findGroups(infos: Map<string, NameInfo>): Group[] {
  const byKey = new Map<string, NameInfo[]>()
  for (const info of Array.from(infos.values())) {
    const k = modelKey(info.model)
    if (!k) continue
    byKey.set(k, [...(byKey.get(k) || []), info])
  }

  const groups: Group[] = []
  for (const names of Array.from(byKey.values())) {
    if (names.length > 1) groups.push({ kind: 'same', names: [...names].sort(byWeight) })
  }

  // A short name that starts a longer one. Five characters is the floor:
  // below that "DS-2" would claim half the catalogue.
  const keys = Array.from(byKey.keys()).sort()
  for (let i = 0; i < keys.length; i++) {
    if (keys[i].length < 5) continue
    const longer: NameInfo[] = []
    // Sorted, so everything a key prefixes sits directly after it.
    for (let j = i + 1; j < keys.length && keys[j].startsWith(keys[i]); j++) longer.push(...byKey.get(keys[j])!)
    if (longer.length) groups.push({ kind: 'maybe', names: [...byKey.get(keys[i])!, ...longer.sort(byWeight)] })
  }
  return groups
}

export default function ProductNames({ dark, accent }: {
  dark: boolean
  accent?: string
}) {
  const A = accent ?? TEAL
  // Colours come from the --qb-* tokens (src/app/qb-ios.css).
  const T = { card: 'var(--qb-card)', border: 'var(--qb-border)', text: 'var(--qb-text)', sub: 'var(--qb-sub)', input: 'var(--qb-input)', inputBorder: 'var(--qb-input-border)' }

  const [open, setOpen] = useState(false)
  const line: StockLine = 'main'
  const [stock, setStock] = useState<Record<StockLine, StockRow[]>>({ main: [] })
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<{ text: string; ok: boolean } | null>(null)
  // The name each group keeps, once the boss has chosen one; otherwise the heaviest.
  const [keep, setKeep] = useState<Record<string, string>>({})
  const [manualFrom, setManualFrom] = useState('')
  const [manualInto, setManualInto] = useState('')

  const load = useCallback(async () => {
    setLoading(true)
    try {
      setStock({ main: await fetchLineStock('main') })
    } catch {
      setMsg({ text: 'Could not read the stock lists', ok: false })
    }
    setLoading(false)
  }, [])
  useEffect(() => { load() }, [load])

  const infos = useMemo(() => summarise(stock[line]), [stock, line])
  const groups = useMemo(() => findGroups(infos), [infos])
  const sure = groups.filter(g => g.kind === 'same')
  const maybe = groups.filter(g => g.kind === 'maybe')

  const where = (n: NameInfo) => n.places.map(p => `${p.warehouse} ${p.qty.toLocaleString()}`).join(' · ')

  const merge = async (pairs: { from: string; into: string }[]) => {
    const todo = pairs.filter(p => p.from && p.into && p.from !== p.into)
    if (!todo.length) return
    const detail = todo.map(p => {
      const n = infos.get(p.from)
      return `• “${p.from}”${n ? ` (${where(n)})` : ''}\n   becomes “${p.into}”`
    }).join('\n')
    if (!confirm(
      `Merge these names?\n\n${detail}\n\n` +
      `In every warehouse the quantities are added together and the old name disappears. ` +
      `Barcodes follow. Past invoices and movement records keep the name they were written with.\n\n` +
      `This cannot be undone from the app.`,
    )) return

    setBusy(true)
    setMsg(null)
    let done = 0
    try {
      for (const p of todo) { await mergeStockModel(line, p.from, p.into); done++ }
      setMsg({ text: `${done} name${done === 1 ? '' : 's'} merged ✓`, ok: true })
    } catch (e: any) {
      setMsg({ text: `${done ? `${done} merged, then: ` : ''}${e.message || 'Merge failed'}`, ok: false })
    }
    setBusy(false)
    setManualFrom(''); setManualInto('')
    load()
  }

  const total = sure.length + maybe.length
  const fld: React.CSSProperties = {
    width: '100%', padding: '9px 12px', borderRadius: 8, fontSize: 14, outline: 'none',
    border: `1px solid ${T.inputBorder}`, background: T.input, color: T.text,
  }
  const btn = (strong: boolean): React.CSSProperties => ({
    padding: '6px 11px', borderRadius: 7, cursor: busy ? 'wait' : 'pointer', fontSize: 11.5, fontWeight: 800,
    whiteSpace: 'nowrap', opacity: busy ? 0.55 : 1,
    border: strong ? 'none' : `1px solid ${T.inputBorder}`,
    background: strong ? A : 'transparent', color: strong ? '#fff' : A,
  })
  const head: React.CSSProperties = { fontSize: 10, fontWeight: 800, letterSpacing: '0.16em', color: A, margin: '18px 0 4px' }
  const pickerTheme = { menuBg: T.card, border: T.inputBorder, text: T.text, sub: T.sub, accent: A, accentText: '#fff' }
  const nameOptions = useMemo(
    () => Array.from(infos.values()).sort((a, b) => a.model.localeCompare(b.model)).map(n => ({ model: n.model, qty: n.total })),
    [infos],
  )

  const renderGroup = (g: Group, i: number) => {
    const id = `${g.kind}:${g.names.map(n => n.model).join('|')}`
    // A bare code is rarely the name worth keeping; the fuller one says what it is.
    const kept = keep[id] && g.names.some(n => n.model === keep[id]) ? keep[id]
      : (g.kind === 'maybe' ? g.names[1] : g.names[0]).model
    const others = g.names.filter(n => n.model !== kept)
    return (
      <div key={id} style={{ padding: '10px 12px', borderRadius: 10, border: `1px solid ${T.border}`, marginTop: 8 }}>
        {g.names.map(n => (
          <div key={n.model} style={{ display: 'flex', gap: 10, alignItems: 'center', padding: '5px 0', flexWrap: 'wrap' }}>
            <label style={{ display: 'flex', gap: 8, alignItems: 'center', flex: '1 1 260px', minWidth: 0, cursor: 'pointer' }}>
              <input type="radio" name={`keep-${line}-${g.kind}-${i}`} checked={n.model === kept}
                onChange={() => setKeep(k => ({ ...k, [id]: n.model }))} />
              <span style={{ minWidth: 0 }}>
                <span style={{ fontVariantNumeric: 'tabular-nums', fontSize: 13, color: T.text, fontWeight: n.model === kept ? 800 : 400, wordBreak: 'break-word' }}>{n.model}</span>
                <span style={{ display: 'block', fontSize: 11, color: T.sub }}>{where(n)}</span>
              </span>
            </label>
            {n.model === kept
              ? <span style={{ fontSize: 11, fontWeight: 800, color: A }}>KEEP</span>
              : <button type="button" disabled={busy} style={btn(false)} onClick={() => merge([{ from: n.model, into: kept }])}>
                  Merge into kept
                </button>}
          </div>
        ))}
        {g.kind === 'same' && others.length > 1 && (
          <button type="button" disabled={busy} style={{ ...btn(true), marginTop: 6 }}
            onClick={() => merge(others.map(n => ({ from: n.model, into: kept })))}>
            Merge all {others.length} into kept
          </button>
        )}
      </div>
    )
  }

  return (
    <div style={{ maxWidth: 980, padding: 18, borderRadius: 12, background: T.card, border: `1px solid ${T.border}`, marginTop: 22 }}>
      <div style={{ display: 'flex', gap: 12, alignItems: 'center', flexWrap: 'wrap' }}>
        <div style={{ fontWeight: 900, fontSize: 15, color: T.text }}>Product names</div>
        {!loading && (
          <span style={{ fontSize: 12, fontWeight: 700, color: total ? AMBER : T.sub }}>
            {total ? `${total} to check` : 'No doubled names found'}
          </span>
        )}
        <button type="button" onClick={() => setOpen(o => !o)} style={{ ...btn(false), marginLeft: 'auto' }}>
          {open ? 'Hide' : 'Show'}
        </button>
      </div>

      {open && (
        <>
          <div style={{ fontSize: 12, color: T.sub, margin: '8px 0 12px' }}>
            One product under two names is counted as two products. Pick the name to keep, then merge the other into it:
            quantities are added together in every warehouse and barcodes follow. Nothing here is merged until you confirm it.
          </div>

          {msg && (
            <div style={{ marginTop: 12, fontSize: 12.5, fontWeight: 700, color: msg.ok ? A : '#ef4444' }}>{msg.text}</div>
          )}

          {loading ? (
            <div style={{ color: T.sub, fontSize: 13, marginTop: 14 }}>Loading…</div>
          ) : (
            <>
              {sure.length > 0 && (
                <>
                  <div style={head}>SAME CODE, WRITTEN DIFFERENTLY · {sure.length}</div>
                  <div style={{ fontSize: 11.5, color: T.sub }}>These differ only in capitals, spaces or punctuation.</div>
                  {sure.map(renderGroup)}
                </>
              )}

              {maybe.length > 0 && (
                <>
                  <div style={{ ...head, color: AMBER }}>POSSIBLY THE SAME · {maybe.length}</div>
                  <div style={{ fontSize: 11.5, color: T.sub }}>
                    One name is the start of the other. Often the same product with a description added — but check the
                    shelf first: a different lens, pack size or kit is a different product and must stay separate.
                  </div>
                  {maybe.map(renderGroup)}
                </>
              )}


              <div style={head}>ANY TWO NAMES</div>
              <div style={{ fontSize: 11.5, color: T.sub, marginBottom: 8 }}>
                For the ones no rule can spot — the same product under completely different wording.
              </div>
              <div style={{ display: 'flex', gap: 8, alignItems: 'flex-start', flexWrap: 'wrap' }}>
                <div style={{ flex: '1 1 240px', minWidth: 0 }}>
                  <ModelPicker value={manualFrom} options={nameOptions} onChange={setManualFrom}
                    inputStyle={fld} placeholder="The name to get rid of" theme={pickerTheme}
                    emptyHint="Nothing is stocked under that name" />
                </div>
                <div style={{ flex: '1 1 240px', minWidth: 0 }}>
                  <ModelPicker value={manualInto} options={nameOptions} onChange={setManualInto}
                    inputStyle={fld} placeholder="The name to keep — or type a better one" theme={pickerTheme}
                    emptyHint="A new name — the product will be renamed to it" />
                </div>
                <button type="button"
                  // The old name is sent exactly as stored: some carry a stray
                  // space, and trimming it would mean it is never found.
                  disabled={busy || !infos.has(manualFrom) || !manualInto.trim() || manualFrom === manualInto.trim()}
                  style={{ ...btn(true), padding: '10px 16px', opacity: busy || !infos.has(manualFrom) || !manualInto.trim() ? 0.55 : 1 }}
                  onClick={() => merge([{ from: manualFrom, into: manualInto.trim() }])}>
                  Merge
                </button>
              </div>
            </>
          )}
        </>
      )}
    </div>
  )
}
