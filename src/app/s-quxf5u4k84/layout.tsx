import type { Metadata, Viewport } from 'next'

// The phone stock app. A manifest and a service worker (registered by
// StockApp) are what let staff add it to the home screen and open it with
// no signal; both are scoped to this address so the public site is untouched.
//
// The address is deliberately unguessable and linked from nowhere. That
// keeps strangers from finding the sign-in screen; it is not what protects
// the stock — the staff login is. Anyone who has the address still has to
// sign the phone in before anything can be recorded.
export const metadata: Metadata = {
  title: { absolute: 'QBNET TECH' },
  description: 'QBNET TECH staff — record stock movements.',
  manifest: '/s-quxf5u4k84.webmanifest',
  robots: { index: false, follow: false },
  // Sized and typed explicitly, and versioned: phones keep a home-screen icon
  // for a long time, and a changed file under the same address is not re-read.
  icons: {
    icon: [
      { url: '/s-quxf5u4k84-192.png?v=2', sizes: '192x192', type: 'image/png' },
      { url: '/s-quxf5u4k84-512.png?v=2', sizes: '512x512', type: 'image/png' },
    ],
    shortcut: '/s-quxf5u4k84-192.png?v=2',
    apple: [{ url: '/s-quxf5u4k84-180.png?v=2', sizes: '180x180', type: 'image/png' }],
  },
  appleWebApp: { capable: true, title: 'QBNET TECH', statusBarStyle: 'default' },
  alternates: { canonical: null },
  openGraph: null,
  twitter: null,
}

export const viewport: Viewport = {
  themeColor: '#ffffff',
  width: 'device-width',
  initialScale: 1,
  viewportFit: 'cover',
}

export default function StockAppLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      {/* The site's body is dark; without this the page shows a dark band when it is over-scrolled. */}
      <style>{`
        body { background: #f5f6f8 !important; }
        /* The site wraps every page in a slide-in animation that leaves a
           transform on <main>. A transformed parent stops "fixed" meaning
           fixed to the screen: the tab bar and the save bar were pinned to
           the bottom of the PAGE instead, a long scroll away. */
        main.animate-page-enter { animation: none !important; transform: none !important; opacity: 1 !important; filter: none !important; }
        /* The site's display font is for the shop window. A working screen
           full of names and figures needs one made for reading. */
        main, main h1, main button, main input, main select, main label {
          font-family: Inter, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif !important;
          letter-spacing: 0;
        }
      `}</style>
      {children}
    </>
  )
}
