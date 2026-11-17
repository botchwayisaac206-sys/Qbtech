'use client'

import { useEffect, useRef, useState } from 'react'

/**
 * Sizes a block to fill the window from where it starts down to the bottom
 * edge, so a screen like the invoice form fits without the page scrolling —
 * only its own inner panels (the item lines) scroll.
 *
 * Returns height null on narrow screens (phones, small tablets): there the
 * block flows normally and the page scrolls, because squeezing a whole
 * invoice into a phone's height would leave nothing usable.
 *
 * Measured against the page's top, not the viewport's, so it gives the same
 * answer whether or not the page happens to be scrolled. Re-measured when the
 * block is shown again (drafts and tabs are hidden with display:none, which
 * gives no size to measure), and on every window resize.
 */
export function useFitHeight({ minWidth = 900, gap = 4, minHeight = 400 } = {}) {
  const ref = useRef<HTMLDivElement>(null)
  const [height, setHeight] = useState<number | null>(null)

  useEffect(() => {
    const el = ref.current
    if (!el) return
    const measure = () => {
      if (window.innerWidth < minWidth) { setHeight(null); return }
      // Hidden right now — keep the last figure, measure again when shown.
      if (el.offsetParent === null) return
      const top = el.getBoundingClientRect().top + window.scrollY
      const h = Math.max(minHeight, Math.floor(window.innerHeight - top - trailing(el) - gap))
      setHeight(prev => (prev === h ? prev : h))
    }
    measure()
    const ro = new ResizeObserver(measure)
    ro.observe(el)
    // Its parent changes size when a hidden tab is shown or a banner above
    // appears, which can move where this block starts.
    if (el.parentElement) ro.observe(el.parentElement)
    // And the block around that: a toolbar above (the drafts row) that wraps
    // onto a second line pushes this block down without resizing its parent.
    if (el.parentElement?.parentElement) ro.observe(el.parentElement.parentElement)
    window.addEventListener('resize', measure)
    return () => { ro.disconnect(); window.removeEventListener('resize', measure) }
  }, [minWidth, gap, minHeight])

  return { ref, height }
}

/**
 * Everything the page lays out after the block: its containers' bottom
 * padding, borders and margins, and whatever follows it in each of them.
 * Without this the block fits but the page still scrolls by that much.
 * Worked out from the ancestors rather than from the page's total height,
 * which includes min-height filler that changes as the block does.
 */
function trailing(el: HTMLElement): number {
  let sum = 0
  let node: HTMLElement | null = el
  while (node && node !== document.body) {
    const parent: HTMLElement | null = node.parentElement
    if (!parent) break
    const ps = getComputedStyle(parent)
    // In a row or a grid, what follows sits beside the block, not under it.
    const stacked = ps.display === 'block' || ps.display === 'flow-root'
      || (ps.display.includes('flex') && ps.flexDirection.startsWith('column'))
    if (stacked) {
      sum += parseFloat(getComputedStyle(node).marginBottom) || 0
      for (let s = node.nextElementSibling as HTMLElement | null; s; s = s.nextElementSibling as HTMLElement | null) {
        const ss = getComputedStyle(s)
        if (ss.position === 'fixed' || ss.position === 'absolute' || ss.display === 'none') continue
        sum += s.offsetHeight + (parseFloat(ss.marginTop) || 0) + (parseFloat(ss.marginBottom) || 0)
      }
      if (ps.display.includes('flex')) sum += parseFloat(ps.rowGap) || 0
    }
    if (parent !== document.body) {
      sum += (parseFloat(ps.paddingBottom) || 0) + (parseFloat(ps.borderBottomWidth) || 0)
    }
    node = parent
  }
  return sum
}
