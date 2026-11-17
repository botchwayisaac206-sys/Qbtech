'use client'

import { useEffect, useState } from 'react'

/**
 * True when the viewport is at or below `breakpoint` px wide.
 * SSR-safe (starts false, corrects on mount) and updates on resize.
 */
export function useIsMobile(breakpoint = 768) {
  const [isMobile, setIsMobile] = useState(false)
  useEffect(() => {
    const mq = window.matchMedia(`(max-width: ${breakpoint}px)`)
    const onChange = () => setIsMobile(mq.matches)
    onChange()
    mq.addEventListener('change', onChange)
    return () => mq.removeEventListener('change', onChange)
  }, [breakpoint])
  return isMobile
}
