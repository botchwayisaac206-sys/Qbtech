'use client'

import { useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { useRole } from '@/lib/sales'

const TEAL = '#0a7cff'

interface StaffRow {
  user_id: string
  role: string
  full_name: string | null
  staff_id: string | null
  created_at: string
}

export default function StaffManager() {
  const { canManageStaff } = useRole()
  const [rows, setRows] = useState<StaffRow[]>([])
  const [loading, setLoading] = useState(true)
  const [msg, setMsg] = useState<{ text: string; type: 'ok' | 'err' } | null>(null)

  const [fullName, setFullName] = useState('')
  const [loginHandle, setLoginHandle] = useState('')
  const [password, setPassword] = useState('')
  const [submitting, setSubmitting] = useState(false)

  // Password reset (Big Boss only)
  const [myId, setMyId] = useState<string | null>(null)
  const [pwTarget, setPwTarget] = useState<StaffRow | null>(null)
  const [pwValue, setPwValue] = useState('')
  const [pwSaving, setPwSaving] = useState(false)

  const toast = (text: string, type: 'ok' | 'err' = 'ok') => {
    setMsg({ text, type })
    setTimeout(() => setMsg(null), 4000)
  }

  // Live preview of the staff ID the server will assign.
  const previewHandle = (loginHandle || (fullName.split(/\s+/)[0] || ''))
    .toLowerCase()
    .replace(/[^a-z0-9.\-]/g, '')
  const previewEmail = previewHandle.length >= 2 ? `${previewHandle}@qbnettech.com` : ''

  async function load() {
    setLoading(true)
    const { data } = await supabase
      .from('user_roles')
      .select('user_id, role, full_name, staff_id, created_at')
      .order('created_at', { ascending: false })
    setRows((data as StaffRow[]) || [])
    setLoading(false)
  }
  useEffect(() => { load() }, [])
  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => setMyId(data.user?.id ?? null))
  }, [])

  async function createStaff(e: React.FormEvent) {
    e.preventDefault()
    setSubmitting(true)
    try {
      const { data: { session } } = await supabase.auth.getSession()
      const token = session?.access_token
      if (!token) throw new Error('Not signed in')

      const res = await fetch('/api/admin/staff/create', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify({ full_name: fullName, password, login_handle: loginHandle }),
      })
      const json = await res.json()
      if (!res.ok) throw new Error(json.error || 'Failed')
      toast(`Staff created · Staff ID: ${json.staff_id}`, 'ok')
      setFullName(''); setPassword(''); setLoginHandle('')
      load()
    } catch (err: any) {
      toast(err.message || 'Failed', 'err')
    } finally { setSubmitting(false) }
  }

  async function deleteStaff(userId: string, name: string) {
    if (!confirm(`Remove ${name || 'this staff'} permanently? They will no longer be able to sign in.`)) return
    try {
      const { data: { session } } = await supabase.auth.getSession()
      const res = await fetch('/api/admin/staff/delete', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${session?.access_token}` },
        body: JSON.stringify({ user_id: userId }),
      })
      const json = await res.json()
      if (!res.ok) throw new Error(json.error || 'Failed')
      toast('Staff removed', 'ok')
      load()
    } catch (err: any) {
      toast(err.message || 'Failed', 'err')
    }
  }

  async function resetPassword(e: React.FormEvent) {
    e.preventDefault()
    if (!pwTarget) return
    setPwSaving(true)
    try {
      const { data: { session } } = await supabase.auth.getSession()
      const token = session?.access_token
      if (!token) throw new Error('Not signed in')

      const res = await fetch('/api/admin/staff/password', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify({ user_id: pwTarget.user_id, password: pwValue }),
      })
      const json = await res.json()
      if (!res.ok) throw new Error(json.error || 'Failed')

      const who = json.staff_id || pwTarget.full_name || 'that account'
      toast(
        json.self
          ? 'Your own password was changed.'
          : `Password changed for ${who}. Tell them the new password.`,
        'ok',
      )
      setPwTarget(null); setPwValue('')
    } catch (err: any) {
      toast(err.message || 'Failed', 'err')
    } finally { setPwSaving(false) }
  }

  const fld: React.CSSProperties = {
    width: '100%', padding: '9px 12px', borderRadius: 8, fontSize: 14, outline: 'none',
    border: '1px solid var(--qb-input-border)', background: 'var(--qb-input)', color: 'var(--qb-text)',
  }
  const lbl: React.CSSProperties = { fontSize: 10, fontWeight: 800, color: TEAL, letterSpacing: '0.18em', textTransform: 'uppercase', display: 'block', marginBottom: 5 }

  // Ordered by tier so the hierarchy reads at a glance.
  const TIER: Record<string, number> = { superboss: 0, boss: 1, admin: 2, cashier: 3 }
  const visible = [...rows].sort(
    (a, b) => (TIER[a.role] ?? 9) - (TIER[b.role] ?? 9) || (a.full_name || '').localeCompare(b.full_name || ''),
  )

  const roleColor = (role: string) =>
    role === 'superboss' ? '#f59e0b' : role === 'cashier' ? TEAL : '#a78bfa'

  // A Big Boss may reset anyone except a DIFFERENT Big Boss. Enforced again
  // server-side in /api/admin/staff/password — this only shapes the buttons.
  const canSetPassword = (r: StaffRow) =>
    canManageStaff && (r.role !== 'superboss' || r.user_id === myId)
  const canRemove = (r: StaffRow) => canManageStaff && r.role === 'cashier'

  return (
    <div style={{ maxWidth: 980, display: 'flex', flexDirection: 'column', gap: 18 }}>

      {msg && (
        <div style={{
          padding: 12, borderRadius: 10,
          background: msg.type === 'ok' ? 'rgba(10,124,255,0.1)' : 'rgba(239,68,68,0.1)',
          border: `1px solid ${msg.type === 'ok' ? 'rgba(10,124,255,0.3)' : 'rgba(239,68,68,0.3)'}`,
          color: msg.type === 'ok' ? TEAL : 'var(--qb-red)',
          fontSize: 13, fontWeight: 700,
        }}>{msg.text}</div>
      )}

      {/* Create form — Big Boss only */}
      {canManageStaff && <form onSubmit={createStaff} style={{
        padding: 18, borderRadius: 14,
        border: '1px solid var(--qb-border)', background: 'var(--qb-card)',
      }}>
        <div style={{ color: TEAL, fontSize: 11, fontWeight: 800, letterSpacing: '0.2em', marginBottom: 14 }}>+ CREATE STAFF ACCOUNT</div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(200px,1fr))', gap: 12 }}>
          <div>
            <label style={lbl}>Full Name *</label>
            <input required style={fld} value={fullName} onChange={e => setFullName(e.target.value)} placeholder="e.g. Isha Mensah" />
          </div>
          <div>
            <label style={lbl}>Login Handle</label>
            <input style={fld} value={loginHandle} onChange={e => setLoginHandle(e.target.value)} placeholder="e.g. isha (auto from first name)" />
            <div style={{ color: 'var(--qb-muted)', fontSize: 10, fontVariantNumeric: 'tabular-nums', marginTop: 4 }}>
              {previewEmail ? `Staff ID → ${previewEmail}` : 'a–z, 0–9, . or -  (min 2)'}
            </div>
          </div>
          <div>
            <label style={lbl}>Password *</label>
            <input required type="password" minLength={6} style={fld} value={password}
              onChange={e => setPassword(e.target.value)} placeholder="min 6 characters" />
          </div>
        </div>
        <button type="submit" disabled={submitting} style={{
          marginTop: 14, width: '100%', padding: 13, borderRadius: 10,
          background: submitting ? 'var(--qb-fill)' : TEAL, color: submitting ? 'var(--qb-muted)' : '#ffffff',
          fontWeight: 900, fontSize: 13, letterSpacing: '0.12em',
          border: 'none', cursor: submitting ? 'not-allowed' : 'pointer',
        }}>
          {submitting ? 'CREATING…' : 'CREATE STAFF'}
        </button>
      </form>}

      {/* Staff list */}
      <div style={{
        borderRadius: 14, border: '1px solid var(--qb-border)',
        background: 'var(--qb-card)', overflow: 'hidden',
      }}>
        <div style={{
          display: 'grid', gridTemplateColumns: '1fr 210px 104px 96px 196px',
          padding: '10px 14px', background: 'var(--qb-header)',
          color: TEAL, fontSize: 10, fontWeight: 800, letterSpacing: '0.15em',
        }}>
          <div>STAFF NAME</div><div>STAFF ID</div><div>ROLE</div><div>CREATED</div><div style={{ textAlign: 'right' }}>ACTIONS</div>
        </div>
        {loading && <div style={{ padding: 30, textAlign: 'center', color: 'var(--qb-muted)', fontVariantNumeric: 'tabular-nums' }}>Loading…</div>}
        {!loading && visible.length === 0 && <div style={{ padding: 30, textAlign: 'center', color: 'var(--qb-muted)', fontVariantNumeric: 'tabular-nums' }}>No accounts yet.</div>}
        {visible.map(s => (
          <div key={s.user_id} style={{
            display: 'grid', gridTemplateColumns: '1fr 210px 104px 96px 196px',
            padding: '10px 14px', borderTop: '1px solid var(--qb-separator)',
            fontSize: 13, color: 'var(--qb-text)', alignItems: 'center',
          }}>
            <div style={{ color: 'var(--qb-text)', fontWeight: 600 }}>{s.full_name || '—'}</div>
            <div style={{ fontVariantNumeric: 'tabular-nums', fontSize: 12, color: TEAL, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {s.staff_id || <span style={{ color: 'var(--qb-faint)' }}>—</span>}
            </div>
            <div>
              <span style={{ padding: '3px 8px', borderRadius: 6, background: `${roleColor(s.role)}1a`, color: roleColor(s.role), fontSize: 11, fontWeight: 700, letterSpacing: '0.1em' }}>
                {s.role === 'superboss' ? 'BIG BOSS' : s.role.toUpperCase()}
              </span>
            </div>
            <div style={{ fontVariantNumeric: 'tabular-nums', fontSize: 11, color: 'var(--qb-muted)' }}>
              {new Date(s.created_at).toLocaleDateString('en-GB')}
            </div>
            <div style={{ display: 'flex', gap: 6, justifyContent: 'flex-end' }}>
              {canSetPassword(s) && (
                <button onClick={() => { setPwTarget(s); setPwValue('') }} style={{
                  padding: '6px 10px', borderRadius: 6, background: 'rgba(10,124,255,0.1)',
                  color: TEAL, border: '1px solid rgba(10,124,255,0.3)',
                  fontSize: 11, fontWeight: 700, cursor: 'pointer', whiteSpace: 'nowrap',
                }}>PASSWORD</button>
              )}
              {canRemove(s) && (
                <button onClick={() => deleteStaff(s.user_id, s.full_name || '')} style={{
                  padding: '6px 10px', borderRadius: 6, background: 'rgba(239,68,68,0.1)',
                  color: 'var(--qb-red)', border: '1px solid rgba(239,68,68,0.3)',
                  fontSize: 11, fontWeight: 700, cursor: 'pointer',
                }}>REMOVE</button>
              )}
            </div>
          </div>
        ))}
      </div>

      {/* Password reset dialog */}
      {pwTarget && (
        <div
          onClick={e => e.target === e.currentTarget && !pwSaving && setPwTarget(null)}
          style={{
            position: 'fixed', inset: 0, zIndex: 1200, background: 'rgba(0,0,0,0.65)',
            backdropFilter: 'blur(4px)', display: 'flex', alignItems: 'center',
            justifyContent: 'center', padding: 16,
          }}>
          <form onSubmit={resetPassword} style={{
            width: '100%', maxWidth: 420, padding: 24, borderRadius: 16,
            background: 'var(--qb-input)', border: '1px solid rgba(10,124,255,0.2)',
            boxShadow: '0 20px 60px rgba(0,0,0,0.6)',
          }}>
            <div style={{ color: TEAL, fontSize: 11, fontWeight: 800, letterSpacing: '0.2em', marginBottom: 6 }}>
              SET A NEW PASSWORD
            </div>
            <div style={{ color: 'var(--qb-text)', fontWeight: 700, fontSize: 15 }}>
              {pwTarget.full_name || pwTarget.staff_id || 'Account'}
            </div>
            <div style={{ color: 'var(--qb-muted)', fontSize: 12, fontVariantNumeric: 'tabular-nums', marginTop: 2, marginBottom: 16 }}>
              {pwTarget.staff_id} · {pwTarget.role === 'superboss' ? 'BIG BOSS' : pwTarget.role.toUpperCase()}
            </div>

            <label style={lbl}>New Password *</label>
            <input
              autoFocus required type="text" minLength={6} style={fld} value={pwValue}
              onChange={e => setPwValue(e.target.value)} placeholder="min 6 characters" />
            <div style={{ color: 'var(--qb-muted)', fontSize: 11, marginTop: 8, lineHeight: 1.5 }}>
              {pwTarget.user_id === myId
                ? 'This is your own account. You stay signed in here.'
                : 'Shown in plain text so you can read it out. They are not signed out, and can keep working until their session ends.'}
            </div>

            <div style={{ display: 'flex', gap: 10, marginTop: 20 }}>
              <button type="submit" disabled={pwSaving || pwValue.length < 6} style={{
                flex: 1, padding: 12, borderRadius: 10,
                background: pwSaving || pwValue.length < 6 ? 'var(--qb-fill)' : TEAL,
                color: pwSaving || pwValue.length < 6 ? 'var(--qb-muted)' : '#ffffff',
                fontWeight: 900, fontSize: 13, letterSpacing: '0.12em', border: 'none',
                cursor: pwSaving || pwValue.length < 6 ? 'not-allowed' : 'pointer',
              }}>{pwSaving ? 'SAVING…' : 'CHANGE PASSWORD'}</button>
              <button type="button" disabled={pwSaving} onClick={() => setPwTarget(null)} style={{
                padding: '12px 18px', borderRadius: 10, background: 'transparent',
                color: 'var(--qb-sub)', fontWeight: 700, fontSize: 13,
                border: '1px solid var(--qb-input-border)', cursor: pwSaving ? 'not-allowed' : 'pointer',
              }}>Cancel</button>
            </div>
          </form>
        </div>
      )}
    </div>
  )
}
