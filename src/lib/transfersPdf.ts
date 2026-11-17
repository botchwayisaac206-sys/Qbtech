'use client'

import { jsPDF } from 'jspdf'
import { supabase } from '@/lib/supabase'
import { fetchAllRows } from '@/lib/adminCache'

/**
 * Dahua stock movements, as a PDF to keep or print — one day's, or every
 * one ever made.
 *
 * One line per product moved: when, which movement, what kind, from where to
 * where, the product, how many, and who did it. Movements are the approved
 * ones — what actually changed the stock. Requests still waiting for
 * approval are listed after them, so nothing done is missing from the page.
 */

interface Head {
  id: string
  transfer_number: string; kind: 'move' | 'receive' | 'return' | 'reversal'
  from_warehouse: string | null; to_warehouse: string; from_line: string | null; to_line: string | null
  supplier: string | null; signed_by: string | null; staff_id: string | null; transferred_at: string
  items: { model: string; quantity: number; position: number; condition: string }[]
}
interface Waiting {
  request_number: string; kind: string; from_warehouse: string | null; to_warehouse: string
  items: { model: string; quantity: number }[]; requested_name: string | null; requested_at: string
}

const KIND: Record<string, string> = { move: 'Moved', receive: 'Received', return: 'Returned', reversal: 'Reversed' }

/** `day` is YYYY-MM-DD in shop time, or 'all' for every movement there has been. */
export async function downloadDahuaTransfersPdf(day: string | 'all') {
  const all = day === 'all'
  const from = all ? null : new Date(day + 'T00:00:00')
  const to = from ? new Date(from.getTime() + 86_400_000) : null

  // Paged: a full history runs past the thousand rows one request returns.
  const heads = await fetchAllRows<Head>((a, b) => {
    let q = supabase.from('dahua_stock_transfers')
      .select('id,transfer_number,kind,from_warehouse,to_warehouse,from_line,to_line,supplier,signed_by,staff_id,transferred_at,items:dahua_stock_transfer_items(model,quantity,position,condition)')
    if (from && to) q = q.gte('transferred_at', from.toISOString()).lt('transferred_at', to.toISOString())
    return q.order('transferred_at', { ascending: true }).order('id', { ascending: true }).range(a, b) as unknown as PromiseLike<{ data: Head[] | null; error: { message: string } | null }>
  })

  // Best effort: before the approval migration there are no requests.
  let pq = supabase.from('dahua_movement_requests')
    .select('request_number,kind,from_warehouse,to_warehouse,items,requested_name,requested_at')
    .eq('status', 'pending')
  if (from && to) pq = pq.gte('requested_at', from.toISOString()).lt('requested_at', to.toISOString())
  const pend = await pq.order('requested_at', { ascending: true }).limit(1000)
  const pending = (pend.data as Waiting[]) || []

  const stamp = (iso: string) => all
    ? new Date(iso).toLocaleString('en-GB', { day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit' })
    : new Date(iso).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })
  const place = (wh: string | null, line: string | null) => (wh ? (line === 'main' ? `${wh} (Main shop)` : wh) : '')
  const rows = heads.flatMap(h => [...(h.items || [])].sort((a, b) => a.position - b.position).map(i => ({
    time: stamp(h.transferred_at),
    ref: h.transfer_number,
    kind: KIND[h.kind] + (i.condition === 'spoilt' ? ' (spoilt)' : ''),
    route: h.kind === 'move' || h.kind === 'reversal' ? `${place(h.from_warehouse, h.from_line)} > ${place(h.to_warehouse, h.to_line)}` : `${h.supplier ? h.supplier + ' > ' : ''}${h.to_warehouse}`,
    product: i.model, qty: Number(i.quantity) || 0,
    who: h.signed_by || h.staff_id || '-',
  })))

  // ── Draw ──────────────────────────────────────────────────
  const doc = new jsPDF({ unit: 'mm', format: 'a4', orientation: 'landscape' })
  const W = doc.internal.pageSize.getWidth(), H = doc.internal.pageSize.getHeight(), M = 12
  const timeW = all ? 28 : 16
  const cols = [
    { k: 'time', t: all ? 'Date' : 'Time', w: timeW }, { k: 'ref', t: 'Ref', w: 34 }, { k: 'kind', t: 'Kind', w: 24 },
    { k: 'route', t: 'From > To', w: 60 }, { k: 'product', t: 'Product', w: 88 - (timeW - 16) }, { k: 'qty', t: 'Qty', w: 14, right: true },
    { k: 'who', t: 'Staff', w: W - 2 * M - (timeW + 34 + 24 + 60 + 88 - (timeW - 16) + 14) },
  ] as { k: keyof typeof rows[number]; t: string; w: number; right?: boolean }[]
  const units = rows.reduce((s, r) => s + r.qty, 0)
  const title = all ? 'QBNET TECH · Dahua stock movements - all time' : 'QBNET TECH · Dahua stock movements'
  const sub = all
    ? (heads.length ? `${new Date(heads[0].transferred_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' })} to ${new Date(heads[heads.length - 1].transferred_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' })}` : 'No movements yet')
    : from!.toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' })
  let y = M

  const header = (first: boolean) => {
    if (first) {
      doc.setFont('helvetica', 'bold'); doc.setFontSize(15); doc.text(title, M, y + 5)
      doc.setFont('helvetica', 'normal'); doc.setFontSize(10); doc.setTextColor(90)
      doc.text(sub, M, y + 11)
      doc.text(`${heads.length.toLocaleString()} movement${heads.length === 1 ? '' : 's'} · ${rows.length.toLocaleString()} line${rows.length === 1 ? '' : 's'} · ${units.toLocaleString()} unit${units === 1 ? '' : 's'}`, W - M, y + 11, { align: 'right' })
      doc.setTextColor(0); y += 17
    }
    doc.setFillColor(235, 238, 242); doc.rect(M, y, W - 2 * M, 7, 'F')
    doc.setFont('helvetica', 'bold'); doc.setFontSize(8.5)
    let x = M + 2
    for (const c of cols) { doc.text(c.t, c.right ? x + c.w - 4 : x, y + 4.8, { align: c.right ? 'right' : 'left' }); x += c.w }
    doc.setFont('helvetica', 'normal'); y += 9
  }
  const line = (cells: Record<string, string | number>) => {
    // Long product names wrap onto a second line rather than run into the next column.
    const wrapped = cols.map(c => doc.splitTextToSize(String(cells[c.k] ?? ''), c.w - 3) as string[])
    const h = Math.max(...wrapped.map(w => w.length)) * 3.8 + 1.6
    if (y + h > H - M) { doc.addPage(); y = M; header(false) }
    let x = M + 2
    cols.forEach((c, n) => { doc.text(wrapped[n], c.right ? x + c.w - 4 : x, y + 3, { align: c.right ? 'right' : 'left' }); x += c.w })
    doc.setDrawColor(225); doc.line(M, y + h - 0.6, W - M, y + h - 0.6)
    y += h
  }

  header(true)
  doc.setFontSize(8.5)
  if (rows.length === 0) {
    doc.setTextColor(120)
    doc.text(all ? 'No Dahua stock has been moved, received or returned yet.' : 'No Dahua stock was moved, received or returned on this day.', M + 2, y + 4)
    doc.setTextColor(0); y += 10
  }
  for (const r of rows) line(r)

  if (pending.length) {
    if (y + 22 > H - M) { doc.addPage(); y = M }
    y += 6
    doc.setFont('helvetica', 'bold'); doc.setFontSize(11); doc.text('Waiting for approval - the stock has NOT changed for these', M, y); y += 4
    doc.setFont('helvetica', 'normal'); header(false); doc.setFontSize(8.5)
    for (const p of pending) for (const i of p.items || []) line({
      time: stamp(p.requested_at), ref: p.request_number, kind: KIND[p.kind] || p.kind,
      route: p.kind === 'move' ? `${p.from_warehouse} > ${p.to_warehouse}` : p.to_warehouse,
      product: i.model, qty: i.quantity, who: p.requested_name || '-',
    })
  }

  const pages = doc.getNumberOfPages()
  for (let n = 1; n <= pages; n++) {
    doc.setPage(n); doc.setFontSize(8); doc.setTextColor(140)
    doc.text(`Printed ${new Date().toLocaleString('en-GB')} · page ${n} of ${pages}`, W - M, H - 5, { align: 'right' })
  }
  doc.save(all ? `dahua-stock-movements-all-time.pdf` : `dahua-stock-movements-${day}.pdf`)
  return { movements: heads.length, lines: rows.length, pending: pending.length }
}
