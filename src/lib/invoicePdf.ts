'use client'

import { jsPDF } from 'jspdf'

export interface InvoiceLine {
  description: string
  quantity: number
  unit_price: number
  line_total: number
}

export interface InvoicePayload {
  invoice_number: string
  issued_at: string | Date
  customer_name: string
  customer_loc?: string
  customer_num?: string
  order_no?: string
  rep?: string
  fob?: string
  payment_method?: string
  staff_name?: string
  items: InvoiceLine[]
  subtotal: number
  vat_rate: number
  vat_amount: number
  total: number
}

const fmt = (n: number) =>
  Number(n || 0).toLocaleString('en-GH', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

/** Build a jsPDF doc but don't download — caller decides what to do with it. */
export function buildInvoicePdf(inv: InvoicePayload): jsPDF {
  return drawInvoice(inv)
}

/** The hidden frame the last invoice was printed from (one at a time). */
let printFrame: HTMLIFrameElement | null = null

/**
 * Print the invoice: the browser's print dialog opens over the current page,
 * where the user can choose a printer or Save-as-PDF.
 *
 * WHY A HIDDEN IFRAME, NOT A NEW TAB
 * This used to open the PDF in a new tab. Browsers only allow a page to open
 * a tab for ~5 seconds after the user's click ("transient activation"), and
 * callers print at the END of a save — after several database round trips,
 * and sometimes after a confirm() the operator sat and read. Once that window
 * lapsed the tab was blocked silently: the invoice saved, but no print dialog
 * appeared. An iframe on the same page needs no popup permission and no user
 * activation, so the dialog appears however long the save took.
 *
 * If the frame cannot print (some browsers refuse to script their PDF
 * viewer), fall back to the old new-tab behaviour.
 */
export function printInvoicePdf(inv: InvoicePayload) {
  printDoc(drawInvoice(inv), fileNameFor(inv.invoice_number, inv.customer_name))
}

/**
 * The name "Save as PDF" offers, e.g. "INV-00123 - KWAME MENSAH". Without it
 * the browser names the file after the page ("QBNET TECH…"), so every saved
 * invoice had the same name.
 */
function fileNameFor(number: string, customer?: string) {
  const name = [number, (customer || '').trim()].filter(Boolean).join(' - ')
  return name.replace(/[\\/:*?"<>|]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 120) || 'Invoice'
}

/** Print any finished document through the hidden frame (see above). */
function printDoc(doc: jsPDF, fileName: string) {
  doc.setProperties({ title: fileName })
  const blobUrl = doc.output('bloburl') as unknown as string

  // Drop the previous invoice's frame. Not done straight after printing:
  // removing a frame while its print dialog is still open can cancel the job.
  if (printFrame) { URL.revokeObjectURL(printFrame.src); printFrame.remove() }

  const frame = document.createElement('iframe')
  frame.setAttribute('aria-hidden', 'true')
  // Off-screen rather than display:none — a hidden frame may never load or
  // lay out its PDF, and then prints a blank page.
  Object.assign(frame.style, { position: 'fixed', right: '0', bottom: '0', width: '0', height: '0', border: '0', visibility: 'hidden' })
  frame.onload = () => {
    // "Save as PDF" names the file after the page's title, so the page
    // carries the invoice's name while the dialog is open, then gets its own
    // back. print() waits for the dialog to close; afterprint covers browsers
    // where it does not.
    const pageTitle = document.title
    let restored = false
    const restore = () => { if (!restored) { restored = true; document.title = pageTitle } }
    document.title = fileName
    try {
      frame.contentWindow?.addEventListener('afterprint', restore)
      frame.contentWindow?.focus()
      frame.contentWindow?.print()
      setTimeout(restore, 1000)
    } catch {
      restore()
      openInNewTab(doc)
    }
  }
  frame.src = blobUrl
  document.body.appendChild(frame)
  printFrame = frame
}

/** Previous behaviour — new tab with the PDF's own auto-print. Fallback only. */
function openInNewTab(doc: jsPDF) {
  doc.autoPrint()
  const a = document.createElement('a')
  a.href = doc.output('bloburl') as unknown as string
  a.target = '_blank'
  a.rel = 'noopener'
  document.body.appendChild(a)
  a.click()
  a.remove()
}

/** Legacy download path — kept for any caller that still wants a file. */
export function downloadInvoicePdf(inv: InvoicePayload) {
  drawInvoice(inv).save(`${inv.invoice_number}.pdf`)
}

function drawInvoice(inv: InvoicePayload): jsPDF {
  const doc = new jsPDF({ unit: 'mm', format: 'a4' })
  const W = 210
  const H = 297
  const M = 14
  const contentW = W - M * 2

  // ── Top-right RECEIPT | INVOICE header ─────────────────────────
  const hdrY = 24
  const hdrH = 10
  const hdrW = 42
  doc.setLineWidth(0.5)
  // horizontal rule across top
  doc.line(M, hdrY, W - M, hdrY)
  // RECEIPT box
  doc.rect(W - M - hdrW * 2, hdrY - hdrH, hdrW, hdrH)
  doc.setFillColor(0, 0, 0)
  doc.rect(W - M - hdrW * 2, hdrY - hdrH, hdrW, hdrH, 'F')
  doc.setTextColor(255)
  doc.setFont('helvetica', 'bold')
  doc.setFontSize(13)
  doc.text('RECEIPT', W - M - hdrW * 2 + 6, hdrY - 2.5)
  // INVOICE box
  doc.setFillColor(0, 0, 0)
  doc.rect(W - M - hdrW, hdrY - hdrH, hdrW, hdrH, 'F')
  doc.setTextColor(255)
  doc.text('INVOICE', W - M - hdrW + 6, hdrY - 2.5)
  doc.setTextColor(0)

  // ── Customer + Misc blocks ────────────────────────────────────
  const blockY = hdrY + 4
  const blockH = 28
  const colW = contentW / 2 - 3

  // Customer block (left)
  doc.setFont('helvetica', 'bold'); doc.setFontSize(8)
  // label tab
  doc.rect(M, blockY, 24, 4.5)
  doc.text('Customer', M + 2, blockY + 3.2)
  // block border
  doc.rect(M, blockY + 4.5, colW, blockH - 4.5)
  // field labels
  doc.setFont('helvetica', 'bold'); doc.setFontSize(8.5)
  doc.text('NAME', M + 2, blockY + 10)
  doc.text('Loc',  M + 2, blockY + 16)
  doc.text('NUM',  M + 2, blockY + 22)
  // values + underlines
  doc.setFont('helvetica', 'normal'); doc.setFontSize(9)
  const drawVal = (label: string, val: string, y: number) => {
    doc.text(val || '', M + 16, y)
    doc.line(M + 16, y + 0.8, M + colW - 3, y + 0.8)
  }
  drawVal('NAME', (inv.customer_name || '').toUpperCase(), blockY + 10)
  drawVal('Loc',  inv.customer_loc || '',                   blockY + 16)
  drawVal('NUM',  inv.customer_num || '',                   blockY + 22)

  // Misc block (right)
  const mx = M + colW + 6
  doc.setFont('helvetica', 'bold'); doc.setFontSize(8)
  doc.rect(mx, blockY, 18, 4.5)
  doc.text('Misc', mx + 2, blockY + 3.2)
  doc.rect(mx, blockY + 4.5, colW, blockH - 4.5)
  doc.setFont('helvetica', 'bold'); doc.setFontSize(8.5)
  doc.text('Order No.', mx + 2, blockY + 16)
  doc.text('Rep',       mx + 2, blockY + 22)
  doc.text('FOB',       mx + 2, blockY + 28)
  doc.setFont('helvetica', 'normal'); doc.setFontSize(9)
  const d = new Date(inv.issued_at)
  const dateStr = `${d.getDate()}/${d.getMonth() + 1}/${d.getFullYear().toString().slice(-2)}`
  // Date top-right of misc block
  doc.text(dateStr, mx + colW - 22, blockY + 10)
  doc.line(mx + colW - 26, blockY + 10.8, mx + colW - 3, blockY + 10.8)
  const drawMisc = (val: string, y: number) => {
    doc.text(val || '', mx + 22, y)
    doc.line(mx + 22, y + 0.8, mx + colW - 3, y + 0.8)
  }
  drawMisc(inv.order_no || '', blockY + 16)
  drawMisc(inv.rep || '',      blockY + 22)
  drawMisc(inv.fob || 'ACC',   blockY + 28)

  // ── Items table ───────────────────────────────────────────────
  const tblY = blockY + blockH + 4
  const rowH = 6
  // column widths
  const cNum = 10, cItem = 110, cPrice = 30, cTotal = contentW - cNum - cItem - cPrice
  // header strip
  doc.setFont('helvetica', 'bold'); doc.setFontSize(8.5)
  doc.rect(M, tblY, contentW, rowH)
  doc.text('TOTAL GH¢', M + cNum + cItem + cPrice + 4, tblY + 4)
  // body box
  const bodyH = 140
  doc.rect(M, tblY + rowH, contentW, bodyH)
  // column dividers
  doc.line(M + cNum, tblY, M + cNum, tblY + rowH + bodyH)
  doc.line(M + cNum + cItem, tblY, M + cNum + cItem, tblY + rowH + bodyH)
  doc.line(M + cNum + cItem + cPrice, tblY, M + cNum + cItem + cPrice, tblY + rowH + bodyH)

  // rows
  doc.setFont('helvetica', 'normal'); doc.setFontSize(10)
  inv.items.slice(0, 18).forEach((it, i) => {
    const y = tblY + rowH + 5 + i * rowH
    doc.text(String(it.quantity), M + 2, y)
    doc.text((it.description || '').slice(0, 60), M + cNum + 2, y)
    doc.text(fmt(it.unit_price), M + cNum + cItem + cPrice - 2, y, { align: 'right' })
    doc.text(fmt(it.line_total), M + contentW - 2, y, { align: 'right' })
  })

  // ── Totals column ─────────────────────────────────────────────
  const totY = tblY + rowH + bodyH + 4
  doc.setFont('helvetica', 'bold'); doc.setFontSize(9)
  doc.rect(M + cNum + cItem + cPrice, totY, cTotal, 7)
  doc.text('SubTotal', M + cNum + cItem + 2, totY + 5)
  doc.text(fmt(inv.subtotal), M + contentW - 2, totY + 5, { align: 'right' })

  // VAT row (only when applied)
  const vatActive = Number(inv.vat_rate) > 0
  if (vatActive) {
    doc.rect(M + cNum + cItem + cPrice, totY + 7, cTotal, 7)
    doc.setFont('helvetica', 'normal')
    doc.text(`VAT (${inv.vat_rate}%)`, M + cNum + cItem + 2, totY + 12)
    doc.text(fmt(inv.vat_amount), M + contentW - 2, totY + 12, { align: 'right' })
  }

  const totalOffsetY = vatActive ? 14 : 7
  doc.rect(M + cNum + cItem + cPrice, totY + totalOffsetY, cTotal, 8)
  doc.setFont('helvetica', 'bold')
  doc.setFontSize(11)
  doc.text(fmt(inv.total), M + contentW - 2, totY + totalOffsetY + 6, { align: 'right' })

  // ── Payment block ─────────────────────────────────────────────
  const payY    = totY
  const payH    = 26
  const payW    = 92
  const pm      = inv.payment_method || 'Cash'
  const isSplit = pm.includes(' + ')
  const payRowH = isSplit ? 9 : 4.5        // taller header row for split

  doc.setFont('helvetica', 'bold'); doc.setFontSize(8)
  doc.rect(M, payY, 22, payRowH)
  doc.text('Payment', M + 2, payY + 3.2)

  if (isSplit) {
    const parts = pm.split(' + ')
    doc.rect(M + 22, payY, 70, payRowH)    // wider box for two lines
    doc.setFont('helvetica', 'normal'); doc.setFontSize(7.5)
    doc.text(parts[0],         M + 24, payY + 3.2)
    doc.text('+ ' + parts[1], M + 24, payY + 7.5)
  } else {
    doc.rect(M + 22, payY, 30, payRowH)
    doc.setFont('helvetica', 'normal'); doc.setFontSize(8)
    doc.text(pm, M + 24, payY + 3.2)
  }

  doc.rect(M, payY + payRowH, payW, payH - payRowH)
  doc.setFont('helvetica', 'normal'); doc.setFontSize(8)
  doc.setTextColor(100)
  doc.text('Served by', M + 2, payY + 12)
  doc.setTextColor(0)
  doc.setFont('helvetica', 'bold'); doc.setFontSize(11)
  doc.text((inv.staff_name || '').toUpperCase(), M + 2, payY + 22)

  // ── Rules footer ──────────────────────────────────────────────
  const rulesY = payY + payH + 6
  doc.setLineWidth(1.2)
  doc.line(M, rulesY, W - M, rulesY)
  doc.line(M, rulesY + 18, W - M, rulesY + 18)
  // black square
  doc.setFillColor(0, 0, 0); doc.rect(M, rulesY + 2, 4, 14, 'F')
  doc.setFont('helvetica', 'italic'); doc.setFontSize(7.5)
  const rules =
    "RULES AND REGULATION... 1) ITEM'S SOLD ARE NOT RETURNABLE...2) NO REFUND OF MONEY AFTER PAYMENT..3) ALWAYS ENSURE THAT YOU ARE GIVEN " +
    "THE RIGHT GOOD'S, BECAUSE ITEMS BOUGHT AND OPEN ARE  NOT  RETURNABLE...4) PLEASE KINDLY ENSURE THAT YOUR HARD DRIVES ARE TESTED " +
    "BECAUSE, TESTED OK NO WARRANTY..WE COUNT ON YOUR PATRONAGE, THANK YOU."
  const split = doc.splitTextToSize(rules, contentW - 10)
  doc.text(split, M + 6, rulesY + 5)

  // ── Tagline ───────────────────────────────────────────────────
  doc.setFont('helvetica', 'italic'); doc.setFontSize(8.5)
  doc.text('Your Best LinkTo IT Technology Worldwide!', W / 2, rulesY + 24, { align: 'center' })

  // ── Invoice number (subtle, top-left) ─────────────────────────
  // The company's phone numbers used to print under it; the shop asked for
  // them off the invoice.
  doc.setFont('helvetica', 'bold'); doc.setFontSize(7)
  doc.setTextColor(120)
  doc.text(`# ${inv.invoice_number}`, M, 10)
  doc.setTextColor(0)

  return doc
}

// ════════════════════════════════════════════════════════════════
// PRO-FORMA INVOICE
// A quotation on letterhead. It is printed only: nothing is saved, no
// stock moves and no sale is counted — the customer has not bought yet.
// ════════════════════════════════════════════════════════════════

/** The brands strip printed across the foot of every pro-forma page. */
export const PROFORMA_BRANDS_IMAGE = '/proforma-brands.png'
export const PROFORMA_VALID_DAYS = 14

const COMPANY = {
  name: 'QBNET TECH SOLUTIONS',
  tagline: 'Your Best LinkTo IT Technology Worldwide!',
  lines: ['Accra, Ghana', 'info@qbnettech.com  ·  www.qbnettech.com'],
}

/** Where customers pay — printed on every pro-forma. */
const BANK: [string, string][] = [
  ['Bank', 'ADD BANK NAME'],
  ['Account name', 'QBNET TECH'],
  ['Account no.', 'ADD ACCOUNT NO.'],
]

const NAVY: [number, number, number] = [13, 31, 60]
const TEAL_RGB: [number, number, number] = [79, 124, 255]

interface LoadedImage { data: string; w: number; h: number }

/**
 * Load a picture from /public as a PNG data URL. Drawn through a canvas so
 * any format the browser can show (progressive JPEG, WebP…) reaches the
 * PDF in one jsPDF is sure to read. Missing or broken → null, and the
 * document is drawn without it rather than not at all.
 */
function loadImage(src: string): Promise<LoadedImage | null> {
  return new Promise(resolve => {
    const img = new Image()
    img.onload = () => {
      try {
        const c = document.createElement('canvas')
        c.width = img.naturalWidth; c.height = img.naturalHeight
        const ctx = c.getContext('2d')
        if (!ctx || !c.width || !c.height) return resolve(null)
        ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, c.width, c.height)
        ctx.drawImage(img, 0, 0)
        resolve({ data: c.toDataURL('image/png'), w: c.width, h: c.height })
      } catch { resolve(null) }
    }
    img.onerror = () => resolve(null)
    img.src = src
  })
}

/**
 * A quote number from the moment it was made: PF-261101-142803. Made in the
 * browser on purpose — a pro-forma is never saved, so there is no series in
 * the database to keep unique; the time to the second tells quotes apart.
 */
export function proformaNumber(at = new Date()) {
  const p = (n: number) => String(n).padStart(2, '0')
  return 'PF-' + String(at.getFullYear()).slice(-2) + p(at.getMonth() + 1) + p(at.getDate()) +
    '-' + p(at.getHours()) + p(at.getMinutes()) + p(at.getSeconds())
}

/** Draw the pro-forma and open the print dialog. */
export async function printProformaPdf(inv: InvoicePayload) {
  const [logo, brands] = await Promise.all([loadImage('/logo.jpg'), loadImage(PROFORMA_BRANDS_IMAGE)])
  printDoc(drawProforma(inv, logo, brands), fileNameFor('Pro-forma ' + inv.invoice_number, inv.customer_name))
}

function drawProforma(inv: InvoicePayload, logo: LoadedImage | null, brands: LoadedImage | null): jsPDF {
  const doc = new jsPDF({ unit: 'mm', format: 'a4' })
  const W = 210, H = 297, M = 14
  const contentW = W - M * 2
  const issued = new Date(inv.issued_at)
  const validUntil = new Date(issued.getTime() + PROFORMA_VALID_DAYS * 86400000)
  const dateStr = (d: Date) => d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })

  // Footer height, reserved on every page: brands strip + tagline.
  const brandsH = brands ? Math.min(22, (contentW * brands.h) / brands.w) : 0
  const footerTop = H - 10 - brandsH - 8

  // ── Letterhead ────────────────────────────────────────────────
  const drawHeader = () => {
    doc.setFillColor(...NAVY); doc.rect(0, 0, W, 4, 'F')
    let textX = M
    if (logo) {
      const maxH = 24, maxW = 40
      let lw = (maxH * logo.w) / logo.h, lh = maxH
      if (lw > maxW) { lw = maxW; lh = (maxW * logo.h) / logo.w }
      doc.addImage(logo.data, 'PNG', M, 9 + (maxH - lh) / 2, lw, lh)
      textX = M + lw + 6
    }
    doc.setTextColor(...NAVY)
    doc.setFont('helvetica', 'bold'); doc.setFontSize(17)
    doc.text(COMPANY.name, textX, 17)
    doc.setFont('helvetica', 'italic'); doc.setFontSize(9); doc.setTextColor(...TEAL_RGB)
    doc.text(COMPANY.tagline, textX, 22.5)
    doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); doc.setTextColor(90)
    COMPANY.lines.forEach((l, i) => doc.text(l, textX, 28 + i * 4.3))
    doc.setDrawColor(...TEAL_RGB); doc.setLineWidth(0.8)
    doc.line(M, 39, W - M, 39)
    doc.setTextColor(0)
  }

  // ── Footer: brands strip, tagline, page number ────────────────
  const drawFooter = (page: number, pages: number) => {
    doc.setDrawColor(210); doc.setLineWidth(0.3)
    doc.line(M, footerTop, W - M, footerTop)
    if (brands) {
      const bw = Math.min(contentW, (brandsH * brands.w) / brands.h)
      doc.addImage(brands.data, 'PNG', (W - bw) / 2, footerTop + 3, bw, brandsH)
    }
    doc.setFont('helvetica', 'italic'); doc.setFontSize(7.5); doc.setTextColor(120)
    doc.text(COMPANY.tagline + '   ·   Page ' + page + ' of ' + pages, W / 2, H - 6, { align: 'center' })
    doc.setFillColor(...NAVY); doc.rect(0, H - 3, W, 3, 'F')
    doc.setTextColor(0)
  }

  drawHeader()

  // ── Title + quote details ─────────────────────────────────────
  doc.setFont('helvetica', 'bold'); doc.setFontSize(22); doc.setTextColor(...NAVY)
  doc.text('PRO-FORMA INVOICE', M, 52)
  doc.setTextColor(0)
  const boxW = 70, boxX = W - M - boxW
  const details: [string, string][] = [
    ['Pro-forma No.', inv.invoice_number],
    ['Date', dateStr(issued)],
    ['Valid until', dateStr(validUntil)],
  ]
  doc.setDrawColor(210); doc.setLineWidth(0.3)
  doc.roundedRect(boxX, 44, boxW, 22, 1.5, 1.5)
  details.forEach(([k, v], i) => {
    const y = 50 + i * 6
    doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); doc.setTextColor(110)
    doc.text(k, boxX + 4, y)
    doc.setFont('helvetica', 'bold'); doc.setTextColor(0)
    doc.text(v, boxX + boxW - 4, y, { align: 'right' })
  })

  // ── Bill to ───────────────────────────────────────────────────
  // No shading behind any text: sections are set apart by rules and space.
  const billY = 74
  doc.setFont('helvetica', 'bold'); doc.setFontSize(8); doc.setTextColor(...TEAL_RGB)
  doc.text('BILL TO', M, billY)
  doc.text('PREPARED BY', W / 2 + 10, billY)
  doc.setTextColor(0); doc.setFontSize(11)
  doc.text((inv.customer_name || '').toUpperCase(), M, billY + 6)
  doc.setFont('helvetica', 'normal'); doc.setFontSize(9); doc.setTextColor(70)
  doc.text([inv.customer_loc, inv.customer_num].filter(Boolean).join('  ·  '), M, billY + 11.5)
  // Prepared by the company — the quote is QBNET TECH's, not one staff member's.
  doc.setFont('helvetica', 'bold'); doc.setFontSize(10); doc.setTextColor(0)
  doc.text(COMPANY.name, W / 2 + 10, billY + 6)
  doc.setFont('helvetica', 'normal'); doc.setFontSize(9); doc.setTextColor(70)
  doc.text(COMPANY.lines[0], W / 2 + 10, billY + 11.5)
  doc.setTextColor(0)

  // ── Items ─────────────────────────────────────────────────────
  // Right edges of the number columns, far enough apart that headings and
  // figures never run into each other.
  const col = {
    no: M + 4,            // "#", left
    desc: M + 13,         // description, left
    descEnd: M + 102,     // description wraps before this
    qty: M + 116,         // right edge
    unit: M + 150,        // right edge
    amt: W - M - 4,       // right edge
  }
  const lineH = 4.4
  const headRow = (top: number) => {
    // A light rounded outline, like the pro-forma details card — no heavy rules.
    doc.setDrawColor(210); doc.setLineWidth(0.3)
    doc.roundedRect(M, top, contentW, 8.5, 1.5, 1.5)
    doc.setFont('helvetica', 'bold'); doc.setFontSize(8.5); doc.setTextColor(...NAVY)
    doc.text('#', col.no, top + 5.6)
    doc.text('DESCRIPTION', col.desc, top + 5.6)
    doc.text('QTY', col.qty, top + 5.6, { align: 'right' })
    doc.text('UNIT PRICE (GHC)', col.unit, top + 5.6, { align: 'right' })
    doc.text('AMOUNT (GHC)', col.amt, top + 5.6, { align: 'right' })
    doc.setTextColor(0)
    return top + 8.5
  }

  // Rows run onto further pages as needed; footers go on every page at the end.
  let y = headRow(94)
  inv.items.forEach((it, i) => {
    doc.setFont('helvetica', 'normal'); doc.setFontSize(9.5)
    const desc = doc.splitTextToSize(it.description || '', col.descEnd - col.desc) as string[]
    const h = Math.max(9, desc.length * lineH + 4.6)
    if (y + h > footerTop - 4) { doc.addPage(); drawHeader(); y = headRow(46) }
    const base = y + 5.8
    doc.setTextColor(0)
    doc.text(String(i + 1), col.no, base)
    doc.text(desc, col.desc, base, { lineHeightFactor: 1.3 })
    doc.text(String(it.quantity), col.qty, base, { align: 'right' })
    doc.text(fmt(it.unit_price), col.unit, base, { align: 'right' })
    doc.setFont('helvetica', 'bold')
    doc.text(fmt(it.line_total), col.amt, base, { align: 'right' })
    doc.setDrawColor(225); doc.setLineWidth(0.2); doc.line(M, y + h, W - M, y + h)
    y += h
  })

  // ── Totals and notes sit together just above the payment details,
  //    which sit just above the footer on the last page. ───────────
  const vatOn = Number(inv.vat_rate) > 0
  const GAP = 12                         // least breathing space under the item lines
  const bankH = 21
  const bankTop = footerTop - 5 - bankH  // where the payment card starts
  doc.setFont('helvetica', 'normal'); doc.setFontSize(8)
  const notes = doc.splitTextToSize(
    'This is a pro-forma invoice: a quotation, not a receipt or a tax invoice. ' +
    'Prices are valid until ' + dateStr(validUntil) + ' and subject to stock availability. ' +
    'Goods are supplied once payment is received.', contentW) as string[]
  const totalsH = (vatOn ? 2 : 1) * 7 + 12
  const notesH = 7 + notes.length * 3.4
  const blockH = 5 + totalsH + 2 + notesH
  const blockTop = bankTop - 5 - blockH
  if (blockTop < y + GAP) { doc.addPage(); drawHeader() }
  y = blockTop + 5                       // first totals baseline
  const tW = 80, tX = W - M - tW

  const totalRow = (label: string, value: string, strong = false) => {
    if (strong) {
      y += 2
      // The same light rounded outline as the pro-forma details card.
      doc.setDrawColor(210); doc.setLineWidth(0.3)
      doc.roundedRect(tX, y - 6.2, tW, 9.5, 1.5, 1.5)
      doc.setTextColor(...NAVY)
    }
    doc.setFont('helvetica', strong ? 'bold' : 'normal'); doc.setFontSize(strong ? 12 : 9.5)
    doc.text(label, tX + 4, y)
    doc.text(value, W - M - 4, y, { align: 'right' })
    doc.setTextColor(0)
    y += strong ? 10 : 7
  }
  totalRow('Subtotal', 'GHC ' + fmt(inv.subtotal))
  if (vatOn) totalRow('VAT (' + inv.vat_rate + '%)', 'GHC ' + fmt(inv.vat_amount))
  totalRow('TOTAL', 'GHC ' + fmt(inv.total), true)

  y += 2
  doc.setFont('helvetica', 'bold'); doc.setFontSize(8.5); doc.setTextColor(...TEAL_RGB)
  doc.text('NOTES', M, y + 2)
  doc.setFont('helvetica', 'normal'); doc.setFontSize(8); doc.setTextColor(80)
  doc.text(notes, M, y + 7)
  doc.setTextColor(0)

  // ── Payment details card, just above the footer ───────────────
  doc.setDrawColor(210); doc.setLineWidth(0.3)
  doc.roundedRect(M, bankTop, contentW, bankH, 1.5, 1.5)
  doc.setFont('helvetica', 'bold'); doc.setFontSize(8); doc.setTextColor(...TEAL_RGB)
  doc.text('PAYMENT DETAILS', M + 5, bankTop + 6)
  // Fixed columns sized to their values: the account name is long, so it
  // gets the widest one and never runs into the account number.
  const bankX = [M + 5, M + 42, M + 128]
  BANK.forEach(([k, v], i) => {
    const bx = bankX[i]
    doc.setFont('helvetica', 'normal'); doc.setFontSize(8); doc.setTextColor(110)
    doc.text(k, bx, bankTop + 12)
    doc.setFont('helvetica', 'bold'); doc.setFontSize(9.5); doc.setTextColor(0)
    doc.text(v, bx, bankTop + 17)
  })
  doc.setTextColor(0)

  const pages = doc.getNumberOfPages()
  for (let p = 1; p <= pages; p++) { doc.setPage(p); drawFooter(p, pages) }
  return doc
}
