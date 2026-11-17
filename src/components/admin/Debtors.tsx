'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import { GHS } from '@/lib/sales'
import { fetchDebts, fetchDebtPayments, payDebt, removeDebtPayment, owed, DEBTS_CHANGED, type Debt, type DebtPayment } from '@/lib/debts'
import type { StockLine } from '@/lib/storeStock'
import ListPager, { usePaged } from '@/components/admin/ListPager'

/**
 * Debtors — who owes the shop, and what they have paid.
 *
 * A debt starts on the invoice form, when a sale is saved with "On credit"
 * switched on. This tab is where it is settled: each payment the customer
 * brings is recorded against the invoice, and the amount still owed comes
 * down until it reaches zero.
 *
 * Any staff login can record a payment — the customer pays whoever is at
 * the counter. Only the Big Boss can take a payment back.
 *
 * Every payment recorded here is what the Sales page counts for that day;
 * the unpaid part of a credit sale is never counted as sales.
 */

const DEFAULT_ACCENT = '#0a7cff'
const AMBER = '#f59e0b'
const METHODS = ['Cash', 'Mobile Money', 'Bank Transfer', 'Cheque'] as const
type Show = 'open' | 'settled' | 'all'

const today = () => new Date().toISOString().slice(0, 10)
const day = (iso: string) => new Date(iso).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: '2-digit' })

export default function Debtors({ userId, isSuperBoss, accent = DEFAULT_ACCENT }: {
  userId: string | null
  /** May take back a payment entered by mistake. */
  isSuperBoss: boolean
  accent?: string
}) {
  const line: StockLine = 'main'
  const [debts, setDebts] = useState<Debt[]>([])
  const [payments, setPayments] = useState<DebtPayment[]>([])
  const [state, setState] = useState<'loading' | 'ready' | 'failed'>('loading')
  const [show, setShow] = useState<Show>('open')
  const [search, setSearch] = useState('')
  const [openId, setOpenId] = useState<string | null>(null)

  // The payment being typed, for whichever debt is open.
  const [amount, setAmount] = useState('')
  const [method, setMethod] = useState<string>('Cash')
  const [paidOn, setPaidOn] = useState(today)
  const [note, setNote] = useState('')
  const [saving, setSaving] = useState(false)

  const load = useCallback(async (quiet = false) => {
    if (!quiet) setState('loading')
    try {
      const [d, p] = await Promise.all([fetchDebts(line), fetchDebtPayments()])
      setDebts(d); setPayments(p); setState('ready')
    } catch {
      if (!quiet) setState('failed')
    }
  }, [line])
  useEffect(() => { load() }, [load])

  // A credit sale saved on the invoice form, or a payment taken on another
  // screen, should appear here without a reload.
  useEffect(() => {
    const again = () => load(true)
    window.addEventListener(DEBTS_CHANGED, again)
    return () => window.removeEventListener(DEBTS_CHANGED, again)
  }, [load])

  const paymentsOf = useMemo(() => {
    const by = new Map<string, DebtPayment[]>()
    for (const p of payments) by.set(p.debt_id, [...(by.get(p.debt_id) || []), p])
    return by
  }, [payments])

  const totals = useMemo(() => {
    const open = debts.filter(d => owed(d) > 0)
    const ids = new Set(debts.map(d => d.id))
    const t = new Date().toDateString()
    return {
      owed: open.reduce((s, d) => s + owed(d), 0),
      debtors: open.length,
      collectedToday: payments.filter(p => ids.has(p.debt_id) && new Date(p.paid_at).toDateString() === t).reduce((s, p) => s + p.amount, 0),
      settled: debts.length - open.length,
    }
  }, [debts, payments])

  const shown = useMemo(() => {
    const q = search.trim().toLowerCase()
    return debts
      .filter(d => show === 'all' || (show === 'open' ? owed(d) > 0 : owed(d) === 0))
      .filter(d => !q || `${d.customer_name} ${d.customer_num || ''} ${d.invoice_number} ${d.customer_loc || ''}`.toLowerCase().includes(q))
      // What is owed most, first; settled ones by date.
      .sort((a, b) => owed(b) - owed(a) || b.issued_at.localeCompare(a.issued_at))
  }, [debts, show, search])

  // Paged, so a long debtors list never turns into an endless scroll.
  const pager = usePaged(shown, `${show}|${search}`)

  const openDebt = (d: Debt) => {
    setOpenId(id => (id === d.id ? null : d.id))
    setAmount(''); setMethod('Cash'); setPaidOn(today()); setNote('')
  }

  const pay = async (d: Debt, full = false) => {
    const amt = full ? owed(d) : Math.round((parseFloat(amount) || 0) * 100) / 100
    if (!(amt > 0)) return alert('Enter the amount the customer is paying')
    if (amt > owed(d) + 0.005) return alert(`That is more than is owed. ${d.customer_name} owes ${GHS(owed(d))}.`)
    if (full && !confirm(`Record ${GHS(amt)} by ${method} from ${d.customer_name}?\n\nThis settles invoice ${d.invoice_number} in full.`)) return
    setSaving(true)
    try {
      // Midday on the chosen date, unless it is today — then, now.
      const paidAt = paidOn === today() ? new Date().toISOString() : new Date(paidOn + 'T12:00:00').toISOString()
      await payDebt({ debtId: d.id, amount: amt, method, paidAt, note, userId })
      setAmount(''); setNote('')
      await load(true)
    } catch (e: any) {
      alert(e.message || 'Could not record the payment')
    } finally { setSaving(false) }
  }

  const takeBack = async (d: Debt, p: DebtPayment) => {
    if (!confirm(`Remove the payment of ${GHS(p.amount)} on ${day(p.paid_at)} from ${d.customer_name}?\n\nThey will owe that amount again, and it comes off that day's sales.`)) return
    try { await removeDebtPayment(p.id); await load(true) }
    catch (e: any) { alert(e.message || 'Could not remove the payment') }
  }

  const fld: React.CSSProperties = {
    width: '100%', boxSizing: 'border-box', padding: '9px 12px', borderRadius: 8, fontSize: 14, outline: 'none',
    border: '1px solid var(--qb-input-border)', background: 'var(--qb-input)', color: 'var(--qb-text)',
  }
  const lbl: React.CSSProperties = { fontSize: 10, fontWeight: 800, color: accent, letterSpacing: '0.18em', textTransform: 'uppercase', display: 'block', marginBottom: 5 }
  const panel: React.CSSProperties = { borderRadius: 14, border: '1px solid var(--qb-border)', background: 'var(--qb-card)' }
  const tile = (title: string, value: string, color = 'var(--qb-text)', sub?: string) => (
    <div style={{ ...panel, padding: 14 }}>
      <div style={{ color: 'var(--qb-sub)', fontSize: 10.5, fontWeight: 800, letterSpacing: '0.16em' }}>{title}</div>
      <div style={{ color, fontSize: 20, fontWeight: 900, fontVariantNumeric: 'tabular-nums', marginTop: 4 }}>{value}</div>
      {sub && <div style={{ color: 'var(--qb-muted)', fontSize: 11.5, marginTop: 2 }}>{sub}</div>}
    </div>
  )

  return (
    <div style={{ maxWidth: 980, display: 'flex', flexDirection: 'column', gap: 16 }}>
      <div style={{ padding: 14, borderRadius: 12, background: 'linear-gradient(135deg, rgba(245,158,11,0.08), var(--qb-card))', border: '1px solid rgba(245,158,11,0.22)' }}>
        <div style={{ color: AMBER, fontSize: 11, fontWeight: 800, letterSpacing: '0.2em' }}>🧾 DEBTORS</div>
        <div style={{ color: 'var(--qb-sub)', fontSize: 12, fontVariantNumeric: 'tabular-nums', marginTop: 2 }}>
          Sales made on credit. Record each payment here · a credit sale counts toward sales only as it is paid.
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(200px,1fr))', gap: 12 }}>
        {tile('STILL OWED', GHS(totals.owed), totals.owed > 0 ? AMBER : 'var(--qb-text)', `${totals.debtors} customer${totals.debtors === 1 ? '' : 's'} owing`)}
        {tile('COLLECTED TODAY', GHS(totals.collectedToday), accent, 'counted in today\'s sales')}
        {tile('SETTLED', String(totals.settled), 'var(--qb-text)', 'debts paid in full')}
      </div>

      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
        <input value={search} onChange={e => setSearch(e.target.value)} placeholder="Search customer, number or invoice…"
          style={{ ...fld, maxWidth: 380 }} />
        {([['open', 'Owing'], ['settled', 'Settled'], ['all', 'All']] as const).map(([k, text]) => (
          <button key={k} onClick={() => setShow(k)} style={{
            padding: '8px 14px', borderRadius: 8, fontSize: 12, fontWeight: 800, cursor: 'pointer',
            border: `1px solid ${show === k ? accent : 'var(--qb-input-border)'}`, background: show === k ? `${accent}26` : 'transparent', color: show === k ? accent : 'var(--qb-sub)',
          }}>{text}</button>
        ))}
        <button onClick={() => load()} style={{ padding: '8px 12px', borderRadius: 8, fontSize: 12, fontWeight: 800, cursor: 'pointer', border: '1px solid var(--qb-input-border)', background: 'transparent', color: accent }}>↻ Refresh</button>
      </div>

      <div style={{ ...panel, overflow: 'hidden' }}>
        {state === 'loading' && <div style={{ padding: 30, textAlign: 'center', color: 'var(--qb-muted)', fontVariantNumeric: 'tabular-nums' }}>Loading…</div>}
        {state === 'failed' && (
          <div style={{ padding: 24, color: 'var(--qb-red)', fontSize: 13 }}>
            Could not load the debtors. If this is the first time, the Debtors migration may not have been run yet.{' '}
            <button onClick={() => load()} style={{ background: 'none', border: 'none', color: accent, fontWeight: 800, cursor: 'pointer', textDecoration: 'underline' }}>Try again</button>
          </div>
        )}
        {state === 'ready' && shown.length === 0 && (
          <div style={{ padding: 30, textAlign: 'center', color: 'var(--qb-muted)', fontVariantNumeric: 'tabular-nums' }}>
            {debts.length === 0 ? 'No sales on credit yet. Switch "On credit" on when making an invoice.' : show === 'open' ? 'Nobody owes anything. 🎉' : 'Nothing matches.'}
          </div>
        )}

        {state === 'ready' && pager.shown.map((d, n) => {
          const left = owed(d), open = openId === d.id, pct = d.total > 0 ? Math.min(100, (d.paid / d.total) * 100) : 0
          const history = paymentsOf.get(d.id) || []
          return (
            <div key={d.id} style={{ borderTop: n ? '1px solid var(--qb-separator)' : 'none' }}>
              <div onClick={() => openDebt(d)} style={{ display: 'flex', gap: 14, alignItems: 'center', padding: '12px 14px', cursor: 'pointer', background: open ? 'var(--qb-separator)' : 'transparent', flexWrap: 'wrap' }}>
                <div style={{ flex: '1 1 240px', minWidth: 0 }}>
                  <div style={{ color: 'var(--qb-text)', fontWeight: 700, fontSize: 14, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{d.customer_name}</div>
                  <div style={{ color: 'var(--qb-muted)', fontSize: 11.5, fontVariantNumeric: 'tabular-nums' }}>
                    {[d.customer_num, d.invoice_number, day(d.issued_at)].filter(Boolean).join(' · ')}
                  </div>
                  {/* How far along it is. */}
                  <div style={{ height: 5, borderRadius: 999, background: 'var(--qb-fill)', marginTop: 7, maxWidth: 320 }}>
                    <div style={{ height: '100%', borderRadius: 999, width: `${pct}%`, background: left === 0 ? accent : AMBER }} />
                  </div>
                </div>
                <div style={{ textAlign: 'right', fontVariantNumeric: 'tabular-nums', fontSize: 12, color: 'var(--qb-sub)' }}>
                  <div>invoice {GHS(d.total)}</div>
                  <div>paid <span style={{ color: accent }}>{GHS(d.paid)}</span></div>
                </div>
                <div style={{ textAlign: 'right', minWidth: 130 }}>
                  {left > 0
                    ? <><div style={{ color: 'var(--qb-sub)', fontSize: 10, fontWeight: 800, letterSpacing: '0.14em' }}>OWES</div><div style={{ color: AMBER, fontWeight: 900, fontVariantNumeric: 'tabular-nums', fontSize: 16 }}>{GHS(left)}</div></>
                    : <span style={{ padding: '4px 10px', borderRadius: 999, background: `${accent}26`, color: accent, fontSize: 11, fontWeight: 800 }}>✓ SETTLED</span>}
                </div>
              </div>

              {open && (
                <div style={{ padding: '4px 14px 16px', background: 'var(--qb-separator)' }}>
                  {left > 0 && (
                    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(150px,1fr))', gap: 10, alignItems: 'end', marginBottom: 14 }}>
                      <div>
                        <label style={lbl}>Paying now (GH₵)</label>
                        <input type="number" step="0.01" min="0" max={left} style={fld} value={amount} onChange={e => setAmount(e.target.value)} placeholder={`up to ${left.toFixed(2)}`} autoFocus />
                      </div>
                      <div>
                        <label style={lbl}>Paid by</label>
                        <select style={fld} value={method} onChange={e => setMethod(e.target.value)}>{METHODS.map(m => <option key={m} value={m}>{m}</option>)}</select>
                      </div>
                      <div>
                        <label style={lbl}>Date</label>
                        <input type="date" style={fld} value={paidOn} max={today()} onChange={e => setPaidOn(e.target.value)} />
                      </div>
                      <div>
                        <label style={lbl}>Note</label>
                        <input style={fld} value={note} onChange={e => setNote(e.target.value)} placeholder="optional" />
                      </div>
                      <button onClick={() => pay(d)} disabled={saving} style={{ padding: '10px 14px', borderRadius: 8, border: 'none', background: saving ? 'var(--qb-fill)' : accent, color: saving ? 'var(--qb-muted)' : '#ffffff', fontWeight: 900, fontSize: 12, letterSpacing: '0.08em', cursor: saving ? 'wait' : 'pointer' }}>
                        {saving ? 'SAVING…' : 'RECORD PAYMENT'}
                      </button>
                      <button onClick={() => pay(d, true)} disabled={saving} style={{ padding: '10px 14px', borderRadius: 8, border: `1px solid ${accent}73`, background: 'transparent', color: accent, fontWeight: 800, fontSize: 12, cursor: saving ? 'wait' : 'pointer' }}>
                        Pay all {GHS(left)}
                      </button>
                    </div>
                  )}

                  <div style={{ color: 'var(--qb-sub)', fontSize: 10.5, fontWeight: 800, letterSpacing: '0.16em', marginBottom: 6 }}>PAYMENTS</div>
                  {history.length === 0 && <div style={{ color: 'var(--qb-muted)', fontSize: 12.5 }}>Nothing paid yet.</div>}
                  {history.map(p => (
                    <div key={p.id} style={{ display: 'flex', gap: 12, alignItems: 'center', padding: '6px 0', borderTop: '1px solid rgba(255,255,255,0.05)', fontSize: 13 }}>
                      <span style={{ color: 'var(--qb-sub)', fontVariantNumeric: 'tabular-nums', fontSize: 12, width: 86 }}>{day(p.paid_at)}</span>
                      <span style={{ color: accent, fontWeight: 800, fontVariantNumeric: 'tabular-nums', width: 130 }}>{GHS(p.amount)}</span>
                      <span style={{ color: 'var(--qb-text)', flex: 1, minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{p.payment_method}{p.note ? ` · ${p.note}` : ''}</span>
                      {isSuperBoss && (
                        <button onClick={() => takeBack(d, p)} title="Remove this payment" style={{ background: 'none', border: 'none', color: 'var(--qb-red)', cursor: 'pointer', fontSize: 15 }}>✕</button>
                      )}
                    </div>
                  ))}
                  {d.customer_loc && <div style={{ color: 'var(--qb-muted)', fontSize: 12, marginTop: 10 }}>Location: {d.customer_loc}</div>}
                </div>
              )}
            </div>
          )
        })}
        {state === 'ready' && <ListPager {...pager} accent="#0a7cff" border="var(--qb-separator)" />}
      </div>
    </div>
  )
}
