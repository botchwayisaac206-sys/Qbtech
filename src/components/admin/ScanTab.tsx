'use client'

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Camera, ScanBarcode, Link2, RotateCw } from 'lucide-react'
import CameraScanner from '@/components/admin/CameraScanner'
import ModelPicker, { type PickerOption } from '@/components/admin/ModelPicker'
import { cleanCode, linkCode, loadCodeMap } from '@/lib/productCodes'
import { fetchLineStock, modelKey, STORE, SPOILT, type StockRow } from '@/lib/storeStock'
import { fetchPricelistMap, fetchStockModels, fetchLastSoldPrices, type LastSold } from '@/lib/adminCache'
import { GHS } from '@/lib/sales'
import { V } from '@/lib/qbTheme'

/**
 * Scan tab: point a scanner (USB wedge or the camera) at a box and see what
 * it is — its selling price, what each location holds, and when it last sold.
 * Looking only; nothing here moves stock. A barcode the shop has never seen
 * can be linked to its product, and from then on it scans everywhere
 * (invoices, transfers, the phone stock app).
 */

interface Hit {
  id: number
  code: string
  model: string | null   // null: an unlinked barcode
  at: Date
}

let hitId = 0

export default function ScanTab({ canLink }: { canLink: boolean }) {
  const [codeMap, setCodeMap] = useState<Map<string, string>>(new Map())
  const [stock, setStock] = useState<StockRow[]>([])
  const [prices, setPrices] = useState<Map<string, number>>(new Map())
  const [lastSold, setLastSold] = useState<Map<string, LastSold>>(new Map())
  const [models, setModels] = useState<string[]>([])
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [hits, setHits] = useState<Hit[]>([])
  const [current, setCurrent] = useState<Hit | null>(null)
  const [camera, setCamera] = useState(false)
  const [linkTo, setLinkTo] = useState('')
  const [linking, setLinking] = useState(false)
  const [linkError, setLinkError] = useState<string | null>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const lastRef = useRef<{ code: string; t: number }>({ code: '', t: 0 })

  const load = useCallback(async () => {
    setLoading(true); setLoadError(null)
    try {
      const [codes, rows, priceMap, sold, stockModels] = await Promise.all([
        loadCodeMap(),
        // Uncached on purpose: an on-hand figure minutes old misleads.
        fetchLineStock('main'),
        fetchPricelistMap(),
        fetchLastSoldPrices().catch(() => new Map<string, LastSold>()),
        fetchStockModels(),
      ])
      setCodeMap(codes); setStock(rows); setPrices(priceMap); setLastSold(sold); setModels(stockModels)
    } catch (e) {
      setLoadError(e instanceof Error ? e.message : 'Could not load stock')
    } finally {
      setLoading(false)
      inputRef.current?.focus()
    }
  }, [])
  useEffect(() => { load() }, [load])

  const handleScan = useCallback((raw: string) => {
    const code = cleanCode(raw)
    if (!code) return
    const now = Date.now()
    if (lastRef.current.code === code && now - lastRef.current.t < 800) return
    lastRef.current = { code, t: now }
    const hit: Hit = { id: ++hitId, code, model: codeMap.get(code) ?? null, at: new Date() }
    setCurrent(hit)
    setHits(h => [hit, ...h.filter(x => x.code !== code)].slice(0, 12))
    setLinkTo(''); setLinkError(null)
    try { navigator.vibrate?.(hit.model ? 35 : 70) } catch { /* no haptics */ }
  }, [codeMap])

  const doLink = async () => {
    if (!current || !linkTo.trim()) return
    setLinking(true); setLinkError(null)
    const { error } = await linkCode(current.code, linkTo)
    setLinking(false)
    if (error) { setLinkError(error); return }
    const model = linkTo.trim()
    setCodeMap(m => new Map(m).set(current.code, model))
    const linked = { ...current, model }
    setCurrent(linked)
    setHits(h => h.map(x => x.code === current.code ? { ...x, model } : x))
    inputRef.current?.focus()
  }

  // Stock per location for the scanned product, matched on the same key the
  // database uses, so a differently spelt row of the same product counts too.
  const detail = useMemo(() => {
    if (!current?.model) return null
    const key = modelKey(current.model)
    const byLoc = new Map<string, number>()
    for (const r of stock) {
      if (modelKey(r.model) !== key) continue
      byLoc.set(r.warehouse, (byLoc.get(r.warehouse) || 0) + r.closing_stock)
    }
    const locs = Array.from(byLoc).sort((a, b) =>
      a[0] === STORE ? -1 : b[0] === STORE ? 1 : a[0] === SPOILT ? 1 : b[0] === SPOILT ? -1 : a[0].localeCompare(b[0]))
    const sellable = locs.filter(([w]) => w !== SPOILT).reduce((s, [, q]) => s + q, 0)
    const price = prices.get(current.model.trim().toUpperCase())
      ?? Array.from(prices).find(([k]) => modelKey(k) === key)?.[1]
    const sold = lastSold.get(current.model.trim().toLowerCase())
    return { locs, sellable, inStore: byLoc.get(STORE) || 0, price, sold }
  }, [current, stock, prices, lastSold])

  const pickerOptions = useMemo<PickerOption[]>(() => models.map(model => ({ model })), [models])

  const card: React.CSSProperties = { background: V.card, border: `1px solid ${V.border}`, borderRadius: 18, padding: 20 }
  const fld: React.CSSProperties = {
    width: '100%', padding: '13px 15px', borderRadius: 12, fontSize: 16, outline: 'none', fontFamily: 'inherit',
    border: `1px solid ${V.inputBorder}`, background: V.input, color: V.text,
  }

  return (
    <div style={{ display: 'grid', gap: 16 }}>
      {/* The scan box: a USB scanner types into it and presses Enter. */}
      <div style={card}>
        <form onSubmit={e => { e.preventDefault(); const v = inputRef.current?.value ?? ''; if (inputRef.current) inputRef.current.value = ''; handleScan(v) }}
          style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
          <div style={{ position: 'relative', flex: '1 1 240px' }}>
            <ScanBarcode size={18} style={{ position: 'absolute', left: 14, top: '50%', transform: 'translateY(-50%)', color: V.muted }} />
            <input ref={inputRef} autoFocus placeholder={loading ? 'Loading products…' : 'Scan a barcode, or type it and press Enter'}
              disabled={loading} inputMode="text" autoComplete="off"
              style={{ ...fld, paddingLeft: 42, fontVariantNumeric: 'tabular-nums' }} />
          </div>
          <button type="button" onClick={() => setCamera(true)} disabled={loading}
            style={{ display: 'inline-flex', alignItems: 'center', gap: 8, padding: '0 18px', minHeight: 48, borderRadius: 12, border: 'none',
              background: V.accent, color: V.onAccent, fontWeight: 650, fontSize: 15, cursor: loading ? 'default' : 'pointer', fontFamily: 'inherit' }}>
            <Camera size={18} /> Camera
          </button>
          <button type="button" onClick={load} title="Reload stock and barcodes" aria-label="Reload" className="qb-icon-btn" style={{ width: 48, height: 48 }}>
            <RotateCw size={17} />
          </button>
        </form>
        {loadError && <div style={{ marginTop: 10, color: V.red, fontSize: 14 }}>{loadError}</div>}
      </div>

      {/* What was scanned */}
      {!current ? (
        <div style={{ ...card, textAlign: 'center', padding: '48px 20px', color: V.sub }}>
          <ScanBarcode size={40} strokeWidth={1.5} style={{ color: V.faint, marginBottom: 12 }} />
          <div style={{ fontSize: 17, fontWeight: 650, color: V.text }}>Scan any box</div>
          <div style={{ fontSize: 14, marginTop: 6 }}>See its price, how many are in the shop and in each warehouse, and when it last sold.</div>
        </div>
      ) : current.model && detail ? (
        <div style={card}>
          <div style={{ color: V.muted, fontSize: 12.5, fontVariantNumeric: 'tabular-nums' }}>{current.code}</div>
          <div style={{ color: V.text, fontSize: 22, fontWeight: 750, letterSpacing: '-0.01em', marginTop: 2, wordBreak: 'break-word' }}>{current.model}</div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))', gap: 10, marginTop: 16 }}>
            <Stat label="Selling price" value={detail.price ? GHS(detail.price) : '—'} />
            <Stat label="In the shop" value={String(detail.inStore)} tone={detail.inStore > 0 ? 'green' : 'red'} />
            <Stat label="Total in stock" value={String(detail.sellable)} />
            <Stat label="Last sold" value={detail.sold ? GHS(detail.sold.price) : '—'}
              sub={detail.sold ? new Date(detail.sold.issued_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : undefined} />
          </div>
          {detail.locs.length > 0 ? (
            <div style={{ marginTop: 16, borderTop: `1px solid ${V.separator}` }}>
              {detail.locs.map(([w, q]) => (
                <div key={w} style={{ display: 'flex', justifyContent: 'space-between', padding: '11px 2px', borderBottom: `1px solid ${V.separator}`, fontSize: 15 }}>
                  <span style={{ color: w === SPOILT ? V.muted : V.text, fontWeight: w === STORE ? 650 : 500 }}>{w}</span>
                  <span style={{ color: q > 0 ? V.text : V.muted, fontWeight: 650, fontVariantNumeric: 'tabular-nums' }}>{q}</span>
                </div>
              ))}
            </div>
          ) : (
            <div style={{ marginTop: 14, color: V.sub, fontSize: 14 }}>No location holds this product yet.</div>
          )}
        </div>
      ) : (
        <div style={card}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <span style={{ width: 36, height: 36, borderRadius: 10, display: 'grid', placeItems: 'center', background: V.amberSoft, color: V.amber }}><Link2 size={18} /></span>
            <div>
              <div style={{ color: V.text, fontSize: 17, fontWeight: 700 }}>New barcode</div>
              <div style={{ color: V.sub, fontSize: 13.5, fontVariantNumeric: 'tabular-nums' }}>{current.code} isn&apos;t linked to a product yet.</div>
            </div>
          </div>
          {canLink ? (
            <form onSubmit={e => { e.preventDefault(); doLink() }} style={{ marginTop: 16, display: 'grid', gap: 10 }}>
              <ModelPicker value={linkTo} options={pickerOptions} onChange={setLinkTo} theme={{ menuBg: 'var(--qb-input)', border: 'var(--qb-input-border)', text: 'var(--qb-text)', sub: 'var(--qb-muted)', accent: 'var(--qb-accent)', accentText: '#ffffff' }}
                inputStyle={fld} placeholder="Which product is it? Start typing…" />
              {linkError && <div style={{ color: V.red, fontSize: 14 }}>{linkError}</div>}
              <button type="submit" disabled={!linkTo.trim() || linking}
                style={{ padding: 13, borderRadius: 12, border: 'none', fontFamily: 'inherit', fontWeight: 650, fontSize: 15,
                  background: linkTo.trim() ? V.accent : V.fill, color: linkTo.trim() ? V.onAccent : V.sub, cursor: linkTo.trim() ? 'pointer' : 'default' }}>
                {linking ? 'Linking…' : 'Link barcode'}
              </button>
            </form>
          ) : (
            <div style={{ marginTop: 12, color: V.sub, fontSize: 14 }}>Ask a Boss to link it.</div>
          )}
        </div>
      )}

      {/* Recent scans this session */}
      {hits.length > 1 && (
        <div style={card}>
          <div style={{ color: V.muted, fontSize: 12, fontWeight: 700, letterSpacing: '0.06em', textTransform: 'uppercase', marginBottom: 6 }}>Recent scans</div>
          {hits.slice(1).map(h => (
            <button key={h.id} onClick={() => { setCurrent(h); setLinkTo(''); setLinkError(null) }}
              style={{ display: 'flex', width: '100%', justifyContent: 'space-between', gap: 12, padding: '10px 2px', border: 'none', borderBottom: `1px solid ${V.separator}`,
                background: 'transparent', cursor: 'pointer', textAlign: 'left', fontFamily: 'inherit', fontSize: 14.5 }}>
              <span style={{ color: h.model ? V.text : V.amber, fontWeight: 550, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{h.model ?? 'Unlinked barcode'}</span>
              <span style={{ color: V.muted, fontVariantNumeric: 'tabular-nums', flexShrink: 0 }}>{h.code}</span>
            </button>
          ))}
        </div>
      )}

      {camera && (
        <CameraScanner
          active
          banner={current ? (current.model ? { tone: 'ok', title: current.model } : { tone: 'warn', title: 'New barcode', sub: 'Close the camera to link it' }) : null}
          onDetect={handleScan}
          onClose={() => { setCamera(false); inputRef.current?.focus() }}
        />
      )}
    </div>
  )
}

function Stat({ label, value, sub, tone }: { label: string; value: string; sub?: string; tone?: 'green' | 'red' }) {
  return (
    <div style={{ background: V.fill, borderRadius: 14, padding: '12px 14px' }}>
      <div style={{ color: V.sub, fontSize: 12.5, fontWeight: 600 }}>{label}</div>
      <div style={{ color: tone ? V[tone] : V.text, fontSize: 20, fontWeight: 750, marginTop: 3, fontVariantNumeric: 'tabular-nums' }}>{value}</div>
      {sub && <div style={{ color: V.muted, fontSize: 12, marginTop: 1 }}>{sub}</div>}
    </div>
  )
}
