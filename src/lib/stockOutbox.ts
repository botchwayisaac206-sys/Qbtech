import { recordMovement, type MovementRequest, type TransferResult } from '@/lib/storeStock'

/**
 * The phone app's outbox — movements recorded on the phone and not yet
 * confirmed by the database.
 *
 * A warehouse is where the signal is worst and where stock actually moves.
 * If saving needs a connection at that moment, staff either wait, or walk
 * off meaning to enter it later — and "later" is how a count drifts. So a
 * movement is written here FIRST, then sent. It leaves the outbox only when
 * the database has answered.
 *
 * Sending twice is safe: every entry carries a request ID the database acts
 * on once (record_stock_movement, 20261005_cross_line_transfers.sql). That
 * is what makes it possible to retry without knowing whether the last try
 * landed.
 *
 * Kept in localStorage, per phone. An entry belongs to the staff member who
 * recorded it and is only ever sent under their login, so the record names
 * the right person even on a shared phone.
 */

export interface Pending extends MovementRequest {
  userId: string
  /** "12 units · BACK → STORE STOCK", for the outbox list. */
  summary: string
  /** Set when the database refused it. It will not be retried until someone looks. */
  error?: string
}

const KEY = 'teamstock:outbox'

export function loadOutbox(): Pending[] {
  try {
    const raw = localStorage.getItem(KEY)
    const list = raw ? JSON.parse(raw) : []
    return Array.isArray(list) ? list : []
  } catch {
    return []
  }
}

export function saveOutbox(list: Pending[]) {
  try { localStorage.setItem(KEY, JSON.stringify(list)) } catch { /* storage full or blocked */ }
}

/** crypto.randomUUID only exists on HTTPS; the fallback covers a phone testing over the LAN. */
export function newRequestId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') return crypto.randomUUID()
  const b = new Uint8Array(16)
  crypto.getRandomValues(b)
  b[6] = (b[6] & 0x0f) | 0x40
  b[8] = (b[8] & 0x3f) | 0x80
  const h = Array.from(b, x => x.toString(16).padStart(2, '0')).join('')
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
}

/**
 * Did this fail because the request could not be made, rather than because
 * the database said no?
 *
 * A refusal from the database always carries a code (P0001 for the
 * functions' own messages). No code means the request never got an answer:
 * no signal, a timeout, a dropped connection. An expired login is treated
 * the same way — nothing is wrong with the movement, it waits for a sign-in.
 */
export function isOffline(e: unknown): boolean {
  if (typeof navigator !== 'undefined' && navigator.onLine === false) return true
  const err = e as { code?: string; message?: string } | null
  if (!err?.code) return true
  if (err.code === 'PGRST301' || /jwt|token/i.test(err.message || '')) return true
  return /failed to fetch|network|load failed|timed? ?out/i.test(err.message || '')
}

export const send = (p: Pending): Promise<TransferResult> => recordMovement(p)
