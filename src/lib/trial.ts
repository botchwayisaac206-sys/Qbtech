'use client'

import { useEffect, useState } from 'react'

/**
 * The 14-day trial.
 *
 * The back office and the phone stock app count down from TRIAL_START and
 * lock when TRIAL_DAYS have passed. Once the company has paid, set
 * NEXT_PUBLIC_LICENSE_PAID=1 in the hosting environment and redeploy: the
 * countdown disappears and nothing locks.
 *
 * NEXT_PUBLIC_TRIAL_START (YYYY-MM-DD) moves the start without a code change,
 * e.g. to extend the trial.
 *
 * Time comes from the server's Date header, not only the device clock, so
 * winding a computer's clock back does not reopen an expired trial. The
 * latest time ever seen is also kept in the browser for the same reason.
 */
export const TRIAL_DAYS = 14
const DEFAULT_START = '2026-11-19'

const DAY = 24 * 60 * 60 * 1000
const SEEN_KEY = 'qbnet.trialSeen'

export const LICENSE_PAID = process.env.NEXT_PUBLIC_LICENSE_PAID === '1'

/** Midnight (local) at the start of the first trial day. */
export function trialStart(): Date {
  const raw = (process.env.NEXT_PUBLIC_TRIAL_START || DEFAULT_START).trim()
  const [y, m, d] = raw.split('-').map(Number)
  if (!y || !m || !d) {
    const [dy, dm, dd] = DEFAULT_START.split('-').map(Number)
    return new Date(dy, dm - 1, dd)
  }
  return new Date(y, m - 1, d)
}

/** The moment the app locks: midnight after the last trial day. */
export function trialEnd(): Date {
  return new Date(trialStart().getTime() + TRIAL_DAYS * DAY)
}

function readSeen(): number {
  try { return Number(localStorage.getItem(SEEN_KEY)) || 0 } catch { return 0 }
}
function writeSeen(t: number) {
  try { if (t > readSeen()) localStorage.setItem(SEEN_KEY, String(t)) } catch { /* private mode */ }
}

/** Server time from the Date header of a tiny uncached request; null offline. */
async function serverNow(): Promise<number | null> {
  try {
    const res = await fetch(`/robots.txt?t=${Date.now()}`, { method: 'HEAD', cache: 'no-store' })
    const d = res.headers.get('date')
    const t = d ? Date.parse(d) : NaN
    return Number.isFinite(t) ? t : null
  } catch { return null }
}

export interface TrialState {
  paid: boolean
  expired: boolean
  /** Milliseconds until the lock; 0 once expired. */
  msLeft: number
  /** Which trial day today is, 1..14. */
  day: number
  end: Date
}

/**
 * Live trial state, re-checked every second for the countdown. `ready` is
 * false until the server's clock has been asked, so the lock never flashes
 * up (or fails to) on a wrong device clock.
 */
export function useTrial(): TrialState & { ready: boolean } {
  const end = trialEnd()
  const [offset, setOffset] = useState(0)
  const [ready, setReady] = useState(LICENSE_PAID)
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    if (LICENSE_PAID) return
    let cancelled = false
    const sync = async () => {
      const s = await serverNow()
      if (cancelled) return
      if (s !== null) setOffset(s - Date.now())
      setReady(true)
    }
    sync()
    // Re-sync now and then, so a tab left open for days still locks on time.
    const resync = setInterval(sync, 10 * 60 * 1000)
    const tick = setInterval(() => setNow(Date.now()), 1000)
    return () => { cancelled = true; clearInterval(resync); clearInterval(tick) }
  }, [])

  if (LICENSE_PAID) return { paid: true, expired: false, msLeft: Infinity, day: TRIAL_DAYS, end, ready: true }

  // The latest of: device clock + server offset, and anything seen before.
  const t = Math.max(now + offset, readSeen())
  if (ready) writeSeen(t)
  const msLeft = Math.max(0, end.getTime() - t)
  const day = Math.min(TRIAL_DAYS, Math.max(1, Math.floor((t - trialStart().getTime()) / DAY) + 1))
  return { paid: false, expired: msLeft <= 0, msLeft, day, end, ready }
}

/** "3d 04:12:09" — days, then a running clock. */
export function formatLeft(ms: number): string {
  const s = Math.floor(ms / 1000)
  const d = Math.floor(s / 86400)
  const hh = String(Math.floor((s % 86400) / 3600)).padStart(2, '0')
  const mm = String(Math.floor((s % 3600) / 60)).padStart(2, '0')
  const ss = String(s % 60).padStart(2, '0')
  return `${d}d ${hh}:${mm}:${ss}`
}
