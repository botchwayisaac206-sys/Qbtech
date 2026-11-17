// Service worker for the phone stock app (/s-quxf5u4k84).
//
// Its only job is to let the app OPEN with no signal. It keeps the page and
// the scripts it needs; it never touches a request to the database, so what
// is saved and when is entirely the app's business (see stockOutbox.ts).
//
// Registered with scope /s-quxf5u4k84, so it controls that page alone and the
// public site never runs through it. Bump CACHE to drop everything kept.

const CACHE = 'teamstock-v2'
const SHELL = '/s-quxf5u4k84'

self.addEventListener('install', event => {
  self.skipWaiting()
  event.waitUntil(
    caches.open(CACHE)
      .then(cache => cache.addAll([SHELL]))
      .catch(() => { /* installed without a warm cache; the first online visit fills it */ }),
  )
})

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) {
      if (key.startsWith('teamstock-') && key !== CACHE) await caches.delete(key)
    }
    await self.clients.claim()
  })())
})

self.addEventListener('fetch', event => {
  const req = event.request
  if (req.method !== 'GET') return
  const url = new URL(req.url)
  // Supabase, fonts, anything not ours: straight to the network.
  if (url.origin !== self.location.origin) return

  // Build output is content-hashed, so a kept copy is never out of date.
  if (url.pathname.startsWith('/_next/static/') || url.pathname.startsWith('/s-quxf5u4k84-')) {
    event.respondWith((async () => {
      const cache = await caches.open(CACHE)
      const hit = await cache.match(req)
      if (hit) return hit
      const res = await fetch(req)
      if (res.ok) cache.put(req, res.clone())
      return res
    })())
    return
  }

  // The page itself: the newest when there is a signal, the kept one when not.
  if (req.mode === 'navigate') {
    event.respondWith((async () => {
      const cache = await caches.open(CACHE)
      try {
        const res = await fetch(req)
        if (res.ok) cache.put(SHELL, res.clone())
        return res
      } catch {
        return (await cache.match(SHELL)) || Response.error()
      }
    })())
  }
})
