'use client'

import type { ReactNode } from 'react'

/**
 * Wraps a tab's contents and makes everything inside non-interactive when
 * `active` is true.
 *
 * A native `<fieldset disabled>` is what actually does the work: the browser
 * disables every form control it contains, at any depth, with no per-component
 * changes. That matters here because it lets read-only mode cover components we
 * don't want to edit (StockTab is a locked reference implementation) and any
 * tab added later, for free.
 *
 * `pointer-events: none` on the inner layer catches the rest — this codebase
 * uses div/span onClick handlers for toggles and row actions, which a disabled
 * fieldset does not reach.
 *
 * This is presentation only. Row-level security is the real boundary; see
 * supabase/migrations/20260807_superboss.sql.
 */
export default function ReadOnlyGuard({ active, children }: { active: boolean; children: ReactNode }) {
  if (!active) return <>{children}</>
  return (
    <fieldset
      disabled
      // A fieldset carries default border/padding/margin and a min-width that
      // breaks flex and grid children — strip all of it so layout is identical.
      style={{ border: 0, margin: 0, padding: 0, minInlineSize: 0, display: 'block' }}
    >
      <div style={{ pointerEvents: 'none' }}>{children}</div>
    </fieldset>
  )
}
