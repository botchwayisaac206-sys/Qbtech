'use client'

import { useEffect, useRef, useState } from 'react'

interface Props {
  value: string   // e.g. "20+", "1000+", "8", "24/7"
  label: string
  delay?: number
}

function parseNumeric(val: string): { num: number; suffix: string } {
  const match = val.match(/^(\d+)(.*)$/)
  if (!match) return { num: 0, suffix: val }
  return { num: parseInt(match[1], 10), suffix: match[2] }
}

/** A figure that counts up once when it scrolls into view. */
export default function CountUpStat({ value, label, delay = 0 }: Props) {
  const ref = useRef<HTMLDivElement>(null)
  const [count, setCount] = useState(0)
  const [visible, setVisible] = useState(false)
  const { num, suffix } = parseNumeric(value)
  const isStatic = num === 0 // "24/7" and the like

  useEffect(() => {
    const el = ref.current
    if (!el) return
    const observer = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) { setVisible(true); observer.disconnect() }
    }, { threshold: 0.3 })
    observer.observe(el)
    return () => observer.disconnect()
  }, [])

  useEffect(() => {
    if (!visible || isStatic) return
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) { setCount(num); return }
    const steps = 45
    let step = 0
    let interval: ReturnType<typeof setInterval> | undefined
    const start = setTimeout(() => {
      interval = setInterval(() => {
        step += 1
        setCount(Math.round((num * step) / steps))
        if (step >= steps && interval) clearInterval(interval)
      }, 1100 / steps)
    }, delay)
    return () => { clearTimeout(start); if (interval) clearInterval(interval) }
  }, [visible, num, delay, isStatic])

  return (
    <div ref={ref}>
      <div className="text-[2.5rem] font-bold leading-none tracking-tight text-qb-text" style={{ fontVariantNumeric: 'tabular-nums' }}>
        {isStatic ? value : `${visible ? count : 0}${suffix}`}
      </div>
      <div className="mt-2 text-[15px] text-qb-sub">{label}</div>
    </div>
  )
}
