import { NextResponse } from 'next/server'
import { createClient } from '@supabase/supabase-js'
import { supabaseAdmin } from '@/lib/supabase'

const URL = process.env.NEXT_PUBLIC_SUPABASE_URL!
const ANON = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!

/** Removes a staff account. Boss-only. Body: { user_id: string } */
export async function POST(req: Request) {
  try {
    const auth = req.headers.get('authorization') || ''
    const accessToken = auth.startsWith('Bearer ') ? auth.slice(7) : null
    if (!accessToken) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })

    const userClient = createClient(URL, ANON, {
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
      auth: { persistSession: false },
    })
    const { data: { user } } = await userClient.auth.getUser()
    if (!user) return NextResponse.json({ error: 'Invalid session' }, { status: 401 })

    const { data: roleRow } = await userClient
      .from('user_roles').select('role').eq('user_id', user.id).maybeSingle()
    if (roleRow?.role !== 'superboss') {
      return NextResponse.json({ error: 'Not permitted' }, { status: 403 })
    }

    const { user_id } = await req.json()
    if (!user_id) return NextResponse.json({ error: 'user_id required' }, { status: 400 })
    if (user_id === user.id) return NextResponse.json({ error: 'Cannot delete yourself' }, { status: 400 })

    const admin = supabaseAdmin()
    // Only allow deleting cashiers (protect bosses from accidental removal)
    const { data: target } = await admin.from('user_roles').select('role').eq('user_id', user_id).maybeSingle()
    if (target && ['superboss', 'boss', 'admin'].includes(target.role)) {
      return NextResponse.json({ error: 'Cannot delete a boss/admin account' }, { status: 403 })
    }

    await admin.from('user_roles').delete().eq('user_id', user_id)
    const { error } = await admin.auth.admin.deleteUser(user_id)
    if (error) return NextResponse.json({ error: error.message }, { status: 500 })

    return NextResponse.json({ ok: true })
  } catch (e: any) {
    return NextResponse.json({ error: e.message || 'Server error' }, { status: 500 })
  }
}
