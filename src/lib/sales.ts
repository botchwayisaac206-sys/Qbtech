'use client'

import { useEffect, useState, useCallback } from 'react'
import { supabase } from '@/lib/supabase'

export type Role = 'superboss' | 'boss' | 'admin' | 'cashier' | null

/**
 * Rolling window a restricted boss (boss/admin) may see. Mirrors
 * public.window_start() in the DB — RLS is the real enforcement; the client
 * filters too so warm caches and derived charts agree with what the server
 * would return.
 */
export const VISIBLE_WINDOW_MS = 24 * 60 * 60 * 1000
export const windowStart = () => new Date(Date.now() - VISIBLE_WINDOW_MS)
/** True when `ts` falls inside the 24-hour window. */
export const withinWindow = (ts: string | Date | null | undefined) =>
  !!ts && Date.now() - new Date(ts).getTime() < VISIBLE_WINDOW_MS

/** One-shot lookup of the signed-in user's role. Returns null if unauthenticated. */
export async function fetchRole(): Promise<Role> {
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return null
  const { data } = await supabase
    .from('user_roles')
    .select('role')
    .eq('user_id', user.id)
    .maybeSingle()
  return (data?.role as Role) ?? 'cashier'
}

/** React hook — exposes {role, userId, loading}. Re-runs on auth change. */
export function useRole() {
  const [role, setRole] = useState<Role>(null)
  const [userId, setUserId] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  // Apply a user object received from auth — either the initial getSession()
  // call or the session passed directly by onAuthStateChange.
  const applyUser = useCallback((user: { id: string } | null | undefined) => {
    const uid = user?.id ?? null
    setUserId(uid)
    if (!uid) { setRole(null); setLoading(false); return }
    // IMPORTANT: defer the DB call out of any onAuthStateChange callback.
    // Supabase holds the internal auth lock while firing callbacks; calling any
    // Supabase method (including from()) inside the callback acquires the same
    // lock → deadlock. setTimeout(0) yields to the next macrotask after the
    // lock is released.
    setTimeout(async () => {
      try {
        const { data } = await supabase.from('user_roles').select('role').eq('user_id', uid).maybeSingle()
        setRole((data?.role as Role) ?? 'cashier')
      } catch { setRole('cashier') }
      setLoading(false)
    }, 0)
  }, [])

  useEffect(() => {
    // Initial check — getSession() is safe here (not inside onAuthStateChange).
    supabase.auth.getSession().then(({ data: { session } }) => applyUser(session?.user))

    // Use the session the callback already receives — NEVER call getSession()
    // or any other Supabase method directly inside onAuthStateChange; the lock
    // is held and the call will deadlock on the second auth event.
    const { data: sub } = supabase.auth.onAuthStateChange((_event, session) => {
      applyUser(session?.user)
    })
    return () => sub.subscription.unsubscribe()
  }, [applyUser])

  return { role, userId, loading, ...permissions(role) }
}

/**
 * Derived permissions for a role.
 *
 *   superboss    Big Boss — unrestricted.
 *   boss/admin   Restricted boss. Same tabs and same layout as before, but
 *                read-only, clamped to the last 24 hours, and with no invoice
 *                list. `isBoss` stays true so every existing boss-shaped gate
 *                keeps rendering exactly as it did.
 *   cashier      Unchanged.
 */
export function permissions(role: Role) {
  const isSuperBoss      = role === 'superboss'
  const isRestrictedBoss = role === 'boss' || role === 'admin'
  return {
    isSuperBoss,
    isRestrictedBoss,
    /** Boss-level UI surface — true for both tiers. */
    isBoss: isSuperBoss || isRestrictedBoss,
    /** May create, edit or delete anything at all. */
    canWrite: isSuperBoss || role === 'cashier',
    /** May manage staff accounts. */
    canManageStaff: isSuperBoss,
    /** May browse the full invoice archive. */
    canSeeInvoices: isSuperBoss,
    /** Data older than 24 hours is withheld. */
    windowed: isRestrictedBoss,
  }
}

/** Session idle-timeout: signs the user out after N minutes of no interaction. */
export function useIdleSignOut(minutes = 30) {
  useEffect(() => {
    if (typeof window === 'undefined') return
    let timer: ReturnType<typeof setTimeout>
    const reset = () => {
      clearTimeout(timer)
      timer = setTimeout(() => { supabase.auth.signOut() }, minutes * 60_000)
    }
    const events = ['mousemove', 'keydown', 'click', 'scroll', 'touchstart'] as const
    events.forEach(e => window.addEventListener(e, reset, { passive: true }))
    reset()
    return () => {
      clearTimeout(timer)
      events.forEach(e => window.removeEventListener(e, reset))
    }
  }, [minutes])
}

/**
 * Where a payment landed, for the dashboards' Cash / MoMo / Bank split.
 * Handles a plain method ("Cash") and a split one
 * ("Cash (GHC 500.00) + Mobile Money (GHC 300.00)").
 */
export function paymentBuckets(method: string | null | undefined, total: number) {
  const out = { cash: 0, momo: 0, bank: 0, other: 0 }
  const pm = method || ''
  const put = (name: string, amt: number) => {
    if      (name.startsWith('Cash'))          out.cash  += amt
    else if (name.startsWith('Mobile Money'))  out.momo  += amt
    else if (name.startsWith('Bank Transfer')) out.bank  += amt
    else                                        out.other += amt
  }
  if (pm.includes(' + ')) {
    pm.split(' + ').forEach(part => {
      const m = part.match(/GH[₵¢C]\s*([\d.]+)/)
      put(part, m ? parseFloat(m[1]) : 0)
    })
  } else {
    put(pm, total)
  }
  return out
}

export const GHS = (n: number) =>
  `GH₵ ${Number(n || 0).toLocaleString('en-GH', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
