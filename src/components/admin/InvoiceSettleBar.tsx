'use client'

import { GHS } from '@/lib/sales'

/**
 * The bar at the top of an invoice form: the VAT switch, the running
 * figures and SAVE & PRINT, all in one row. Kept at the top so the button is
 * always in reach and the right-hand column is left whole for delivery and
 * credit.
 */
export default function InvoiceSettleBar({
  vatEnabled, onToggleVat, vatRate, subtotal, vatAmount, total,
  saving, savingLabel = 'SAVING…', onSave, accent, tint,
  proforma = false, onToggleProforma,
}: {
  vatEnabled: boolean
  onToggleVat: () => void
  vatRate: number
  subtotal: number
  vatAmount: number
  total: number
  saving: boolean
  savingLabel?: string
  onSave: () => void
  accent: string
  /** Border/background tint, as an "r,g,b" triple. */
  tint: string
  /** Pro-forma mode: the button prints a quote instead of saving a sale. */
  proforma?: boolean
  onToggleProforma?: () => void
}) {
  const PURPLE = '#a78bfa'
  const toggle = (on: boolean, color: string, label: string, onClick: () => void) => (
    <label onClick={onClick} style={{ display: 'flex', alignItems: 'center', gap: 10, cursor: 'pointer', userSelect: 'none' }}>
      <div style={{ width: 44, height: 24, borderRadius: 12, background: on ? color : 'var(--qb-fill)', position: 'relative', transition: 'background 0.2s', flexShrink: 0 }}>
        <div style={{ position: 'absolute', top: 4, width: 16, height: 16, borderRadius: '50%', background: '#ffffff', transition: 'transform 0.2s', transform: on ? 'translateX(24px)' : 'translateX(4px)' }} />
      </div>
      <span style={{ color: on ? color : 'var(--qb-text)', fontSize: 12, fontWeight: 700, letterSpacing: '0.08em', whiteSpace: 'nowrap' }}>
        {label}
      </span>
    </label>
  )
  const figure = (label: string, value: number, big = false) => (
    <div style={{ display: 'flex', flexDirection: 'column', lineHeight: 1.15 }}>
      <span style={{ fontSize: 9.5, fontWeight: 800, letterSpacing: '0.16em', color: big ? accent : 'var(--qb-muted)' }}>{label}</span>
      <span style={{ fontVariantNumeric: 'tabular-nums', fontWeight: big ? 900 : 600, fontSize: big ? 18 : 13.5, color: big ? 'var(--qb-text)' : 'var(--qb-text)', whiteSpace: 'nowrap' }}>{GHS(value)}</span>
    </div>
  )

  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 18, flexWrap: 'wrap',
      padding: '8px 8px 8px 14px', borderRadius: 12,
      background: `linear-gradient(135deg, rgba(${tint},0.1), var(--qb-card))`,
      border: `1px solid rgba(${tint},0.25)`,
    }}>
      {onToggleProforma && toggle(proforma, PURPLE, `PRO-FORMA ${proforma ? 'ON' : 'OFF'}`, onToggleProforma)}
      {toggle(vatEnabled, accent, `APPLY VAT (${vatRate}%) ${vatEnabled ? 'ON' : 'OFF'}`, onToggleVat)}

      <div style={{ display: 'flex', alignItems: 'center', gap: 22, marginLeft: 'auto', flexWrap: 'wrap' }}>
        {figure('SUBTOTAL', subtotal)}
        {vatEnabled && figure(`VAT (${vatRate}%)`, vatAmount)}
        {figure('TOTAL', total, true)}
      </div>

      <button onClick={onSave} disabled={saving} style={{
        padding: '13px 28px', borderRadius: 10, background: saving ? 'var(--qb-fill)' : proforma ? PURPLE : accent,
        color: saving ? 'var(--qb-muted)' : '#ffffff', fontWeight: 900, fontSize: 14, letterSpacing: '0.12em',
        border: 'none', cursor: saving ? 'not-allowed' : 'pointer', whiteSpace: 'nowrap',
      }}>
        {saving ? (proforma ? 'PREPARING…' : savingLabel) : proforma ? 'PRINT PRO-FORMA' : 'SAVE & PRINT'}
      </button>
    </div>
  )
}
