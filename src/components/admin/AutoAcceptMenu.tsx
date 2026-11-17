'use client'

import { useCallback, useEffect, useRef, useState } from 'react'
import { setAutoAccept, setNoStockSales, useAutoAccept, useNoStockSales } from '@/lib/stockApproval'

/**
 * The Big Boss's switches, kept off the pages and on a right-click (or
 * long-press) of the tab they belong to:
 *
 *   Transfers tab    auto-accept staff requests after 45 seconds
 *   New Invoice tab  let staff invoice what is not in stock
 *
 *   const menu = useAutoAcceptMenu(isSuperBoss, dark)
 *   <button onContextMenu={menu.open}>Transfers</button>
 *   {menu.element}
 */
function useSwitchMenu({ enabled, dark, on, flip, title, onText, offText }: {
  enabled: boolean
  dark: boolean
  on: boolean
  flip: (next: boolean) => Promise<unknown>
  title: string
  onText: string
  offText: string
}) {
  const [at, setAt] = useState<{ x: number; y: number } | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const box = useRef<HTMLDivElement>(null)

  const open = useCallback((e: React.MouseEvent) => {
    if (!enabled) return
    e.preventDefault()
    setError(null)
    // Kept on screen, whichever corner the tab is in.
    const W = 300, H = 150
    setAt({ x: Math.min(e.clientX, window.innerWidth - W - 8), y: Math.min(e.clientY, window.innerHeight - H - 8) })
  }, [enabled])

  useEffect(() => {
    if (!at) return
    const close = (e: MouseEvent | KeyboardEvent) => {
      if (e instanceof KeyboardEvent ? e.key === 'Escape' : !box.current?.contains(e.target as Node)) setAt(null)
    }
    window.addEventListener('mousedown', close)
    window.addEventListener('keydown', close)
    window.addEventListener('scroll', () => setAt(null), { once: true, capture: true })
    return () => { window.removeEventListener('mousedown', close); window.removeEventListener('keydown', close) }
  }, [at])
  useEffect(() => { if (at) box.current?.querySelector('button')?.focus() }, [at])

  const toggle = async () => {
    setBusy(true); setError(null)
    try { await flip(!on) }
    catch (e: any) { setError(e.message || 'Could not change it') }
    finally { setBusy(false) }
  }

  // Colours come from the --qb-* tokens (src/app/qb-ios.css).
  const C = { bg: 'var(--qb-card-strong)', border: 'var(--qb-border)', text: 'var(--qb-text)', sub: 'var(--qb-sub)', track: 'var(--qb-fill)' }

  const element = at && (
    <div ref={box} role="menu" aria-label={title}
      style={{ position: 'fixed', left: at.x, top: at.y, zIndex: 300, width: 300, padding: 6, borderRadius: 12,
        background: C.bg, border: `1px solid ${C.border}`, boxShadow: '0 16px 40px rgba(0,0,0,0.35)' }}>
      <button type="button" role="menuitemcheckbox" aria-checked={on} disabled={busy} onClick={toggle}
        style={{ display: 'flex', gap: 12, alignItems: 'flex-start', width: '100%', padding: '10px 10px', borderRadius: 8, border: 'none',
          background: 'transparent', color: C.text, textAlign: 'left', cursor: busy ? 'wait' : 'pointer' }}>
        <span aria-hidden style={{ flexShrink: 0, marginTop: 2, width: 34, height: 19, borderRadius: 999, background: on ? '#f59e0b' : C.track, position: 'relative', transition: 'background .15s' }}>
          <span style={{ position: 'absolute', top: 2, left: on ? 17 : 2, width: 15, height: 15, borderRadius: 999, background: '#fff', transition: 'left .15s' }} />
        </span>
        <span>
          <span style={{ display: 'block', fontWeight: 800, fontSize: 13.5 }}>{title}</span>
          <span style={{ display: 'block', fontSize: 12, color: C.sub, marginTop: 3, lineHeight: 1.4 }}>{on ? onText : offText}</span>
        </span>
      </button>
      {error && <div style={{ padding: '4px 10px 8px', fontSize: 12, color: '#ef4444', fontWeight: 700 }}>{error}</div>}
    </div>
  )

  return { open: enabled ? open : undefined, element }
}

/** Transfers tab: auto-accept staff requests. */
export function useAutoAcceptMenu(enabled: boolean, dark: boolean) {
  const auto = useAutoAccept()
  const menu = useSwitchMenu({
    enabled, dark, on: auto.on, flip: next => setAutoAccept(next),
    title: `Auto-accept requests after ${auto.seconds}s`,
    onText: 'On. Staff moves go through on their own unless you reject them in time.',
    offText: 'Off. Every staff move waits until you approve it.',
  })
  return { ...menu, auto }
}

/** New Invoice tab: may staff invoice what is not in stock? */
export function useNoStockMenu(enabled: boolean, dark: boolean) {
  const on = useNoStockSales()
  return useSwitchMenu({
    enabled, dark, on, flip: next => setNoStockSales(next),
    title: 'Allow invoicing items not in stock',
    onText: 'On. Staff are warned, but can invoice an item with no stock. Its count goes below zero.',
    offText: 'Off. An item with no stock cannot be invoiced.',
  })
}
