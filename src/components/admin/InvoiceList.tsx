'use client'

import { useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { removeDebtForInvoice } from '@/lib/debts'
import { downloadInvoicePdf } from '@/lib/invoicePdf'
import { GHS, useRole } from '@/lib/sales'
import { cached, fetchAllRows, fetchStaffNames, peek } from '@/lib/adminCache'
import ListPager, { usePaged } from '@/components/admin/ListPager'

const TEAL = '#0a7cff'

interface Row {
  id: string
  invoice_number: string
  customer_name: string
  customer_loc: string | null
  customer_num: string | null
  order_no: string | null
  payment_method: string | null
  subtotal: number
  vat_rate: number
  vat_amount: number
  total: number
  issued_at: string
  created_by: string | null
}

const INVOICE_LIST_KEY = 'invoices_list_rows'
const fetchInvoiceRows = () => cached<Row[]>(INVOICE_LIST_KEY, async () => {
  const rows = await fetchAllRows<Row>((from, to) =>
    supabase.from('invoices')
      .select('id,invoice_number,customer_name,customer_loc,customer_num,order_no,payment_method,subtotal,vat_rate,vat_amount,total,issued_at,created_by')
      .order('id', { ascending: true })
      .range(from, to))
  return rows.sort((a, b) => +new Date(b.issued_at) - +new Date(a.issued_at))
})

export default function InvoiceList() {
  const { isBoss, canSeeInvoices, loading: roleLoading } = useRole()
  const warmRows   = peek<Row[]>(INVOICE_LIST_KEY)
  const warmStaff  = peek<Record<string, string>>('staff_names')
  const [rows, setRows]         = useState<Row[]>(warmRows || [])
  const [staffMap, setStaffMap] = useState<Record<string, string>>(warmStaff || {})
  const [search, setSearch]     = useState('')
  const [loading, setLoading]   = useState(warmRows === undefined)
  const [deletingId, setDeletingId] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    // Roles below superboss have no invoice archive. Skip the fetch entirely so
    // the 24h rows RLS would still return never reach this list.
    if (roleLoading) return
    if (!canSeeInvoices) { setRows([]); setLoading(false); return }
    ;(async () => {
      try {
        const [invRows, names] = await Promise.all([
          fetchInvoiceRows(),
          fetchStaffNames(),
        ])
        if (cancelled) return
        setRows(invRows)
        setStaffMap(names)
      } catch (err) {
        if (!cancelled) console.warn('InvoiceList load failed:', err)
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()
    return () => { cancelled = true }
  }, [roleLoading, canSeeInvoices])

  const filtered = rows.filter(r =>
    `${r.invoice_number} ${r.customer_name}`.toLowerCase().includes(search.toLowerCase()))
  // A page at a time, so the list never becomes an endless scroll.
  const pager = usePaged(filtered, search)
  const shown = pager.shown

  async function reprint(r: Row) {
    const { data: items } = await supabase.from('invoice_items')
      .select('description,quantity,unit_price,line_total')
      .eq('invoice_id', r.id).order('position', { ascending: true })
    downloadInvoicePdf({
      invoice_number: r.invoice_number,
      issued_at: r.issued_at,
      customer_name: r.customer_name,
      customer_loc: r.customer_loc || undefined,
      customer_num: r.customer_num || undefined,
      order_no: r.order_no || undefined,
      payment_method: r.payment_method || 'Cash',
      items: (items || []).map(i => ({
        description: i.description, quantity: Number(i.quantity),
        unit_price: Number(i.unit_price), line_total: Number(i.line_total),
      })),
      subtotal: Number(r.subtotal), vat_rate: Number(r.vat_rate),
      vat_amount: Number(r.vat_amount), total: Number(r.total),
      staff_name: r.created_by ? (staffMap[r.created_by] || undefined) : undefined,
    })
  }

  async function remove(r: Row) {
    if (!confirm(`Delete invoice ${r.invoice_number} for ${r.customer_name}?\n\nWhat it took from ${'STORE STOCK'} goes back.`)) return
    setDeletingId(r.id)
    try {
      // Gives back what the invoice took from STORE STOCK and deletes it, in
      // one step (20261024_stock_accuracy.sql). Deleting the row alone left
      // the store short by every unit on it.
      const { error: rpcErr } = await supabase.rpc('delete_invoice_restoring_stock', { p_line: 'main', p_invoice_id: r.id })
      if (rpcErr) {
        if (rpcErr.code !== 'PGRST202' && !/could not find the function/i.test(rpcErr.message)) throw rpcErr
        // Not set up yet: delete as before.
        const { error } = await supabase.from('invoices').delete().eq('id', r.id)
        if (error) throw error
      }
      // If the sale was a delivery, its delivery row goes too — or the
      // Sales page would keep counting a sale that no longer exists.
      await supabase.from('deliveries').delete().eq('invoice_number', r.invoice_number)
      await removeDebtForInvoice('main', r.invoice_number)
      setRows(rs => rs.filter(x => x.id !== r.id))
    } catch (e:any) {
      alert('Delete failed: ' + (e.message || 'unknown error'))
    } finally {
      setDeletingId(null)
    }
  }

  if (loading) return <div style={{ padding: 48, textAlign: 'center', color: 'var(--qb-muted)' }}>Loading invoices…</div>

  return (
    <div>
      <input value={search} onChange={e => setSearch(e.target.value)} placeholder="Search invoice # or customer…"
             style={{ width: '100%', maxWidth: 420, padding: '10px 14px', borderRadius: 10, border: '1px solid var(--qb-input-border)', background: 'var(--qb-input)', color: 'var(--qb-text)', marginBottom: 14 }} />
      <div style={{ border: '1px solid var(--qb-border)', borderRadius: 12, overflow: 'hidden' }}>
        <div style={{ display: 'grid', gridTemplateColumns: isBoss ? '140px 1fr 120px 130px 140px 110px 200px' : '140px 1fr 120px 140px 120px 110px', padding: '10px 14px', background: 'var(--qb-header)', color: TEAL, fontSize: 10, fontWeight: 800, letterSpacing: '0.15em' }}>
          <div>INVOICE #</div>
          <div>CUSTOMER</div>
          <div>DATE</div>
          {isBoss && <div>CREATED BY</div>}
          <div>TOTAL</div>
          <div>METHOD</div>
          <div></div>
        </div>
        {shown.map(r => (
          <div key={r.id} style={{ display: 'grid', gridTemplateColumns: isBoss ? '140px 1fr 120px 130px 140px 110px 200px' : '140px 1fr 120px 140px 120px 110px', padding: '10px 14px', borderTop: '1px solid var(--qb-separator)', alignItems: 'center', color: 'var(--qb-text)', fontSize: 13 }}>
            <div style={{ fontVariantNumeric: 'tabular-nums', color: TEAL }}>{r.invoice_number}</div>
            <div style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{r.customer_name}</div>
            <div style={{ fontVariantNumeric: 'tabular-nums', color: 'var(--qb-sub)', fontSize: 12 }}>{new Date(r.issued_at).toLocaleDateString()}</div>
            {isBoss && (
              <div style={{ fontSize: 12, color: 'var(--qb-text)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {r.created_by ? (staffMap[r.created_by] || '—') : <span style={{ color: 'var(--qb-faint)' }}>—</span>}
              </div>
            )}
            <div style={{ fontVariantNumeric: 'tabular-nums', fontWeight: 700 }}>{GHS(r.total)}</div>
            <div style={{ fontSize: 12, color: 'var(--qb-sub)' }}>{r.payment_method}</div>
            <div style={{ display: 'flex', gap: 6 }}>
              <button onClick={() => reprint(r)} disabled={deletingId === r.id} style={{ padding: '6px 12px', borderRadius: 8, background: 'rgba(10,124,255,0.1)', border: '1px solid rgba(10,124,255,0.3)', color: TEAL, fontWeight: 700, cursor: deletingId === r.id ? 'not-allowed' : 'pointer', fontSize: 11 }}>
                REPRINT
              </button>
              {isBoss && (
                <button onClick={() => remove(r)} disabled={deletingId === r.id} style={{ padding: '6px 12px', borderRadius: 8, background: deletingId === r.id ? 'rgba(239,68,68,0.2)' : 'rgba(239,68,68,0.1)', border: '1px solid rgba(239,68,68,0.3)', color: '#ef4444', fontWeight: 700, cursor: deletingId === r.id ? 'wait' : 'pointer', fontSize: 11 }}>
                  {deletingId === r.id ? '…' : 'DELETE'}
                </button>
              )}
            </div>
          </div>
        ))}
        {filtered.length === 0 && (
          <div style={{ padding: 40, textAlign: 'center', color: 'var(--qb-muted)' }}>
            {canSeeInvoices ? 'No invoices yet.' : 'No invoices to display.'}
          </div>
        )}
        <ListPager {...pager} accent={TEAL} border="var(--qb-border)" />
      </div>
    </div>
  )
}
