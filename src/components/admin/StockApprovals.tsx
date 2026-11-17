'use client'

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  approveStockRequest, rejectStockRequest, reverseStockRequest, fetchStockRequests, settleDue,
  useAutoAccept, STOCK_REQUESTS_CHANGED, type StockRequest, type RequestStatus,
} from '@/lib/stockApproval'
import { downloadDahuaTransfersPdf } from '@/lib/transfersPdf'
import { LINE_LABEL } from '@/lib/storeStock'

/**
 * The approval queue — every stock movement staff enter, on either line,
 * waits here for the Big Boss.
 *
 * Each request is drawn as a docket: the slip a storeman hands over before
 * stock leaves a shelf. Waiting ones carry Approve and Reject; approved ones
 * carry Reverse; decided ones are stamped with what became of them.
 * Auto-accept works out of sight: nothing on screen counts down, and an
 * auto-accepted request looks like any other approved one.
 *
 * The list sits in a box of fixed height that scrolls on its own — the page
 * around it never grows with the queue.
 *
 * Staff see the same panel with their own requests and no buttons, so
 * nobody wonders whether a move they entered "went through".
 */

const AMBER = '#f59e0b'
const RED = '#ef4444'
const KIND: Record<string, string> = { move: 'Move', receive: 'Delivery', return: 'Return' }
const STAMP: Record<Exclude<RequestStatus, 'pending'>, string> = { approved: 'APPROVED', rejected: 'REJECTED', reversed: 'REVERSED' }
const when = (iso: string) => new Date(iso).toLocaleString('en-GB', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })
const today = () => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}` }

type View = 'pending' | 'approved' | 'rejected' | 'reversed'

export default function StockApprovals({ isSuperBoss, isBoss, dark, accent = '#0a7cff', accentText = '#ffffff', pdf = true, listHeight = 380 }: {
  isSuperBoss: boolean
  /** Bosses see every request; staff see their own. */
  isBoss: boolean
  dark: boolean
  accent?: string
  /** Text on the accent colour — dark on the pale Dahua accents. */
  accentText?: string
  /** The Dahua movements PDF, for bosses. */
  pdf?: boolean
  /** The tallest the queue grows; past it, it scrolls inside. */
  listHeight?: number
}) {
  // Colours come from the --qb-* tokens (src/app/qb-ios.css).
  const T = { card: 'var(--qb-card)', slip: 'var(--qb-card-strong)', border: 'var(--qb-border)', text: 'var(--qb-text)', sub: 'var(--qb-sub)', faint: 'var(--qb-faint)', input: 'var(--qb-input)', hole: 'var(--qb-bg)' }
  const onA = accentText
  const auto = useAutoAccept()

  const [rows, setRows] = useState<StockRequest[]>([])
  const [state, setState] = useState<'loading' | 'ready' | 'failed'>('loading')
  const [view, setView] = useState<View>('pending')
  const [busy, setBusy] = useState<string | null>(null)
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  // Reject and Reverse ask for a reason in the docket itself, not a pop-up.
  const [asking, setAsking] = useState<{ id: string; act: 'reject' | 'reverse' } | null>(null)
  const [reason, setReason] = useState('')
  const [day, setDay] = useState(today)
  const [printing, setPrinting] = useState(false)
  const [now, setNow] = useState(() => Date.now())

  const load = useCallback(async (quiet = false) => {
    if (!quiet) setState('loading')
    try { setRows(await fetchStockRequests()); setState('ready') }
    catch { if (!quiet) setState('failed') }
  }, [])
  useEffect(() => { load() }, [load])
  useEffect(() => {
    const again = () => load(true)
    window.addEventListener(STOCK_REQUESTS_CHANGED, again)
    const timer = setInterval(() => { if (document.visibilityState === 'visible') again() }, 60_000)
    return () => { window.removeEventListener(STOCK_REQUESTS_CHANGED, again); clearInterval(timer) }
  }, [load])

  const pending = useMemo(() => rows.filter(r => r.status === 'pending'), [rows])
  const counts = useMemo(() => {
    const c: Record<View, number> = { pending: 0, approved: 0, rejected: 0, reversed: 0 }
    for (const r of rows) c[r.status]++
    return c
  }, [rows])
  const shown = useMemo(() => rows.filter(r => r.status === view), [rows, view])

  // Auto-accept, unseen: a quiet tick while anything is waiting, so the
  // database is asked to settle the moment one is due.
  const settling = useRef(false)
  useEffect(() => {
    if (!auto.on || pending.length === 0) return
    const timer = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(timer)
  }, [auto.on, pending.length])
  const leftOf = (r: StockRequest) => {
    const start = new Date(r.filed_at || r.requested_at).getTime()
    return Math.max(0, auto.seconds - Math.floor((now - start) / 1000))
  }
  useEffect(() => {
    if (!auto.on || settling.current) return
    if (!pending.some(r => leftOf(r) === 0)) return
    settling.current = true
    settleDue().finally(() => { settling.current = false; load(true) })
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [now, auto.on, pending])

  const act = async (r: StockRequest, what: 'approve' | 'reject' | 'reverse') => {
    setBusy(r.id); setMsg(null)
    try {
      if (what === 'approve') {
        const res = await approveStockRequest(r.id)
        setMsg({ ok: true, text: `${r.request_number} approved — stock updated as ${res.transfer_number}.` })
      } else if (what === 'reject') {
        await rejectStockRequest(r.id, reason)
        setMsg({ ok: true, text: `${r.request_number} rejected. Nothing changed.` })
      } else {
        const res = await reverseStockRequest(r.id, reason)
        setMsg({ ok: true, text: `${r.transfer_number} reversed as ${res.reversal_number} — the stock is back where it was.` })
      }
      setAsking(null); setReason('')
      await load(true)
    } catch (e: any) {
      setMsg({ ok: false, text: `${r.request_number}: ${e.message || 'that did not go through'}` })
    } finally { setBusy(null) }
  }

  const download = async (which: string | 'all') => {
    setPrinting(true); setMsg(null)
    try {
      const r = await downloadDahuaTransfersPdf(which)
      setMsg({ ok: true, text: `PDF downloaded: ${r.movements} movement${r.movements === 1 ? '' : 's'}${r.pending ? `, ${r.pending} still waiting for approval` : ''}.` })
    } catch (e: any) { setMsg({ ok: false, text: e.message || 'Could not make the PDF' }) }
    finally { setPrinting(false) }
  }

  const place = (line: string | null, wh: string | null, other: string | null) =>
    `${wh}${line && other && line !== other ? ` (${LINE_LABEL[line as 'main' | 'dahua']})` : ''}`
  const route = (r: StockRequest) => r.kind === 'move'
    ? `${place(r.from_line, r.from_warehouse, r.to_line)} → ${place(r.to_line, r.to_warehouse, r.from_line)}`
    : r.party ? `${r.party} → ${r.to_warehouse}` : `Into ${r.to_warehouse}`
  const lineTag = (r: StockRequest) => r.from_line && r.from_line !== r.to_line
    ? `${LINE_LABEL[r.from_line]} → ${LINE_LABEL[r.to_line]}` : LINE_LABEL[r.to_line]
  const units = (r: StockRequest) => (r.items || []).reduce((s, i) => s + (Number(i.quantity) || 0), 0)
  const btn = (bg: string, fg: string, border = 'none'): React.CSSProperties => ({
    padding: '8px 14px', borderRadius: 8, border, background: bg, color: fg, fontWeight: 800, fontSize: 12.5, cursor: 'pointer', whiteSpace: 'nowrap',
  })

  const docket = (r: StockRequest) => {
    const tone = r.status === 'pending' ? AMBER : r.status === 'approved' ? accent : r.status === 'reversed' ? T.sub : RED
    const open = asking?.id === r.id
    return (
      <div key={r.id} className="sa-docket" style={{
        position: 'relative', margin: '0 0 10px', padding: '13px 14px 12px 22px', borderRadius: 10,
        background: T.slip, border: `1px solid ${T.border}`, overflow: 'hidden',
      }}>
        {/* The perforated edge of the slip. */}
        <span aria-hidden style={{
          position: 'absolute', left: 6, top: 6, bottom: 6, width: 6,
          backgroundImage: `radial-gradient(circle, ${T.hole} 2.2px, transparent 2.6px)`, backgroundSize: '6px 9px', backgroundRepeat: 'repeat-y',
        }} />
        {r.status !== 'pending' && (
          <span aria-hidden className="sa-stamp" style={{
            position: 'absolute', right: 14, top: 10, padding: '2px 8px', border: `2px solid ${tone}`, borderRadius: 4,
            color: tone, fontSize: 11, fontWeight: 900, letterSpacing: '0.16em', transform: 'rotate(-6deg)', opacity: 0.75,
          }}>
            {STAMP[r.status]}
          </span>
        )}

        <div style={{ display: 'flex', gap: 8, alignItems: 'baseline', flexWrap: 'wrap', paddingRight: r.status !== 'pending' ? 110 : 0 }}>
          <span style={{ fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace', fontSize: 12, fontWeight: 700, color: tone }}>{r.request_number}</span>
          <span style={{ fontSize: 11, fontWeight: 800, letterSpacing: '0.08em', textTransform: 'uppercase', color: T.sub }}>{KIND[r.kind]} · {lineTag(r)}</span>
        </div>
        <div style={{ marginTop: 4, fontSize: 14.5, fontWeight: 800, color: T.text, wordBreak: 'break-word' }}>{route(r)}</div>
        <div style={{ marginTop: 2, fontSize: 12, color: T.sub }}>
          {r.requested_name || r.requested_staff_id || 'Staff'} · {when(r.requested_at)}{r.note ? ` · ${r.note}` : ''}
        </div>

        <div style={{ marginTop: 8, paddingTop: 8, borderTop: `1px dashed ${T.border}`, fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace', fontSize: 12.5, color: T.text }}>
          {(r.items || []).map((i, n) => (
            <div key={n} style={{ display: 'flex', gap: 10 }}>
              <span style={{ minWidth: 34, textAlign: 'right', fontWeight: 800 }}>{i.quantity}</span>
              <span style={{ flex: 1, minWidth: 0, wordBreak: 'break-word' }}>
                {i.model}
                {i.to_model && i.to_model !== i.model && <span style={{ color: T.sub }}> → as {i.to_model}</span>}
                {i.condition === 'spoilt' && <span style={{ color: RED }}> · spoilt</span>}
              </span>
            </div>
          ))}
        </div>

        {r.status === 'approved' && r.transfer_number && <div style={{ marginTop: 6, fontSize: 12, color: T.sub }}>Booked as <strong style={{ color: T.text }}>{r.transfer_number}</strong></div>}
        {r.status === 'reversed' && <div style={{ marginTop: 6, fontSize: 12, color: T.sub }}>{r.transfer_number} undone by <strong style={{ color: T.text }}>{r.reversal_number}</strong>{r.reverse_reason ? ` — ${r.reverse_reason}` : ''}</div>}
        {r.status === 'rejected' && r.reject_reason && <div style={{ marginTop: 6, fontSize: 12, color: RED }}>Reason: {r.reject_reason}</div>}

        {/* Actions — the Big Boss's only. */}
        {isSuperBoss && (r.status === 'pending' || r.status === 'approved') && (
          <div style={{ marginTop: 10, display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
            {open ? (
              <>
                <input autoFocus value={reason} onChange={e => setReason(e.target.value)}
                  onKeyDown={e => { if (e.key === 'Enter') act(r, asking!.act); if (e.key === 'Escape') setAsking(null) }}
                  placeholder={asking!.act === 'reject' ? 'Reason — staff will see it (optional)' : 'Why it is being reversed (optional)'}
                  style={{ flex: '1 1 220px', padding: '8px 10px', borderRadius: 8, border: `1px solid ${T.border}`, background: T.input, color: T.text, fontSize: 13, outline: 'none' }} />
                <button type="button" disabled={busy === r.id} onClick={() => act(r, asking!.act)} style={btn(asking!.act === 'reject' ? RED : T.text, asking!.act === 'reject' ? '#fff' : T.card)}>
                  {busy === r.id ? '…' : asking!.act === 'reject' ? 'Reject — change nothing' : `Reverse ${units(r)} unit${units(r) === 1 ? '' : 's'}`}
                </button>
                <button type="button" onClick={() => setAsking(null)} style={btn('transparent', T.sub, `1px solid ${T.border}`)}>Cancel</button>
              </>
            ) : r.status === 'pending' ? (
              <>
                <button type="button" disabled={busy === r.id} onClick={() => act(r, 'approve')} style={btn(accent, onA)}>
                  {busy === r.id ? '…' : `Approve ${units(r)} unit${units(r) === 1 ? '' : 's'}`}
                </button>
                <button type="button" disabled={busy === r.id} onClick={() => { setAsking({ id: r.id, act: 'reject' }); setReason('') }} style={btn('transparent', RED, `1px solid ${RED}66`)}>Reject</button>
              </>
            ) : (
              <button type="button" onClick={() => { setAsking({ id: r.id, act: 'reverse' }); setReason('') }} style={btn('transparent', T.text, `1px solid ${T.border}`)}>↶ Reverse</button>
            )}
          </div>
        )}
        {!isSuperBoss && r.status === 'pending' && (
          <div style={{ marginTop: 8, fontSize: 12, color: AMBER, fontWeight: 700 }}>
            Waiting for the Big Boss. The stock has not changed yet.
          </div>
        )}
      </div>
    )
  }

  const VIEWS: { key: View; label: string }[] = [
    { key: 'pending', label: 'Waiting' }, { key: 'approved', label: 'Approved' },
    { key: 'rejected', label: 'Rejected' }, { key: 'reversed', label: 'Reversed' },
  ]

  return (
    <section aria-label="Stock approvals" style={{ maxWidth: 980, borderRadius: 12, background: T.card, border: `1px solid ${pending.length ? `${AMBER}66` : T.border}`, marginBottom: 22 }}>
      <style>{`
        @media (prefers-reduced-motion: no-preference) { .sa-docket { animation: sa-in .22s ease-out both } }
        @keyframes sa-in { from { opacity: 0; transform: translateY(4px) } to { opacity: 1; transform: none } }
        .sa-scroll { scrollbar-width: thin; }
        .sa-scroll:focus-visible, .sa-docket button:focus-visible { outline: 2px solid ${accent}; outline-offset: 2px; }
      `}</style>
      <header style={{ padding: '14px 14px 8px', display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
        <div style={{ flex: 1, minWidth: 200 }}>
          <div style={{ fontWeight: 900, fontSize: 15.5, color: T.text }}>
            {isSuperBoss ? 'Stock waiting for your approval' : isBoss ? 'Stock waiting for the Big Boss' : 'Your stock requests'}
          </div>
          <div style={{ fontSize: 12, color: T.sub, marginTop: 2 }}>
            {isSuperBoss
              ? 'Moves, deliveries and returns staff enter — main shop and Dahua — change the stock only when you approve them.'
              : 'Moves, deliveries and returns go to the Big Boss first. The stock changes when he approves.'}
          </div>
        </div>
        {/* Auto-accept is switched from the Transfers tab's right-click menu only. */}
        <button type="button" onClick={() => load()} style={btn('transparent', accent, `1px solid ${T.border}`)}>↻ Refresh</button>
      </header>

      {/* Which part of the record: one row, the count of each. */}
      <div role="tablist" style={{ display: 'flex', gap: 4, margin: '2px 14px 10px', padding: 3, borderRadius: 9, background: T.input, width: 'fit-content', maxWidth: 'calc(100% - 28px)', overflowX: 'auto' }}>
        {VIEWS.map(v => {
          const on = view === v.key
          return (
            <button key={v.key} type="button" role="tab" aria-selected={on} onClick={() => { setView(v.key); setAsking(null) }}
              style={{ padding: '6px 12px', borderRadius: 7, border: 'none', cursor: 'pointer', fontSize: 12.5, fontWeight: 800, whiteSpace: 'nowrap',
                background: on ? T.card : 'transparent', color: on ? T.text : T.sub, boxShadow: on ? '0 1px 2px rgba(0,0,0,0.18)' : 'none' }}>
              {v.label}
              <span style={{ marginLeft: 6, padding: '0 6px', borderRadius: 999, fontSize: 11, background: v.key === 'pending' && counts.pending ? AMBER : 'transparent', color: v.key === 'pending' && counts.pending ? '#1f1300' : T.faint }}>
                {counts[v.key]}
              </span>
            </button>
          )
        })}
      </div>

      {msg && <div role="status" style={{ margin: '0 14px 10px', padding: '8px 12px', borderRadius: 8, fontSize: 12.5, fontWeight: 700, color: msg.ok ? accent : RED, background: msg.ok ? `${accent}1a` : `${RED}1a` }}>{msg.text}</div>}

      {/* The queue: a fixed height, scrolling inside. */}
      <div className="sa-scroll" tabIndex={0} aria-label={`${VIEWS.find(v => v.key === view)!.label} requests`}
        style={{ maxHeight: listHeight, minHeight: 120, overflowY: 'auto', overscrollBehavior: 'contain', padding: '2px 14px 4px', borderTop: `1px solid ${T.border}`, borderBottom: `1px solid ${T.border}`, paddingTop: 12 }}>
        {state === 'loading' && <div style={{ color: T.sub, fontSize: 13 }}>Loading…</div>}
        {state === 'failed' && <div style={{ color: RED, fontSize: 13 }}>Could not load the requests. If this is new, the approval migration may not have been run yet.</div>}
        {state === 'ready' && shown.length === 0 && (
          <div style={{ minHeight: 96, display: 'grid', placeItems: 'center', textAlign: 'center', color: T.sub, fontSize: 13 }}>
            {view === 'pending' ? 'Nothing waiting. New requests appear here as staff enter them.'
              : view === 'approved' ? 'Nothing approved yet.'
              : view === 'rejected' ? 'Nothing has been rejected.'
              : 'Nothing has been reversed.'}
          </div>
        )}
        {state === 'ready' && shown.map(docket)}
      </div>

      {/* The Dahua movements as a PDF — the Big Boss's record. */}
      {isBoss && pdf ? (
        <div style={{ padding: '11px 14px', display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
          <span style={{ color: T.text, fontWeight: 800, fontSize: 13 }}>Dahua movements PDF</span>
          <input type="date" value={day} max={today()} onChange={e => setDay(e.target.value)} aria-label="Day"
            style={{ padding: '7px 10px', borderRadius: 8, border: `1px solid ${T.border}`, background: T.input, color: T.text, fontSize: 13 }} />
          <button type="button" onClick={() => download(day)} disabled={printing || !day} style={btn(accent, onA)}>{printing ? 'Making…' : day === today() ? "Download today's PDF" : 'Download PDF'}</button>
          <button type="button" onClick={() => download('all')} disabled={printing} style={btn('transparent', accent, `1px solid ${accent}66`)}>All-time PDF</button>
        </div>
      ) : <div style={{ height: 10 }} />}
    </section>
  )
}
