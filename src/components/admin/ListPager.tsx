'use client'

import { useEffect, useState } from 'react'

/** How many invoices a list shows at once. */
export const PAGE_SIZE = 25

/**
 * Pages a list so it never grows into an endless scroll. Goes back to the
 * first page whenever `resetKey` changes (a new search or date range).
 */
export function usePaged<T>(items: T[], resetKey: unknown, size = PAGE_SIZE) {
  const [page, setPage] = useState(0)
  useEffect(() => { setPage(0) }, [resetKey])
  const pages = Math.max(1, Math.ceil(items.length / size))
  const current = Math.min(page, pages - 1)
  return {
    shown: items.slice(current * size, current * size + size),
    page: current, pages, total: items.length, size, setPage,
  }
}

export default function ListPager({ page, pages, total, size, setPage, accent, border }: {
  page: number; pages: number; total: number; size: number
  setPage: (p: number) => void
  accent: string; border: string
}) {
  if (total <= size) return null
  const from = page * size + 1
  const to = Math.min(total, from + size - 1)
  const btn = (label: string, target: number, disabled: boolean) => (
    <button type="button" disabled={disabled} onClick={() => setPage(target)} style={{
      padding: '6px 12px', borderRadius: 8, border: `1px solid ${border}`, background: 'transparent',
      color: disabled ? 'var(--qb-faint)' : accent, fontWeight: 800, fontSize: 12,
      cursor: disabled ? 'not-allowed' : 'pointer',
    }}>{label}</button>
  )
  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10, flexWrap: 'wrap', padding: '10px 14px', borderTop: `1px solid ${border}` }}>
      <span style={{ color: 'var(--qb-muted)', fontSize: 12, fontVariantNumeric: 'tabular-nums' }}>
        {from}–{to} of {total.toLocaleString()}
      </span>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
        {btn('« First', 0, page === 0)}
        {btn('‹ Prev', page - 1, page === 0)}
        <span style={{ color: 'var(--qb-text)', fontSize: 12, fontVariantNumeric: 'tabular-nums', padding: '0 6px' }}>page {page + 1} / {pages}</span>
        {btn('Next ›', page + 1, page >= pages - 1)}
        {btn('Last »', pages - 1, page >= pages - 1)}
      </div>
    </div>
  )
}
