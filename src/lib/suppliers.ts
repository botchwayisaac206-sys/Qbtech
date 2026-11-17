import { supabase } from '@/lib/supabase'

/**
 * Suppliers, what we owe them, and what our stock cost
 * (20261117_suppliers_and_costs.sql). Bosses read; only the Big Boss writes,
 * and every write goes through a database function.
 */

export type DocKind = 'received' | 'payment' | 'returned'

export interface SupplierBalance {
  id: string
  name: string
  phone: string | null
  note: string | null
  received: number
  returned: number
  paid: number
  /** received − returned − paid. Above 0 means we owe them. */
  balance: number
  last_activity: string | null
}

export interface DocItem { model: string; quantity: number; unit_cost: number; position: number }

export interface SupplierDoc {
  id: string
  number: string
  kind: DocKind
  supplier_id: string
  doc_date: string
  location: string | null
  ref: string | null
  amount: number
  stock_booked: boolean
  transfer_number: string | null
  note: string | null
  signed_by: string | null
  voided_at: string | null
  void_reason: string | null
  items: DocItem[]
}

export interface ProductCost { model_key: string; model: string; unit_cost: number; source: string | null; updated_at: string }

export interface ItemInput { model: string; quantity: number; unit_cost?: number }

const num = (v: unknown) => Number(v) || 0

export async function fetchSupplierBalances(): Promise<SupplierBalance[]> {
  const { data, error } = await supabase.from('supplier_balances').select('*').order('name')
  if (error) throw error
  return (data || []).map(r => ({ ...r, received: num(r.received), returned: num(r.returned), paid: num(r.paid), balance: num(r.balance) })) as SupplierBalance[]
}

/** Every document, newest first, with its lines. */
export async function fetchSupplierDocs(supplierId?: string): Promise<SupplierDoc[]> {
  let q = supabase.from('supplier_docs')
    .select('*, items:supplier_doc_items(model,quantity,unit_cost,position)')
    .order('doc_date', { ascending: false }).order('created_at', { ascending: false })
    .limit(500)
  if (supplierId) q = q.eq('supplier_id', supplierId)
  const { data, error } = await q
  if (error) throw error
  return (data || []).map(d => ({
    ...d,
    amount: num(d.amount),
    items: ((d.items || []) as DocItem[])
      .map(i => ({ ...i, quantity: num(i.quantity), unit_cost: num(i.unit_cost) }))
      .sort((a, b) => a.position - b.position),
  })) as SupplierDoc[]
}

export async function fetchProductCosts(): Promise<ProductCost[]> {
  const out: ProductCost[] = []
  for (let from = 0; ; from += 1000) {
    const { data, error } = await supabase.from('product_costs').select('*').order('model').range(from, from + 999)
    if (error) throw error
    out.push(...(data || []).map(r => ({ ...r, unit_cost: num(r.unit_cost) })) as ProductCost[])
    if (!data || data.length < 1000) break
  }
  return out
}

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args)
  if (error) throw new Error(error.message)
  return data as T
}

export const saveSupplier = (id: string | null, name: string, phone?: string, note?: string) =>
  rpc('supplier_save', { p_id: id, p_name: name, p_phone: phone || null, p_note: note || null })

export const receiveFromSupplier = (a: {
  supplierId: string; items: ItemInput[]; date: string; to: string; bookStock: boolean; ref?: string; note?: string
}) => rpc<SupplierDoc>('supplier_receive', {
  p_supplier: a.supplierId, p_items: a.items, p_date: a.date, p_to: a.to,
  p_book_stock: a.bookStock, p_ref: a.ref || null, p_note: a.note || null,
})

export const paySupplier = (a: { supplierId: string; amount: number; date: string; ref?: string; note?: string }) =>
  rpc<SupplierDoc>('supplier_payment', {
    p_supplier: a.supplierId, p_amount: a.amount, p_date: a.date, p_ref: a.ref || null, p_note: a.note || null,
  })

export const returnToSupplier = (a: { supplierId: string; items: ItemInput[]; from: string; date: string; ref?: string; note?: string }) =>
  rpc<SupplierDoc>('supplier_return', {
    p_supplier: a.supplierId, p_items: a.items, p_from: a.from, p_date: a.date, p_ref: a.ref || null, p_note: a.note || null,
  })

export const voidSupplierDoc = (id: string, reason?: string) =>
  rpc<SupplierDoc>('supplier_void', { p_doc: id, p_reason: reason || null })

export const setProductCost = (model: string, cost: number) =>
  rpc<ProductCost>('set_product_cost', { p_model: model, p_cost: cost })

export const KIND_LABEL: Record<DocKind, string> = { received: 'Goods received', payment: 'Payment', returned: 'Returned' }
