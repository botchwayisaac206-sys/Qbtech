/**
 * Creates (or rotates the password of) the Big Boss account.
 *
 *   npm run bigboss
 *
 * Reads from .env.local:
 *   BIGBOSS_EMAIL              the login email, created in Supabase Auth
 *   BIGBOSS_PASSWORD           the password to set
 *   NEXT_PUBLIC_SUPABASE_URL
 *   SUPABASE_SERVICE_ROLE_KEY  admin key — server-side only, never bundled
 *
 * WHY A SCRIPT AND NOT A RUNTIME LOOKUP
 * -------------------------------------
 * The password is NOT checked against the env at sign-in. Sign-in goes through
 * Supabase Auth like every other account, against the salted hash Supabase
 * stores. The env var is only the value this script PUSHES INTO Supabase.
 *
 * That distinction matters. Sign-in happens in the browser
 * (supabase.auth.signInWithPassword), so any env var the login form could
 * compare against would have to be NEXT_PUBLIC_*, which Next.js inlines into
 * the client bundle in plain text — readable by anyone who opens DevTools,
 * including the very account we restricted. BIGBOSS_PASSWORD has no
 * NEXT_PUBLIC_ prefix, so it stays on the server and in this script only.
 *
 * Idempotent: re-run any time to rotate the password or repair the role.
 */
import { createClient } from '@supabase/supabase-js'
import { readFileSync, existsSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')

// Load .env.local without adding a dependency. Real env wins, so CI/Vercel
// can supply these without a file present.
const envPath = resolve(root, '.env.local')
if (existsSync(envPath)) {
  for (const line of readFileSync(envPath, 'utf8').split(/\r?\n/)) {
    const t = line.trim()
    if (!t || t.startsWith('#')) continue
    const i = t.indexOf('=')
    if (i < 1) continue
    const k = t.slice(0, i).trim()
    if (process.env[k] === undefined) {
      process.env[k] = t.slice(i + 1).trim().replace(/^["']|["']$/g, '')
    }
  }
}

const die = (msg) => { console.error(`\n  ✗ ${msg}\n`); process.exit(1) }

const url      = process.env.NEXT_PUBLIC_SUPABASE_URL
const service  = process.env.SUPABASE_SERVICE_ROLE_KEY
const email    = (process.env.BIGBOSS_EMAIL || '').trim().toLowerCase()
const password = process.env.BIGBOSS_PASSWORD || ''

if (!url || !service) die('NEXT_PUBLIC_SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set in .env.local')
if (!email)    die('BIGBOSS_EMAIL is not set in .env.local')
if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) die(`BIGBOSS_EMAIL is not a valid email: ${email}`)
if (!password) die('BIGBOSS_PASSWORD is not set in .env.local')
if (password.length < 10) die('BIGBOSS_PASSWORD must be at least 10 characters — this account can read every invoice and manage staff.')
if (/^(change|placeholder|password|secret|your)/i.test(password)) die('BIGBOSS_PASSWORD still looks like a placeholder. Set a real password.')

const admin = createClient(url, service, { auth: { autoRefreshToken: false, persistSession: false } })

/** listUsers is paginated; page through to find an existing account. */
async function findByEmail(target) {
  for (let page = 1; page <= 50; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 })
    if (error) die(`Could not list users: ${error.message}`)
    const hit = data.users.find(u => (u.email || '').toLowerCase() === target)
    if (hit) return hit
    if (data.users.length < 200) return null
  }
  return null
}

console.log(`\n  Big Boss setup → ${email}`)

const existing = await findByEmail(email)
let userId

if (existing) {
  const { error } = await admin.auth.admin.updateUserById(existing.id, {
    password,
    email_confirm: true,
  })
  if (error) die(`Could not update the account: ${error.message}`)
  userId = existing.id
  console.log('  · account already existed — password reset')
} else {
  const { data, error } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { full_name: 'Big Boss', staff_id: email },
  })
  if (error || !data.user) die(`Could not create the account: ${error?.message || 'unknown error'}`)
  userId = data.user.id
  console.log('  · account created')
}

const { error: roleErr } = await admin.from('user_roles').upsert({
  user_id: userId,
  role: 'superboss',
  full_name: 'Big Boss',
  staff_id: email,
})
if (roleErr) {
  die(`Account exists but the role could not be set: ${roleErr.message}\n`
    + `    If this says the role check constraint failed, run\n`
    + `    supabase/migrations/20260807_superboss.sql first.`)
}
console.log('  · role set to superboss')

// Report the resulting tiers so a missing or duplicate superboss is obvious.
const { data: roles } = await admin.from('user_roles').select('role, staff_id').order('role')
const supers = (roles || []).filter(r => r.role === 'superboss')
const tally = {}
for (const r of roles || []) tally[r.role] = (tally[r.role] || 0) + 1
console.log('\n  Roles now in the system:')
for (const [role, n] of Object.entries(tally)) console.log(`    ${role.padEnd(10)} ${n}`)
if (supers.length !== 1) {
  console.log(`\n  ! ${supers.length} superboss accounts exist: ${supers.map(s => s.staff_id).join(', ')}`)
}

console.log(`\n  ✓ Done. Sign in at /teamqtech with ${email} and the password from BIGBOSS_PASSWORD.\n`)
