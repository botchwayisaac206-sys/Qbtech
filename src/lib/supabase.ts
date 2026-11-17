import { createClient } from '@supabase/supabase-js'

function requiredEnv(name: string, value: string | undefined): string {
  if (!value) {
    throw new Error(`Missing ${name}. Add it to .env.local to connect to Supabase.`)
  }

  return value
}

const supabaseUrl = requiredEnv('NEXT_PUBLIC_SUPABASE_URL', process.env.NEXT_PUBLIC_SUPABASE_URL)
const supabaseAnonKey = requiredEnv('NEXT_PUBLIC_SUPABASE_ANON_KEY', process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY)

export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  // persistSession:true   → session is stored in localStorage so a page refresh
  //   restores the login instead of forcing the user to re-enter credentials.
  //   Nothing signs a user out for being idle: they stay signed in until
  //   they sign out, on the admin panel and in the stock app alike.
  // autoRefreshToken:true → the JWT (1h lifetime) is silently rotated while the user
  //   is signed in, so Supabase queries don't start hanging after an hour. This was
  //   the root cause of "after some time, data stops loading until I refresh".
  // detectSessionInUrl:false → we never hand-off auth via URL hash.
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: false,
  },
  global: {
    headers: { 'x-app-name': 'qbnet-tech' },
  },
})

// Admin client for server-side operations (uses service role key)
export const supabaseAdmin = () => {
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY
  if (!serviceKey) throw new Error('Missing SUPABASE_SERVICE_ROLE_KEY')
  return createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })
}
