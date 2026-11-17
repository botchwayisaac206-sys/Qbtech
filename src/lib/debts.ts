import { supabase } from '@/lib/supabase'
import { fetchAllRows } from '@/lib/adminCache'
import type { StockLine } from '@/lib/storeStock'

/**
 * Sales on credit (20261013_debtors.sql).
 *
 * A debt is one invoice a customer has not finished paying for. Payments are
 * recorded against it as they come in; what is owed is the total less those.
 *
 * The rule the Sales pages follow, and the reason this file has
 * `loadCreditLedger`: a credit sale does not count as sales when it is
 * written — each payment counts, on the day it is received. So Sales is the
 * money that has come in, and Debtors is the money that has not.
 */

export interface Debt {
  id: string
  line: StockLine
  invoice_id: string
  invoice_number: string
  customer_name: string
  customer_num: string | null
  customer_loc: string | null
  total: number
  paid: number
  settled_at: string | null
  issued_at: string
}

export interface DebtPayment {
  id: string
  debt_id: string
  amount: number
  payment_method: string
  paid_at: string
  note: string | null
}

const DEBT_COLS = 'id,line,invoice_id,invoice_number,customer_name,customer_num,customer_loc,total,paid,settled_at,issued_at'
const PAY_COLS = 'id,debt_id,amount,payment_method,paid_at,note'
const num = (d: Debt): Debt => ({ ...d, total: Number(d.total) || 0, paid: Number(d.paid) || 0 })

export const owed = (d: Debt) => Math.max(0, +(d.total - d.paid).toFixed(2))

export async function fetchDebts(line: StockLine): Promise<Debt[]> {
  const rows = await fetchAllRows<Debt>((from, to) =>
    supabase.from('debts').select(DEBT_COLS).eq('line', line).order('id', { ascending: true }).range(from, to))
  return rows.map(num).sort((a, b) => b.issued_at.localeCompare(a.issued_at))
}

export async function fetchDebtPayments(): Promise<DebtPayment[]> {
  const rows = await fetchAllRows<DebtPayment>((from, to) =>
    supabase.from('debt_payments').select(PAY_COLS).order('id', { ascending: true }).range(from, to))
  return rows.map(p => ({ ...p, amount: Number(p.amount) || 0 })).sort((a, b) => b.paid_at.localeCompare(a.paid_at))
}

/**
 * Open a debt for an invoice that has just been saved on credit, with
 * whatever the customer paid on the spot.
 */
export async function openDebt(args: {
  line: StockLine; invoiceId: string; invoiceNumber: string
  customer: string; customerNum: string; customerLoc: string
  total: number; issuedAt: string; userId: string | null
  paidNow: number; method: string
}) {
  const { data, error } = await supabase.from('debts').insert({
    line: args.line, invoice_id: args.invoiceId, invoice_number: args.invoiceNumber,
    customer_name: args.customer.trim(), customer_num: args.customerNum.trim() || null, customer_loc: args.customerLoc.trim() || null,
    total: args.total, issued_at: args.issuedAt, created_by: args.userId,
  }).select('id').single()
  if (error) throw error
  if (args.paidNow > 0) {
    await payDebt({ debtId: data.id, amount: args.paidNow, method: args.method, paidAt: args.issuedAt, note: 'Paid when the invoice was made', userId: args.userId })
  }
}

/** Record a payment. The database refuses one that would take the debt below zero. */
export async function payDebt(args: { debtId: string; amount: number; method: string; paidAt: string; note?: string; userId: string | null }) {
  const { error } = await supabase.from('debt_payments').insert({
    debt_id: args.debtId, amount: args.amount, payment_method: args.method,
    paid_at: args.paidAt, note: args.note?.trim() || null, created_by: args.userId,
  })
  if (error) throw error
  window.dispatchEvent(new CustomEvent(DEBTS_CHANGED))
}

/** Big Boss only: take back a payment entered by mistake. */
export async function removeDebtPayment(id: string) {
  const { error } = await supabase.from('debt_payments').delete().eq('id', id)
  if (error) throw error
  window.dispatchEvent(new CustomEvent(DEBTS_CHANGED))
}

/** When an invoice is deleted, its debt (and the payments on it) go too. */
export async function removeDebtForInvoice(line: StockLine, invoiceNumber: string) {
  await supabase.from('debts').delete().eq('line', line).eq('invoice_number', invoiceNumber)
}

/** Fired on window when a debt or payment is saved, so an open Debtors tab can reload. */
export const DEBTS_CHANGED = 'qbnet:debts-changed'

/** What the Sales pages need: which invoices are credit sales, and the payments that have come in. */
export interface CreditLedger {
  /** Invoice numbers sold on credit — left out of sales; their payments are counted instead. */
  numbers: Set<string>
  payments: { id: string; amount: number; payment_method: string; paid_at: string; customer_name: string; invoice_number: string }[]
  /** Still owed, across every open debt on the line. */
  outstanding: number
  debtors: number
}

export const emptyLedger = (): CreditLedger => ({ numbers: new Set(), payments: [], outstanding: 0, debtors: 0 })

/**
 * Never throws: before the migration is run, or with no signal, the Sales
 * page simply behaves as it did — no credit sales, nothing left out.
 */
export async function loadCreditLedger(line: StockLine): Promise<CreditLedger> {
  try {
    const [debts, pays] = await Promise.all([fetchDebts(line), fetchDebtPayments()])
    const byId = new Map(debts.map(d => [d.id, d]))
    const open = debts.filter(d => owed(d) > 0)
    return {
      numbers: new Set(debts.map(d => d.invoice_number)),
      payments: pays.filter(p => byId.has(p.debt_id)).map(p => {
        const d = byId.get(p.debt_id)!
        return { id: p.id, amount: p.amount, payment_method: p.payment_method, paid_at: p.paid_at, customer_name: d.customer_name, invoice_number: d.invoice_number }
      }),
      outstanding: open.reduce((s, d) => s + owed(d), 0),
      debtors: open.length,
    }
  } catch {
    return emptyLedger()
  }
}
