import type { Metadata } from 'next'
import './qb-ios.css'
import './globals.css'
import { Toaster } from 'react-hot-toast'
import { SiteHeader, SiteFooter } from '@/components/SiteChrome'
import { CONTACT, whatsappLink } from '@/lib/constants'

// Sets <html data-qb-theme> before first paint: light unless the visitor has
// picked dark with the switch, so neither the shop nor the admin panel flashes the wrong
// theme. Kept tiny and dependency-free on purpose.
const THEME_BOOT = `(function(){var d=document.documentElement,t;try{t=localStorage.getItem('qbnet.theme.v2')}catch(e){}if(t!=='dark'){t='light'}d.setAttribute('data-qb-theme',t);d.style.colorScheme=t})()`

const BASE = 'https://www.qbnettech.com'

export const metadata: Metadata = {
  metadataBase: new URL(BASE),

  title: {
    default: 'QBNET TECH SOLUTIONS | CCTV, Security & IT Solutions Ghana',
    template: '%s | QBNET TECH SOLUTIONS',
  },
  description: 'IT & security solutions in Ghana. Hikvision, Dahua, TP-Link, D-Link & more. CCTV cameras, access control, networking, fire alarms — wholesale & retail with nationwide delivery.',
  keywords: [
    'CCTV cameras Ghana', 'Hikvision Ghana', 'Dahua Ghana', 'security cameras Accra',
    'IT equipment Ghana', 'access control Ghana', 'networking equipment Accra',
    'fire alarm Ghana', 'TP-Link Ghana', 'D-Link Ghana', 'Grandstream Ghana',
    'security solutions Ghana', 'QBNET TECH SOLUTIONS', 'qbnettech',
    'surveillance cameras Ghana', 'NVR DVR Ghana', 'IP cameras Accra',
    'authorized Hikvision dealer Ghana', 'IT distributor Ghana',
  ],

  authors: [{ name: 'QBNET TECH SOLUTIONS', url: BASE }],
  creator: 'QBNET TECH SOLUTIONS',
  publisher: 'QBNET TECH SOLUTIONS',

  icons: {
    icon: [{ url: '/fav.jpg', type: 'image/jpeg' }],
    apple: '/fav.jpg',
    shortcut: '/fav.jpg',
  },

  openGraph: {
    type: 'website',
    locale: 'en_GH',
    url: BASE,
    siteName: 'QBNET TECH SOLUTIONS',
    title: 'QBNET TECH SOLUTIONS | CCTV, Security & IT Solutions Ghana',
    description: 'IT & security solutions in Ghana. Hikvision, Dahua, TP-Link & more. Nationwide delivery.',
    images: [{ url: '/preview.jpg', width: 1200, height: 630, alt: 'QBNET TECH SOLUTIONS' }],
  },

  twitter: {
    card: 'summary_large_image',
    title: 'QBNET TECH SOLUTIONS | IT & Security Solutions Ghana',
    description: 'Hikvision, Dahua, TP-Link & more. CCTV, access control, networking & IT equipment across Ghana.',
    images: ['/preview.jpg'],
  },

  robots: {
    index: true,
    follow: true,
    googleBot: { index: true, follow: true, 'max-image-preview': 'large', 'max-snippet': -1 },
  },

  alternates: { canonical: BASE },

  category: 'technology',
  classification: 'IT & Security Equipment',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className="scroll-smooth" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: THEME_BOOT }} />
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="" />
      </head>
      <body className="qb-ios">
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify({
            '@context': 'https://schema.org',
            '@type': 'LocalBusiness',
            name: 'QBNET TECH SOLUTIONS',
            url: 'https://www.qbnettech.com',
            logo: 'https://www.qbnettech.com/logo.jpg',
            image: 'https://www.qbnettech.com/preview.jpg',
            description: 'IT & security solutions in Ghana. Hikvision, Dahua, TP-Link, D-Link and more.',
            telephone: CONTACT.phones.map(p => p.tel),
            email: CONTACT.email,
            address: { '@type': 'PostalAddress', addressLocality: 'Accra', addressCountry: 'GH' },
            geo: { '@type': 'GeoCoordinates', latitude: 5.6037, longitude: -0.1870 },
            openingHoursSpecification: [
              { '@type': 'OpeningHoursSpecification', dayOfWeek: ['Monday','Tuesday','Wednesday','Thursday','Friday'], opens: '08:00', closes: '18:00' },
              { '@type': 'OpeningHoursSpecification', dayOfWeek: ['Saturday'], opens: '09:00', closes: '16:00' },
            ],
            sameAs: [whatsappLink(), `https://instagram.com/${CONTACT.instagram}`],
            priceRange: '₵₵',
            currenciesAccepted: 'GHS',
            paymentAccepted: 'Cash, Mobile Money',
            areaServed: { '@type': 'Country', name: 'Ghana' },
          })}}
        />
        <SiteHeader />
        <main>{children}</main>
        <SiteFooter />
        <Toaster 
          position="top-center"
          toastOptions={{
            style: {
              background: 'var(--qb-card-strong)',
              color: 'var(--qb-text)',
              border: '1px solid var(--qb-border)',
              borderRadius: 999,
              boxShadow: 'var(--qb-shadow)',
              backdropFilter: 'blur(28px) saturate(180%)',
              fontWeight: 600,
            },
            success: { iconTheme: { primary: '#30d158', secondary: '#ffffff' } },
            error: { iconTheme: { primary: '#ff3b30', secondary: '#ffffff' } },
          }}
        />
      </body>
    </html>
  )
}
