'use client'


/**
 * "On credit", on the invoice.
 *
 * Switched on, the sale is saved as a debt: the customer takes the goods and
 * pays bit by bit. Whatever they pay on the spot is recorded as the first
 * payment; the rest is tracked in the Debtors tab until it is settled.
 *
 * It changes what the Sales page counts, not what the invoice is. The
 * invoice is still printed and numbered, and the stock still comes off the
 * shelf at once — the goods have left. But only money actually received
 * counts as sales: the part paid now today, and each later payment on the
 * day it comes in.
 */

export interface CreditDraft {
  on: boolean
  /** What the customer is paying right now, as typed. Blank = nothing yet. */
  paidNow: string
}

export const newCreditDraft = (): CreditDraft => ({ on: false, paidNow: '' })

export const paidNowOf = (c: CreditDraft) => Math.max(0, Math.round((parseFloat(c.paidNow) || 0) * 100) / 100)

/** Why the credit sale cannot be saved as it stands, or null when it can. */
export function creditProblem(c: CreditDraft, total: number, customerNum: string): string | null {
  if (!c.on) return null
  if (total <= 0) return 'On credit: the invoice has no amount to owe'
  if (c.paidNow.trim() !== '' && !(parseFloat(c.paidNow) >= 0)) return 'On credit: "paid now" is not a valid amount'
  if (paidNowOf(c) >= total) return 'On credit: "paid now" covers the whole invoice — switch credit off, this is an ordinary sale'
  // A debt nobody can be reached about is a debt that is not collected.
  if (!customerNum.trim()) return 'On credit: enter the customer\'s phone number, so they can be followed up'
  return null
}

export default function InvoiceCredit({ value, onChange, total, method, fld, lbl }: {
  value: CreditDraft
  onChange: (next: CreditDraft) => void
  total: number
  /** How the part paid now is being paid — the invoice's own Payment field. */
  method: string
  fld: React.CSSProperties
  lbl: React.CSSProperties
}) {
  const AMBER = '#f59e0b'
  const set = (patch: Partial<CreditDraft>) => onChange({ ...value, ...patch })
  const paid = paidNowOf(value)
  const left = Math.max(0, +(total - paid).toFixed(2))
  const money = (n: number) => `GH₵ ${n.toLocaleString('en-GH', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`

  return (
    <div style={{ marginBottom: 16, borderRadius: 12, border: `1px solid ${value.on ? `${AMBER}73` : 'var(--qb-border)'}`, background: value.on ? `${AMBER}12` : 'transparent', transition: 'all 0.2s' }}>
      <label style={{ display: 'flex', alignItems: 'center', gap: 10, cursor: 'pointer', userSelect: 'none', padding: '12px 14px', flexWrap: 'wrap' }}>
        <div onClick={() => set({ on: !value.on })}
          style={{ width: 44, height: 24, borderRadius: 12, background: value.on ? AMBER : 'var(--qb-fill)', position: 'relative', transition: 'background 0.2s', flexShrink: 0 }}>
          <div style={{ position: 'absolute', top: 4, width: 16, height: 16, borderRadius: '50%', background: '#ffffff', transition: 'transform 0.2s', transform: value.on ? 'translateX(24px)' : 'translateX(4px)' }} />
        </div>
        <span onClick={() => set({ on: !value.on })} style={{ color: 'var(--qb-text)', fontSize: 12, fontWeight: 700, letterSpacing: '0.08em' }}>
          🧾 ON CREDIT {value.on ? 'ON' : 'OFF'}
        </span>
        <span style={{ color: 'var(--qb-muted)', fontSize: 11.5 }}>
          {value.on
            ? 'Goes to the Debtors tab. Counts as sales only as it is paid.'
            : 'Switch on if the customer is taking the goods and paying later.'}
        </span>
      </label>

      {value.on && (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(190px,1fr))', gap: 12, padding: '0 14px 14px', alignItems: 'end' }}>
          <div>
            <label style={{ ...lbl, color: AMBER }}>Paid now (GH₵)</label>
            <input type="number" step="0.01" min="0" style={fld} value={value.paidNow} onChange={e => set({ paidNow: e.target.value })} placeholder="0.00 if nothing yet" />
            <div style={{ fontSize: 10.5, color: 'var(--qb-muted)', marginTop: 3, fontVariantNumeric: 'tabular-nums' }}>
              {paid > 0 ? `by ${method} · counts as sales today` : 'leave blank if they pay nothing today'}
            </div>
          </div>
          <div style={{ padding: '9px 12px', borderRadius: 8, border: '1px dashed rgba(245,158,11,0.4)' }}>
            <div style={{ fontSize: 10, fontWeight: 800, letterSpacing: '0.18em', color: 'var(--qb-sub)' }}>INVOICE</div>
            <div style={{ color: 'var(--qb-text)', fontVariantNumeric: 'tabular-nums', fontWeight: 700, fontSize: 15 }}>{money(total)}</div>
          </div>
          <div style={{ padding: '9px 12px', borderRadius: 8, border: `1px solid ${AMBER}73`, background: `${AMBER}1f` }}>
            <div style={{ fontSize: 10, fontWeight: 800, letterSpacing: '0.18em', color: AMBER }}>WILL OWE</div>
            <div style={{ color: 'var(--qb-text)', fontVariantNumeric: 'tabular-nums', fontWeight: 900, fontSize: 15 }}>{money(left)}</div>
          </div>
        </div>
      )}
    </div>
  )
}
