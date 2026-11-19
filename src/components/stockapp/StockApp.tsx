'use client'

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { useRole } from '@/lib/sales'
import { cleanCode, loadCodeMap } from '@/lib/productCodes'
import {
  fetchLevels, fetchLocations, fetchLineStock, fetchStockHandlers, addStockHandler, removeStockHandler,
  signInHandler, setHandlerPassword, resetHandlerPassword,
  modelKey, similarNames, SPOILT, STORE,
  type Levels, type Location, type StockLine, type StockRow,
} from '@/lib/storeStock'
import { loadOutbox, saveOutbox, newRequestId, isOffline, send, type Pending } from '@/lib/stockOutbox'
import CameraScanner from '@/components/admin/CameraScanner'
import { settleAfterDelay } from '@/lib/stockApproval'
import ModelPicker, { type PickerOption } from '@/components/admin/ModelPicker'
import BossView from '@/components/stockapp/BossView'
import { TrialLock, useTrial } from '@/components/admin/TrialGate'

/**
 * Stock moves, on a phone — /s-quxf5u4k84, installable to the home screen.
 *
 * The same three movements as the Transfers tab (move, receive, return),
 * and nothing else: no history, no prices, no stock
 * editing. It exists so a movement is recorded where and when it happens —
 * standing at the shelf, by scanning the box — instead of from memory at a
 * desk afterwards, which is where most of a count's drift comes from.
 *
 * Three things make it safe to use in a warehouse with a bad signal:
 *
 *   • A movement is saved to the phone's outbox before it is sent, and only
 *     leaves it when the database confirms (stockOutbox.ts).
 *   • Every movement carries a request ID the database acts on once, so a
 *     retry can never move the stock twice.
 *   • Locations, on-hand figures and barcodes are kept from the last time
 *     they loaded, so the form still works with no signal at all. On-hand
 *     figures shown offline are marked as possibly out of date.
 *
 * WHO DID IT
 *   The phone is signed in once with a staff login and stays signed in —
 *   there is no idle sign-out here, or staff would be typing a password at
 *   the shelf all day. That login says which phone; it does not say which
 *   person. So before anything can be recorded, staff tap their own name
 *   from the stock staff list, and it is written onto every movement
 *   (20261005_stock_handlers.sql). Once someone has logged in with their
 *   name they stay logged in on that phone — through closing the app,
 *   through the night — until they log out themselves. The shop chose that
 *   over being asked every time; the price is that whoever picks the phone
 *   up next must log the last person out first, or their work goes under
 *   the wrong name. The name stays in the top bar so that is hard to miss.
 *
 *   A tapped name alone proves nothing, so each person has a password they
 *   set themselves (20261006_stock_staff_passwords.sql). Entering it gives
 *   the phone a key for that person, which goes with every movement they
 *   record; the database refuses a movement in their name without it. With
 *   no signal the password is checked against a fingerprint this phone kept
 *   from the last time it was accepted — never the password itself.
 */

// Light theme, the same palette as the admin panel and the boss's side of the
// app (BossView). Each colour is dark enough to read as text on white and to
// carry white text as a button. (TEAL is the action blue; the name is kept.)
const TEAL = '#1f5fd6'
const AMBER = '#b45309'
const RED = '#c81e1e'
const BG = '#eef1f6'
const CARD = '#ffffff'
const INPUT = '#ffffff'
const TEXT = '#0f172a'
const SUB = '#475569'
const LINE = '#d6dde8'

/** The phone app covers the main shop only. */
const LINES: readonly StockLine[] = ['main']

/** Who is logged in on this phone by name, and the key their password earned it. */
const HANDLER_KEY = 'teamstock:handler'
const WHO_KEY = 'teamstock:who'

// ── What this phone keeps so a password can be checked with no signal ──
// Per person: a salted fingerprint of their password, and the key the
// database issued for it. Only ever written after the database has accepted
// the password, and replaced each time it does.
const KEYS_KEY = 'teamstock:keys'
type KeptKey = { salt: string; hash: string; token: string }
const loadKeys = (): Record<string, KeptKey> => {
  try { return JSON.parse(localStorage.getItem(KEYS_KEY) || '{}') || {} } catch { return {} }
}
async function fingerprint(salt: string, password: string): Promise<string | null> {
  // Only available on HTTPS (and localhost) — which is where the app runs.
  if (typeof crypto === 'undefined' || !crypto.subtle) return null
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${salt}:${password}`))
  return Array.from(new Uint8Array(bytes), b => b.toString(16).padStart(2, '0')).join('')
}
async function keepKey(name: string, password: string, token: string) {
  const salt = newRequestId()
  const hash = await fingerprint(salt, password)
  if (!hash) return
  try { localStorage.setItem(KEYS_KEY, JSON.stringify({ ...loadKeys(), [name]: { salt, hash, token } })) } catch { /* storage blocked */ }
}
const forgetKey = (name: string) => {
  try { const k = loadKeys(); delete k[name]; localStorage.setItem(KEYS_KEY, JSON.stringify(k)) } catch { /* storage blocked */ }
}
const answerWithin = <T,>(p: Promise<T>, ms: number): Promise<T> =>
  Promise.race([p, new Promise<never>((_, reject) => setTimeout(() => reject(new Error('timeout')), ms))])

type Mode = 'move' | 'receive' | 'return'
const MODES: { key: Mode; label: string }[] = [
  { key: 'move', label: 'Move' },
  { key: 'receive', label: 'Receive' },
  { key: 'return', label: 'Return' },
]

interface Item {
  key: number
  model: string
  quantity: number
  spoilt?: boolean
  /** The name it joins at the destination, once staff have chosen one. */
  toModel?: string
}
let keyCounter = 0

const locKey = (l: Location | null) => (l ? `${l.line}|${l.name}` : '')
const parseLoc = (key: string): Location => {
  const i = key.indexOf('|')
  return { line: key.slice(0, i) as StockLine, name: key.slice(i + 1) }
}

/** How long the network gets to answer before the phone's own copy is used instead. */
const PATIENCE_MS = 4000

/**
 * Load from the network and keep a copy; with no network, hand back the copy.
 * `stale` tells the caller which it got.
 *
 * "No network" is not only a failed request. With no signal a request does
 * not fail quickly — it hangs, and Supabase spends up to half a minute
 * trying to renew the login before it even tries. So the copy is used at
 * once when the phone knows it is offline, and after a few seconds when the
 * network is simply not answering. The request is left running either way,
 * so the copy is fresh for next time if it ever does arrive.
 */
async function remember<T>(key: string, load: () => Promise<T>): Promise<{ value: T; stale: boolean }> {
  const k = `teamstock:${key}`
  const kept = (): { value: T; stale: boolean } | null => {
    try {
      const raw = localStorage.getItem(k)
      return raw ? { value: JSON.parse(raw) as T, stale: true } : null
    } catch { return null }
  }
  const fresh = load().then(value => {
    try { localStorage.setItem(k, JSON.stringify(value)) } catch { /* storage full */ }
    return { value, stale: false }
  })
  const copy = kept()
  if (!copy) return fresh
  fresh.catch(() => { /* the copy has already been handed back */ })
  if (typeof navigator !== 'undefined' && navigator.onLine === false) return copy
  return Promise.race([
    fresh.catch(() => copy),
    new Promise<{ value: T; stale: boolean }>(resolve => setTimeout(() => resolve(copy), PATIENCE_MS)),
  ])
}

const fld: React.CSSProperties = {
  width: '100%', padding: '13px 12px', borderRadius: 10, outline: 'none',
  // 16px or iOS zooms the page every time a field is focused.
  fontSize: 16, border: `1px solid ${LINE}`, background: INPUT, color: TEXT,
}
const lbl: React.CSSProperties = {
  fontSize: 13, fontWeight: 700, color: SUB, display: 'block', marginBottom: 6,
}
const pickerTheme = { menuBg: '#ffffff', border: LINE, text: TEXT, sub: SUB, accent: TEAL, accentText: '#fff' }

/** The trial lock sits in front of the whole app; see src/lib/trial.ts. */
export default function StockApp() {
  const trial = useTrial()
  if (trial.ready && trial.expired) return <TrialLock onSignOut={() => { supabase.auth.signOut() }} />
  return <StockAppInner />
}

function StockAppInner() {
  const [checking, setChecking] = useState(true)
  const [authed, setAuthed] = useState(false)
  const role = useRole()
  // With no signal for over an hour the login token expires and cannot be
  // renewed, and Supabase then reports "no session" — though nobody signed
  // out. The phone must keep working through that, so who it is signed in
  // as is kept from the last time it was known, and used until the signal
  // returns. Nothing recorded this way reaches the database until the real
  // login is live again; the outbox holds it.
  const [keptWho, setKeptWho] = useState<{ userId: string; canWrite: boolean } | null>(null)
  const userId      = role.userId ?? keptWho?.userId ?? null
  const canWrite    = role.userId ? role.canWrite : !!keptWho?.canWrite
  const isSuperBoss = role.userId ? role.isSuperBoss : false
  const roleLoading = role.loading

  // Who is holding the phone. Null until a name is tapped.
  const [handler, setHandler] = useState<string | null>(null)
  // The key that person's password earned this phone; sent with what they record.
  const [handlerToken, setHandlerToken] = useState<string | null>(null)
  const [handlers, setHandlers] = useState<string[]>([])
  const [withPassword, setWithPassword] = useState<Set<string>>(new Set())
  // The name that has been tapped and is waiting on its password.
  const [picking, setPicking] = useState<string | null>(null)
  const [passMode, setPassMode] = useState<'enter' | 'create' | 'change'>('enter')
  const [pass, setPass] = useState('')
  const [passNew, setPassNew] = useState('')
  const [passAgain, setPassAgain] = useState('')
  const [passError, setPassError] = useState('')
  const [passBusy, setPassBusy] = useState(false)
  const [handlersState, setHandlersState] = useState<'loading' | 'ready' | 'failed'>('loading')
  const [newName, setNewName] = useState('')
  const [nameError, setNameError] = useState('')
  const searchRow = useRef<HTMLDivElement | null>(null)

  const [loginId, setLoginId] = useState('')
  const [password, setPassword] = useState('')
  const [signingIn, setSigningIn] = useState(false)
  const [loginError, setLoginError] = useState('')

  const [online, setOnline] = useState(true)
  const [mode, setMode] = useState<Mode>('move')
  const [locations, setLocations] = useState<Record<StockLine, string[]>>({ main: [] })
  const [from, setFrom] = useState<Location | null>(null)
  const [to, setTo] = useState<Location | null>(null)
  const [party, setParty] = useState('')
  const [note, setNote] = useState('')
  const [items, setItems] = useState<Item[]>([])
  const [search, setSearch] = useState('')
  // "+ New product" on a delivery: a name typed on purpose, checked against the list.
  const [naming, setNaming] = useState(false)
  const [productName, setProductName] = useState('')

  const [levels, setLevels] = useState<Levels>(new Map())
  const [levelsStale, setLevelsStale] = useState(false)
  const [levelsLoading, setLevelsLoading] = useState(false)
  const [lineStock, setLineStock] = useState<Record<StockLine, StockRow[]>>({ main: [] })
  const [codeMaps, setCodeMaps] = useState<Record<StockLine, Map<string, string>>>({ main: new Map() })

  const [camera, setCamera] = useState(false)
  const [flash, setFlash] = useState<{ ok: boolean; text: string } | null>(null)
  const [banner, setBanner] = useState<{ tone: 'ok' | 'wait' | 'err'; title: string; sub?: string } | null>(null)
  const [saving, setSaving] = useState(false)

  const [outbox, setOutbox] = useState<Pending[]>([])
  const [showOutbox, setShowOutbox] = useState(false)
  // A boss login opens on sales, activity and prices; stock moves is one tap away.
  const [view, setView] = useState<'boss' | 'moves'>('boss')
  // Bumped by the Refresh button: every list below reloads when it changes.
  const [tick, setTick] = useState(0)
  const [refreshing, setRefreshing] = useState(false)
  const outboxRef = useRef<Pending[]>([])
  const flushing = useRef(false)

  // ── Session ──────────────────────────────────────────────
  useEffect(() => {
    let mounted = true
    // A stored login that could not be renewed for lack of signal. Supabase
    // deletes its stored token on a real sign-out, so "token still there" is
    // what tells the two apart.
    const keptLogin = () => {
      try {
        const hasToken = Object.keys(localStorage).some(k => /^sb-.+-auth-token$/.test(k) && !!localStorage.getItem(k))
        const who = JSON.parse(localStorage.getItem(WHO_KEY) || 'null')
        return hasToken && who?.userId ? who as { userId: string; canWrite: boolean } : null
      } catch { return null }
    }
    const settle = (signedIn: boolean) => {
      if (!mounted) return
      const kept = signedIn ? null : keptLogin()
      if (kept) setKeptWho(kept)
      setAuthed(signedIn || !!kept); setChecking(false)
    }
    supabase.auth.getSession().then(({ data: { session } }) => settle(!!session)).catch(() => settle(false))
    // With an expired login and no signal, that call spends half a minute
    // retrying before it answers. A phone already signed in does not wait
    // for it: it opens as who it was, and the answer corrects it if needed.
    const early = setTimeout(() => {
      if (!mounted) return
      const kept = keptLogin()
      if (kept) { setKeptWho(kept); setAuthed(true); setChecking(false) }
    }, navigator.onLine === false ? 0 : 1500)
    const { data: listener } = supabase.auth.onAuthStateChange((event) => {
      if (!mounted) return
      if (event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED') { setAuthed(true); setChecking(false) }
      else if (event === 'SIGNED_OUT') {
        // Fired for a real sign-out, and also when a renewal fails. Only the
        // first removes the stored token.
        const kept = keptLogin()
        setKeptWho(kept); setAuthed(!!kept); setChecking(false)
      }
    })
    return () => { mounted = false; clearTimeout(early); listener.subscription.unsubscribe() }
  }, [])

  // Remember who this phone is signed in as, while that is known for certain.
  useEffect(() => {
    if (!role.userId || role.loading || !navigator.onLine) return
    try { localStorage.setItem(WHO_KEY, JSON.stringify({ userId: role.userId, canWrite: role.canWrite })) } catch { /* storage blocked */ }
  }, [role.userId, role.loading, role.canWrite])

  /** A deliberate sign-out forgets the phone's login entirely. */
  const signOutPhone = useCallback(() => {
    try { localStorage.removeItem(WHO_KEY) } catch { /* storage blocked */ }
    setKeptWho(null)
    supabase.auth.signOut().finally(() => setAuthed(false))
  }, [])

  // ── Whose hands the phone is in ──────────────────────────
  // Kept on the phone: a person stays logged in until they log out.
  // Passing null is logging out.
  const chooseHandler = useCallback((name: string | null, token: string | null = null) => {
    setHandler(name)
    setHandlerToken(name ? token : null)
    try {
      if (name) localStorage.setItem(HANDLER_KEY, JSON.stringify({ name, token }))
      else localStorage.removeItem(HANDLER_KEY)
    } catch { /* storage blocked */ }
  }, [])

  useEffect(() => {
    try {
      const kept = JSON.parse(localStorage.getItem(HANDLER_KEY) || 'null')
      if (kept?.name) { setHandler(kept.name); setHandlerToken(kept.token ?? null) }
    } catch { /* nobody was logged in */ }
  }, [])

  const loadHandlers = useCallback(async () => {
    try {
      const r = await remember('handlers2', fetchStockHandlers)
      setHandlers(r.value.map(h => h.name))
      setWithPassword(new Set(r.value.filter(h => h.hasPassword).map(h => h.name)))
      setHandlersState('ready')
    } catch {
      setHandlersState('failed')
    }
  }, [])
  useEffect(() => { if (authed) loadHandlers() }, [authed, loadHandlers])

  // A name taken off the list cannot sign anything; the database would refuse it.
  useEffect(() => {
    if (handler && handlersState === 'ready' && !handlers.includes(handler)) chooseHandler(null)
  }, [handler, handlers, handlersState, chooseHandler])

  // ── Installable, and able to open with no signal ─────────
  useEffect(() => {
    // Production only: in development a service worker serves stale bundles.
    if (process.env.NODE_ENV === 'production' && 'serviceWorker' in navigator) {
      navigator.serviceWorker.register('/sw-s-quxf5u4k84.js', { scope: '/s-quxf5u4k84' }).catch(() => { /* still works online */ })
    }
    setOnline(navigator.onLine)
    const up = () => setOnline(true)
    const down = () => setOnline(false)
    window.addEventListener('online', up)
    window.addEventListener('offline', down)
    return () => { window.removeEventListener('online', up); window.removeEventListener('offline', down) }
  }, [])

  // ── Outbox ───────────────────────────────────────────────
  const commit = useCallback((list: Pending[]) => {
    outboxRef.current = list
    setOutbox(list)
    saveOutbox(list)
  }, [])
  useEffect(() => { const list = loadOutbox(); outboxRef.current = list; setOutbox(list) }, [])

  const reloadStock = useCallback(() => {
    for (const l of LINES) {
      remember(`stock:${l}`, () => fetchLineStock(l))
        .then(r => setLineStock(s => ({ ...s, [l]: r.value }))).catch(() => { /* suggestions stay off */ })
    }
  }, [])

  /**
   * Send everything waiting, oldest first, stopping at the first one that
   * cannot get through — order matters when one movement stocks a location
   * and the next moves out of it.
   */
  const flush = useCallback(async () => {
    if (flushing.current || !userId) return
    flushing.current = true
    let sent = 0
    try {
      for (const p of outboxRef.current.filter(x => x.userId === userId && !x.error)) {
        try {
          const t = await send(p)
          commit(outboxRef.current.filter(x => x.requestId !== p.requestId))
          setBanner(t.pending
            ? { tone: 'ok', title: `${t.request_number || t.transfer_number} sent for approval`, sub: `The stock changes once the Big Boss approves it. ${p.summary}` }
            : { tone: 'ok', title: `${t.transfer_number} ✓`, sub: p.summary })
          // With auto-accept on, this phone settles it when its time is up.
          if (t.pending) settleAfterDelay()
          sent++
        } catch (e: any) {
          if (isOffline(e)) break
          commit(outboxRef.current.map(x => x.requestId === p.requestId
            ? { ...x, error: e?.message || 'The database refused this movement' } : x))
          setBanner({ tone: 'err', title: 'Not saved — needs checking', sub: e?.message || p.summary })
        }
      }
    } finally {
      flushing.current = false
    }
    if (sent) reloadStock()
    return sent
  }, [userId, commit, reloadStock])

  // Try again whenever there is a reason to think it might now get through.
  useEffect(() => {
    if (!authed || !userId) return
    flush()
    const onVisible = () => { if (document.visibilityState === 'visible') flush() }
    window.addEventListener('online', flush)
    document.addEventListener('visibilitychange', onVisible)
    const timer = setInterval(flush, 30_000)
    return () => {
      window.removeEventListener('online', flush)
      document.removeEventListener('visibilitychange', onVisible)
      clearInterval(timer)
    }
  }, [authed, userId, flush])

  /**
   * Refresh: fetch everything again — staff names, locations, what each
   * warehouse holds, barcodes — and push out anything still waiting to send.
   * The lists also reload by themselves when the app is opened; this is for
   * when something was just changed elsewhere (a name added, stock counted)
   * and the phone should show it now.
   */
  const refresh = useCallback(async () => {
    if (refreshing) return
    setRefreshing(true)
    setTick(t => t + 1)
    // Long enough to show it did something, never long enough to hang on a dead signal.
    await Promise.race([
      Promise.all([loadHandlers(), flush(), new Promise(r => setTimeout(r, 600))]),
      new Promise(r => setTimeout(r, 6000)),
    ])
    setRefreshing(false)
    setBanner(navigator.onLine === false
      ? { tone: 'wait', title: 'No signal', sub: 'Showing the lists this phone saved last time. Try again when the signal is back.' }
      : { tone: 'ok', title: 'Up to date ✓', sub: 'Names, locations and stock figures reloaded.' })
  }, [refreshing, loadHandlers, flush])

  // ── Locations, barcodes, names ───────────────────────────
  useEffect(() => {
    if (!authed) return
    ;(async () => {
      const got: Record<StockLine, string[]> = { main: [] }
      for (const l of LINES) {
        try { got[l] = (await remember(`locations:${l}`, () => fetchLocations(l))).value } catch { /* that line stays empty */ }
      }
      setLocations(got)
      // The usual job: out of the first back warehouse, onto the shop floor.
      const firstFrom = got.main.find(n => n !== STORE && n !== SPOILT) || got.main[0]
      setFrom(f => f ?? (firstFrom ? { line: 'main', name: firstFrom } : null))
      const firstTo = got.main.includes(STORE) ? STORE : got.main.find(n => n !== SPOILT && n !== firstFrom)
      setTo(t => t ?? (firstTo ? { line: 'main', name: firstTo } : null))
    })()
    for (const l of LINES) {
      remember(`codes:${l}`, async () => Array.from(await loadCodeMap('product_codes')))
        .then(r => setCodeMaps(c => ({ ...c, [l]: new Map(r.value) }))).catch(() => { /* scanning stays off */ })
    }
    reloadStock()
  }, [authed, reloadStock, tick])

  // On a move the figures that matter are the SOURCE's; on a delivery or a
  // return, the destination's — what it already stocks, and under what name.
  const ref = mode === 'move' ? from : to
  const refKey = locKey(ref)

  const loadLevels = useCallback(async (loc: Location) => {
    const r = await remember(`levels:${locKey(loc)}`, async () => Array.from(await fetchLevels(loc.name, loc.line)))
    return { levels: new Map(r.value) as Levels, stale: r.stale }
  }, [])

  useEffect(() => {
    if (!authed || !refKey) { setLevels(new Map()); return }
    let cancelled = false
    setLevelsLoading(true)
    loadLevels(parseLoc(refKey))
      .then(r => { if (!cancelled) { setLevels(r.levels); setLevelsStale(r.stale) } })
      .catch(() => { if (!cancelled) { setLevels(new Map()); setLevelsStale(true) } })
      .finally(() => { if (!cancelled) setLevelsLoading(false) })
    return () => { cancelled = true }
  }, [authed, refKey, loadLevels, tick])

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
    return { main: build(lineStock.main) }
  }, [lineStock])

  const options = useMemo<PickerOption[]>(() => {
    const here = Array.from(levels, ([model, qty]) => ({ model, qty })).sort((a, b) => a.model.localeCompare(b.model))
    if (!ref) return here
    // On a move, what the source can actually send comes first. STORE STOCK
    // lists every product the shop carries, most of them at 0.
    if (mode === 'move') {
      const empty = here.filter(o => o.qty <= 0)
      if (!empty.length) return here
      return [
        ...here.filter(o => o.qty > 0).map(o => ({ ...o, group: `In stock in ${ref.name}` })),
        ...empty.map(o => ({ ...o, group: `Listed in ${ref.name}, none in stock` })),
      ]
    }
    const elsewhere = Array.from(names[ref.line].exact).filter(m => !levels.has(m)).sort((a, b) => a.localeCompare(b))
      .map(model => ({ model, group: 'Stocked in other locations' }))
    return [...here.map(o => ({ ...o, group: `In ${ref.name}` })), ...elsewhere]
  }, [levels, mode, ref, names])

  /**
   * What the destination warehouse itself already stocks. A move must not
   * open a second row there for a product it has under another spelling.
   */
  const destHere = useMemo(() => {
    const exact = new Set<string>()
    const byKey = new Map<string, string>()
    const qty = new Map<string, number>()
    if (to) {
      for (const r of lineStock[to.line]) {
        if (r.warehouse !== to.name) continue
        exact.add(r.model)
        qty.set(r.model, (qty.get(r.model) || 0) + r.closing_stock)
        const k = modelKey(r.model)
        if (k && !byKey.has(k)) byKey.set(k, r.model)
      }
    }
    return { exact, byKey, qty }
  }, [lineStock, to])

  /** The destination warehouse's own spelling first, then the shop's, then the name it left under. */
  const suggestArrival = useCallback((model: string) => {
    if (!to) return model
    const m = model.trim()
    const k = modelKey(m)
    if (destHere.exact.has(m)) return m
    const dest = names[to.line]
    return destHere.byKey.get(k) ?? (dest.exact.has(m) ? m : dest.byKey.get(k) ?? m)
  }, [destHere, names, to])
  const arrivesAs = (i: Item) => (i.toModel ?? suggestArrival(i.model)).trim()

  const arrivalOptions = useMemo<PickerOption[]>(() => {
    if (mode !== 'move' || !to) return []
    const byName = (a: string, b: string) => a.localeCompare(b)
    return [
      ...Array.from(destHere.exact).sort(byName).map(model => ({ model, group: `In ${to.name}` })),
      ...Array.from(names[to.line].exact).filter(m => !destHere.exact.has(m)).sort(byName)
        .map(model => ({ model, group: 'Elsewhere in the shop' })),
    ]
  }, [mode, to, names, destHere])

  // ── Items ────────────────────────────────────────────────
  const setItem = (key: number, patch: Partial<Item>) =>
    setItems(list => list.map(i => (i.key === key ? { ...i, ...patch } : i)))

  /** Adding what is already on the list bumps it: scanning six boxes is six scans. */
  const addOrBump = useCallback((model: string) => {
    setItems(list => {
      const hit = list.find(i => i.model === model)
      return hit
        ? list.map(i => (i === hit ? { ...i, quantity: i.quantity + 1 } : i))
        : [...list, { key: ++keyCounter, model, quantity: 1 }]
    })
    setFlash({ ok: true, text: model })
    try { navigator.vibrate?.(35) } catch { /* no haptics */ }
  }, [])

  const add = useCallback((raw: string) => {
    const model = raw.trim()
    if (!model) return
    // You cannot send what the source has never held; the database says the
    // same. With no figures at all (first use, no signal) it is left to the
    // database to judge when the movement is sent.
    if (mode === 'move' && levels.size > 0 && !levels.has(model)) {
      setFlash({ ok: false, text: `${from?.name ?? 'The source'} has never carried ${model}` })
      return
    }
    addOrBump(model)
    setSearch('')
  }, [mode, levels, from, addOrBump])

  const handleScan = useCallback((raw: string) => {
    const code = cleanCode(raw.trim())
    if (!code || !ref) return
    const model = codeMaps[ref.line].get(code)
    if (!model) {
      setFlash({ ok: false, text: 'Unknown barcode — link it in Codes first, or pick the item by name' })
      try { navigator.vibrate?.([60, 40, 60]) } catch { /* no haptics */ }
      return
    }
    add(model)
  }, [codeMaps, ref, add])

  const units = items.reduce((s, i) => s + i.quantity, 0)
  const short = mode === 'move' ? items.filter(i => (levels.get(i.model) ?? 0) < i.quantity) : []

  // ── Save ─────────────────────────────────────────────────
  const submit = async () => {
    if (!userId || !to || !handler || saving) return
    if (mode === 'move') {
      if (!from) return setBanner({ tone: 'err', title: 'Pick where the stock is coming from' })
      if (locKey(from) === locKey(to)) return setBanner({ tone: 'err', title: 'Pick two different locations' })
    }
    if (!items.length) return setBanner({ tone: 'err', title: 'Add at least one item' })
    if (short.length && !levelsStale && !confirm(
      `${from!.name} does not hold enough of:\n\n` +
      short.map(i => `• ${i.model} — has ${levels.get(i.model) ?? 0}, sending ${i.quantity}`).join('\n') +
      `\n\nMove anyway? ${from!.name} will go negative, and the count there needs checking.`,
    )) return

    const spoilt = items.filter(i => i.spoilt).reduce((s, i) => s + i.quantity, 0)
    const summary = mode === 'move' ? `${units} unit${units === 1 ? '' : 's'} · ${from!.name} → ${to.name}`
      : mode === 'receive' ? `${units} unit${units === 1 ? '' : 's'} received into ${to.name}`
      : `${units - spoilt} back into ${to.name}${spoilt ? `, ${spoilt} spoilt` : ''}`

    const pending: Pending = {
      requestId: newRequestId(),
      userId,
      kind: mode,
      from: mode === 'move' ? from : null,
      to,
      items: items.map(i => ({
        model: i.model,
        quantity: i.quantity,
        // The name it joins at the destination, when that is not the name it left under.
        ...(mode === 'move' && arrivesAs(i) !== i.model ? { to_model: arrivesAs(i) } : {}),
        ...(mode === 'return' ? { condition: i.spoilt ? 'spoilt' as const : 'good' as const } : {}),
      })),
      party: mode === 'move' ? undefined : party.trim() || undefined,
      note: note.trim() || undefined,
      when: new Date().toISOString(),
      doneBy: handler,
      doneToken: handlerToken ?? undefined,
      summary,
    }

    // Onto the phone first. From here it cannot be lost, only delayed.
    commit([...outboxRef.current, pending])
    setItems([]); setNote(''); setParty(''); setSearch(''); setFlash(null)

    // It is safe on the phone already, so the button does not hold staff
    // up waiting on a network that may never answer: a few seconds with a
    // signal, not at all without one. Sending carries on behind.
    setSaving(true)
    await Promise.race([flush(), new Promise(r => setTimeout(r, navigator.onLine === false ? 0 : 8000))])
    setSaving(false)

    if (outboxRef.current.some(p => p.requestId === pending.requestId && !p.error)) {
      setBanner({
        tone: 'wait',
        title: 'Saved on this phone',
        sub: 'Not sent yet. It will send by itself when the signal is back — do not enter it again.',
      })
    }
    if (ref) loadLevels(ref).then(r => { setLevels(r.levels); setLevelsStale(r.stale) }).catch(() => { /* next change reloads */ })
  }

  const mine = outbox.filter(p => p.userId === userId)
  const waiting = mine.filter(p => !p.error).length
  const refused = mine.filter(p => p.error).length

  // ── Screens ──────────────────────────────────────────────
  const page: React.CSSProperties = {
    minHeight: '100dvh', background: BG, color: TEXT,
    fontFamily: 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
  }

  if (checking || (authed && roleLoading && !keptWho)) {
    return <div style={{ ...page, display: 'flex', alignItems: 'center', justifyContent: 'center', color: SUB }}>Loading…</div>
  }

  if (!authed) {
    return (
      <div style={{ ...page, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 20 }}>
        <form style={{ width: '100%', maxWidth: 380 }} onSubmit={async e => {
          e.preventDefault()
          if (!loginId.trim() || !password) return setLoginError('Staff ID and password required')
          // Staff type their handle; the full staff ID is handle@qbnettech.com.
          const raw = loginId.trim()
          const email = raw.includes('@') ? raw : `${raw.toLowerCase()}@qbnettech.com`
          setSigningIn(true); setLoginError('')
          const { error } = await supabase.auth.signInWithPassword({ email, password })
          setSigningIn(false)
          if (error) setLoginError(error.message || 'Sign in failed')
          else setPassword('')
        }}>
          <div style={{ textAlign: 'center', marginBottom: 26 }}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src="/s-quxf5u4k84-192.png?v=2" alt="" width={72} height={72} style={{ borderRadius: 18 }} />
            <h1 style={{ fontSize: 24, fontWeight: 900, margin: '14px 0 4px' }}>Stock moves</h1>
            <div style={{ color: SUB, fontSize: 13 }}>QBNET TECH · staff sign in</div>
          </div>
          <label style={lbl}>Staff ID</label>
          <input style={{ ...fld, marginBottom: 14 }} value={loginId} onChange={e => setLoginId(e.target.value)}
            autoComplete="username" autoCapitalize="none" autoCorrect="off" />
          <label style={lbl}>Password</label>
          <input style={{ ...fld, marginBottom: 18 }} type="password" value={password}
            onChange={e => setPassword(e.target.value)} autoComplete="current-password" />
          {loginError && <div style={{ color: RED, fontSize: 13, fontWeight: 700, marginBottom: 12 }}>{loginError}</div>}
          <button type="submit" disabled={signingIn}
            style={{ width: '100%', padding: 15, borderRadius: 12, border: 'none', background: TEAL, color: '#fff', fontWeight: 900, fontSize: 16, opacity: signingIn ? 0.6 : 1 }}>
            {signingIn ? 'Signing in…' : 'Sign in'}
          </button>
          <div style={{ color: SUB, fontSize: 12.5, marginTop: 14, textAlign: 'center' }}>
            Done once per phone. After this, staff only tap their name.
          </div>
        </form>
      </div>
    )
  }

  // ── The boss's side ──────────────────────────────────────
  // Only once the role is known for certain: with no signal the phone runs
  // on what it remembers, and that is enough to record stock, not to show
  // sales figures.
  if (role.isBoss && view === 'boss') {
    return <BossView isSuperBoss={isSuperBoss} windowed={role.windowed} onMoves={() => setView('moves')} onSignOut={signOutPhone} />
  }
  const backToBoss = role.isBoss && (
    <button type="button" onClick={() => setView('boss')}
      style={{ background: 'none', border: 'none', padding: 0, color: TEAL, fontWeight: 800, fontSize: 14, marginBottom: 14 }}>
      ← Sales, activity and prices
    </button>
  )

  // ── Who is recording ─────────────────────────────────────
  if (canWrite && !handler) {
    const addName = async () => {
      const name = newName.trim()
      if (name.length < 2) return setNameError('Type the name first')
      setNameError('')
      try { await addStockHandler(name); setNewName(''); await loadHandlers() }
      catch (e: any) { setNameError(e?.message || 'Could not add that name') }
    }
    const pickName = (name: string) => {
      setPicking(name); setPassMode(withPassword.has(name) ? 'enter' : 'create')
      setPass(''); setPassNew(''); setPassAgain(''); setPassError('')
    }
    const letIn = (name: string, token: string) => {
      chooseHandler(name, token)
      setPicking(null); setPass(''); setPassNew(''); setPassAgain(''); setPassError('')
    }

    /** Check the password with the database; with no signal, against what this phone kept. */
    const enter = async () => {
      const name = picking!
      if (!pass) return setPassError('Enter your password')
      setPassBusy(true); setPassError('')
      try {
        if (navigator.onLine === false) throw new Error('offline')
        const res = await answerWithin(signInHandler(name, pass), 7000)
        if (res.ok) { await keepKey(name, pass, res.token); letIn(res.name, res.token) }
        else if (res.no_password) { forgetKey(name); setPassMode('create'); setPass(''); loadHandlers() }
        else setPassError(res.error)
      } catch (e: any) {
        if (e?.code && !isOffline(e)) setPassError(e.message || 'Could not check the password')
        else {
          const kept = loadKeys()[name]
          if (!kept) setPassError('No signal. The first time you use your password on this phone, it needs a signal.')
          else if ((await fingerprint(kept.salt, pass)) === kept.hash) letIn(name, kept.token)
          else setPassError('Wrong password')
        }
      }
      setPassBusy(false)
    }

    /** Set a first password, or change one. Both need the database, so both need a signal. */
    const setPassword = async () => {
      const name = picking!
      if (passMode === 'change' && !pass) return setPassError('Enter your current password')
      if (passNew.length < 4) return setPassError('Use at least 4 characters')
      if (passNew !== passAgain) return setPassError('The two passwords are not the same')
      setPassBusy(true); setPassError('')
      try {
        const res = await answerWithin(setHandlerPassword(name, passNew, passMode === 'change' ? pass : undefined), 9000)
        if (res.ok) { await keepKey(name, passNew, res.token); loadHandlers(); letIn(res.name, res.token) }
        else setPassError(res.error === 'The current password is wrong' && passMode === 'create'
          ? 'A password has already been set for this name. Go back and enter it, or ask the Big Boss to reset it.'
          : res.error)
      } catch (e: any) {
        setPassError(e?.code && !isOffline(e) ? (e.message || 'Could not save the password') : 'Setting a password needs a signal. Try again when you have one.')
      }
      setPassBusy(false)
    }

    if (picking) {
      const passFld: React.CSSProperties = { ...fld, marginBottom: 12 }
      return (
        <div style={{ ...page, padding: 'calc(28px + env(safe-area-inset-top)) 18px 28px' }}>
          <form style={{ maxWidth: 440, margin: '0 auto' }} onSubmit={e => { e.preventDefault(); if (!passBusy) (passMode === 'enter' ? enter() : setPassword()) }}>
            <button type="button" onClick={() => setPicking(null)}
              style={{ background: 'none', border: 'none', padding: 0, color: TEAL, fontWeight: 800, fontSize: 14, marginBottom: 14 }}>
              ← Not {picking}
            </button>
            <h1 style={{ fontSize: 26, fontWeight: 900, margin: '0 0 6px' }}>{picking}</h1>
            <div style={{ color: SUB, fontSize: 14, marginBottom: 18 }}>
              {passMode === 'enter' ? 'Enter your password.'
                : passMode === 'create' ? 'Choose a password. You will enter it each time you pick your name, so nobody else can record stock as you. Do not share it.'
                : 'Change your password. Other phones will ask for the new one.'}
            </div>

            {/* autoComplete="new-password" on every field: on a shared phone the
                browser must not offer one person's saved password to the next. */}
            {passMode !== 'create' && (
              <>
                <label style={lbl}>{passMode === 'change' ? 'Current password' : 'Password'}</label>
                <input style={passFld} type="password" value={pass} onChange={e => setPass(e.target.value)}
                  autoComplete="new-password" autoCapitalize="none" autoCorrect="off" autoFocus />
              </>
            )}
            {passMode !== 'enter' && (
              <>
                <label style={lbl}>New password</label>
                <input style={passFld} type="password" value={passNew} onChange={e => setPassNew(e.target.value)}
                  autoComplete="new-password" autoCapitalize="none" autoCorrect="off" autoFocus={passMode === 'create'} />
                <label style={lbl}>New password again</label>
                <input style={passFld} type="password" value={passAgain} onChange={e => setPassAgain(e.target.value)}
                  autoComplete="new-password" autoCapitalize="none" autoCorrect="off" />
              </>
            )}
            {passError && <div style={{ color: RED, fontSize: 13.5, fontWeight: 700, marginBottom: 12 }}>{passError}</div>}

            <button type="submit" disabled={passBusy}
              style={{ width: '100%', padding: 15, borderRadius: 12, border: 'none', background: TEAL, color: '#fff', fontWeight: 900, fontSize: 16, opacity: passBusy ? 0.6 : 1 }}>
              {passBusy ? 'Checking…' : passMode === 'enter' ? 'Continue' : 'Save password'}
            </button>

            {passMode === 'enter' && (
              <div style={{ marginTop: 18, fontSize: 13, color: SUB }}>
                <button type="button" onClick={() => { setPassMode('change'); setPass(''); setPassError('') }}
                  style={{ background: 'none', border: 'none', padding: 0, color: TEAL, fontWeight: 800, fontSize: 13, textDecoration: 'underline' }}>
                  Change my password
                </button>
                <div style={{ marginTop: 8 }}>Forgotten it? Ask the Big Boss to reset it.</div>
              </div>
            )}
            {passMode === 'change' && (
              <button type="button" onClick={() => { setPassMode('enter'); setPassError('') }}
                style={{ marginTop: 18, background: 'none', border: 'none', padding: 0, color: SUB, fontSize: 13, textDecoration: 'underline' }}>
                Cancel
              </button>
            )}
          </form>
        </div>
      )
    }

    return (
      <div style={{ ...page, padding: 'calc(28px + env(safe-area-inset-top)) 18px 28px' }}>
        <div style={{ maxWidth: 440, margin: '0 auto' }}>
          {backToBoss}
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 6 }}>
            <h1 style={{ fontSize: 26, fontWeight: 900, margin: 0, flex: 1 }}>Who is recording?</h1>
            <button type="button" onClick={refresh} disabled={refreshing}
              style={{ padding: '9px 13px', borderRadius: 10, border: `1px solid ${LINE}`, background: CARD, color: TEAL, fontWeight: 800, fontSize: 13, opacity: refreshing ? 0.6 : 1 }}>
              {refreshing ? 'Refreshing…' : '↻ Refresh'}
            </button>
          </div>
          <div style={{ color: SUB, fontSize: 14, marginBottom: 20 }}>
            Tap your own name, then enter your password. Your name goes on every stock movement you record.
          </div>

          {handlersState === 'loading' && <div style={{ color: SUB }}>Loading…</div>}
          {handlersState === 'failed' && (
            <div style={{ color: RED, fontSize: 14, fontWeight: 700 }}>
              The staff list could not be loaded. Check the signal and{' '}
              <button type="button" onClick={loadHandlers} style={{ background: 'none', border: 'none', padding: 0, color: TEAL, fontWeight: 800, fontSize: 14, textDecoration: 'underline' }}>try again</button>.
            </div>
          )}
          {handlersState === 'ready' && handlers.length === 0 && (
            <div style={{ background: CARD, border: `1px solid ${LINE}`, borderRadius: 12, padding: 16, color: SUB, fontSize: 14 }}>
              No stock staff have been added yet. {isSuperBoss ? 'Add the first name below.' : 'Ask the Big Boss to add your name.'}
            </div>
          )}

          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            {handlers.map(name => (
              <div key={name} style={{ display: 'flex', gap: 8 }}>
                <button type="button" onClick={() => pickName(name)}
                  style={{ flex: 1, minWidth: 0, padding: '16px 16px', borderRadius: 14, border: `1px solid ${LINE}`, background: CARD, color: TEXT, fontSize: 18, fontWeight: 800, textAlign: 'left' }}>
                  {name}
                  {!withPassword.has(name) && (
                    <span style={{ display: 'block', fontSize: 12, fontWeight: 700, color: AMBER, marginTop: 2 }}>No password yet — tap to set one</span>
                  )}
                </button>
                {/* A forgotten password is the Big Boss's to clear; the person then sets a new one. */}
                {isSuperBoss && withPassword.has(name) && (
                  <button type="button"
                    onClick={async () => {
                      if (!confirm(`Reset ${name}'s password?\n\nThey will be asked to choose a new one the next time they pick their name.`)) return
                      try { await resetHandlerPassword(name); forgetKey(name); await loadHandlers() }
                      catch (e: any) { setNameError(e?.message || 'Could not reset that password') }
                    }}
                    style={{ padding: '0 12px', borderRadius: 14, border: `1px solid ${LINE}`, background: CARD, color: TEAL, fontSize: 12.5, fontWeight: 800 }}>Reset</button>
                )}
                {isSuperBoss && (
                  <button type="button" aria-label={`Remove ${name}`}
                    onClick={async () => {
                      if (!confirm(`Take ${name} off the stock staff list?\n\nMovements they already recorded keep their name.`)) return
                      try { await removeStockHandler(name); await loadHandlers() }
                      catch (e: any) { setNameError(e?.message || 'Could not remove that name') }
                    }}
                    style={{ width: 54, borderRadius: 14, border: `1px solid ${LINE}`, background: CARD, color: RED, fontSize: 16 }}>✕</button>
                )}
              </div>
            ))}
          </div>

          {/* The list is the Big Boss's: it decides whose name a record can carry. */}
          {isSuperBoss && handlersState === 'ready' && (
            <div style={{ marginTop: 22 }}>
              <label style={lbl}>Add stock staff</label>
              <div style={{ display: 'flex', gap: 8 }}>
                <input style={fld} value={newName} onChange={e => setNewName(e.target.value)} maxLength={60}
                  placeholder="Full name" autoCapitalize="words"
                  onKeyDown={e => { if (e.key === 'Enter') addName() }} />
                <button type="button" onClick={addName}
                  style={{ padding: '0 20px', borderRadius: 10, border: 'none', background: TEAL, color: '#fff', fontWeight: 900, fontSize: 15 }}>Add</button>
              </div>
            </div>
          )}
          {nameError && <div style={{ color: RED, fontSize: 13, fontWeight: 700, marginTop: 10 }}>{nameError}</div>}

          <button type="button"
            onClick={() => {
              if (waiting && !confirm(`${waiting} movement${waiting === 1 ? ' is' : 's are'} still waiting to send. They stay on this phone and send next time you sign in here. Sign out?`)) return
              signOutPhone()
            }}
            style={{ marginTop: 28, background: 'none', border: 'none', padding: 0, color: SUB, fontSize: 13, textDecoration: 'underline' }}>
            Sign this phone out
          </button>
        </div>
      </div>
    )
  }


  const locationSelect = (value: Location | null, onPick: (l: Location) => void, skip: (l: Location) => boolean) => (
    <select style={fld} value={locKey(value)} onChange={e => onPick(parseLoc(e.target.value))}>
      {!value && <option value="">Choose…</option>}
      {LINES.flatMap(l => locations[l].filter(name => !skip({ line: l, name }))
        .map(name => <option key={`${l}|${name}`} value={`${l}|${name}`}>{name}</option>))}
    </select>
  )
  // Deliveries and returns never land in SPOILT by hand, and stay on one line.
  const noSpoilt = (l: Location) => l.name === SPOILT

  const typed = search.trim()
  const canAddNew = mode !== 'move' && typed && !options.some(o => o.model === typed)
  const typedTwin = canAddNew && ref ? names[ref.line].byKey.get(modelKey(typed)) : undefined

  return (
    <div style={{ ...page, paddingTop: 'calc(68px + env(safe-area-inset-top))', paddingBottom: 'calc(96px + env(safe-area-inset-bottom))' }}>
      {/* ── Top bar ── */}
      {/* Fixed, not sticky: the site sets overflow-x on the page, and sticky does not hold under that. */}
      <div style={{ position: 'fixed', top: 0, left: 0, right: 0, zIndex: 60, background: BG, borderBottom: `1px solid ${LINE}`, padding: 'calc(10px + env(safe-area-inset-top)) 14px 10px', display: 'flex', alignItems: 'center', gap: 10 }}>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 11.5, fontWeight: 600, color: SUB, whiteSpace: 'nowrap' }}>QBNET TECH</div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 7, fontWeight: 800, fontSize: 18, whiteSpace: 'nowrap', lineHeight: 1.2 }}>
            Stock moves
            <span title={online ? 'Online' : 'No signal'} style={{ fontSize: 11, fontWeight: 700, padding: '2px 8px', borderRadius: 999,
              color: online ? '#157f3c' : AMBER, background: online ? '#e3f4e8' : '#fdf4dc' }}>{online ? 'Online' : 'No signal'}</span>
          </div>
        </div>
        {handler && (
          <button type="button" title="Not you? Tap to log out"
            onClick={() => { if (confirm(`Log out ${handler}?\n\nThe next person will pick their own name and enter their password.`)) chooseHandler(null) }}
            style={{ maxWidth: 150, padding: '7px 11px', borderRadius: 999, border: `1px solid ${TEAL}`, background: `${TEAL}14`, color: TEAL, fontWeight: 800, fontSize: 12.5, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {handler} ▾
          </button>
        )}
        {(waiting > 0 || refused > 0) && (
          <button type="button" onClick={() => setShowOutbox(s => !s)}
            style={{ padding: '7px 11px', borderRadius: 999, border: 'none', fontWeight: 900, fontSize: 12, background: refused ? RED : AMBER, color: '#fff' }}>
            {refused ? `${refused} refused` : `${waiting} waiting`}
          </button>
        )}
        <button type="button" onClick={refresh} disabled={refreshing} aria-label="Refresh"
          style={{ padding: '7px 10px', borderRadius: 8, border: `1px solid ${TEAL}`, background: 'transparent', color: TEAL, fontWeight: 800, fontSize: 12, whiteSpace: 'nowrap', opacity: refreshing ? 0.6 : 1 }}>
          {refreshing ? '…' : '↻ Refresh'}
        </button>
      </div>

      <div style={{ maxWidth: 560, margin: '0 auto', padding: 14 }}>
        {backToBoss}
        {/* ── Outbox ── */}
        {showOutbox && mine.length > 0 && (
          <div style={{ background: CARD, border: `1px solid ${LINE}`, borderRadius: 12, padding: 12, marginBottom: 14 }}>
            <div style={{ display: 'flex', alignItems: 'center', marginBottom: 6 }}>
              <div style={{ fontWeight: 900, fontSize: 14, flex: 1 }}>Not yet in the system</div>
              <button type="button" onClick={() => flush()}
                style={{ padding: '7px 12px', borderRadius: 8, border: 'none', background: TEAL, color: '#fff', fontWeight: 800, fontSize: 12 }}>
                Send now
              </button>
            </div>
            {mine.map(p => (
              <div key={p.requestId} style={{ padding: '9px 0', borderTop: `1px solid ${LINE}` }}>
                <div style={{ fontSize: 13.5, fontWeight: 700 }}>{p.summary}</div>
                <div style={{ fontSize: 11.5, color: p.error ? RED : SUB, marginTop: 2 }}>
                  {new Date(p.when).toLocaleString('en-GB', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })}
                  {' · '}{p.error ? `Refused: ${p.error}` : 'Waiting for signal'}
                </div>
                <div style={{ fontSize: 11.5, color: SUB, marginTop: 2 }}>
                  {p.items.map(i => `${i.quantity} × ${i.model}`).join(', ')}
                </div>
                {p.error && (
                  <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
                    <button type="button"
                      // Sent again with the key from the password just entered:
                      // the one it was recorded with may have been replaced since.
                      onClick={() => {
                        commit(outboxRef.current.map(x => x.requestId === p.requestId
                          ? { ...x, error: undefined, doneToken: x.doneBy === handler && handlerToken ? handlerToken : x.doneToken } : x))
                        flush()
                      }}
                      style={{ padding: '7px 12px', borderRadius: 8, border: `1px solid ${LINE}`, background: 'transparent', color: TEAL, fontWeight: 800, fontSize: 12 }}>
                      Try again
                    </button>
                    <button type="button"
                      onClick={() => { if (confirm(`Throw this away?\n\n${p.summary}\n\nIt was never saved, so stock is unchanged. Enter it again if the goods really moved.`)) commit(outboxRef.current.filter(x => x.requestId !== p.requestId)) }}
                      style={{ padding: '7px 12px', borderRadius: 8, border: `1px solid ${LINE}`, background: 'transparent', color: RED, fontWeight: 800, fontSize: 12 }}>
                      Discard
                    </button>
                  </div>
                )}
              </div>
            ))}
          </div>
        )}

        {banner && (
          <div onClick={() => setBanner(null)} style={{
            borderRadius: 12, padding: '12px 14px', marginBottom: 14, fontWeight: 800,
            background: banner.tone === 'ok' ? '#157f3c' : banner.tone === 'wait' ? AMBER : RED,
            color: '#fff',
          }}>
            <div style={{ fontSize: 15 }}>{banner.title}</div>
            {banner.sub && <div style={{ fontSize: 12.5, fontWeight: 600, marginTop: 3, opacity: 0.92 }}>{banner.sub}</div>}
          </div>
        )}

        {!canWrite ? (
          <div style={{ background: CARD, border: `1px solid ${LINE}`, borderRadius: 12, padding: 18, color: SUB, fontSize: 14 }}>
            This login can view stock but not move it. Sign in with a staff login to record movements.
          </div>
        ) : (
          <>
            {/* ── What kind of movement, and where ── */}
            {/* Kept to two short rows, so the search sits near the top of the
                screen and its list has the room above the keyboard. */}
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 6, marginBottom: 10 }}>
              {MODES.map(m => (
                <button key={m.key} type="button" onClick={() => {
                  setMode(m.key); setItems([]); setFlash(null)
                  // A delivery or a return has no source, and never lands in SPOILT by hand.
                  if (m.key !== 'move' && (!to || to.name === SPOILT)) {
                    const first = locations.main.find(n => n !== SPOILT)
                    if (first) setTo({ line: 'main', name: first })
                  }
                  if (m.key === 'move' && locKey(to) === locKey(from)) setTo(null)
                }}
                  style={{
                    padding: '11px 6px', borderRadius: 10, fontSize: 14, fontWeight: 800,
                    border: `1px solid ${mode === m.key ? TEAL : LINE}`,
                    background: mode === m.key ? `${TEAL}1f` : CARD, color: mode === m.key ? TEAL : SUB,
                  }}>
                  {m.label}
                </button>
              ))}
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: mode === 'move' ? '1fr 1fr' : '1fr', gap: 8, marginBottom: 12 }}>
              {mode === 'move' && (
                <div style={{ minWidth: 0 }}>
                  <label style={lbl}>From</label>
                  {locationSelect(from, l => {
                    setFrom(l); setItems([])
                    if (locKey(l) === locKey(to)) setTo(null)
                  }, () => false)}
                </div>
              )}
              <div style={{ minWidth: 0 }}>
                <label style={lbl}>{mode === 'move' ? 'To' : mode === 'return' ? 'Good items back into' : 'Into'}</label>
                {locationSelect(to, l => {
                  if (to && l.line !== to.line) setItems(list => list.map(i => ({ ...i, toModel: undefined })))
                  setTo(l)
                }, l => noSpoilt(l) || (mode === 'move' && locKey(l) === locKey(from)))}
              </div>
            </div>
            {/* ── What ── */}
            {/* Tapping the field lists everything the location holds, and
                brings the field to the top of the screen so the list is not
                hidden behind the keyboard. */}
            <div ref={searchRow} style={{ display: 'flex', gap: 8, scrollMarginTop: 'calc(74px + env(safe-area-inset-top))' }}
              onFocusCapture={() => setTimeout(() => searchRow.current?.scrollIntoView({ block: 'start', behavior: 'smooth' }), 250)}>
              <div style={{ flex: 1, minWidth: 0 }}>
                <ModelPicker
                  touch
                  value={search}
                  options={options}
                  onChange={v => (options.some(o => o.model === v) ? add(v) : setSearch(v))}
                  onEnterUnmatched={() => { if (mode !== 'move') add(search) }}
                  inputStyle={{ ...fld, padding: '15px 12px', borderColor: TEAL, borderWidth: 2 }}
                  theme={pickerTheme}
                  placeholder={levelsLoading ? 'Loading…'
                    : !ref ? 'Choose a location first'
                    : mode === 'move' ? `Tap to see what ${ref.name} holds`
                    : `Tap to see what ${ref.name} stocks`}
                  emptyHint={mode === 'move' ? `Nothing in ${ref?.name ?? 'there'} matches` : undefined}
                />
              </div>
              <button type="button" onClick={() => setCamera(true)} disabled={!ref} aria-label="Scan barcodes"
                style={{ flexShrink: 0, padding: '0 18px', borderRadius: 10, border: 'none', background: TEAL, color: '#fff', fontWeight: 900, fontSize: 15, opacity: ref ? 1 : 0.5 }}>
                Scan
              </button>
            </div>
            {typedTwin && (
              <button type="button" onClick={() => add(typedTwin)}
                style={{ width: '100%', marginTop: 8, padding: 12, borderRadius: 10, border: `1px solid ${TEAL}`, background: 'transparent', color: TEAL, fontWeight: 800, fontSize: 13.5, textAlign: 'left' }}>
                Already stocked as “{typedTwin}” — add that
              </button>
            )}
            {mode === 'receive' && !naming && !canAddNew && (
              <button type="button" onClick={() => { setNaming(true); setProductName('') }}
                style={{ width: '100%', marginTop: 8, padding: 12, borderRadius: 10, border: `1px dashed ${TEAL}`, background: `${TEAL}12`, color: TEAL, fontWeight: 800, fontSize: 14, textAlign: 'left' }}>
                + New product — one the shop has never stocked
              </button>
            )}
            {mode === 'receive' && naming && (() => {
              const name = productName.trim()
              const twin = name && ref ? (names[ref.line].exact.has(name) ? name : names[ref.line].byKey.get(modelKey(name))) : undefined
              return (
                <div style={{ marginTop: 8, padding: 12, borderRadius: 12, border: `1px solid ${TEAL}`, background: CARD }}>
                  <label style={lbl}>New product name</label>
                  <input autoFocus value={productName} onChange={e => setProductName(e.target.value)} enterKeyHint="done"
                    onKeyDown={e => { if (e.key === 'Enter' && name && !twin) { add(name); setNaming(false) } }}
                    placeholder="As it should appear on invoices" style={{ ...fld, padding: '13px 12px' }} />
                  {twin && (
                    <button type="button" onClick={() => { add(twin); setNaming(false) }}
                      style={{ width: '100%', marginTop: 8, padding: 11, borderRadius: 10, border: `1px solid ${TEAL}`, background: 'transparent', color: TEAL, fontWeight: 800, fontSize: 13.5, textAlign: 'left' }}>
                      Already stocked as “{twin}” — add that instead
                    </button>
                  )}
                  <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
                    <button type="button" disabled={!name || !!twin} onClick={() => { add(name); setNaming(false) }}
                      style={{ flex: 2, padding: 12, borderRadius: 10, border: 'none', background: TEAL, color: '#fff', fontWeight: 900, fontSize: 14.5, opacity: !name || twin ? 0.5 : 1 }}>
                      Add new product
                    </button>
                    <button type="button" onClick={() => setNaming(false)}
                      style={{ flex: 1, padding: 12, borderRadius: 10, border: `1px solid ${LINE}`, background: 'transparent', color: SUB, fontWeight: 800, fontSize: 14 }}>
                      Cancel
                    </button>
                  </div>
                </div>
              )
            })()}
            {canAddNew && !typedTwin && (
              <button type="button" onClick={() => add(typed)}
                style={{ width: '100%', marginTop: 8, padding: 12, borderRadius: 10, border: `1px dashed ${AMBER}`, background: 'transparent', color: AMBER, fontWeight: 800, fontSize: 13.5, textAlign: 'left' }}>
                Add “{typed}” as a NEW product name — only if it is not on the list under another name
              </button>
            )}
            {flash && (
              <div style={{ fontSize: 13, fontWeight: 700, marginTop: 8, color: flash.ok ? TEAL : AMBER }}>
                {flash.ok ? '✓ ' : '⚠ '}{flash.text}
              </div>
            )}
            {levelsStale && ref && (
              <div style={{ fontSize: 12, color: AMBER, marginTop: 8 }}>
                No signal — the figures for {ref.name} are from the last time this phone loaded them.
              </div>
            )}

            {/* ── The list ── */}
            <div style={{ marginTop: 14, display: 'flex', flexDirection: 'column', gap: 10 }}>
              {items.map(i => {
                const have = levels.get(i.model)
                const tooFew = mode === 'move' && (have ?? 0) < i.quantity
                // A line whose exact name the destination does not stock is
                // shown what it will join, or be created as.
                const showArrival = mode === 'move' && !!to && !destHere.exact.has(i.model)
                const arrival = showArrival ? arrivesAs(i) : ''
                const joins = !!arrival && destHere.exact.has(arrival)
                const lookalikes = showArrival && !joins ? similarNames(arrival, destHere.exact).slice(0, 3) : []
                const stepper: React.CSSProperties = {
                  width: 52, height: 52, borderRadius: 12, border: `1px solid ${LINE}`, background: BG,
                  color: TEXT, fontSize: 26, fontWeight: 700, lineHeight: 1,
                }
                return (
                  <div key={i.key} style={{ background: CARD, border: `1px solid ${tooFew ? AMBER : LINE}`, borderRadius: 12, padding: 12 }}>
                    <div style={{ display: 'flex', gap: 10, alignItems: 'flex-start' }}>
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontFamily: 'ui-monospace, monospace', fontSize: 14.5, fontWeight: 700, wordBreak: 'break-word' }}>{i.model}</div>
                        {mode === 'move' && (
                          <div style={{ fontSize: 12, marginTop: 3, color: tooFew ? AMBER : SUB }}>
                            {from!.name} has {(have ?? 0).toLocaleString()}{tooFew ? ` — sending ${i.quantity}` : ''}
                          </div>
                        )}
                        {/* The matching row at the other end, so staff see the
                            two piles are the same product before they send. */}
                        {mode === 'move' && to && destHere.exact.has(i.model) && (
                          <div style={{ fontSize: 12, marginTop: 2, color: TEAL, fontWeight: 700 }}>
                            ✓ Matches “{i.model}” in {to.name} · has {(destHere.qty.get(i.model) ?? 0).toLocaleString()}
                          </div>
                        )}
                        {mode !== 'move' && ref && !names[ref.line].exact.has(i.model) && (
                          <div style={{ fontSize: 12, marginTop: 3, color: AMBER }}>New product name</div>
                        )}
                      </div>
                      <button type="button" aria-label="Remove" onClick={() => setItems(list => list.filter(x => x.key !== i.key))}
                        style={{ width: 40, height: 40, borderRadius: 10, border: `1px solid ${LINE}`, background: 'transparent', color: SUB, fontSize: 16 }}>✕</button>
                    </div>
                    <div style={{ display: 'flex', gap: 8, alignItems: 'center', marginTop: 10 }}>
                      <button type="button" style={stepper} aria-label="One fewer"
                        onClick={() => setItem(i.key, { quantity: Math.max(1, i.quantity - 1) })}>−</button>
                      <input type="number" inputMode="numeric" min={1} value={i.quantity}
                        onChange={e => setItem(i.key, { quantity: Math.max(1, parseInt(e.target.value) || 1) })}
                        onFocus={e => e.target.select()}
                        style={{ ...fld, width: 84, height: 52, textAlign: 'center', fontSize: 20, fontWeight: 800, padding: 0 }} />
                      <button type="button" style={stepper} aria-label="One more"
                        onClick={() => setItem(i.key, { quantity: i.quantity + 1 })}>+</button>
                      {mode === 'return' && (
                        <button type="button" onClick={() => setItem(i.key, { spoilt: !i.spoilt })}
                          style={{
                            marginLeft: 'auto', height: 52, padding: '0 14px', borderRadius: 12, fontSize: 13, fontWeight: 800,
                            border: `1px solid ${i.spoilt ? RED : LINE}`, background: i.spoilt ? `${RED}1a` : 'transparent', color: i.spoilt ? RED : SUB,
                          }}>
                          {i.spoilt ? '✕ Spoilt' : 'Not spoilt'}
                        </button>
                      )}
                    </div>
                    {showArrival && (
                      <div style={{ marginTop: 10 }}>
                        <label style={{ ...lbl, color: SUB }}>{`Goes into ${to!.name} as`}</label>
                        <ModelPicker
                          value={i.toModel ?? suggestArrival(i.model)}
                          options={arrivalOptions}
                          onChange={m => setItem(i.key, { toModel: m })}
                          inputStyle={{ ...fld, fontSize: 16, padding: '10px 12px' }}
                          theme={pickerTheme}
                          placeholder={`What ${to!.name} calls it`}
                          emptyHint={`${to!.name} stocks nothing under that name — it will be created`}
                        />
                        {joins && arrival !== i.model && (
                          <div style={{ fontSize: 12.5, marginTop: 6, color: TEAL, fontWeight: 700 }}>
                            ✓ Matches “{arrival}” in {to!.name} · has {(destHere.qty.get(arrival) ?? 0).toLocaleString()}. The units join that row — no second one is made.
                          </div>
                        )}
                        {lookalikes.length > 0 && (
                          <div style={{ marginTop: 8 }}>
                            <div style={{ fontSize: 12.5, color: AMBER, fontWeight: 700, marginBottom: 6 }}>
                              {to!.name} has a similar name. Same product? Add to it. Different? Leave it and a new row is made.
                            </div>
                            {lookalikes.map(n => (
                              <button key={n} type="button" onClick={() => setItem(i.key, { toModel: n })}
                                style={{ width: '100%', marginBottom: 6, padding: 12, borderRadius: 10, border: `1px solid ${TEAL}`, background: 'transparent', color: TEAL, fontWeight: 800, fontSize: 13.5, textAlign: 'left' }}>
                                Add to “{n}”
                              </button>
                            ))}
                          </div>
                        )}
                        {arrival && !joins && lookalikes.length === 0 && (
                          <div style={{ fontSize: 12, marginTop: 4, color: SUB }}>
                            New to {to!.name} — a row will be created for it.
                          </div>
                        )}
                      </div>
                    )}
                  </div>
                )
              })}
              {items.length === 0 && (
                <div style={{ textAlign: 'center', color: SUB, fontSize: 13.5, padding: '26px 10px' }}>
                  Nothing added yet. Tap the box above to pick from the list, or scan.
                </div>
              )}
            </div>

            {/* ── Optional details ── */}
            <div style={{ background: CARD, border: `1px solid ${LINE}`, borderRadius: 12, padding: 12, marginTop: 14 }}>
              {mode !== 'move' && (
                <div style={{ marginBottom: 12 }}>
                  <label style={lbl}>{mode === 'return' ? 'Returned by' : 'Supplier'} · optional</label>
                  <input style={fld} value={party} onChange={e => setParty(e.target.value)}
                    placeholder={mode === 'return' ? 'which buyer' : 'who brought it'} />
                </div>
              )}
              <label style={lbl}>Note · optional</label>
              <input style={fld} value={note} onChange={e => setNote(e.target.value)}
                placeholder={mode === 'receive' ? 'e.g. waybill 4471' : mode === 'return' ? 'e.g. invoice number' : 'e.g. restocking the shelf'} />
            </div>
          </>
        )}
      </div>

      {/* ── Save bar ── */}
      {canWrite && (
        <div style={{ position: 'fixed', left: 0, right: 0, bottom: 0, zIndex: 60, background: BG, borderTop: `1px solid ${LINE}`, padding: '10px 14px calc(10px + env(safe-area-inset-bottom))' }}>
          <div style={{ maxWidth: 560, margin: '0 auto', display: 'flex', gap: 12, alignItems: 'center' }}>
            <div style={{ fontSize: 12.5, color: SUB, minWidth: 74 }}>
              <div style={{ fontSize: 20, fontWeight: 900, color: TEXT }}>{units.toLocaleString()}</div>
              unit{units === 1 ? '' : 's'} · {items.length} item{items.length === 1 ? '' : 's'}
            </div>
            <button type="button" onClick={submit} disabled={saving || !items.length || !to}
              style={{ flex: 1, padding: 16, borderRadius: 12, border: 'none', background: TEAL, color: '#fff', fontWeight: 900, fontSize: 16, opacity: saving || !items.length || !to ? 0.5 : 1 }}>
              {saving ? 'Saving…'
                : mode === 'receive' ? `Receive into ${to?.name ?? '…'}`
                : mode === 'return' ? 'Record return'
                : `Move to ${to?.name ?? '…'}`}
            </button>
          </div>
        </div>
      )}

      {camera && (
        <CameraScanner
          active
          banner={flash ? { tone: flash.ok ? 'ok' : 'warn', title: flash.text } : null}
          onDetect={handleScan}
          onClose={() => setCamera(false)}
        />
      )}
    </div>
  )
}
