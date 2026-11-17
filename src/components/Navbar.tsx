'use client'

import QbnetLogo from '@/components/admin/QbnetLogo'
import { useState, useEffect, useRef } from 'react'
import Link from 'next/link'
import Image from 'next/image'
import { usePathname, useRouter } from 'next/navigation'
import { Search, Menu, X, ChevronDown, ChevronRight, Sun, Moon } from 'lucide-react'
import { useQbTheme } from '@/lib/qbTheme'
import { whatsappLink } from '@/lib/constants'

// ── Category tree ────────────────────────────────────────────
// icon: a logo in /public, or null for a lettered tile until one is added.
type SubSub = { name: string; slug: string }
type Sub    = { name: string; slug: string; subsubs?: SubSub[] }
type Cat    = { name: string; slug: string; icon: string | null; subs: Sub[] }

const CATEGORIES: Cat[] = [
  { name: 'Hikvision',  slug: 'hikvision',  icon: '/hik.png',
    subs: [
      { name: 'NVR',               slug: 'hikvision-nvr' },
      { name: 'EVR/EDVR',          slug: 'hikvision-evr' },
      { name: 'DVR',               slug: 'hikvision-dvr', subsubs: [{ name: '2MP', slug: 'hikvision-dvr-2mp' }, { name: '5MP', slug: 'hikvision-dvr-5mp' }] },
      { name: 'IP cameras',        slug: 'hikvision-ip' },
      { name: 'Analogue cameras',  slug: 'hikvision-analogue-cameras' },
      { name: 'IP speakers',       slug: 'hikvision-ip-speakers' },
      { name: 'Analogue speakers', slug: 'hikvision-analogue-speakers' },
    ],
  },
  { name: 'Dahua',      slug: 'dahua',      icon: '/dahu.jpg',
    subs: [
      { name: 'NVR',               slug: 'dahua-nvr' },
      { name: 'DVR',               slug: 'dahua-dvr', subsubs: [{ name: '4MP', slug: 'dahua-dvr-4mp' }, { name: '8MP', slug: 'dahua-dvr-8mp' }] },
      { name: 'IP cameras',        slug: 'dahua-ip' },
      { name: 'Analogue cameras',  slug: 'dahua-analogue-cameras' },
      { name: 'IP speakers',       slug: 'dahua-ip-speakers' },
      { name: 'Analogue speakers', slug: 'dahua-analogue-speakers' },
    ],
  },
  { name: 'TP-Link',     slug: 'tp-link',     icon: '/ti.png',    subs: [] },
  { name: 'D-Link',      slug: 'd-link',      icon: '/dlink.png', subs: [] },
  { name: 'Panasonic',   slug: 'panasonic',   icon: '/pana.png',  subs: [] },
  { name: 'Hi-Look',     slug: 'hi-look',     icon: '/hilook-seeklogo.png', subs: [] },
  { name: 'Grandstream', slug: 'grandstream', icon: '/grandstream.png', subs: [] },
  { name: 'Alfama',      slug: 'alfama',      icon: '/LOGO ALFAMA-bsl-rvb.png', subs: [] },
  { name: 'Addressable fire alarm',  slug: 'addressable-fire-alarm',  icon: null, subs: [] },
  { name: 'Conventional fire alarm', slug: 'conventional-fire-alarm', icon: null, subs: [] },
  { name: 'Solar 4G PTZ cameras',    slug: 'solar-4g-ptz',            icon: null, subs: [] },
  { name: 'Wi-Fi cameras',           slug: 'wifi-cameras',            icon: null, subs: [] },
  { name: 'Networking accessories',  slug: 'networking-accessories',  icon: null, subs: [] },
  { name: 'CCTV accessories',        slug: 'cctv-accessories',        icon: null, subs: [] },
]

const NAV_LINKS = [
  { label: 'Home',     href: '/' },
  { label: 'Products', href: '/products' },
  { label: 'About',    href: '/about' },
  { label: 'Contact',  href: '/contact' },
]

const catHref = (slug: string) => `/products?category_id=${slug}`

/** A brand logo on a white tile, or the category's initials while it has none. */
function CatIcon({ cat, size }: { cat: Cat; size: number }) {
  return (
    <span className="flex shrink-0 items-center justify-center overflow-hidden rounded-[9px] bg-white ring-1 ring-black/5"
      style={{ width: size, height: size, padding: 3 }}>
      {cat.icon
        ? <Image src={cat.icon} alt="" width={size} height={size} className="h-full w-full object-contain" />
        : <span className="text-[9px] font-bold text-neutral-500">{cat.name.split(' ').map(w => w[0]).join('').slice(0, 2)}</span>}
    </span>
  )
}

const WhatsAppGlyph = () => (
  <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
    <path d="M17.47 14.38c-.3-.15-1.76-.87-2.03-.97-.27-.1-.47-.15-.67.15-.2.3-.77.97-.94 1.16-.17.2-.35.22-.64.07-.3-.15-1.26-.46-2.39-1.47-.88-.79-1.48-1.76-1.65-2.06-.17-.3-.02-.46.13-.6.13-.14.3-.35.45-.52.15-.18.2-.3.3-.5.1-.2.05-.37-.03-.52-.07-.15-.67-1.6-.92-2.2-.24-.58-.49-.5-.67-.51h-.57c-.2 0-.52.08-.8.37-.27.3-1.04 1.02-1.04 2.48 0 1.46 1.07 2.88 1.21 3.07.15.2 2.1 3.2 5.08 4.49.71.3 1.26.49 1.7.63.71.22 1.36.2 1.87.12.57-.09 1.76-.72 2-1.41.25-.7.25-1.29.18-1.41-.08-.13-.28-.2-.57-.35zM12.05 21.8h-.01a9.87 9.87 0 0 1-5.03-1.38l-.36-.21-3.74.98 1-3.65-.24-.37a9.86 9.86 0 0 1-1.51-5.26c0-5.45 4.44-9.88 9.89-9.88 2.64 0 5.12 1.03 6.99 2.9a9.82 9.82 0 0 1 2.89 6.99c0 5.45-4.44 9.88-9.88 9.88zm8.41-18.3A11.82 11.82 0 0 0 12.05 0C5.5 0 .16 5.34.16 11.89c0 2.1.55 4.14 1.59 5.95L.06 24l6.3-1.65a11.88 11.88 0 0 0 5.68 1.45h.01c6.55 0 11.89-5.34 11.89-11.89 0-3.18-1.24-6.17-3.48-8.41z"/>
  </svg>
)

export default function Navbar() {
  const pathname = usePathname() || '/'
  const router = useRouter()
  const { dark, toggle } = useQbTheme()
  const [hidden,      setHidden]      = useState(false)
  const [megaOpen,    setMegaOpen]    = useState(false)
  const [hoveredCat,  setHoveredCat]  = useState<string | null>(null)
  const [mobileOpen,  setMobileOpen]  = useState(false)
  const [mobileCats,  setMobileCats]  = useState(false)
  const [expandedCat, setExpandedCat] = useState<string | null>(null)
  const [searchOpen,  setSearchOpen]  = useState(false)
  const [query,       setQuery]       = useState('')
  const lastY = useRef(0)
  const closeTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Tuck the bar away while scrolling down a long page; bring it back on the way up.
  useEffect(() => {
    const onScroll = () => {
      const y = window.scrollY
      setHidden(y > 160 && y > lastY.current)
      lastY.current = y
    }
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [])

  useEffect(() => { setMobileOpen(false); setMegaOpen(false) }, [pathname])

  // A short delay lets the pointer travel from the trigger into the panel.
  const openMega  = () => { if (closeTimer.current) clearTimeout(closeTimer.current); setMegaOpen(true) }
  const closeMega = () => { closeTimer.current = setTimeout(() => { setMegaOpen(false); setHoveredCat(null) }, 140) }

  const submitSearch = (e: React.FormEvent) => {
    e.preventDefault()
    const q = query.trim()
    if (!q) return
    router.push(`/products?search=${encodeURIComponent(q)}`)
    setSearchOpen(false); setQuery('')
  }

  const hovCat = CATEGORIES.find(c => c.slug === hoveredCat)
  const isActive = (href: string) => href === '/' ? pathname === '/' : pathname.startsWith(href)

  return (
    <header className="sticky top-0 z-50 px-3 pt-3 transition-transform duration-300 ease-out sm:px-5"
      style={{ transform: hidden && !mobileOpen && !megaOpen ? 'translateY(-120%)' : 'none' }}>
      <nav aria-label="Main" className="glass-strong mx-auto max-w-6xl rounded-[22px] sm:rounded-full">
        <div className="flex h-14 items-center gap-2 pl-3 pr-2 sm:pl-4">

          {/* Wordmark */}
          <Link href="/" className="mr-2 flex shrink-0 items-center gap-2.5" aria-label="QBNET TECH SOLUTIONS home">
            <QbnetLogo size={34} radius={10} />
            <span className="text-[17px] font-bold leading-none tracking-tight text-qb-text">QBNET<span className="font-medium text-qb-sub"> Tech Solutions</span></span>
          </Link>

          {/* Desktop links */}
          <div className="hidden flex-1 items-center justify-center gap-1 lg:flex">
            {NAV_LINKS.map(({ label, href }) => (
              <Link key={href} href={href} aria-current={isActive(href) ? 'page' : undefined}
                className={`rounded-full px-3.5 py-1.5 text-[15px] transition-colors ${isActive(href) ? 'bg-qb-fill font-semibold text-qb-text' : 'text-qb-sub hover:text-qb-text'}`}>
                {label}
              </Link>
            ))}

            <div className="relative" onMouseEnter={openMega} onMouseLeave={closeMega}>
              <button type="button" aria-expanded={megaOpen} onClick={() => setMegaOpen(o => !o)}
                className={`flex items-center gap-1 rounded-full px-3.5 py-1.5 text-[15px] transition-colors ${megaOpen ? 'text-qb-text' : 'text-qb-sub hover:text-qb-text'}`}>
                Categories <ChevronDown size={15} className={`transition-transform ${megaOpen ? 'rotate-180' : ''}`} />
              </button>

              {megaOpen && (
                <div className="glass-strong absolute left-1/2 top-[calc(100%+12px)] -translate-x-1/2 overflow-hidden rounded-3xl"
                  style={{ width: hovCat && hovCat.subs.length ? 640 : 320, transition: 'width 0.2s ease', animation: 'qb-rise 0.18s ease both' }}
                  onMouseEnter={openMega} onMouseLeave={closeMega}>
                  <div className="flex">
                    <div className="w-[320px] shrink-0 p-2.5">
                      <div className="max-h-[380px] overflow-y-auto">
                        {CATEGORIES.map(cat => (
                          <Link key={cat.slug} href={catHref(cat.slug)} onMouseEnter={() => setHoveredCat(cat.slug)}
                            className={`flex items-center gap-3 rounded-xl px-2.5 py-2 text-[15px] transition-colors ${hoveredCat === cat.slug ? 'bg-qb-fill text-qb-text' : 'text-qb-sub'}`}>
                            <CatIcon cat={cat} size={28} />
                            <span className="flex-1">{cat.name}</span>
                            {cat.subs.length > 0 && <ChevronRight size={15} className="text-qb-faint" />}
                          </Link>
                        ))}
                      </div>
                      <Link href="/products" className="mt-1 block rounded-xl px-2.5 py-2.5 text-[15px] font-semibold text-qb-accent hover:bg-qb-fill">
                        See all products
                      </Link>
                    </div>

                    {hovCat && hovCat.subs.length > 0 && (
                      <div className="flex-1 border-l border-qb-separator p-4">
                        <div className="mb-3 flex items-center gap-3">
                          <CatIcon cat={hovCat} size={40} />
                          <div>
                            <div className="font-semibold text-qb-text">{hovCat.name}</div>
                            <div className="text-[13px] text-qb-sub">{hovCat.subs.length} ranges</div>
                          </div>
                        </div>
                        {hovCat.subs.map(sub => (
                          <div key={sub.slug} className="flex items-center justify-between rounded-xl px-2.5 py-2 hover:bg-qb-fill">
                            <Link href={catHref(sub.slug)} className="flex-1 text-[15px] text-qb-text">{sub.name}</Link>
                            {sub.subsubs && (
                              <span className="flex gap-1.5">
                                {sub.subsubs.map(ss => (
                                  <Link key={ss.slug} href={catHref(ss.slug)}
                                    className="rounded-full border border-qb-border px-2 py-0.5 text-[12px] font-medium text-qb-sub hover:border-qb-accent hover:text-qb-accent">
                                    {ss.name}
                                  </Link>
                                ))}
                              </span>
                            )}
                          </div>
                        ))}
                      </div>
                    )}
                  </div>
                </div>
              )}
            </div>
          </div>

          {/* Actions */}
          <div className="ml-auto flex items-center gap-1.5">
            {searchOpen ? (
              <form onSubmit={submitSearch} className="flex items-center gap-1" role="search">
                <input autoFocus type="search" value={query} onChange={e => setQuery(e.target.value)}
                  placeholder="Search products" aria-label="Search products"
                  className="qb-field !w-40 !rounded-full !py-1.5 sm:!w-56" />
                <button type="button" aria-label="Close search" onClick={() => { setSearchOpen(false); setQuery('') }} className="qb-icon-btn"><X size={16} /></button>
              </form>
            ) : (
              <button type="button" aria-label="Search products" onClick={() => setSearchOpen(true)} className="qb-icon-btn"><Search size={16} /></button>
            )}
            <button type="button" onClick={toggle} aria-label={dark ? 'Switch to light mode' : 'Switch to dark mode'} className="qb-icon-btn">
              {dark ? <Sun size={16} /> : <Moon size={16} />}
            </button>
            <a href={whatsappLink()} target="_blank" rel="noopener noreferrer"
              className="btn-whatsapp hidden !px-4 !py-2 !text-[15px] md:inline-flex">
              <WhatsAppGlyph /> WhatsApp
            </a>
            <button type="button" onClick={() => setMobileOpen(o => !o)} aria-expanded={mobileOpen} aria-label={mobileOpen ? 'Close menu' : 'Open menu'}
              className="qb-icon-btn lg:hidden">
              {mobileOpen ? <X size={17} /> : <Menu size={17} />}
            </button>
          </div>
        </div>

        {/* Mobile menu */}
        {mobileOpen && (
          <div className="max-h-[75vh] overflow-y-auto border-t border-qb-separator px-2 pb-3 pt-2 lg:hidden" style={{ animation: 'qb-rise 0.18s ease both' }}>
            {NAV_LINKS.map(({ label, href }) => (
              <Link key={href} href={href} aria-current={isActive(href) ? 'page' : undefined}
                className={`block rounded-xl px-3 py-2.5 text-[17px] ${isActive(href) ? 'bg-qb-fill font-semibold text-qb-text' : 'text-qb-text'}`}>
                {label}
              </Link>
            ))}
            <button type="button" onClick={() => setMobileCats(o => !o)} aria-expanded={mobileCats}
              className="flex w-full items-center justify-between rounded-xl px-3 py-2.5 text-[17px] text-qb-text">
              Categories <ChevronDown size={17} className={`text-qb-sub transition-transform ${mobileCats ? 'rotate-180' : ''}`} />
            </button>
            {mobileCats && (
              <div className="pb-1 pl-1">
                {CATEGORIES.map(cat => (
                  <div key={cat.slug}>
                    <div className="flex items-center">
                      <Link href={catHref(cat.slug)} className="flex flex-1 items-center gap-3 rounded-xl px-2.5 py-2 text-[15px] text-qb-text">
                        <CatIcon cat={cat} size={26} />{cat.name}
                      </Link>
                      {cat.subs.length > 0 && (
                        <button type="button" aria-label={`Show ${cat.name} ranges`} onClick={() => setExpandedCat(expandedCat === cat.slug ? null : cat.slug)}
                          className="qb-icon-btn !h-8 !w-8 !bg-transparent">
                          <ChevronRight size={15} className={`transition-transform ${expandedCat === cat.slug ? 'rotate-90' : ''}`} />
                        </button>
                      )}
                    </div>
                    {expandedCat === cat.slug && (
                      <div className="ml-12 pb-1">
                        {cat.subs.map(sub => (
                          <Link key={sub.slug} href={catHref(sub.slug)} className="block rounded-lg px-2 py-1.5 text-[15px] text-qb-sub">{sub.name}</Link>
                        ))}
                      </div>
                    )}
                  </div>
                ))}
              </div>
            )}
            <a href={whatsappLink()} target="_blank" rel="noopener noreferrer" className="btn-whatsapp mt-2 w-full">
              <WhatsAppGlyph /> Chat on WhatsApp
            </a>
          </div>
        )}
      </nav>
    </header>
  )
}
