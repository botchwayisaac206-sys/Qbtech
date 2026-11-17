'use client'

import { fetchStaffNames } from '@/lib/adminCache'
import { printProformaPdf, proformaNumber } from '@/lib/invoicePdf'

/**
 * Print a pro-forma invoice (a quotation) from what is on the invoice form.
 *
 * DELIBERATELY TOUCHES NOTHING. No invoice row, no stock deduction, no
 * debt, no delivery: the customer has not bought anything yet, so nothing
 * may reach the sales figures or the stock count. The form is left filled in
 * afterwards, so the same quote can be turned into a real invoice by
 * switching pro-forma off and saving.
 *
 * Its figures are worked out here rather than read back from the database
 * like a real invoice's, because there is no saved row to read — they are
 * the list prices the form shows, with the same rounding the database uses.
 */
export async function printProformaFromForm(f: {
  customer: string; loc: string; num: string
  lines: { description: string; quantity: number; unit_price: number }[]
  issueDate: string; vatRate: number; userId: string | null
}) {
  if (!f.customer.trim()) { alert('Customer name is required'); return }
  const lines = f.lines.filter(l => l.description.trim() && l.quantity > 0)
  if (lines.length === 0) { alert('Add at least one line item'); return }
  const unpriced = lines.filter(l => !(l.unit_price > 0))
  if (unpriced.length && !confirm(
    `These lines have no price and will show 0.00 on the pro-forma:\n\n` +
    unpriced.map(l => `• ${l.description.trim()}`).join('\n') + `\n\nPrint anyway?`,
  )) return

  const items = lines.map(l => ({
    description: l.description.trim(), quantity: l.quantity,
    unit_price: l.unit_price, line_total: +(l.quantity * l.unit_price).toFixed(2),
  }))
  const subtotal = +items.reduce((s, i) => s + i.line_total, 0).toFixed(2)
  const vat = +(subtotal * f.vatRate / 100).toFixed(2)
  const names = await fetchStaffNames().catch(() => ({} as Record<string, string>))
  const issued = new Date(f.issueDate + 'T' + new Date().toTimeString().slice(0, 8))

  await printProformaPdf({
    invoice_number: proformaNumber(),
    issued_at: isNaN(+issued) ? new Date() : issued,
    customer_name: f.customer.trim(), customer_loc: f.loc.trim(), customer_num: f.num.trim(),
    items, subtotal, vat_rate: f.vatRate, vat_amount: vat, total: +(subtotal + vat).toFixed(2),
    staff_name: f.userId ? names[f.userId] || undefined : undefined,
  })
}
