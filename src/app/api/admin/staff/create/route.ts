import { NextResponse } from 'next/server'
import { createClient } from '@supabase/supabase-js'
import { supabaseAdmin } from '@/lib/supabase'

const URL = process.env.NEXT_PUBLIC_SUPABASE_URL!
const ANON = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!

/**
 * Creates a cashier account. Boss-only.
 * Body: { full_name: string, password: string, login_handle?: string }
 * Staff ID = login email in the form `<handle>@qbnettech.com` (e.g. isha@qbnettech.com).
 * If login_handle is not supplied, the handle is derived from the first word of full_name.
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
    const full_name = String(body.full_name || '').trim()
    const password = String(body.password || '')
    const rawHandle = String(body.login_handle || '').trim().toLowerCase()

    if (!full_name) return NextResponse.json({ error: 'Full name required' }, { status: 400 })
    if (password.length < 6) return NextResponse.json({ error: 'Password must be at least 6 characters' }, { status: 400 })

    // Derive handle from first word of full_name if caller didn't provide one.
    const derived = (full_name.split(/\s+/)[0] || '').toLowerCase()
    const handle = (rawHandle || derived).replace(/[^a-z0-9.\-]/g, '')
    if (handle.length < 2) {
      return NextResponse.json({ error: 'Login handle must be at least 2 letters (a–z, 0–9, . or -)' }, { status: 400 })
    }

    const email = `${handle}@qbnettech.com`
    const staff_id = email

    const admin = supabaseAdmin()

    const { data: created, error: cErr } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { full_name, staff_id },
    })
    if (cErr || !created.user) {
      const msg = (cErr?.message || '').toLowerCase().includes('already')
        ? `That login handle is already taken: ${handle}`
        : (cErr?.message || 'Failed to create user')
      return NextResponse.json({ error: msg }, { status: 400 })
    }

    const { error: rErr } = await admin.from('user_roles').upsert({
      user_id: created.user.id,
      role: 'cashier',
      full_name,
      staff_id,
    })
    if (rErr) {
      await admin.auth.admin.deleteUser(created.user.id)
      return NextResponse.json({ error: `Role assignment failed: ${rErr.message}` }, { status: 500 })
    }

    return NextResponse.json({ ok: true, email, staff_id, full_name })
  } catch (e: any) {
    return NextResponse.json({ error: e.message || 'Server error' }, { status: 500 })
  }
}
