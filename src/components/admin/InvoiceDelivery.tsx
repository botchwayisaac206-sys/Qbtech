'use client'

import { supabase } from '@/lib/supabase'
import { invalidate } from '@/lib/adminCache'

/**
 * Delivery, entered on the invoice.
 *
 * A sale that is being delivered used to be typed twice: once as an invoice,
 * then again in the Deliveries tab — same customer, same number, same place.
 * The second entry was the one that got forgotten. With this switched on, the
 * invoice itself logs the delivery when it is saved, and the Deliveries tab
 * becomes the list of them rather than a second form to fill in.
 *
 * Who it is going to starts as whoever the invoice is for: the name, number
 * and location follow the customer fields above until staff type something
 * different here (a delivery to a site, or to someone receiving on the
 * customer's behalf).
 *
 * A sale with delivery switched on IS a delivery. It is logged with the
 * invoice's own total and payment method, and the Sales page counts it under
 * Delivery instead of ordinary sales (deliveredInvoiceNumbers in adminCache),
 * so the money appears once, in the right place.
 */

export const DELIVERY_PAYMENTS = ['Cash', 'Mobile Money'] as const
/** Fired on window when an invoice logs a delivery; detail is the table it went into. */
export const DELIVERY_LOGGED = 'qbnet:delivery-logged'

export interface DeliveryDraft {
  on: boolean
  /** null = follow the invoice's customer field; a string = staff typed their own. */
  name: string | null
  number: string | null
  location: string | null
}

export const newDeliveryDraft = (): DeliveryDraft => ({ on: false, name: null, number: null, location: null })

/** What will actually be logged: the delivery's own details, or the customer's where none were typed. */
export function resolveDelivery(d: DeliveryDraft, customer: string, num: string, loc: string) {
  return {
    name: (d.name ?? customer).trim(),
    number: (d.number ?? num).trim(),
    location: (d.location ?? loc).trim(),
  }
}

/** Why the delivery cannot be saved as it stands, or null when it can. */
export function deliveryProblem(d: DeliveryDraft, customer: string, num: string, loc: string): string | null {
  if (!d.on) return null
  const r = resolveDelivery(d, customer, num, loc)
  if (!r.name) return 'Delivery: who is it being delivered to?'
  return null
}

/**
 * Log the delivery for an invoice that has just been saved.
 *
 * The customer's number and the invoice it belongs to are kept in columns of
 * their own (20261007_delivery_from_invoice.sql). Until that migration is run
 * they go in the note instead, so the delivery is logged either way.
 */
export async function logInvoiceDelivery(args: {
  name: string; number: string; location: string
  /** The invoice's total and how it was paid — the delivery is that sale. */
  amount: number; method: string
  invoiceNumber: string; deliveredAt: string; userId: string | null
}) {
  const table = 'deliveries'
  const base = {
    customer_name: args.name,
    location: args.location || null,
    amount: args.amount,
    payment_method: args.method,
    delivered_at: args.deliveredAt,
    created_by: args.userId,
  }
  let { error } = await supabase.from(table).insert({ ...base, customer_num: args.number || null, invoice_number: args.invoiceNumber })
  // PGRST204 / 42703: the two new columns are not there yet.
  if (error && (error.code === 'PGRST204' || error.code === '42703')) {
    ({ error } = await supabase.from(table).insert({ ...base, note: [args.invoiceNumber, args.number && `Tel ${args.number}`].filter(Boolean).join(' · ') }))
  }
  if (error) throw error
  invalidate(table)
  // The Deliveries tab stays mounted once opened; tell it there is a new row.
  window.dispatchEvent(new CustomEvent(DELIVERY_LOGGED, { detail: table }))
}

export default function InvoiceDelivery({ value, onChange, customer, num, loc, total, accent, fld, lbl }: {
  value: DeliveryDraft
  onChange: (next: DeliveryDraft) => void
  /** The invoice's own customer fields, which this follows until overridden. */
  customer: string; num: string; loc: string
  /** The invoice total as it stands, shown so staff see what the delivery will be logged at. */
  total: number
  accent: string
  fld: React.CSSProperties
  lbl: React.CSSProperties
}) {
  const set = (patch: Partial<DeliveryDraft>) => onChange({ ...value, ...patch })
  // Typing the same thing the customer field says goes back to following it.
  const follow = (typed: string, source: string) => (typed === source ? null : typed)
  const filled = (v: string | null) => v === null

  return (
    <div style={{ marginBottom: 16, borderRadius: 12, border: `1px solid ${value.on ? `${accent}59` : 'var(--qb-border)'}`, background: value.on ? `${accent}0f` : 'transparent', transition: 'all 0.2s' }}>
      <label style={{ display: 'flex', alignItems: 'center', gap: 10, cursor: 'pointer', userSelect: 'none', padding: '12px 14px', flexWrap: 'wrap' }}>
        <div onClick={() => set({ on: !value.on })}
          style={{ width: 44, height: 24, borderRadius: 12, background: value.on ? accent : 'var(--qb-fill)', position: 'relative', transition: 'background 0.2s', flexShrink: 0 }}>
          <div style={{ position: 'absolute', top: 4, width: 16, height: 16, borderRadius: '50%', background: '#ffffff', transition: 'transform 0.2s', transform: value.on ? 'translateX(24px)' : 'translateX(4px)' }} />
        </div>
        <span onClick={() => set({ on: !value.on })} style={{ color: 'var(--qb-text)', fontSize: 12, fontWeight: 700, letterSpacing: '0.08em' }}>
          🚚 DELIVERY {value.on ? 'ON' : 'OFF'}
        </span>
        <span style={{ color: 'var(--qb-muted)', fontSize: 11.5 }}>
          {value.on
            ? `This sale is counted as a delivery — GH₵ ${total.toLocaleString('en-GH', { minimumFractionDigits: 2, maximumFractionDigits: 2 })} — and listed in the Deliveries tab. No need to enter it there.`
            : 'Switch on if this order is being delivered.'}
        </span>
      </label>

      {value.on && (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(190px,1fr))', gap: 12, padding: '0 14px 14px' }}>
          <div>
            <label style={lbl}>Deliver to *</label>
            <input style={fld} value={value.name ?? customer} onChange={e => set({ name: follow(e.target.value, customer) })} placeholder="customer name" />
            {filled(value.name) && customer.trim() && <Hint text="from the customer name" />}
          </div>
          <div>
            <label style={lbl}>Number</label>
            <input style={fld} value={value.number ?? num} onChange={e => set({ number: follow(e.target.value, num) })} placeholder="phone number" inputMode="tel" />
            {filled(value.number) && num.trim() && <Hint text="from the customer number" />}
          </div>
          <div>
            <label style={lbl}>Deliver where</label>
            <input style={fld} value={value.location ?? loc} onChange={e => set({ location: follow(e.target.value, loc) })} placeholder="e.g. Tema" />
            {filled(value.location) && loc.trim() && <Hint text="from the customer location" />}
          </div>
        </div>
      )}
    </div>
  )
}

function Hint({ text }: { text: string }) {
  return <div style={{ fontSize: 10.5, color: 'var(--qb-muted)', marginTop: 3, fontVariantNumeric: 'tabular-nums' }}>↑ filled {text}</div>
}
