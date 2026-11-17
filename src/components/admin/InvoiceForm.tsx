'use client'

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { supabase } from '@/lib/supabase'
import InvoiceCredit, { newCreditDraft, creditProblem, paidNowOf, type CreditDraft } from '@/components/admin/InvoiceCredit'
import { openDebt } from '@/lib/debts'
import InvoiceDelivery, { newDeliveryDraft, resolveDelivery, deliveryProblem, logInvoiceDelivery, type DeliveryDraft } from '@/components/admin/InvoiceDelivery'
import { printInvoicePdf, type InvoiceLine } from '@/lib/invoicePdf'
import { printProformaFromForm } from '@/lib/proforma'
import { fetchProductsLite, fetchStockModels, fetchStaffNames, fetchPricelistMap, fetchLastSoldPrices, invalidate, type LastSold } from '@/lib/adminCache'
import { cleanCode, linkCode, loadCodeMap } from '@/lib/productCodes'
import CameraScanner from '@/components/admin/CameraScanner'
import { deductInvoiceStore, describeShortfalls, fetchLevels, modelKey, STORE, type Levels } from '@/lib/storeStock'
import ModelPicker, { type PickerOption } from '@/components/admin/ModelPicker'
import { fetchNoStockSales, useNoStockSales } from '@/lib/stockApproval'
import { useFitHeight } from '@/lib/useFitHeight'
import InvoiceSettleBar from '@/components/admin/InvoiceSettleBar'

const TEAL = '#0a7cff'
const VAT_RATE_DEFAULT = 20 // percent

/**
 * The key a price is filed under: the same product key every stock movement
 * matches on (stock_model_key), so "DS-2CE16D0T-LPFS" and "ds-2ce16d0t lpfs"
 * share one price — as price_for_model() resolves it since
 * 20261024_stock_accuracy.sql.
 */
const priceKey = (model: string) => modelKey(model)

interface Product { id: string; title: string; model_number: string; price: number | null }

interface Line {
  key: number
  product_id: string | null
  description: string
  quantity: number
  unit_price: number
}

let keyCounter = 0
const newLine = (): Line => ({ key: ++keyCounter, product_id: null, description: '', quantity: 1, unit_price: 0 })

// Invoice & order numbers are assigned server-side by a BEFORE INSERT trigger
// (see migration 20260603_server_invoice_numbers.sql). The client no longer
// computes them — that was unsafe for cashiers, who can't SELECT other staff's
// invoices under RLS and so kept reusing already-taken numbers.

export default function InvoiceForm({ onSaved, userId, toolbarSlot = null }: {
  onSaved?: () => void; userId: string | null
  /** A place in the drafts row to draw the date and scanner; drawn above the form without one. */
  toolbarSlot?: HTMLElement | null
}) {
  const [products, setProducts] = useState<Product[]>([])
  const [stockModels, setStockModels] = useState<string[]>([])
  const [codeMap, setCodeMap] = useState<Map<string, string>>(new Map())
  const [priceMap, setPriceMap] = useState<Map<string, number>>(new Map())
  const [lastSold, setLastSold] = useState<Map<string, LastSold>>(new Map())
  const [pendingLink, setPendingLink] = useState<{ code: string } | null>(null)
  const [camera, setCamera] = useState(false)
  const [scanFlash, setScanFlash] = useState<{ tone: 'ok' | 'warn' | 'err'; text: string } | null>(null)
  const scanRef = useRef<HTMLInputElement>(null)
  // Scan mode: off until switched on; on, the barcode box shows and takes the focus.
  const [scanMode, setScanMode] = useState(false)
  useEffect(() => { if (scanMode) scanRef.current?.focus() }, [scanMode])
  const lastScanRef = useRef<{ code: string; t: number }>({ code: '', t: 0 })
  const [customer, setCustomer] = useState('')
  const [loc, setLoc] = useState('')
  const [num, setNum] = useState('')
  const [payment, setPayment]         = useState('Cash')
  const [splitMode, setSplitMode]     = useState(false)
  const [splitMethod1, setSplitMethod1] = useState('Cash')
  const [splitAmount1, setSplitAmount1] = useState('')
  const [splitMethod2, setSplitMethod2] = useState('Mobile Money')
  const [lines, setLines] = useState<Line[]>([newLine()])
  // What the shop floor holds, by model. Invoiced units come out of STORE
  // STOCK, so the cashier is shown the figure BEFORE the sale is committed —
  // a shortfall never blocks the invoice, it just has to be visible.
  const [storeLevels, setStoreLevels] = useState<Levels>(new Map())
  const [saving, setSaving] = useState(false)
  const [issueDate, setIssueDate] = useState(() => new Date().toISOString().slice(0,10))
  const [vatEnabled, setVatEnabled] = useState(false)
  // Delivery, logged with the invoice instead of typed again in the Deliveries tab.
  const [delivery, setDelivery] = useState<DeliveryDraft>(newDeliveryDraft)
  // A sale on credit: tracked in the Debtors tab, counted as sales only as it is paid.
  const [credit, setCredit] = useState<CreditDraft>(newCreditDraft)
  // On a computer screen the whole form fits the window; on a phone it flows.
  const { ref: fitRef, height: fitH } = useFitHeight()
  const wide = fitH !== null

  useEffect(() => {
    let cancelled = false
    ;(async () => {
      try {
        const [prods, models, codes, prices, sold, levels] = await Promise.all([
          fetchProductsLite(), fetchStockModels(), loadCodeMap(), fetchPricelistMap(), fetchLastSoldPrices(),
          // Deliberately uncached: an on-hand figure that is minutes old is
          // more misleading than showing none at all.
          fetchLevels().catch(() => new Map() as Levels),
        ])
        if (cancelled) return
        setProducts(prods as Product[])
        setStockModels(models)
        setCodeMap(codes)
        setPriceMap(prices)
        setLastSold(sold)
        setStoreLevels(levels)
      } catch (err) {
        if (!cancelled) console.warn('InvoiceForm load failed:', err)
      }
    })()
    return () => { cancelled = true }
  }, [])

  // ── Scan-to-add-line: resolve a material code to a model, then either bump
  // an existing line for that model or append a new one. Mirrors ScanStock's
  // resolve/link flow so the same barcode vocabulary works in both places.
  const flash = useCallback((tone: 'ok' | 'warn' | 'err', text: string) => {
    setScanFlash({ tone, text })
    try { navigator.vibrate?.(tone === 'ok' ? 35 : 70) } catch { /* no haptics */ }
  }, [])

  const addOrBumpModel = useCallback((model: string) => {
    setLines(ls => {
      const idx = ls.findIndex(l => l.description === model)
      if (idx >= 0) {
        const l = ls[idx]
        const updated = { ...l, quantity: l.quantity + 1 }
        return ls.map((x, i) => i === idx ? updated : x)
      }
      const matchedProduct = products.find(p => p.model_number === model)
      const unit_price = matchedProduct?.price ?? priceMap.get(priceKey(model)) ?? 0
      const line: Line = {
        key: ++keyCounter, product_id: matchedProduct?.id ?? null,
        description: model, quantity: 1, unit_price,
      }
      // Reuse the first still-blank line instead of always appending.
      const blankIdx = ls.findIndex(l => !l.description.trim())
      if (blankIdx >= 0) return ls.map((x, i) => i === blankIdx ? line : x)
      return [...ls, line]
    })
    flash('ok', model)
  }, [products, priceMap, flash])

  const handleScan = useCallback((raw: string) => {
    const trimmed = raw.trim()
    if (!trimmed) return
    const code = cleanCode(trimmed)
    if (!code) return

    const now = Date.now()
    if (lastScanRef.current.code === code && now - lastScanRef.current.t < 150) return
    lastScanRef.current = { code, t: now }

    const model = codeMap.get(code)
    if (!model) { flash('warn', 'New barcode — link it below'); setPendingLink({ code }); return }
    addOrBumpModel(model)
  }, [codeMap, addOrBumpModel, flash])

  const subtotal  = useMemo(() => lines.reduce((s, l) => s + l.quantity * l.unit_price, 0), [lines])
  const vatRate   = vatEnabled ? VAT_RATE_DEFAULT : 0
  const vatAmount = +(subtotal * vatRate / 100).toFixed(2)
  const total     = +(subtotal + vatAmount).toFixed(2)

  const splitAmt1 = Math.min(total, Math.max(0, parseFloat(splitAmount1) || 0))
  const splitAmt2 = +Math.max(0, total - splitAmt1).toFixed(2)
  const effectivePayment = splitMode
    ? `${splitMethod1} (GHC ${splitAmt1.toFixed(2)}) + ${splitMethod2} (GHC ${splitAmt2.toFixed(2)})`
    : payment

  /**
   * What the item field offers. STORE STOCK comes first with its on-hand
   * figure, because that is what the sale is deducted from and what the
   * cashier can actually hand over. Models tracked elsewhere but not in the
   * store follow underneath — without them the field would be empty until
   * the store has been stocked, which would be a step backwards.
   */
  const pickerOptions = useMemo<PickerOption[]>(() => {
    const inStore: PickerOption[] = []
    for (const [model, qty] of Array.from(storeLevels)) {
      inStore.push({ model, qty, group: STORE })
    }
    inStore.sort((a, b) => a.model.localeCompare(b.model))
    const elsewhere = stockModels.filter(m => !storeLevels.has(m))
    // Before the store has been stocked there is nothing to contrast against,
    // so drop the headings rather than filing every model under "Not in store".
    if (inStore.length === 0) return elsewhere.map(model => ({ model }))
    return [...inStore, ...elsewhere.map(model => ({ model, group: 'Not in store' }))]
  }, [storeLevels, stockModels])

  /**
   * NO STOCK, NO SALE. A line that sells a product the shop stocks — picked
   * from the catalogue, or named the way a stock row names it — can only be
   * invoiced up to what STORE STOCK holds. Lines that match no stocked
   * product (installation, labour, a one-off) are not stock and go through.
   * Matched on the same key the database uses, so a different spelling of a
   * stocked product is caught too.
   */
  // The Big Boss can let staff past the rule (right-click New Invoice).
  const noStockAllowed = useNoStockSales()
  const trackedKeys = useMemo(() => new Set(stockModels.map(modelKey).filter(Boolean)), [stockModels])
  const stockKeyOf = useCallback((l: Line) => {
    const p = l.product_id ? products.find(x => x.id === l.product_id) : null
    const k = modelKey((p?.model_number || l.description).trim())
    return k && trackedKeys.has(k) ? k : null
  }, [products, trackedKeys])
  const storeHas = (levels: Levels) => {
    const by = new Map<string, number>()
    for (const [model, qty] of Array.from(levels)) by.set(modelKey(model), (by.get(modelKey(model)) || 0) + qty)
    return by
  }
  const storeByKey = useMemo(() => storeHas(storeLevels), [storeLevels])
  const needByKey = useMemo(() => {
    const by = new Map<string, number>()
    for (const l of lines) { const k = stockKeyOf(l); if (k && l.quantity > 0) by.set(k, (by.get(k) || 0) + l.quantity) }
    return by
  }, [lines, stockKeyOf])
  /** Every stocked product on the invoice that the store cannot cover. */
  const outOfStock = (levels: Map<string, number>, list: Line[]) => {
    const need = new Map<string, { name: string; qty: number }>()
    for (const l of list) {
      const k = stockKeyOf(l)
      if (!k || l.quantity <= 0) continue
      const n = need.get(k) || { name: l.description.trim(), qty: 0 }
      n.qty += l.quantity; need.set(k, n)
    }
    return Array.from(need, ([k, n]) => ({ ...n, have: Math.max(0, levels.get(k) ?? 0) })).filter(x => x.qty > x.have)
  }

  const updateLine = (key: number, patch: Partial<Line>) =>
    setLines(ls => ls.map(l => l.key === key ? { ...l, ...patch } : l))

  /**
   * The price list fills the price in as soon as an item is entered. When the
   * item changes to one with no listed price, a price that only came from the
   * old item's listing is cleared rather than carried over; one the cashier
   * typed is left alone.
   */
  const listPriceFor = (line: Line, desc: string): Partial<Line> => {
    const list = priceMap.get(priceKey(desc))
    if (list != null) return { unit_price: list }
    const before = priceMap.get(priceKey(line.description))
    return before != null && line.unit_price === before ? { unit_price: 0 } : {}
  }

  const pickProduct = (key: number, pid: string) => {
    if (!pid) return updateLine(key, { product_id: null, description: '', unit_price: 0 })
    const p = products.find(x => x.id === pid)
    if (!p) return
    updateLine(key, {
      product_id: p.id,
      description: `${p.title}${p.model_number ? ' — ' + p.model_number : ''}`,
      // The price list is what the shop sells at; the catalogue price is a fallback.
      unit_price: (p.model_number ? priceMap.get(priceKey(p.model_number)) : undefined) ?? p.price ?? 0,
    })
  }

  // One save at a time. The checks before the invoice is written wait on the
  // network, and a second click in that gap used to save — and print — the
  // same invoice twice. The lock is taken on the very first click.
  // Pro-forma mode: the button prints a quotation instead of saving a sale.
  // Switching it on turns VAT on, as a quote shows the full price.
  const [proforma, setProforma] = useState(false)
  const toggleProforma = () => { const on = !proforma; setProforma(on); if (on) setVatEnabled(true) }
  const saveLock = useRef(false)
  async function save() {
    if (saveLock.current) return
    saveLock.current = true
    setSaving(true)
    // Pro-forma: print a quote only — nothing is saved (see printProformaFromForm).
    try { await (proforma ? printProformaFromForm({ customer, loc, num, lines, issueDate, vatRate, userId: userId ?? null }) : saveOnce()) }
    finally { saveLock.current = false; setSaving(false) }
  }

  async function saveOnce() {
    if (!customer.trim()) return alert('Customer name is required')
    const validLines = lines.filter(l => l.description.trim() && l.quantity > 0)
    if (validLines.length === 0) return alert('Add at least one line item')
    const deliveryIssue = deliveryProblem(delivery, customer, num, loc)
    if (deliveryIssue) return alert(deliveryIssue)
    const creditIssue = creditProblem(credit, total, num)
    if (creditIssue) return alert(creditIssue)
    // Checked against a fresh count, not the one loaded when the form opened.
    const fresh = await fetchLevels().catch(() => null)
    if (fresh) setStoreLevels(fresh)
    const short = outOfStock(storeHas(fresh ?? storeLevels), validLines)
    // Read fresh: he may have switched it a moment ago.
    if (short.length && await fetchNoStockSales()) {
      if (!confirm(
        `Not enough in ${STORE}:\n\n` +
        short.map(s => `• ${s.name} — ${s.have === 0 ? 'none in stock' : `only ${s.have} in stock`}, invoicing ${s.qty}`).join('\n') +
        `\n\nInvoice anyway? The stock count will go below zero.`,
      )) return
    } else if (short.length) {
      return alert(
        `Not enough in ${STORE} to invoice:\n\n` +
        short.map(s => `• ${s.name} — ${s.have === 0 ? 'none in stock' : `only ${s.have} in stock`}, invoicing ${s.qty}`).join('\n') +
        `\n\nMove stock into ${STORE} first (Transfers tab), or lower the quantity.`,
      )
    }
    // On a credit sale the Payment field says how the part paid NOW is paid;
    // the invoice itself is recorded, and printed, as a credit sale.
    const paidNow = credit.on ? paidNowOf(credit) : 0
    const paidNowMethod = splitMode ? splitMethod1 : payment
    const invoicePayment = !credit.on ? effectivePayment
      : paidNow > 0 ? `Credit (paid GHC ${paidNow.toFixed(2)} by ${paidNowMethod})` : 'Credit'

    setSaving(true)
    try {
      const staffNames = await fetchStaffNames()
      const staffName = userId ? (staffNames[userId] || '') : ''
      const issued_at = new Date(issueDate + 'T' + new Date().toTimeString().slice(0,8)).toISOString()

      // Invoice number + order number are assigned server-side by the
      // BEFORE INSERT trigger (RLS-proof). We send them null and read the
      // assigned values back — no client-side counter, no collision retries.
      const { data: inv, error: invErr } = await supabase.from('invoices').insert({
        customer_name: customer.trim(),
        customer_loc: loc || null,
        customer_num: num || null,
        payment_method: invoicePayment,
        subtotal, vat_rate: vatRate, vat_amount: vatAmount, total,
        issued_at,
        created_by: userId,
      }).select('id, invoice_number, order_no').single()
      if (invErr) throw invErr
      if (!inv) throw new Error('Invoice insert failed')

      const invoice_number_final = inv.invoice_number
      const orderNo              = inv.order_no

      const itemsPayload = validLines.map((l, i) => ({
        invoice_id: inv.id,
        product_id: l.product_id,
        description: l.description,
        quantity: l.quantity,
        unit_price: l.unit_price,
        line_total: +(l.quantity * l.unit_price).toFixed(2),
        position: i + 1,
      }))
      // Read the rows back rather than trusting the payload. Since
      // 20260921_main_fixed_pricing.sql, trg_invoice_item_apply_price has
      // the last word on an unpriced line's price and re-derives line_total,
      // so the printed PDF must show what was actually stored.
      const { data: savedItems, error: itemErr } = await supabase.from('invoice_items')
        .insert(itemsPayload).select('description,quantity,unit_price,line_total,position')
        .order('position', { ascending: true })
      if (itemErr) throw itemErr

      const finalItems = (savedItems?.length ? savedItems : itemsPayload) as {
        description: string; quantity: number; unit_price: number; line_total: number
      }[]

      // trg_invoice_resync_totals recomputes the header from those lines, so
      // the figures printed on the invoice come from the row, not from what
      // this form worked out before saving.
      const { data: savedInv } = await supabase.from('invoices')
        .select('subtotal,vat_amount,total').eq('id', inv.id).single()
      const finalSubtotal = Number(savedInv?.subtotal   ?? subtotal)
      const finalVat      = Number(savedInv?.vat_amount ?? vatAmount)
      const finalTotal    = Number(savedInv?.total      ?? total)

      // Fire-and-forget: log watch_alerts for any invoiced product the boss is watching
      const watchedProductIds = validLines.map(l => l.product_id).filter(Boolean) as string[]
      if (watchedProductIds.length > 0) {
        supabase.from('product_watches').select('id,product_id')
          .in('product_id', watchedProductIds)
          .then(({ data: watches }) => {
            if (!watches?.length) return
            const alertRows = watches.map(w => {
              const line = validLines.find(l => l.product_id === w.product_id)
              return { watch_id: w.id, product_id: w.product_id, quantity: line?.quantity ?? 1, invoice_id: inv!.id }
            })
            supabase.from('watch_alerts').insert(alertRows)
          })
      }

      // ── Deduct from STORE STOCK ───────────────────────────────
      // Runs after the invoice is safely saved and is never allowed to fail
      // the sale: the shop's rule is that a bad count must not stop a
      // customer. Shortfalls come back so the cashier knows what to go and
      // check, and the store figure is simply driven negative.
      // The database works out what to deduct from the saved lines — a line
      // picked from the catalogue deducts against the product's model number,
      // since its "Title — MODEL" description matches no stock row.
      let shortfalls: Awaited<ReturnType<typeof deductInvoiceStore>> = []
      try {
        shortfalls = await deductInvoiceStore(inv.id)
      } catch (stockErr) {
        console.warn('[INV] store stock deduction failed:', stockErr)
        shortfalls = []
        alert(
          `Invoice ${invoice_number_final} was saved, but ${STORE} could not be updated.
` +
          `Adjust it by hand in the Stock tab.`,
        )
      }

      // ── Log the delivery ──────────────────────────────────────
      // After the invoice is safely saved, and never allowed to fail it: a
      // delivery that could not be logged is a line to add by hand, not a
      // sale to lose.
      if (delivery.on) {
        try {
          await logInvoiceDelivery({
            ...resolveDelivery(delivery, customer, num, loc),
            // What the database stored, after it priced the lines — the same
            // figure that prints on the invoice.
            amount: finalTotal, method: invoicePayment,
            invoiceNumber: invoice_number_final, deliveredAt: issued_at, userId,
          })
        } catch (delErr) {
          console.warn('[INV] delivery log failed:', delErr)
          alert(`Invoice ${invoice_number_final} was saved, but the delivery could not be logged.\nAdd it in the Deliveries tab.`)
        }
      }

      // ── Open the debt ─────────────────────────────────────────
      // Like the delivery, after the invoice is safe and never allowed to
      // fail it. A credit sale with no debt behind it would simply drop out
      // of the books — not in sales, not in Debtors — so say so loudly.
      if (credit.on) {
        try {
          await openDebt({
            line: 'main', invoiceId: inv.id, invoiceNumber: invoice_number_final,
            customer, customerNum: num, customerLoc: loc,
            total: finalTotal, issuedAt: issued_at, userId,
            paidNow: Math.min(paidNow, finalTotal), method: paidNowMethod,
          })
        } catch (debtErr: any) {
          console.warn('[INV] debt not opened:', debtErr)
          alert(`Invoice ${invoice_number_final} was saved, but it could NOT be added to Debtors:\n${debtErr?.message || 'unknown error'}\n\nTell the Big Boss — until it is added, this sale counts as an ordinary sale.`)
        }
      }

      const pdfItems: InvoiceLine[] = finalItems.map(i => ({
        description: i.description, quantity: Number(i.quantity),
        unit_price: Number(i.unit_price), line_total: Number(i.line_total),
      }))
      printInvoicePdf({
        invoice_number: invoice_number_final,
        issued_at, customer_name: customer, customer_loc: loc, customer_num: num,
        order_no: orderNo, payment_method: invoicePayment,
        items: pdfItems, subtotal: finalSubtotal, vat_rate: vatRate, vat_amount: finalVat, total: finalTotal,
        staff_name: staffName || undefined,
      })

      // A line typed free-hand, or picked from the product catalogue (whose
      // description is "Title — MODEL"), will never match a stock row. Those
      // are not a shortfall, they are just items the warehouse does not track,
      // so only report an untracked model the shop stocks SOMEWHERE — that one
      // really is missing from the store.
      const tracked = new Set(stockModels)
      const worthSaying = shortfalls.filter(sf => sf.tracked || tracked.has(sf.model))
      if (worthSaying.length > 0) {
        alert(`Invoice ${invoice_number_final} saved.

${STORE} is short on:

${describeShortfalls(worthSaying)}`)
      }

      // Both the store figures and the stock model list may have moved.
      fetchLevels().then(setStoreLevels).catch(() => { /* reload on next open */ })
      invalidate('invoices', 'invoice_items', 'invoices_list_rows', 'last_sold_prices', 'deliveries')
      setCustomer(''); setLoc(''); setNum('')
      setPayment('Cash')
      setSplitMode(false); setSplitAmount1(''); setSplitMethod1('Cash'); setSplitMethod2('Mobile Money')
      setVatEnabled(false)
      setIssueDate(new Date().toISOString().slice(0, 10))
      setLines([newLine()])
      setDelivery(newDeliveryDraft())
      setCredit(newCreditDraft())
      onSaved?.()
    } catch (e: any) {
      console.error('[INV] save failed:', e)
      alert(e.message || 'Failed to save invoice')
    } finally { setSaving(false) }
  }

  const fld: React.CSSProperties = {
    width: '100%', padding: '9px 12px', borderRadius: 8, fontSize: 14, outline: 'none',
    border: '1px solid var(--qb-input-border)', background: 'var(--qb-input)', color: 'var(--qb-text)',
  }
  const lbl: React.CSSProperties = { fontSize: 10, fontWeight: 800, color: TEAL, letterSpacing: '0.18em', textTransform: 'uppercase', display: 'block', marginBottom: 5 }

  return (
    <div ref={fitRef} style={wide
      ? { height: fitH!, display: 'flex', flexDirection: 'column', gap: 12, maxWidth: 1500 }
      : { maxWidth: 980 }}>

      {/* Date and the scanner sit up in the drafts row, so the lines get the
          height. Scanning is a mode: switched on, the barcode box appears and
          takes the focus, ready for a wedge scanner or a typed code + Enter. */}
      {(() => {
        const tools = (
          <>
            {scanMode && (
              <>
                {scanFlash && (
                  <span style={{
                    fontSize: 11, fontWeight: 800, fontVariantNumeric: 'tabular-nums', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', minWidth: 0,
                    color: scanFlash.tone === 'ok' ? TEAL : scanFlash.tone === 'warn' ? '#f59e0b' : 'var(--qb-red)',
                  }}>
                    {scanFlash.tone === 'ok' ? '✓ ' : scanFlash.tone === 'warn' ? '⚠ ' : '⛔ '}{scanFlash.text}
                  </span>
                )}
                <form onSubmit={e => { e.preventDefault(); const v = scanRef.current?.value ?? ''; if (scanRef.current) scanRef.current.value = ''; if (v.trim()) handleScan(v) }}
                  style={{ display: 'flex', gap: 6, flex: '0 1 280px', minWidth: 150 }}>
                  <input ref={scanRef} placeholder="Scan a barcode…"
                    autoComplete="off" autoCorrect="off" autoCapitalize="off" spellCheck={false}
                    style={{ ...fld, padding: '7px 10px', fontVariantNumeric: 'tabular-nums', fontSize: 13, minWidth: 0 }} />
                  <button type="submit" style={{ padding: '0 12px', borderRadius: 8, border: 'none', background: TEAL, color: '#ffffff', fontWeight: 900, fontSize: 12, letterSpacing: '0.06em', cursor: 'pointer', whiteSpace: 'nowrap' }}>ADD</button>
                </form>
                <button type="button" onClick={() => setCamera(true)} title="Scan with camera"
                  style={{ padding: '6px 10px', borderRadius: 8, border: '1px solid var(--qb-input-border)', background: 'var(--qb-input)', color: 'var(--qb-text)', fontSize: 15, cursor: 'pointer', flexShrink: 0 }}>📷</button>
              </>
            )}
            <button type="button" onClick={() => setScanMode(s => !s)} title={scanMode ? 'Turn scan mode off' : 'Turn scan mode on to add lines by barcode'}
              style={{
                display: 'flex', alignItems: 'center', gap: 8, padding: '6px 12px', borderRadius: 10, flexShrink: 0,
                border: `1px solid ${scanMode ? TEAL : 'var(--qb-input-border)'}`, background: scanMode ? 'var(--qb-border)' : 'var(--qb-input)',
                color: scanMode ? TEAL : 'var(--qb-text)', fontWeight: 800, fontSize: 11.5, letterSpacing: '0.1em', cursor: 'pointer',
              }}>
              {/* Block-level, or the track and knob take no size at all. */}
              <span style={{ display: 'block', flexShrink: 0, width: 36, height: 20, borderRadius: 10, background: scanMode ? TEAL : '#334155', position: 'relative', transition: 'background 0.2s' }}>
                <span style={{ display: 'block', position: 'absolute', top: 3, left: 0, width: 14, height: 14, borderRadius: '50%', background: '#ffffff', transition: 'transform 0.2s', transform: scanMode ? 'translateX(19px)' : 'translateX(3px)' }} />
              </span>
              SCAN
            </button>
            <label style={{ display: 'flex', alignItems: 'center', gap: 8, flexShrink: 0 }}>
              <span style={{ ...lbl, marginBottom: 0 }}>Date</span>
              <input type="date" style={{ ...fld, width: 'auto', padding: '7px 10px' }} value={issueDate} onChange={e => setIssueDate(e.target.value)} />
            </label>
          </>
        )
        return toolbarSlot ? createPortal(tools, toolbarSlot)
          : <div style={{ display: 'flex', justifyContent: 'flex-end', alignItems: 'center', gap: 8, flexWrap: 'wrap', marginBottom: wide ? 0 : 12 }}>{tools}</div>
      })()}

      {/* VAT, the figures and SAVE & PRINT — always at the top, in reach. */}
      <div style={{ marginBottom: wide ? 0 : 12 }}>
        <InvoiceSettleBar
          vatEnabled={vatEnabled} onToggleVat={() => setVatEnabled(v => !v)} vatRate={VAT_RATE_DEFAULT}
          subtotal={subtotal} vatAmount={vatAmount} total={total}
          saving={saving} onSave={save} accent={TEAL} tint="79,124,255"
          proforma={proforma} onToggleProforma={toggleProforma} />
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(170px,1fr))', gap: 10, marginBottom: wide ? 0 : 16 }}>
        <div><label style={lbl}>Customer Name *</label><input style={fld} value={customer} onChange={e => setCustomer(e.target.value)} placeholder="e.g. AKWASI" /></div>
        <div><label style={lbl}>Location</label><input style={fld} value={loc} onChange={e => setLoc(e.target.value)} /></div>
        <div><label style={lbl}>Customer Num</label><input style={fld} value={num} onChange={e => setNum(e.target.value)} placeholder="phone number" /></div>
        <div style={{ gridColumn: splitMode ? 'span 3' : undefined }}>
          <label style={lbl}>Payment</label>
          {!splitMode ? (
            <div style={{ display: 'flex', gap: 6 }}>
              <select style={{ ...fld, flex: 1 }} value={payment} onChange={e => setPayment(e.target.value)}>
                <option>Cash</option><option>Mobile Money</option><option>Bank Transfer</option><option>Cheque</option>
              </select>
              <button type="button" onClick={() => setSplitMode(true)}
                style={{ padding: '0 12px', borderRadius: 8, border: '1px solid var(--qb-input-border)', background: 'var(--qb-input)', color: TEAL, fontSize: 11, fontWeight: 800, cursor: 'pointer', whiteSpace: 'nowrap' }}>
                ⊕ Split
              </button>
            </div>
          ) : (
            // The whole split on one line: method · amount + method · balance.
            <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
              <select style={{ ...fld, flex: 1, minWidth: 0 }} value={splitMethod1} onChange={e => setSplitMethod1(e.target.value)}>
                <option>Cash</option><option>Mobile Money</option><option>Bank Transfer</option><option>Cheque</option>
              </select>
              <input type="number" min={0} step="0.01" placeholder="Amount"
                value={splitAmount1} onChange={e => setSplitAmount1(e.target.value)}
                style={{ ...fld, width: 95, flexShrink: 0 }} />
              <span style={{ color: 'var(--qb-muted)', fontWeight: 900 }}>+</span>
              <select style={{ ...fld, flex: 1, minWidth: 0 }} value={splitMethod2} onChange={e => setSplitMethod2(e.target.value)}>
                <option>Cash</option><option>Mobile Money</option><option>Bank Transfer</option><option>Cheque</option>
              </select>
              {/* The balance, not an input — it is always total minus leg one. */}
              <div title="The rest of the total" style={{ ...fld, width: 95, flexShrink: 0, color: TEAL, fontVariantNumeric: 'tabular-nums', fontSize: 13, background: 'var(--qb-separator)', textAlign: 'right' }}>
                {splitAmt2.toFixed(2)}
              </div>
              <button type="button" onClick={() => { setSplitMode(false); setSplitAmount1('') }} title="Back to a single payment"
                style={{ flexShrink: 0, padding: '9px 10px', borderRadius: 8, border: '1px solid var(--qb-input-border)', background: 'none', color: 'var(--qb-muted)', fontSize: 12, cursor: 'pointer' }}>
                ✕
              </button>
            </div>
          )}
        </div>
      </div>

      {/* Body: the lines on the left, everything that settles the sale on the
          right — so SAVE & PRINT is always on screen, however many lines. */}
      <div style={wide
        ? { flex: 1, minHeight: 0, display: 'grid', gridTemplateColumns: 'minmax(0,1fr) 340px', gridTemplateRows: 'minmax(0,1fr)', gap: 12 }
        : undefined}>
      <div style={wide ? { display: 'flex', flexDirection: 'column', minHeight: 0 } : undefined}>


      {/* Line items table */}
      <div style={wide
        ? { border: '1px solid var(--qb-border)', borderRadius: 12, flex: 1, minHeight: 0, overflowY: 'auto', overscrollBehavior: 'contain' }
        : { border: '1px solid var(--qb-border)', borderRadius: 12, overflow: 'hidden', marginBottom: 14 }}>
        <div style={{ display: 'grid', gridTemplateColumns: '40px 1fr 90px 130px 130px 40px', padding: '10px 12px', background: '#0b2236', color: TEAL, fontSize: 10, fontWeight: 800, letterSpacing: '0.15em', position: 'sticky', top: 0, zIndex: 1 }}>
          <div>#</div><div>ITEM / DESCRIPTION</div><div>QTY</div><div>UNIT PRICE</div><div>TOTAL GH¢</div><div></div>
        </div>
        {lines.map((l, i) => (
          <div key={l.key} style={{ display: 'grid', gridTemplateColumns: '40px 1fr 90px 130px 130px 40px', padding: 10, borderTop: '1px solid var(--qb-separator)', alignItems: 'center', gap: 6 }}>
            <div style={{ color: 'var(--qb-sub)', fontVariantNumeric: 'tabular-nums' }}>{i + 1}</div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <select style={{ ...fld, padding: '6px 10px', fontSize: 12 }} value={l.product_id || ''} onChange={e => pickProduct(l.key, e.target.value)}>
                <option value="">— Pick product —</option>
                {products.map(p => <option key={p.id} value={p.id}>{p.title} · {p.model_number}</option>)}
              </select>
              <ModelPicker
                value={l.description}
                options={pickerOptions}
                onChange={desc => updateLine(l.key, { description: desc, ...listPriceFor(l, desc) })}
                inputStyle={{ ...fld, padding: '6px 10px', fontSize: 12 }}
                placeholder="click to see store stock, or type…"
                emptyHint="No stock match — keep typing to use as custom description"
                theme={{
                  menuBg: 'var(--qb-input)', border: 'var(--qb-input-border)', text: 'var(--qb-text)',
                  sub: 'var(--qb-muted)', accent: TEAL, accentText: '#ffffff',
                }}
              />
              {/* The model's fixed price, and whether this line departs from
                  it. The database applies the price on save either way; an
                  override is allowed but written to the audit log, so it
                  should never be a surprise. */}
              {(() => {
                const list = priceMap.get(priceKey(l.description))
                if (!list) return null
                const over = l.unit_price > 0 && Math.abs(l.unit_price - list) >= 0.005
                return (
                  <div style={{ fontSize: 11, fontVariantNumeric: 'tabular-nums', color: over ? '#f59e0b' : 'var(--qb-muted)' }}>
                    {over ? '⚠ override — list ' : 'list '}
                    <button type="button" onClick={() => updateLine(l.key, { unit_price: list })}
                      title="Click to use the list price"
                      style={{ background: 'none', border: 'none', padding: 0, cursor: 'pointer', fontFamily: 'inherit', fontSize: 'inherit', fontWeight: 700, color: over ? '#f59e0b' : TEAL }}>
                      GH₵{list.toLocaleString('en-GH', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                    </button>
                    {over && ` · selling at ${l.unit_price.toFixed(2)}`}
                  </div>
                )
              })()}

              {/* What the shop floor holds. A stocked product cannot be
                  invoiced past it — the save is refused, so say so here first. */}
              {(() => {
                const k = stockKeyOf(l)
                if (!k) return null
                const have = Math.max(0, storeByKey.get(k) ?? 0)
                const need = needByKey.get(k) ?? l.quantity
                const short = need > have
                return (
                  <div style={{ fontSize: 11, fontVariantNumeric: 'tabular-nums', color: short ? (noStockAllowed ? '#f59e0b' : '#ef4444') : 'var(--qb-muted)', fontWeight: short ? 700 : 400 }}>
                    {short
                      ? (noStockAllowed
                          ? (have === 0 ? `⚠ out of stock in ${STORE.toLowerCase()} — allowed, will go below zero` : `⚠ only ${have} in ${STORE.toLowerCase()} — allowed, will go below zero`)
                          : have === 0 ? `✕ out of stock in ${STORE.toLowerCase()} — can't be invoiced` : `✕ only ${have} in ${STORE.toLowerCase()} — can't invoice ${need}`)
                      : <>{STORE.toLowerCase()}: <span style={{ fontWeight: 700, color: TEAL }}>{have.toLocaleString()}</span></>}
                  </div>
                )
              })()}
              {(() => {
                const sold = lastSold.get(l.description.trim().toLowerCase())
                if (!sold) return null
                return (
                  <button type="button" onClick={() => updateLine(l.key, { unit_price: sold.price })}
                    title="Click to use this price"
                    style={{ alignSelf: 'flex-start', background: 'none', border: 'none', padding: 0, color: 'var(--qb-muted)', fontSize: 11, fontVariantNumeric: 'tabular-nums', cursor: 'pointer', textAlign: 'left' }}>
                    last sold <span style={{ color: TEAL, fontWeight: 700 }}>GH₵{sold.price.toLocaleString('en-GH', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</span> · {new Date(sold.issued_at).toLocaleDateString('en-GB')}
                  </button>
                )
              })()}
            </div>
            <input type="number" min={0} step="1" style={{ ...fld, padding: '6px 10px' }} value={l.quantity} onChange={e => updateLine(l.key, { quantity: +e.target.value || 0 })} />
            <input type="number" min={0} step="0.01" style={{ ...fld, padding: '6px 10px' }} value={l.unit_price} onChange={e => updateLine(l.key, { unit_price: +e.target.value || 0 })} />
            <div style={{ color: 'var(--qb-text)', fontVariantNumeric: 'tabular-nums', fontSize: 13, textAlign: 'right' }}>{(l.quantity * l.unit_price).toFixed(2)}</div>
            <button onClick={() => setLines(ls => ls.filter(x => x.key !== l.key))} style={{ background: 'none', border: 'none', color: 'var(--qb-red)', cursor: 'pointer', fontSize: 18 }} title="Remove">×</button>
          </div>
        ))}
        <div style={{ padding: 10, borderTop: '1px solid var(--qb-separator)' }}>
          <button onClick={() => setLines(ls => [...ls, newLine()])} style={{ padding: '8px 14px', borderRadius: 8, background: 'rgba(10,124,255,0.1)', border: '1px solid rgba(10,124,255,0.3)', color: TEAL, fontWeight: 700, cursor: 'pointer', fontSize: 12 }}>
            + Add line
          </button>
        </div>
      </div>
      </div>{/* end lines column */}

      {/* Delivery and credit get the whole right-hand column. */}
      <div style={wide ? { minHeight: 0, overflowY: 'auto', overscrollBehavior: 'contain' } : undefined}>
        <InvoiceDelivery value={delivery} onChange={setDelivery} customer={customer} num={num} loc={loc} total={total} accent={TEAL} fld={fld} lbl={lbl} />
        <InvoiceCredit value={credit} onChange={setCredit} total={total} method={splitMode ? splitMethod1 : payment} fld={fld} lbl={lbl} />
      </div>
      </div>{/* end body */}

      {pendingLink && (
        <ScanLinkModal
          code={pendingLink.code}
          models={stockModels}
          fld={fld}
          lbl={lbl}
          onClose={() => { setPendingLink(null); scanRef.current?.focus() }}
          onLinked={async model => {
            const code = cleanCode(pendingLink.code)
            const { error } = await linkCode(code, model)
            if (error) { flash('err', error); return }
            setCodeMap(m => new Map(m).set(code, model))
            setPendingLink(null)
            addOrBumpModel(model)
            scanRef.current?.focus()
          }}
        />
      )}

      {camera && (
        <CameraScanner
          active={!pendingLink}
          banner={scanFlash ? { tone: scanFlash.tone, title: scanFlash.text } : null}
          onDetect={handleScan}
          onClose={() => { setCamera(false); scanRef.current?.focus() }}
        />
      )}
    </div>
  )
}

// ── Unknown-barcode link modal (scan-to-add-invoice-line) ─────
function ScanLinkModal({ code, models, fld, lbl, onClose, onLinked }: {
  code: string; models: string[]; fld: React.CSSProperties; lbl: React.CSSProperties
  onClose: () => void; onLinked: (model: string) => void
}) {
  const [val, setVal] = useState('')
  const inputRef = useRef<HTMLInputElement>(null)
  useEffect(() => { inputRef.current?.focus() }, [])
  return (
    <div onClick={onClose} style={{ position: 'fixed', inset: 0, zIndex: 9998, background: 'rgba(0,0,0,0.55)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 20 }}>
      <div onClick={e => e.stopPropagation()} style={{ width: '100%', maxWidth: 440, background: 'var(--qb-input)', border: '1px solid var(--qb-input-border)', borderRadius: 16, padding: 26 }}>
        <h3 style={{ margin: '0 0 4px', fontSize: 17, fontWeight: 900, color: 'var(--qb-text)' }}>New barcode</h3>
        <p style={{ margin: '0 0 16px', color: 'var(--qb-sub)', fontSize: 13 }}>
          <span style={{ fontVariantNumeric: 'tabular-nums', color: TEAL }}>{cleanCode(code)}</span> isn&apos;t linked yet. Which product is it?
        </p>
        <form onSubmit={e => { e.preventDefault(); if (val.trim()) onLinked(val.trim()) }}>
          <label style={lbl}>Product model</label>
          <input ref={inputRef} list="invoice-scan-models" value={val} onChange={e => setVal(e.target.value)}
            placeholder="Start typing a model…" style={{ ...fld, fontVariantNumeric: 'tabular-nums' }} />
          <datalist id="invoice-scan-models">{models.map(m => <option key={m} value={m} />)}</datalist>
          <div style={{ display: 'flex', gap: 10, marginTop: 20 }}>
            <button type="button" onClick={onClose} style={{ flex: 1, padding: '11px', borderRadius: 9, border: '1px solid var(--qb-input-border)', background: 'transparent', color: 'var(--qb-sub)', fontWeight: 800, fontSize: 12, cursor: 'pointer' }}>CANCEL</button>
            <button type="submit" disabled={!val.trim()} style={{ flex: 2, padding: '11px', borderRadius: 9, border: 'none', background: val.trim() ? TEAL : 'var(--qb-input-border)', color: val.trim() ? '#ffffff' : 'var(--qb-sub)', fontWeight: 900, fontSize: 12, letterSpacing: '0.06em', cursor: val.trim() ? 'pointer' : 'not-allowed' }}>LINK & ADD</button>
          </div>
        </form>
      </div>
    </div>
  )
}


/** Text input with a filter-as-you-type popup of stock model suggestions. */
