import QbnetLogo from '@/components/admin/QbnetLogo'
import Link from 'next/link'
import { Phone, Mail, MapPin, Instagram } from 'lucide-react'
import { BRANDS } from '@/types'
import { CONTACT, whatsappLink } from '@/lib/constants'

const LINKS = [
  { href: '/', label: 'Home' },
  { href: '/products', label: 'All products' },
  { href: '/about', label: 'About us' },
  { href: '/contact', label: 'Contact' },
]

// The footer lists brands only, not product-type categories.
const FOOTER_BRANDS = BRANDS.slice(0, 8)

export default function Footer() {
  return (
    <footer className="px-5 pb-8 pt-4">
      <div className="glass mx-auto max-w-6xl !rounded-[28px] px-6 py-10 sm:px-10">
        <div className="grid grid-cols-1 gap-10 md:grid-cols-2 lg:grid-cols-[1.4fr_1fr_1fr_1.2fr]">
          <div>
            <Link href="/" className="inline-flex items-center gap-3">
              <QbnetLogo size={44} radius={12} />
              <span className="text-[18px] font-bold tracking-tight text-qb-text">QBNET<span className="font-medium text-qb-sub"> Tech Solutions</span></span>
            </Link>
            <p className="mt-4 max-w-xs text-[15px] leading-relaxed text-qb-sub">
              IT equipment, security systems and networking for homes and businesses across Ghana.
            </p>
            <div className="mt-5 flex gap-2">
              <a href={whatsappLink()} target="_blank" rel="noopener noreferrer" className="btn-whatsapp !px-4 !py-2 !text-[15px]">WhatsApp us</a>
              <a href={`https://instagram.com/${CONTACT.instagram}`} target="_blank" rel="noopener noreferrer"
                aria-label="QBNET TECH on Instagram" className="qb-icon-btn !h-10 !w-10"><Instagram size={18} /></a>
            </div>
          </div>

          <nav aria-label="Brands">
            <h3 className="text-[15px] font-semibold text-qb-text">Brands</h3>
            <ul className="mt-3 space-y-2">
              {FOOTER_BRANDS.map(brand => (
                <li key={brand}>
                  <Link href={`/products?brand=${encodeURIComponent(brand)}`} className="text-[15px] text-qb-sub hover:text-qb-text">{brand}</Link>
                </li>
              ))}
            </ul>
          </nav>

          <nav aria-label="Site">
            <h3 className="text-[15px] font-semibold text-qb-text">Shop</h3>
            <ul className="mt-3 space-y-2">
              {LINKS.map(({ href, label }) => (
                <li key={href}><Link href={href} className="text-[15px] text-qb-sub hover:text-qb-text">{label}</Link></li>
              ))}
            </ul>
          </nav>

          <div>
            <h3 className="text-[15px] font-semibold text-qb-text">Contact</h3>
            <ul className="mt-3 space-y-2.5 text-[15px] text-qb-sub">
              {CONTACT.phones.map(p => (
                <li key={p.tel}>
                  <a href={`tel:${p.tel}`} className="flex items-center gap-2.5 hover:text-qb-text"><Phone size={16} className="text-qb-accent" />{p.display}</a>
                </li>
              ))}
              <li>
                <a href={`mailto:${CONTACT.email}`} className="flex items-center gap-2.5 break-all hover:text-qb-text"><Mail size={16} className="shrink-0 text-qb-accent" />{CONTACT.email}</a>
              </li>
              <li className="flex items-center gap-2.5"><MapPin size={16} className="text-qb-accent" />{CONTACT.city}</li>
            </ul>
          </div>
        </div>

        <div className="mt-10 border-t border-qb-separator pt-6 text-[13px] text-qb-muted">
          © {new Date().getFullYear()} QBNET TECH SOLUTIONS. All rights reserved.
        </div>
      </div>
    </footer>
  )
}
