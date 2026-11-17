'use client'

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'

/**
 * A model field that drops open on click and filters as you type.
 *
 * Used by the invoice form (listing what STORE STOCK holds) and the transfer
 * form (listing what the source warehouse holds). Both want the same thing:
 * see everything in that location without typing, with the on-hand figure
 * next to each model, and still be able to type something that isn't on the
 * list.
 *
 * Options carry an optional `group`, which renders as a sticky heading. That
 * is what lets the invoice form put the shop floor first and the rest of the
 * tracked models underneath, instead of hiding models the store has not been
 * stocked with yet.
 *
 * THE LIST IS DRAWN ON TOP OF THE PAGE, NOT INSIDE IT
 *   It used to hang below the field inside whatever box held it. The invoice
 *   lines sit in a box that clips its contents, so the list was cut off at
 *   the box's edge — and with STORE STOCK listing every product, most of it
 *   could not be reached. It is now placed over the page beside the field,
 *   opening upwards when there is more room above, and as tall as the screen
 *   allows.
 */

export interface PickerOption {
  model: string
  /** On-hand at the location, shown on the right. Omitted renders nothing. */
  qty?: number
  /** Heading this option sits under. Options are shown in the order given. */
  group?: string
}

export interface PickerTheme {
  menuBg: string
  border: string
  text: string
  sub: string
  accent: string
  /** Text colour on the highlighted row. */
  accentText: string
}

/**
 * How many rows to draw at once. STORE STOCK lists every product the shop
 * carries — over a thousand — and the whole list has to be scrollable, not
 * just its first screenful. Typing narrows it.
 */
const MAX_ROWS = 2500

export default function ModelPicker({
  value, options, onChange, theme, inputStyle, placeholder, emptyHint, onEnterUnmatched, touch = false,
}: {
  /**
   * Rows sized for a thumb, and a taller list — the phone stock app. The
   * desk forms keep the compact rows, where a mouse makes them easy to hit.
   */
  touch?: boolean
  value: string
  options: PickerOption[]
  onChange: (v: string) => void
  theme: PickerTheme
  inputStyle?: React.CSSProperties
  placeholder?: string
  /** Shown when nothing matches. Typing something off-list stays allowed. */
  emptyHint?: string
  /** Enter with no highlighted match — lets a parent submit or add a line. */
  onEnterUnmatched?: () => void
}) {
  const [open, setOpen] = useState(false)
  const [highlight, setHighlight] = useState(0)
  const wrapRef = useRef<HTMLDivElement | null>(null)
  const listRef = useRef<HTMLDivElement | null>(null)
  const inputRef = useRef<HTMLInputElement | null>(null)
  // Where the list sits on screen, worked out from the field each time it opens or the page moves.
  const [place, setPlace] = useState<{ left: number; width: number; top?: number; bottom?: number; maxHeight: number } | null>(null)

  useEffect(() => {
    function onDocClick(e: MouseEvent) {
      const t = e.target as Node
      // The list is drawn outside the field's box, so a click in it is not a click away.
      if (wrapRef.current?.contains(t) || listRef.current?.contains(t)) return
      setOpen(false)
    }
    document.addEventListener('mousedown', onDocClick)
    return () => document.removeEventListener('mousedown', onDocClick)
  }, [])

  const measure = useCallback(() => {
    const el = inputRef.current
    if (!el) return
    const r = el.getBoundingClientRect()
    const vh = window.innerHeight
    const want = touch ? Math.min(vh * 0.4, 340) : Math.min(vh * 0.55, 420)
    const below = vh - r.bottom - 10
    const above = r.top - 10
    // Below unless it would be cramped there and there is more room above.
    if (below < Math.min(want, 220) && above > below) {
      setPlace({ left: r.left, width: r.width, bottom: vh - r.top + 2, maxHeight: Math.max(120, Math.min(want, above)) })
    } else {
      setPlace({ left: r.left, width: r.width, top: r.bottom + 2, maxHeight: Math.max(120, Math.min(want, below)) })
    }
  }, [touch])

  useLayoutEffect(() => {
    if (!open) return
    measure()
    // Follow the field when the page or any box around it scrolls, or the window changes size.
    window.addEventListener('scroll', measure, true)
    window.addEventListener('resize', measure)
    return () => { window.removeEventListener('scroll', measure, true); window.removeEventListener('resize', measure) }
  }, [open, measure])

  const q = value.trim().toLowerCase()
  const matches = useMemo(() => {
    const hits = q ? options.filter(o => o.model.toLowerCase().includes(q)) : options
    return hits.slice(0, MAX_ROWS)
  }, [q, options])
  const hiddenCount = useMemo(() => {
    const total = q ? options.filter(o => o.model.toLowerCase().includes(q)).length : options.length
    return Math.max(0, total - matches.length)
  }, [q, options, matches.length])

  // A filter that shortens the list must not leave the highlight past its end.
  useEffect(() => { setHighlight(h => Math.min(h, Math.max(0, matches.length - 1))) }, [matches.length])

  // Keep the highlighted row in view when arrowing through a long list.
  useEffect(() => {
    if (!open || !listRef.current) return
    const row = listRef.current.querySelector<HTMLElement>(`[data-row="${highlight}"]`)
    row?.scrollIntoView({ block: 'nearest' })
  }, [highlight, open])

  const pick = (m: string) => { onChange(m); setOpen(false) }

  const menu: React.CSSProperties = {
    position: 'fixed', zIndex: 10000,
    left: place?.left ?? 0, width: place?.width ?? 0, top: place?.top, bottom: place?.bottom,
    background: theme.menuBg, border: `1px solid ${theme.border}`, borderRadius: 8,
    maxHeight: place?.maxHeight ?? 260, overflowY: 'auto', overscrollBehavior: 'contain',
    boxShadow: touch ? '0 10px 28px rgba(0,0,0,0.18)' : '0 8px 24px rgba(0,0,0,0.4)',
  }
  // Drawn over the page, so no box the field sits in can clip it.
  const float = (node: React.ReactNode) =>
    open && place && typeof document !== 'undefined' ? createPortal(node, document.body) : null

  let lastGroup: string | undefined

  return (
    <div ref={wrapRef} style={{ position: 'relative' }}>
      <input
        ref={inputRef}
        style={inputStyle}
        value={value}
        onChange={e => { onChange(e.target.value); setOpen(true); setHighlight(0) }}
        onFocus={() => setOpen(true)}
        // A click on an already-focused field should reopen a menu the user
        // dismissed with Escape, rather than doing nothing.
        onClick={() => setOpen(true)}
        autoComplete="off"
        placeholder={placeholder}
        onKeyDown={e => {
          if (e.key === 'Escape') { setOpen(false); return }
          if (e.key === 'ArrowDown') {
            e.preventDefault()
            if (!open) { setOpen(true); return }
            setHighlight(h => Math.min(h + 1, matches.length - 1))
          } else if (e.key === 'ArrowUp') {
            e.preventDefault()
            setHighlight(h => Math.max(h - 1, 0))
          } else if (e.key === 'Enter') {
            if (open && matches[highlight]) { e.preventDefault(); pick(matches[highlight].model) }
            else if (onEnterUnmatched) { e.preventDefault(); setOpen(false); onEnterUnmatched() }
          }
        }}
      />

      {matches.length > 0 && float(
        <div ref={listRef} style={menu}>
          {matches.map((o, i) => {
            const heading = o.group && o.group !== lastGroup ? o.group : null
            lastGroup = o.group
            const on = i === highlight
            return (
              <div key={`${o.group ?? ''}-${o.model}`}>
                {heading && (
                  <div style={{
                    position: 'sticky', top: 0, zIndex: 1,
                    padding: '6px 10px', fontSize: 9.5, fontWeight: 800, letterSpacing: '0.14em',
                    color: theme.sub, background: theme.menuBg, borderBottom: `1px solid ${theme.border}`,
                  }}>{heading.toUpperCase()}</div>
                )}
                <div
                  data-row={i}
                  onMouseDown={e => { e.preventDefault(); pick(o.model) }}
                  onMouseEnter={() => setHighlight(i)}
                  style={{
                    display: 'flex', alignItems: 'center', gap: 10, justifyContent: 'space-between',
                    padding: touch ? '13px 12px' : '7px 10px', fontSize: touch ? 15 : 12,
                    cursor: 'pointer', fontVariantNumeric: 'tabular-nums',
                    borderBottom: touch ? `1px solid ${theme.border}` : undefined,
                    color: on ? theme.accentText : theme.text,
                    background: on ? theme.accent : 'transparent',
                  }}>
                  <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{o.model}</span>
                  {o.qty !== undefined && (
                    <span style={{
                      flexShrink: 0, fontWeight: 800,
                      color: on ? theme.accentText : o.qty <= 0 ? '#f87171' : theme.accent,
                    }}>{o.qty.toLocaleString()}</span>
                  )}
                </div>
              </div>
            )
          })}
          {hiddenCount > 0 && (
            <div style={{ padding: '7px 10px', fontSize: 11, color: theme.sub, fontVariantNumeric: 'tabular-nums' }}>
              +{hiddenCount.toLocaleString()} more — keep typing to narrow
            </div>
          )}
        </div>
      )}

      {matches.length === 0 && emptyHint && float(
        <div ref={listRef} style={{ ...menu, padding: '8px 10px', fontSize: touch ? 13 : 11, color: theme.sub, fontVariantNumeric: 'tabular-nums' }}>
          {emptyHint}
        </div>
      )}
    </div>
  )
}
