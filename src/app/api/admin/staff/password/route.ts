import { NextResponse } from 'next/server'
import { createClient } from '@supabase/supabase-js'
import { supabaseAdmin } from '@/lib/supabase'

const URL = process.env.NEXT_PUBLIC_SUPABASE_URL!
const ANON = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!

/**
 * Resets another account's password. Big Boss (superboss) only.
 * Body: { user_id: string, password: string }
 *
 * WHY THIS IS A SERVER ROUTE
 * --------------------------
 * Changing a password you do not own requires auth.admin.updateUserById, which
 * only works with the service role key. That key must never reach the browser,
 * so the whole operation lives here — same shape as ../create and ../delete.
 *
 * WHO MAY BE TARGETED
 *   cashier / boss / admin   yes — this is the point of the feature
 *   another superboss        no  — a second Big Boss could otherwise be locked
 *                                  out of their own account by the first
 *   yourself                 yes — you already hold this session
 */
export async function POST(req: Request) {
  try {
    const auth = req.headers.get('authorization') || ''
    const accessToken = auth.startsWith('Bearer ') ? auth.slice(7) : null
    if (!accessToken) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })

    const userClient = createClient(URL, ANON, {
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
      auth: { persistSession: false },
    })
    const { data: { user }, error: uErr } = await userClient.auth.getUser()
    if (uErr || !user) return NextResponse.json({ error: 'Invalid session' }, { status: 401 })

    const { data: roleRow } = await userClient
      .from('user_roles').select('role').eq('user_id', user.id).maybeSingle()
    if (roleRow?.role !== 'superboss') {
      return NextResponse.json({ error: 'Not permitted' }, { status: 403 })
    }

    const body = await req.json()
    const user_id = String(body.user_id || '')
    const password = String(body.password || '')

    if (!user_id) return NextResponse.json({ error: 'user_id required' }, { status: 400 })
    if (password.length < 6) {
      return NextResponse.json({ error: 'Password must be at least 6 characters' }, { status: 400 })
    }

    const admin = supabaseAdmin()

    const { data: target } = await admin
      .from('user_roles').select('role, full_name, staff_id').eq('user_id', user_id).maybeSingle()
    if (!target) return NextResponse.json({ error: 'That account no longer exists' }, { status: 404 })

    // Protect other Big Boss accounts. Resetting your own is allowed.
    if (target.role === 'superboss' && user_id !== user.id) {
      return NextResponse.json({ error: 'Cannot change another Big Boss password' }, { status: 403 })
    }

    const { error } = await admin.auth.admin.updateUserById(user_id, { password })
    if (error) return NextResponse.json({ error: error.message }, { status: 500 })

    return NextResponse.json({
      ok: true,
      full_name: target.full_name,
      staff_id: target.staff_id,
      role: target.role,
      self: user_id === user.id,
    })
  } catch (e: any) {
    return NextResponse.json({ error: e.message || 'Server error' }, { status: 500 })
  }
}
