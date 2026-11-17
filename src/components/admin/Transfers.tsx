'use client'

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { fetchAllRows } from '@/lib/adminCache'
import { cleanCode, loadCodeMap } from '@/lib/productCodes'
import {
  fetchLevels, transferStock, receiveStock, returnStock, crossTransferStock, fetchLocations, fetchLineStock,
  tablesFor, otherLine, modelKey, similarNames, LINE_LABEL, STORE, SPOILT,
  type Levels, type StockLine, type StockRow,
} from '@/lib/storeStock'
import CameraScanner from '@/components/admin/CameraScanner'
import ModelPicker, { type PickerOption } from '@/components/admin/ModelPicker'
import { needsApproval, requestStockMovement, settleAfterDelay } from '@/lib/stockApproval'

/**
 * Stock transfers — moving units between locations, and the record of it.
 *
 * The back warehouses hold the bulk; STORE STOCK is the shop floor that
 * invoices are deducted from. Nothing reaches the store on its own, so this
 * is the tab that fills it. Any location can send to any other, because
 * returns and corrections are the same movement in reverse and would
 * otherwise have had to be faked by editing opening counts by hand.
 *
 * The move itself is a single `transfer_stock` call: source and destination
 * change in one transaction, or not at all.
 *
 * Receiving and returns share this tab but are not transfers — neither
 * deducts from anywhere, both bring units into the system. They land in the
 * same numbered history so "where did this stock come from" has one answer,
 * under their own RCV and RNA series.
 *
 * A return is the one that needs care: a line marked spoilt is recorded in
 * full but restocks NOTHING, because putting damaged goods back on the
 * shelf as sellable is how a shop ends up invoicing what it cannot supply.
 *
 * Who did it is the staff ID of whoever is signed in, recorded by the
 * database rather than typed, so it cannot be another hand.
 *
 * The Dahua portal mounts this with `dahua`: the same three movements, run
 * against dahua_stock through the dahua_* functions and recorded in their
 * own DH-TRF / DH-RCV / DH-RNA series (20260930_dahua_transfers.sql). Dahua
 * has no STORE STOCK — its invoices deduct from whichever row is picked —
 * so there a transfer is simply units changing warehouse.
 *
 * Either portal can also move stock across to the other line: the location
 * lists carry the other side's warehouses under their own heading. That is
 * one `cross_transfer_stock` call, recorded on both sides under one XTR
 * number (20261005_cross_line_transfers.sql). The two sides do not always
 * call a product the same thing, so a cross line says what it arrives as.
 */

const TEAL = '#0a7cff'
const AMBER = '#f59e0b'

interface Theme {
  card: string; border: string; text: string; sub: string; muted: string
  input: string; inputBorder: string; headerBg: string
}
// Colours come from the --qb-* tokens (src/app/qb-ios.css): <html data-qb-theme>
// picks light or dark, so both palettes point at the same values.
const DARK: Theme = {
  card: 'var(--qb-card)', border: 'var(--qb-border)', text: 'var(--qb-text)', sub: 'var(--qb-sub)',
  muted: 'var(--qb-muted)', input: 'var(--qb-input)', inputBorder: 'var(--qb-input-border)',
  headerBg: 'var(--qb-header)',
}
const LIGHT: Theme = DARK

interface Line {
  key: number
  model: string
  quantity: number
  /** Returns only: a spoilt line is logged but never restocked. */
  spoilt?: boolean
  /** Cross-line moves only: the name it takes on the other side, once staff have chosen one. */
  toModel?: string
  /** A delivery of a product the shop has never stocked: typed, not picked. */
  isNew?: boolean
}
let keyCounter = 0
const newLine = (): Line => ({ key: ++keyCounter, model: '', quantity: 1, spoilt: false })

type Mode = 'move' | 'receive' | 'return'
const MODES: { key: Mode; label: string }[] = [
  { key: 'move',    label: 'Move between locations' },
  { key: 'receive', label: 'Receive from outside' },
  { key: 'return',  label: 'Returns (RNA)' },
]

interface TransferRow {
  id: string
  transfer_number: string
  kind: 'move' | 'receive' | 'return' | 'reversal'
  /** Null on a receive — a delivery has no source location. */
  from_warehouse: string | null
  to_warehouse: string
  supplier: string | null
  note: string | null
  signed_by: string | null
  staff_id: string | null
  transferred_at: string
  /** Both set on a move between the main shop and Dahua, both null otherwise. */
  from_line?: StockLine | null
  to_line?: StockLine | null
  /** Aliased in the select, since the two lines name their item tables differently. */
  items: { model: string; quantity: number; position: number; condition: string; other_model?: string | null }[]
}

/** Select values: a location is a line and a name, and both lines have a SPOILT. */
const locKey = (line: StockLine, name: string) => `${line}|${name}`
const parseLoc = (key: string) => {
  const i = key.indexOf('|')
  return { line: key.slice(0, i) as StockLine, name: key.slice(i + 1) }
}

export default function Transfers({ dark, canWrite, isBoss, isSuperBoss = false, dahua = false, accent }: {
  dark: boolean
  canWrite: boolean
  /** Run against the Dahua stock pool and movement record instead of the main shop's. */
  dahua?: boolean
  /** The tab's accent colour; defaults to the main panel's green. */
  accent?: string
  /**
   * The Big Boss's movements apply at once; everyone else's — main shop and
   * Dahua — go to him for approval first (20261023_stock_approval_everywhere.sql).
   */
  isSuperBoss?: boolean
  /**
   * The history is a running account of everything the shop moves,
   * receives, returns and writes off — not counter staff's to browse. They
   * keep the ability to record movements; the confirmation toast still
   * names the reference they just created. Enforced by RLS as well, in
   * 20260922_movement_history_boss_only.sql.
   */
  isBoss: boolean
}) {
  const T = dark ? DARK : LIGHT
  const A = accent ?? TEAL
  // White on the muted Dahua accents is too faint; they take dark text, as the portal's own buttons do.
  const onA = dahua ? '#060d1a' : '#ffffff'
  const line: StockLine = dahua ? 'dahua' : 'main'
  const other = otherLine(line)
  const tables = tablesFor(line)

  // Move stock between locations, book in a delivery, or take goods back.
  const [mode, setMode] = useState<Mode>('move')
  // The other party: a supplier on a receive, the buyer on a return.
  // Optional in both cases — a delivery with no paperwork still has to go in.
  const [supplier, setSupplier] = useState('')

  const [warehouses, setWarehouses] = useState<string[]>([])
  // The other line's locations, offered on a move only. Empty until they load,
  // and left empty if they cannot be read — this tab then works as it always has.
  const [otherWarehouses, setOtherWarehouses] = useState<string[]>([])
  // Which line each end is on. Both are this tab's own line except on a cross move.
  const [fromLine, setFromLine] = useState<StockLine>(line)
  const [toLine, setToLine] = useState<StockLine>(line)
  const [from, setFrom] = useState('')
  // Dahua has no STORE STOCK; its default is picked once the locations load.
  const [to, setTo] = useState(dahua ? '' : STORE)
  const [note, setNote] = useState('')
  const [lines, setLines] = useState<Line[]>([newLine()])
  const [saving, setSaving] = useState(false)
  const [toast, setToast] = useState<{ msg: string; ok: boolean } | null>(null)

  // On-hand at the source, so a line can show what is actually there. Reloaded
  // whenever the source changes — a stale figure here is worse than none.
  const [sourceLevels, setSourceLevels] = useState<Levels>(new Map())
  const [levelsLoading, setLevelsLoading] = useState(false)

  // Barcodes and names are kept per line; a scan resolves against the line
  // the stock is leaving.
  const [codeMaps, setCodeMaps] = useState<Record<StockLine, Map<string, string>>>({ main: new Map(), dahua: new Map() })
  // What every location on each line calls each product. This is what lets a
  // delivery be booked under the name the shop already uses somewhere else.
  const [lineStock, setLineStock] = useState<Record<StockLine, StockRow[]>>({ main: [], dahua: [] })
  const [camera, setCamera] = useState(false)
  const [scanFlash, setScanFlash] = useState<{ ok: boolean; text: string } | null>(null)
  const lastScanRef = useRef<{ code: string; t: number }>({ code: '', t: 0 })

  const [history, setHistory] = useState<TransferRow[]>([])
  const [historyLoading, setHistoryLoading] = useState(true)
  const [expanded, setExpanded] = useState<string | null>(null)
  // The boss's view of the record: one person's entries, or just today's.
  const [byWho, setByWho] = useState('')
  const [todayOnly, setTodayOnly] = useState(false)
  // Search: the list shows the latest 300 entries, but a search looks
  // through every entry ever made, loaded in full the first time it is used.
  const [query, setQuery] = useState('')
  const [allHistory, setAllHistory] = useState<TransferRow[] | null>(null)
  const [allLoading, setAllLoading] = useState(false)

  const showToast = (msg: string, ok = true) => {
    setToast({ msg, ok })
    setTimeout(() => setToast(null), 4000)
  }

  // ── Locations ────────────────────────────────────────────
  useEffect(() => {
    ;(async () => {
      const { data } = await supabase.from(dahua ? 'dahua_warehouses' : 'warehouses').select('name').order('created_at')
      const names = (data || []).map(w => w.name as string)
      setWarehouses(names)
      // Default to moving stock the way it usually moves: out of the first
      // back warehouse and onto the shop floor (on Dahua, into the next one).
      const firstFrom = names.find(n => n !== STORE && n !== SPOILT) || ''
      setFrom(f => f || firstFrom)
      setTo(t => (names.includes(t) && t !== SPOILT ? t : names.find(n => n !== SPOILT && n !== firstFrom) || ''))
    })()
    fetchLocations(otherLine(dahua ? 'dahua' : 'main')).then(setOtherWarehouses).catch(() => { /* cross-line moves stay off */ })
    for (const l of ['main', 'dahua'] as const) {
      loadCodeMap(l === 'dahua' ? 'dahua_product_codes' : 'product_codes')
        .then(m => setCodeMaps(c => ({ ...c, [l]: m }))).catch(() => { /* scanning stays off */ })
    }
  }, [dahua])

  const loadLineStock = useCallback(() => {
    for (const l of ['main', 'dahua'] as const) {
      fetchLineStock(l).then(rows => setLineStock(s => ({ ...s, [l]: rows }))).catch(() => { /* suggestions stay off */ })
    }
  }, [])
  useEffect(() => { loadLineStock() }, [loadLineStock])

  // ── Source levels ────────────────────────────────────────
  // On a move that is the SOURCE, to check there is enough to send. On a
  // delivery or a return it is the DESTINATION, so staff typing an item see
  // what that location already stocks and top it up rather than inventing a
  // second spelling for something already on the shelf.
  const refWarehouse = mode === 'move' ? from : to
  const refLine      = mode === 'move' ? fromLine : line
  const codeMap      = codeMaps[refLine]
  /** Leaving one line for the other, rather than changing warehouse within one. */
  const cross = mode === 'move' && fromLine !== toLine

  useEffect(() => {
    if (!refWarehouse) { setSourceLevels(new Map()); return }
    let cancelled = false
    setLevelsLoading(true)
    fetchLevels(refWarehouse, refLine)
      .then(l => { if (!cancelled) setSourceLevels(l) })
      .catch(() => { if (!cancelled) showToast('Could not read what ' + refWarehouse + ' holds', false) })
      .finally(() => { if (!cancelled) setLevelsLoading(false) })
    return () => { cancelled = true }
  }, [refWarehouse, refLine])

  // ── History ──────────────────────────────────────────────
  const loadHistory = useCallback(async (quiet = false) => {
    if (!isBoss) { setHistory([]); setHistoryLoading(false); return }
    if (!quiet) setHistoryLoading(true)
    const read = (lines: string, otherModel: string) => supabase
      .from(tables.transfers)
      .select(historyCols(lines, otherModel))
      .order('transferred_at', { ascending: false })
      .limit(300)
    let { data, error } = await read('from_line,to_line,', ',other_model')
    // Before 20261005_cross_line_transfers.sql is run those columns do not
    // exist; the history must still load.
    if (error) ({ data, error } = await read('', ''))
    if (error) { if (!quiet) showToast('Could not load transfer history', false); return setHistoryLoading(false) }
    setHistory((data as unknown as TransferRow[]) || [])
    // A refresh by hand also refreshes what a search looks through.
    if (!quiet) setAllHistory(null)
    setHistoryLoading(false)
  }, [isBoss, tables])

  const historyCols = (lines: string, otherModel: string) =>
    `id,transfer_number,kind,from_warehouse,to_warehouse,${lines}supplier,note,signed_by,staff_id,transferred_at,items:${tables.items}(model,quantity,position,condition${otherModel})`

  // Every entry, paged past the 1000-row cap — only once someone searches.
  const searching = query.trim().length > 0
  useEffect(() => {
    if (!searching || allHistory || allLoading || !isBoss) return
    setAllLoading(true)
    const all = (lines: string, otherModel: string) => fetchAllRows<TransferRow>((f, t) => supabase
      .from(tables.transfers).select(historyCols(lines, otherModel)).order('id').range(f, t) as any)
    all('from_line,to_line,', ',other_model')
      .catch(() => all('', ''))
      .then(rows => setAllHistory(rows.sort((a, b) => b.transferred_at.localeCompare(a.transferred_at))))
      .catch(() => showToast('Could not load the full history to search', false))
      .finally(() => setAllLoading(false))
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searching, allHistory, allLoading, isBoss, tables])
  useEffect(() => { loadHistory() }, [loadHistory])

  // Entries made on the stock phones should reach this screen without the
  // boss having to reload it: checked once a minute, quietly, while it is open.
  useEffect(() => {
    if (!isBoss) return
    const timer = setInterval(() => { if (document.visibilityState === 'visible') loadHistory(true) }, 60_000)
    return () => clearInterval(timer)
  }, [isBoss, loadHistory])

  /** Who recorded it: the person who entered their password, else the login used. */
  const whoOf = (t: TransferRow) => t.signed_by || t.staff_id || 'Unknown'
  const unitsOf = (t: TransferRow) => (t.items || []).reduce((n, i) => n + i.quantity, 0)

  /** Today at a glance: how much was entered, and by whom. */
  const today = useMemo(() => {
    const day = new Date().toDateString()
    const rows = history.filter(t => new Date(t.transferred_at).toDateString() === day)
    const people = new Map<string, { entries: number; units: number }>()
    for (const t of rows) {
      const p = people.get(whoOf(t)) || { entries: 0, units: 0 }
      p.entries++; p.units += unitsOf(t)
      people.set(whoOf(t), p)
    }
    return {
      entries: rows.length,
      units: rows.reduce((n, t) => n + unitsOf(t), 0),
      people: Array.from(people, ([name, v]) => ({ name, ...v })).sort((a, b) => b.entries - a.entries),
    }
  }, [history])

  const everyone = useMemo(() => Array.from(new Set(history.map(whoOf))).sort((a, b) => a.localeCompare(b)), [history])
  const searchWords = useMemo(() => query.toLowerCase().split(/\s+/).filter(Boolean), [query])
  /** What a search looks at: reference, places, person, supplier, note, date and every product on it. */
  const haystack = (t: TransferRow) => [
    t.transfer_number, t.kind, t.from_warehouse, t.to_warehouse, t.supplier, t.note, t.signed_by, t.staff_id,
    new Date(t.transferred_at).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }),
    ...(t.items || []).flatMap(i => [i.model, i.other_model]),
  ].filter(Boolean).join(' ').toLowerCase()
  const itemHits = (t: TransferRow) => searchWords.length
    ? (t.items || []).filter(i => { const h = `${i.model} ${i.other_model ?? ''}`.toLowerCase(); return searchWords.every(w => h.includes(w)) })
    : []
  const searchPool = searching ? (allHistory ?? history) : history
  const shownHistory = useMemo(() => {
    const day = new Date().toDateString()
    return searchPool.filter(t => (!byWho || whoOf(t) === byWho) && (!todayOnly || new Date(t.transferred_at).toDateString() === day)
      && (!searchWords.length || (() => { const h = haystack(t); return searchWords.every(w => h.includes(w)) })()))
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchPool, byWho, todayOnly, searchWords])

  // ── Lines ────────────────────────────────────────────────
  const setLine = (key: number, patch: Partial<Line>) =>
    setLines(ls => ls.map(l => (l.key === key ? { ...l, ...patch } : l)))
  const removeLine = (key: number) =>
    setLines(ls => (ls.length === 1 ? [newLine()] : ls.filter(l => l.key !== key)))

  /** Scanning the same model twice bumps the quantity rather than repeating it. */
  const addOrBump = useCallback((model: string) => {
    setLines(ls => {
      const i = ls.findIndex(l => l.model === model)
      if (i >= 0) return ls.map((l, j) => (j === i ? { ...l, quantity: l.quantity + 1 } : l))
      const line: Line = { key: ++keyCounter, model, quantity: 1 }
      const blank = ls.findIndex(l => !l.model.trim())
      return blank >= 0 ? ls.map((l, j) => (j === blank ? line : l)) : [...ls, line]
    })
    setScanFlash({ ok: true, text: model })
    try { navigator.vibrate?.(35) } catch { /* no haptics */ }
  }, [])

  const handleScan = useCallback((raw: string) => {
    const code = cleanCode(raw.trim())
    if (!code) return
    const now = Date.now()
    // A hardware scanner can fire the same code twice in a few milliseconds.
    if (lastScanRef.current.code === code && now - lastScanRef.current.t < 150) return
    lastScanRef.current = { code, t: now }
    const model = codeMap.get(code)
    if (!model) { setScanFlash({ ok: false, text: 'Unknown barcode — link it in Codes first' }); return }
    addOrBump(model)
  }, [codeMap, addOrBump])

  /**
   * Every name each line uses, and the name it uses for a given product code.
   * `byKey` is how a second spelling is caught before it is saved: two names
   * that differ only in case, spacing or punctuation share a key.
   */
  const names = useMemo(() => {
    const build = (rows: StockRow[]) => {
      const exact = new Set<string>()
      const byKey = new Map<string, string>()
      for (const r of rows) {
        exact.add(r.model)
        const k = modelKey(r.model)
        if (k && !byKey.has(k)) byKey.set(k, r.model)
      }
      return { exact, byKey }
    }
    return { main: build(lineStock.main), dahua: build(lineStock.dahua) }
  }, [lineStock])

  /**
   * Everything the reference warehouse holds, shown the moment the field
   * opens. On a delivery or a return the rest of the line follows under its
   * own heading: a product that is new to THIS warehouse but stocked in
   * another should go in under the name it already has there.
   */
  const pickerOptions = useMemo<PickerOption[]>(() => {
    const here = Array.from(sourceLevels, ([model, qty]) => ({ model, qty }))
      .sort((a, b) => a.model.localeCompare(b.model))
    // On a move, what the source can actually send comes first. STORE STOCK
    // lists every product the shop carries, most of them at 0.
    if (mode === 'move') {
      const empty = here.filter(o => o.qty <= 0)
      if (!empty.length) return here
      return [
        ...here.filter(o => o.qty > 0).map(o => ({ ...o, group: `In stock in ${from}` })),
        ...empty.map(o => ({ ...o, group: `Listed in ${from}, none in stock` })),
      ]
    }
    const elsewhere = Array.from(names[line].exact)
      .filter(m => !sourceLevels.has(m))
      .sort((a, b) => a.localeCompare(b))
      .map(model => ({ model, group: 'Stocked in other locations' }))
    return [...here.map(o => ({ ...o, group: `In ${to}` })), ...elsewhere]
  }, [sourceLevels, mode, names, line, to, from])

  /**
   * What the destination warehouse itself already stocks. A move must not
   * open a second row there for a product it has under another spelling, so
   * every line is checked against this before it is sent.
   */
  const destHere = useMemo(() => {
    const exact = new Set<string>()
    const byKey = new Map<string, string>()
    const qty = new Map<string, number>()
    for (const r of lineStock[toLine]) {
      if (r.warehouse !== to) continue
      exact.add(r.model)
      qty.set(r.model, (qty.get(r.model) || 0) + r.closing_stock)
      const k = modelKey(r.model)
      if (k && !byKey.has(k)) byKey.set(k, r.model)
    }
    return { exact, byKey, qty }
  }, [lineStock, toLine, to])

  /**
   * The name a line takes at the destination: the destination warehouse's
   * own spelling if it stocks the product, then the destination line's, and
   * only then the name it left under.
   */
  const suggestArrival = useCallback((model: string) => {
    const m = model.trim()
    const k = modelKey(m)
    if (destHere.exact.has(m)) return m
    const dest = names[toLine]
    return destHere.byKey.get(k) ?? (dest.exact.has(m) ? m : dest.byKey.get(k) ?? m)
  }, [destHere, names, toLine])
  const arrivesAs = (l: Line) => (l.toModel ?? suggestArrival(l.model)).trim()

  /** The destination's names — its own warehouse first, then the rest of its line. */
  const arrivalOptions = useMemo<PickerOption[]>(() => {
    if (mode !== 'move') return []
    const here = new Map<string, number>()
    for (const r of lineStock[toLine]) {
      if (r.warehouse === to) here.set(r.model, (here.get(r.model) || 0) + r.closing_stock)
    }
    const byName = (a: string, b: string) => a.localeCompare(b)
    return [
      ...Array.from(here.keys()).sort(byName).map(model => ({ model, qty: here.get(model), group: `In ${to}` })),
      ...Array.from(names[toLine].exact).filter(m => !here.has(m)).sort(byName)
        .map(model => ({ model, group: `Elsewhere in ${LINE_LABEL[toLine]}` })),
    ]
  }, [mode, lineStock, names, toLine, to])

  const validLines = useMemo(
    () => lines.filter(l => l.model.trim() && l.quantity > 0),
    [lines],
  )
  /** Lines the source cannot cover — shown as a warning, checked again server-side. */
  const short = useMemo(
    () => mode !== 'move' ? []
      : validLines.filter(l => (sourceLevels.get(l.model.trim()) ?? 0) < l.quantity),
    [validLines, sourceLevels, mode],
  )
  /**
   * Models the source has never carried. transfer_stock rejects these
   * outright; receiving has no source, and a delivery of something new is
   * exactly how stock is supposed to arrive.
   */
  const unknown = useMemo(
    () => mode !== 'move' ? []
      : validLines.filter(l => !sourceLevels.has(l.model.trim())),
    [validLines, sourceLevels, mode],
  )

  const submit = async () => {
    if (!to)                return showToast(
      mode === 'return' ? 'Pick where the good items go back to' : 'Pick where the stock is going', false)
    if (mode === 'move') {
      if (!from)            return showToast('Pick where the stock is coming from', false)
      if (from === to && fromLine === toLine) return showToast('A transfer needs two different locations', false)
    }
    if (!validLines.length) return showToast('Add at least one item', false)
    if (unknown.length) {
      return showToast(`${from} has never carried ${unknown[0].model} — add it there first`, false)
    }
    if (short.length && !confirm(
      `${from} does not hold enough of:\n\n` +
      short.map(l => `• ${l.model} — has ${sourceLevels.get(l.model.trim()) ?? 0}, sending ${l.quantity}`).join('\n') +
      `\n\nTransfer anyway? The source will go negative.`,
    )) return

    setSaving(true)
    try {
      const payload = validLines.map(l => ({ model: l.model.trim(), quantity: l.quantity }))
      const units = validLines.reduce((s, l) => s + l.quantity, 0)

      // A movement by staff is a request until the Big Boss approves it.
      const fromL = mode === 'move' ? fromLine : null
      const toL = mode === 'move' ? toLine : line
      if (needsApproval(isSuperBoss)) {
        const req = await requestStockMovement({
          kind: mode, fromLine: fromL, from: mode === 'move' ? from : null, toLine: toL, to,
          items: mode === 'return'
            ? validLines.map(l => ({ model: l.model.trim(), quantity: l.quantity, condition: l.spoilt ? 'spoilt' : 'good' }))
            : mode === 'move'
              ? validLines.map(l => {
                  const model = l.model.trim(), as = arrivesAs(l)
                  return as && as !== model ? { model, quantity: l.quantity, to_model: as } : { model, quantity: l.quantity }
                })
              : payload,
          party: supplier, note,
        })
        showToast(`${req.request_number} — sent to the Big Boss for approval. The stock changes when he approves.`)
        settleAfterDelay()
        setLines([newLine()])
        setNote('')
        setSupplier('')
        return
      }

      let t
      let said: string
      if (mode === 'receive') {
        t = await receiveStock(to, payload, supplier, note, { line })
        said = `${units} unit${units === 1 ? '' : 's'} received into ${to}`
      } else if (mode === 'return') {
        t = await returnStock(
          to,
          validLines.map(l => ({
            model: l.model.trim(), quantity: l.quantity,
            condition: l.spoilt ? 'spoilt' as const : 'good' as const,
          })),
          supplier, note, { line },
        )
        const back = validLines.filter(l => !l.spoilt).reduce((s, l) => s + l.quantity, 0)
        const gone = units - back
        said = gone > 0
          ? `${back} back into ${to}, ${gone} spoilt to ${SPOILT}`
          : `${back} unit${back === 1 ? '' : 's'} back into ${to}`
      } else if (cross) {
        t = await crossTransferStock(
          { line: fromLine, name: from }, { line: toLine, name: to },
          validLines.map(l => ({ model: l.model.trim(), quantity: l.quantity, to_model: arrivesAs(l) })),
          note,
        )
        said = `${units} unit${units === 1 ? '' : 's'} moved to ${to} (${LINE_LABEL[toLine]})`
      } else {
        // The name it joins at the destination goes with it when that is
        // not the name it left under.
        t = await transferStock(from, to, validLines.map(l => {
          const model = l.model.trim()
          const as = arrivesAs(l)
          return as && as !== model ? { model, quantity: l.quantity, to_model: as } : { model, quantity: l.quantity }
        }), note, { line })
        said = `${units} unit${units === 1 ? '' : 's'} moved to ${to}`
      }
      showToast(`${t.transfer_number} — ${said} ✓`)

      setLines([newLine()])
      setNote('')
      setSupplier('')
      // What the reference warehouse holds has changed either way.
      if (refWarehouse) {
        fetchLevels(refWarehouse, refLine).then(setSourceLevels).catch(() => { /* next edit reloads */ })
      }
      loadLineStock()
      loadHistory()
    } catch (e: any) {
      showToast(e.message || (
        mode === 'receive' ? 'Could not receive the delivery'
        : mode === 'return' ? 'Could not record the return'
        : 'Transfer failed'), false)
    } finally {
      setSaving(false)
    }
  }

  // ── Styles ───────────────────────────────────────────────
  const fld: React.CSSProperties = {
    width: '100%', padding: '9px 12px', borderRadius: 8, fontSize: 14, outline: 'none',
    border: `1px solid ${T.inputBorder}`, background: T.input, color: T.text,
  }
  const lbl: React.CSSProperties = {
    fontSize: 10, fontWeight: 800, color: A, letterSpacing: '0.18em',
    textTransform: 'uppercase', display: 'block', marginBottom: 5,
  }
  const th: React.CSSProperties = {
    padding: '9px 10px', textAlign: 'left', fontSize: 10, fontWeight: 800,
    letterSpacing: '0.12em', color: T.sub, borderBottom: `1px solid ${T.border}`,
  }
  const td: React.CSSProperties = { padding: '9px 10px', fontSize: 13, color: T.text }

  // SPOILT is filled by marking a line spoilt, never chosen by hand, so it
  // is not offered as anywhere to send stock. It stays available as a
  // source, which is how a repaired unit or a disposal leaves the pile.
  const sendable      = warehouses.filter(w => w !== SPOILT)
  const destinations  = sendable.filter(w => !(fromLine === line && w === from))
  const otherSendable = otherWarehouses.filter(w => w !== SPOILT && !(fromLine === other && w === from))
  /** A location on the other line carries its line's name wherever it is shown alone. */
  const placed = (l: StockLine, name: string) => (l === line ? name : `${name} (${LINE_LABEL[l]})`)

  return (
    <div style={{ maxWidth: 980 }}>

      {/* ── Move form ───────────────────────────────────────── */}
      {canWrite && (
        <div style={{ padding: 18, borderRadius: 12, background: T.card, border: `1px solid ${T.border}`, marginBottom: 22 }}>
          <div style={{ fontWeight: 900, fontSize: 17, color: T.text, marginBottom: 10 }}>
            {mode === 'receive' ? 'Receive stock from outside'
              : mode === 'return' ? 'Returns from buyers'
              : 'Transfer stock'}
          </div>

          {/* Three different things, one tab, because all three answer
              "where did this stock come from". */}
          <div role="tablist" style={{ display: 'inline-flex', gap: 3, padding: 3, borderRadius: 10, background: T.input, marginBottom: 12, maxWidth: '100%', overflowX: 'auto' }}>
            {MODES.map(m => (
              <button key={m.key} type="button" onClick={() => {
                setMode(m.key)
                // A delivery or a return is booked into this tab's own line,
                // and can land anywhere sellable there — so the destination
                // must not be left blank, or left on the other side.
                if (m.key !== 'move') {
                  setFromLine(line)
                  if (toLine !== line || !to) { setToLine(line); setTo(warehouses.find(w => w !== SPOILT) || '') }
                }
              }}
                role="tab" aria-selected={mode === m.key}
                style={{
                  padding: '8px 14px', borderRadius: 8, cursor: 'pointer', fontSize: 12.5, fontWeight: 800, whiteSpace: 'nowrap',
                  border: 'none',
                  background: mode === m.key ? T.card : 'transparent',
                  color: mode === m.key ? A : T.sub,
                  boxShadow: mode === m.key ? '0 1px 3px rgba(0,0,0,0.2)' : 'none',
                }}>
                {m.label}
              </button>
            ))}
          </div>

          <div style={{ fontSize: 12, color: T.sub, marginBottom: 16 }}>
            {mode === 'receive'
              ? <>A supplier delivery. Nothing is taken from anywhere — these units enter the system, and a model that has never been stocked here is created.</>
              : mode === 'return'
              ? <>Goods back from a buyer. Tick <strong style={{ color: '#ef4444' }}>spoilt</strong> on anything that cannot be sold again: it goes to {SPOILT} instead of back on the shelf, where it can be counted against what you have written off. Everything else returns to stock.</>
              : cross
              ? <>Units leave {placed(fromLine, from)} and arrive in {placed(toLine, to)} in a single step, recorded on both sides under one XTR reference. Check what each item <strong style={{ color: T.text }}>arrives as</strong>: the two sides do not always use the same name.</>
              : dahua
              ? <>Units leave one Dahua warehouse and arrive at the other in a single step. Dahua invoices deduct from whichever stock row the cashier picks.</>
              : <>Units leave one location and arrive at the other in a single step. Invoices are deducted from {STORE}.</>}
            {!isSuperBoss && (
              <div style={{ marginTop: 6, color: AMBER, fontWeight: 700 }}>
                This goes to the Big Boss for approval. The stock changes when he approves.
              </div>
            )}
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(200px,1fr))', gap: 12, marginBottom: 16 }}>
            {mode === 'move' ? (
              <div>
                <label style={lbl}>From</label>
                <select style={fld} value={locKey(fromLine, from)} onChange={e => {
                  const next = parseLoc(e.target.value)
                  setFromLine(next.line)
                  setFrom(next.name)
                  // What was typed against the old source means nothing here.
                  if (next.line !== fromLine) setLines(ls => ls.map(l => ({ ...l, toModel: undefined })))
                  if (next.name === to && next.line === toLine) {
                    setToLine(line)
                    setTo(sendable.find(w => !(next.line === line && w === next.name)) || '')
                  }
                }}>
                  {otherWarehouses.length === 0
                    ? warehouses.map(w => <option key={w} value={locKey(line, w)}>{w}</option>)
                    : <>
                        <optgroup label={LINE_LABEL[line]}>
                          {warehouses.map(w => <option key={w} value={locKey(line, w)}>{w}</option>)}
                        </optgroup>
                        <optgroup label={LINE_LABEL[other]}>
                          {otherWarehouses.map(w => <option key={w} value={locKey(other, w)}>{w}</option>)}
                        </optgroup>
                      </>}
                </select>
              </div>
            ) : (
              <div>
                <label style={lbl}>{mode === 'return' ? 'Returned by' : 'Supplier'} · optional</label>
                <input style={fld} value={supplier} onChange={e => setSupplier(e.target.value)}
                  placeholder={mode === 'return' ? 'which buyer' : 'who brought it'} />
              </div>
            )}
            <div>
              <label style={lbl}>{mode === 'move' ? 'To' : mode === 'return' ? 'Good items back into' : 'Into'}</label>
              <select style={fld} value={locKey(toLine, to)} onChange={e => {
                const next = parseLoc(e.target.value)
                if (next.line !== toLine) setLines(ls => ls.map(l => ({ ...l, toModel: undefined })))
                setToLine(next.line)
                setTo(next.name)
              }}>
                {mode !== 'move' || otherSendable.length === 0
                  ? (mode === 'move' ? destinations : sendable).map(w => <option key={w} value={locKey(line, w)}>{w}</option>)
                  : <>
                      <optgroup label={LINE_LABEL[line]}>
                        {destinations.map(w => <option key={w} value={locKey(line, w)}>{w}</option>)}
                      </optgroup>
                      <optgroup label={LINE_LABEL[other]}>
                        {otherSendable.map(w => <option key={w} value={locKey(other, w)}>{w}</option>)}
                      </optgroup>
                    </>}
              </select>
            </div>
            <div>
              <label style={lbl}>Note</label>
              <input style={fld} value={note} onChange={e => setNote(e.target.value)}
                placeholder={mode === 'receive' ? 'optional — e.g. waybill 4471'
                  : mode === 'return' ? 'optional — e.g. invoice INV-2026-0104'
                  : 'optional — e.g. restocking the display shelf'} />
            </div>
          </div>

          {/* Scanner */}
          <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap', marginBottom: 12 }}>
            <input
              style={{ ...fld, flex: '1 1 240px', width: 'auto' }}
              placeholder="Scan a barcode to add an item…"
              onKeyDown={e => {
                if (e.key !== 'Enter') return
                e.preventDefault()
                handleScan((e.target as HTMLInputElement).value)
                ;(e.target as HTMLInputElement).value = ''
              }} />
            <button type="button" onClick={() => setCamera(c => !c)}
              style={{ padding: '9px 14px', borderRadius: 8, border: `1px solid ${T.inputBorder}`, background: T.input, color: A, fontWeight: 800, fontSize: 12, cursor: 'pointer' }}>
              {camera ? '✕ Close camera' : '📷 Camera'}
            </button>
            {scanFlash && (
              <span style={{ fontSize: 12, fontWeight: 700, color: scanFlash.ok ? A : AMBER }}>
                {scanFlash.ok ? '✓ ' : '⚠ '}{scanFlash.text}
              </span>
            )}
          </div>
          {camera && (
            <div style={{ marginBottom: 12 }}>
              <CameraScanner
                active
                banner={scanFlash ? { tone: scanFlash.ok ? 'ok' : 'warn', title: scanFlash.text } : null}
                onDetect={handleScan}
                onClose={() => setCamera(false)}
              />
            </div>
          )}

          {/* Lines — a long delivery scrolls inside this box, not the page. */}
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8, marginBottom: 14, maxHeight: 420, overflowY: 'auto', overscrollBehavior: 'contain', paddingRight: 2 }}>
            {lines.map(l => {
              const model = l.model.trim()
              const have  = model ? sourceLevels.get(model) : undefined
              const missing = !!model && have === undefined && !levelsLoading
              const tooFew  = have !== undefined && have < l.quantity
              // A delivery or return typed under a name the line does not
              // use: either a second spelling of something it does stock, or
              // a product that really is new.
              const known    = names[line]
              const twin     = model && !known.exact.has(model) ? known.byKey.get(modelKey(model)) : undefined
              const brandNew = mode !== 'move' && !!model && !levelsLoading && !known.exact.has(model) && !twin
              // On a move, a line whose exact name the destination does not
              // stock is shown what it will join, or be created as.
              const showArrival = mode === 'move' && !!model && (cross || (!levelsLoading && !destHere.exact.has(model)))
              const arrival  = showArrival ? arrivesAs(l) : ''
              const joins    = !!arrival && destHere.exact.has(arrival)
              const lookalikes = showArrival && !joins ? similarNames(arrival, destHere.exact).slice(0, 3) : []
              return (
                <div key={l.key} style={{ display: 'flex', gap: 8, alignItems: 'flex-start', flexWrap: 'wrap' }}>
                  <div style={{ flex: '1 1 260px', minWidth: 0 }}>
                    {l.isNew ? (
                      <div style={{ position: 'relative' }}>
                        <span style={{ position: 'absolute', left: 10, top: '50%', transform: 'translateY(-50%)', fontSize: 9.5, fontWeight: 900, letterSpacing: '0.12em', color: onA, background: A, padding: '2px 6px', borderRadius: 5, pointerEvents: 'none' }}>NEW</span>
                        <input autoFocus style={{ ...fld, paddingLeft: 56, borderColor: `${A}88` }} value={l.model}
                          onChange={e => setLine(l.key, { model: e.target.value })}
                          placeholder="Product name, as it should appear on invoices" />
                      </div>
                    ) : (
                    <ModelPicker
                      value={l.model}
                      options={pickerOptions}
                      onChange={m => setLine(l.key, { model: m, toModel: undefined })}
                      inputStyle={fld}
                      placeholder={levelsLoading ? 'Loading…'
                        : mode === 'receive' ? `What was delivered — click to see what ${to} stocks`
                        : mode === 'return'  ? `What came back — click to see what ${to} stocks`
                        : `Click to see what ${from} holds`}
                      emptyHint={mode === 'move'
                        ? `Nothing in ${from} matches`
                        : `Not stocked in ${to} yet — it will be created`}
                      theme={{
                        menuBg: T.card, border: T.inputBorder, text: T.text,
                        sub: T.sub, accent: A, accentText: onA,
                      }}
                    />
                    )}
                    {/* What the source actually holds, under the field it applies to. */}
                    {model && !levelsLoading && mode === 'move' && (
                      <div style={{ fontSize: 11, marginTop: 4, color: missing || tooFew ? AMBER : T.sub }}>
                        {missing
                          ? `${from} has never carried this model`
                          : `${from} has ${have!.toLocaleString()}${tooFew ? ` — sending ${l.quantity}` : ''}`}
                      </div>
                    )}
                    {/* The matching row at the other end, so staff see the two
                        piles are the same product before they send. */}
                    {mode === 'move' && model && !cross && destHere.exact.has(model) && (
                      <div style={{ fontSize: 11, marginTop: 2, color: A }}>
                        ✓ Matches “{model}” in {to} · has {(destHere.qty.get(model) ?? 0).toLocaleString()}
                      </div>
                    )}
                    {mode !== 'move' && twin && (
                      <div style={{ fontSize: 11, marginTop: 4, color: AMBER }}>
                        Already stocked as “{twin}” —{' '}
                        <button type="button" onClick={() => setLine(l.key, { model: twin })}
                          style={{ background: 'none', border: 'none', padding: 0, color: A, fontWeight: 800, fontSize: 11, cursor: 'pointer', textDecoration: 'underline' }}>
                          use that name
                        </button>
                        , or this becomes a second row for the same product.
                      </div>
                    )}
                    {brandNew && (
                      <div style={{ fontSize: 11, marginTop: 4, color: l.isNew ? A : AMBER }}>
                        {l.isNew
                          ? <>New product — it is created in {to}{isSuperBoss ? '' : ' once the Big Boss approves'}.</>
                          : <>A new name — nothing is stocked under it anywhere yet. Check the list before adding one.</>}
                      </div>
                    )}
                    {showArrival && (
                      <div style={{ marginTop: 6 }}>
                        <div style={{ fontSize: 10, fontWeight: 800, letterSpacing: '0.12em', color: T.sub, marginBottom: 3 }}>
                          {cross ? `ARRIVES IN ${LINE_LABEL[toLine].toUpperCase()} AS` : `GOES INTO ${to.toUpperCase()} AS`}
                        </div>
                        <ModelPicker
                          value={l.toModel ?? suggestArrival(l.model)}
                          options={arrivalOptions}
                          onChange={m => setLine(l.key, { toModel: m })}
                          inputStyle={{ ...fld, fontSize: 13, padding: '7px 10px' }}
                          placeholder={`What ${cross ? LINE_LABEL[toLine] : to} calls it`}
                          emptyHint={`${cross ? LINE_LABEL[toLine] : to} stocks nothing under that name — it will be created`}
                          theme={{
                            menuBg: T.card, border: T.inputBorder, text: T.text,
                            sub: T.sub, accent: A, accentText: onA,
                          }}
                        />
                        {joins && arrival !== model && (
                          <div style={{ fontSize: 11, marginTop: 4, color: A }}>
                            ✓ Matches “{arrival}” in {to} · has {(destHere.qty.get(arrival) ?? 0).toLocaleString()} — the units join that row, no second one is made.
                          </div>
                        )}
                        {lookalikes.length > 0 && (
                          <div style={{ fontSize: 11, marginTop: 4, color: AMBER }}>
                            {to} has a similar name:{' '}
                            {lookalikes.map(n => (
                              <button key={n} type="button" onClick={() => setLine(l.key, { toModel: n })}
                                style={{ background: 'none', border: 'none', padding: 0, marginRight: 8, color: A, fontWeight: 800, fontSize: 11, cursor: 'pointer', textDecoration: 'underline' }}>
                                add to “{n}”
                              </button>
                            ))}
                            Same product? Add to it. A different one? Leave this and a new row is made.
                          </div>
                        )}
                        {arrival && !joins && lookalikes.length === 0 && (
                          <div style={{ fontSize: 11, marginTop: 4, color: cross && !names[toLine].exact.has(arrival) ? AMBER : T.sub }}>
                            {cross && !names[toLine].exact.has(arrival)
                              ? `${LINE_LABEL[toLine]} stocks nothing as “${arrival}” — a new row will be created there.`
                              : `New to ${to} — a row will be created for it.`}
                          </div>
                        )}
                      </div>
                    )}
                  </div>
                  <input type="number" min={1} style={{ ...fld, width: 100 }} value={l.quantity}
                    onChange={e => setLine(l.key, { quantity: Math.max(1, parseInt(e.target.value) || 1) })} />
                  {mode === 'return' && (
                    <button type="button" onClick={() => setLine(l.key, { spoilt: !l.spoilt })}
                      title={l.spoilt ? `Written off — goes to ${SPOILT}, not back on the shelf` : 'Goes back into stock'}
                      style={{
                        padding: '9px 13px', borderRadius: 8, cursor: 'pointer', fontSize: 11.5, fontWeight: 800,
                        whiteSpace: 'nowrap',
                        border: `1px solid ${l.spoilt ? '#ef444459' : T.inputBorder}`,
                        background: l.spoilt ? '#ef444426' : 'transparent',
                        color: l.spoilt ? '#ef4444' : T.sub,
                      }}>
                      {l.spoilt ? '✕ spoilt' : 'not spoilt'}
                    </button>
                  )}
                  <button type="button" onClick={() => removeLine(l.key)}
                    style={{ padding: '9px 12px', borderRadius: 8, border: `1px solid ${T.inputBorder}`, background: 'transparent', color: T.sub, cursor: 'pointer' }}>✕</button>
                </div>
              )
            })}
          </div>

          <div style={{ display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
            <button type="button" onClick={() => setLines(ls => [...ls, newLine()])}
              style={{ padding: '9px 14px', borderRadius: 8, border: `1px dashed ${T.inputBorder}`, background: 'transparent', color: T.sub, fontWeight: 700, fontSize: 12, cursor: 'pointer' }}>
              + Add item
            </button>
            {mode === 'receive' && (
              <button type="button" onClick={() => setLines(ls => {
                const blank = ls.findIndex(x => !x.model.trim())
                const fresh = { ...newLine(), isNew: true }
                return blank >= 0 ? ls.map((x, j) => (j === blank ? fresh : x)) : [...ls, fresh]
              })}
                title="A product the shop has never stocked"
                style={{ padding: '9px 14px', borderRadius: 8, border: `1px dashed ${A}`, background: `${A}12`, color: A, fontWeight: 800, fontSize: 12, cursor: 'pointer' }}>
                + New product
              </button>
            )}
            <button type="button" disabled={saving || !validLines.length} onClick={submit}
              style={{ padding: '11px 22px', borderRadius: 9, border: 'none', background: A, color: onA, fontWeight: 900, fontSize: 13, cursor: saving ? 'wait' : 'pointer', opacity: saving || !validLines.length ? 0.55 : 1 }}>
              {saving
                ? (mode === 'receive' ? 'Receiving…' : mode === 'return' ? 'Recording…' : 'Moving…')
                : !isSuperBoss
                  ? 'Send for approval'
                  : (mode === 'receive' ? `Receive into ${to || '…'}`
                    : mode === 'return' ? 'Record return'
                    : `Transfer to ${to ? placed(toLine, to) : '…'}`)}
            </button>
            {validLines.length > 0 && (() => {
              const units  = validLines.reduce((s, l) => s + l.quantity, 0)
              const spoilt = validLines.filter(l => l.spoilt).reduce((s, l) => s + l.quantity, 0)
              return (
                <span style={{ fontSize: 12, color: T.sub }}>
                  {units.toLocaleString()} units · {validLines.length} item{validLines.length === 1 ? '' : 's'}
                  {mode === 'return' && spoilt > 0 && (
                    <span style={{ color: '#ef4444', fontWeight: 700 }}>
                      {' · '}{spoilt} spoilt, {(units - spoilt).toLocaleString()} back to stock
                    </span>
                  )}
                </span>
              )
            })()}
          </div>
        </div>
      )}

      {/* ── History — boss only ─────────────────────────────── */}
      {isBoss && (
      <div style={{ padding: 18, borderRadius: 12, background: T.card, border: `1px solid ${T.border}` }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap', marginBottom: 12 }}>
          <div style={{ fontWeight: 900, fontSize: 15, color: T.text, flex: 1 }}>Stock activity</div>
          <button type="button" onClick={() => loadHistory()}
            style={{ padding: '6px 11px', borderRadius: 7, border: `1px solid ${T.inputBorder}`, background: 'transparent', color: A, fontWeight: 800, fontSize: 11.5, cursor: 'pointer' }}>
            ↻ Refresh
          </button>
        </div>

        {/* Everything entered today — from this screen and from the stock
            phones — and who entered it. A name here is the person who gave
            their own password on the phone; an email is the login used when
            the entry was made at a desk. */}
        {!historyLoading && (
          <div style={{ padding: '12px 14px', borderRadius: 10, background: T.headerBg, border: `1px solid ${T.border}`, marginBottom: 14 }}>
            <div style={{ fontSize: 10, fontWeight: 800, letterSpacing: '0.16em', color: A, marginBottom: 6 }}>TODAY</div>
            {today.entries === 0 ? (
              <div style={{ fontSize: 13, color: T.sub }}>Nothing has been entered today.</div>
            ) : (
              <>
                <div style={{ fontSize: 14, color: T.text, fontWeight: 800, marginBottom: 8 }}>
                  {today.entries} entr{today.entries === 1 ? 'y' : 'ies'} · {today.units.toLocaleString()} unit{today.units === 1 ? '' : 's'}
                </div>
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                  {today.people.map(p => (
                    <button key={p.name} type="button"
                      onClick={() => { setByWho(byWho === p.name ? '' : p.name); setTodayOnly(true) }}
                      title="Show only this person's entries today"
                      style={{
                        padding: '6px 11px', borderRadius: 999, cursor: 'pointer', fontSize: 12, fontWeight: 700,
                        border: `1px solid ${byWho === p.name ? A : T.inputBorder}`,
                        background: byWho === p.name ? `${A}26` : 'transparent', color: byWho === p.name ? A : T.text,
                      }}>
                      {p.name} · {p.entries} entr{p.entries === 1 ? 'y' : 'ies'}, {p.units.toLocaleString()} units
                    </button>
                  ))}
                </div>
              </>
            )}
          </div>
        )}

        {!historyLoading && history.length > 0 && (
          <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap', marginBottom: 10 }}>
            <input type="search" value={query} onChange={e => setQuery(e.target.value)} aria-label="Search stock activity"
              placeholder="Search a product, reference, place or person…"
              style={{ ...fld, flex: '1 1 260px', width: 'auto', padding: '7px 11px', fontSize: 13 }} />
            <select value={byWho} onChange={e => setByWho(e.target.value)}
              style={{ ...fld, width: 'auto', padding: '6px 10px', fontSize: 12.5 }}>
              <option value="">Everyone</option>
              {everyone.map(n => <option key={n} value={n}>{n}</option>)}
            </select>
            <button type="button" onClick={() => setTodayOnly(v => !v)}
              style={{
                padding: '6px 11px', borderRadius: 7, cursor: 'pointer', fontSize: 12, fontWeight: 800,
                border: `1px solid ${todayOnly ? A : T.inputBorder}`, background: todayOnly ? `${A}26` : 'transparent', color: todayOnly ? A : T.sub,
              }}>
              Today only
            </button>
            <span style={{ fontSize: 12, color: T.sub }}>
              {searching
                ? (allLoading && !allHistory ? 'Searching every entry…' : `${shownHistory.length} match${shownHistory.length === 1 ? '' : 'es'} in all ${searchPool.length} entries`)
                : `${shownHistory.length} of the last ${history.length} entries`}
            </span>
          </div>
        )}

        {historyLoading ? (
          <div style={{ color: T.sub, fontSize: 13 }}>Loading…</div>
        ) : history.length === 0 ? (
          <div style={{ color: T.sub, fontSize: 13 }}>Nothing has been moved yet.</div>
        ) : shownHistory.length === 0 ? (
          <div style={{ color: T.sub, fontSize: 13 }}>{searching ? `Nothing matches “${query.trim()}”.` : 'Nothing matches that filter.'}</div>
        ) : (
          <div tabIndex={0} aria-label="Stock activity" style={{ overflow: 'auto', maxHeight: 460, overscrollBehavior: 'contain', borderRadius: 8, border: `1px solid ${T.border}` }}>
            <table style={{ width: '100%', borderCollapse: 'collapse' }}>
              <thead style={{ position: 'sticky', top: 0, zIndex: 1, background: T.card }}><tr>
                <th style={th}>REFERENCE</th><th style={th}>WHEN</th>
                <th style={th}>FROM → TO</th>
                <th style={th}>ENTERED BY</th>
                <th style={{ ...th, textAlign: 'right' }}>ITEMS</th>
                <th style={{ ...th, textAlign: 'right' }}>UNITS</th>
              </tr></thead>
              <tbody>
                {shownHistory.map(t => {
                  const items = t.items || []
                  const units  = items.reduce((s, i) => s + i.quantity, 0)
                  const spoilt = items.filter(i => i.condition === 'spoilt').reduce((s, i) => s + i.quantity, 0)
                  const open  = expanded === t.id
                  return (
                    <tr key={t.id} onClick={() => setExpanded(open ? null : t.id)}
                      style={{ cursor: 'pointer', borderBottom: `1px solid ${T.border}`, background: open ? T.headerBg : 'transparent' }}>
                      <td style={{ ...td, fontVariantNumeric: 'tabular-nums', color: A, fontWeight: 700 }}>
                        {t.transfer_number}
                        {!open && itemHits(t).length > 0 && (
                          <div style={{ marginTop: 4, fontFamily: 'inherit', fontSize: 11.5, color: T.sub, fontWeight: 400, whiteSpace: 'normal' }}>
                            {itemHits(t).slice(0, 3).map(i => <div key={i.position}>{i.quantity} × {i.model}</div>)}
                            {itemHits(t).length > 3 && <div>…and {itemHits(t).length - 3} more</div>}
                          </div>
                        )}
                        {open && (
                          <div style={{ marginTop: 8, fontFamily: 'inherit', color: T.sub, fontWeight: 400, whiteSpace: 'normal' }}>
                            {[...items].sort((a, b) => a.position - b.position).map(i => (
                              <div key={i.position}>
                                {i.quantity} × {i.model}
                                {i.other_model && (
                                  <span style={{ marginLeft: 8, fontSize: 11 }}>
                                    {t.from_line && t.to_line
                                      ? `(${LINE_LABEL[t.from_line === line ? t.to_line : t.from_line]} calls it ${i.other_model})`
                                      : `(joined “${i.other_model}” in ${t.to_warehouse})`}
                                  </span>
                                )}
                                {i.condition === 'spoilt' && (
                                  <span style={{ marginLeft: 8, color: '#ef4444', fontWeight: 800, fontSize: 11 }}>
                                    SPOILT · written off to {SPOILT}
                                  </span>
                                )}
                              </div>
                            ))}
                            {t.supplier && (
                              <div style={{ marginTop: 6 }}>
                                {t.kind === 'return' ? 'returned by ' : 'from '}{t.supplier}
                              </div>
                            )}
                            {t.note && <div style={{ marginTop: 6, fontStyle: 'italic' }}>{t.note}</div>}
                          </div>
                        )}
                      </td>
                      <td style={{ ...td, color: T.sub, whiteSpace: 'nowrap' }}>
                        {new Date(t.transferred_at).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: '2-digit' })}
                        <div style={{ fontSize: 11, color: T.muted }}>
                          {new Date(t.transferred_at).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })}
                        </div>
                      </td>
                      <td style={{ ...td, whiteSpace: 'nowrap' }}>
                        {t.kind === 'reversal' && (
                          <span style={{ marginRight: 6, padding: '1px 6px', borderRadius: 4, border: '1px solid #ef444488', color: '#ef4444', fontSize: 10, fontWeight: 900, letterSpacing: '0.1em' }}>REVERSAL</span>
                        )}
                        <span style={{ color: t.kind === 'move' || t.kind === 'reversal' ? T.sub : A }}>
                          {t.kind === 'move' || t.kind === 'reversal' ? placed(t.from_line ?? line, t.from_warehouse || '')
                            : t.supplier || (t.kind === 'return' ? 'Returned' : 'Outside')}
                        </span>
                        <span style={{ color: T.muted, margin: '0 6px' }}>→</span>
                        <span style={{ color: t.to_warehouse === STORE ? AMBER : T.text, fontWeight: 700 }}>{placed(t.to_line ?? line, t.to_warehouse)}</span>
                      </td>
                      {/* Who did it: the person first, then the login it was
                          entered under — on a stock phone those are different. */}
                      <td style={{ ...td, whiteSpace: 'nowrap', fontSize: 12.5 }}>
                        <span style={{ fontWeight: 700 }}>{t.signed_by || t.staff_id || '—'}</span>
                        {t.staff_id && t.signed_by && (
                          <div style={{ fontSize: 11, color: T.muted }}>login {t.staff_id}</div>
                        )}
                      </td>
                      <td style={{ ...td, textAlign: 'right', fontVariantNumeric: 'tabular-nums', color: T.sub }}>{items.length}</td>
                      <td style={{ ...td, textAlign: 'right', fontVariantNumeric: 'tabular-nums', fontWeight: 800 }}>
                        {units.toLocaleString()}
                        {spoilt > 0 && (
                          <div style={{ fontSize: 11, color: '#ef4444', fontWeight: 700 }}>{spoilt} spoilt</div>
                        )}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
      )}

      {toast && (
        <div style={{
          position: 'fixed', bottom: 20, left: '50%', transform: 'translateX(-50%)', zIndex: 200,
          padding: '12px 20px', borderRadius: 10, fontSize: 13, fontWeight: 700, maxWidth: '90vw',
          background: toast.ok ? A : '#ef4444', color: toast.ok ? onA : '#fff', boxShadow: '0 10px 30px rgba(0,0,0,0.35)',
        }}>{toast.msg}</div>
      )}
    </div>
  )
}
