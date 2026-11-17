'use client'

import { useCallback, useEffect, useState } from 'react'

/**
 * The site's light and dark themes (shop and admin panel alike).
 *
 * ONE source of truth: every colour is a CSS custom property defined in
 * src/app/qb-ios.css under <html data-qb-theme="light|dark">. Components use
 * the `V` strings below in their inline styles, so flipping the attribute
 * re-themes every tab at once — no component needs to be told about the mode.
 *
 * Components that still take a `dark` prop keep working; it is simply no
 * longer needed for colour.
 */

export type QbMode = 'light' | 'dark'

// v2: an earlier build saved the system setting automatically; this ignores it.
const KEY = 'qbnet.theme.v2'

/** Colour tokens as CSS-variable strings, for inline styles. */
export const V = {
  bg:          'var(--qb-bg)',
  card:        'var(--qb-card)',          // frosted panel (blur is added by CSS)
  cardStrong:  'var(--qb-card-strong)',   // more opaque glass: bars, menus
  border:      'var(--qb-border)',
  separator:   'var(--qb-separator)',
  text:        'var(--qb-text)',
  sub:         'var(--qb-sub)',
  muted:       'var(--qb-muted)',
  faint:       'var(--qb-faint)',
  fill:        'var(--qb-fill)',
  input:       'var(--qb-input)',
  inputBorder: 'var(--qb-input-border)',
  header:      'var(--qb-header)',
  rowHover:    'var(--qb-row-hover)',
  tag:         'var(--qb-tag)',
  accent:      'var(--qb-accent)',
  onAccent:    'var(--qb-on-accent)',
  red:         'var(--qb-red)',
  orange:      'var(--qb-orange)',
  green:       'var(--qb-green)',
  amber:       'var(--qb-amber)',
  accentSoft:  'var(--qb-accent-soft)',
  greenSoft:   'var(--qb-green-soft)',
  redSoft:     'var(--qb-red-soft)',
  amberSoft:   'var(--qb-amber-soft)',
  shadow:      'var(--qb-shadow)',
} as const

/** Brand blue as a hex, for places that append an alpha suffix (`${ACCENT}22`). */
export const ACCENT = '#0a7cff'

function initialMode(): QbMode {
  // Already applied before first paint by the boot script in app/layout.tsx.
  const applied = typeof document !== 'undefined' ? document.documentElement.getAttribute('data-qb-theme') : null
  if (applied === 'light' || applied === 'dark') return applied
  try {
    const saved = localStorage.getItem(KEY)
    if (saved === 'light' || saved === 'dark') return saved
  } catch {}
  // Light unless dark was chosen with the switch.
  return 'light'
}

/**
 * Reads and changes the theme: the saved choice, or light by default,
 * applied to <html> and remembered per browser.
 */
export function useQbTheme() {
  const [mode, setMode] = useState<QbMode>('light')
  const [ready, setReady] = useState(false)

  useEffect(() => { setMode(initialMode()); setReady(true) }, [])

  useEffect(() => {
    if (!ready) return
    const el = document.documentElement
    el.setAttribute('data-qb-theme', mode)
    el.style.colorScheme = mode
  }, [mode, ready])

  const toggle = useCallback(() => setMode(m => {
    const next: QbMode = m === 'dark' ? 'light' : 'dark'
    try { localStorage.setItem(KEY, next) } catch {}
    return next
  }), [])
  return { mode, dark: mode === 'dark', toggle, setMode }
}

/**
 * For the few places that need a real colour value rather than a CSS variable
 * (chart libraries that write SVG attributes). Follows the attribute on <html>.
 */
export function useQbDark(): boolean {
  const [dark, setDark] = useState(false)
  useEffect(() => {
    const el = document.documentElement
    const read = () => setDark(el.getAttribute('data-qb-theme') === 'dark')
    read()
    const obs = new MutationObserver(read)
    obs.observe(el, { attributes: true, attributeFilter: ['data-qb-theme'] })
    return () => obs.disconnect()
  }, [])
  return dark
}
