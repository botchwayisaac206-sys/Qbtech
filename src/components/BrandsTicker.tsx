'use client'

import Image from 'next/image'
import Link from 'next/link'

const brands = [
  { name: 'Hikvision',   logo: '/hik.png' },
  { name: 'Dahua',       logo: '/dahu.jpg' },
  { name: 'TP-Link',     logo: '/ti.png' },
  { name: 'D-Link',      logo: '/dlink.png' },
  { name: 'Panasonic',   logo: '/pana.png' },
  { name: 'Hi-Look',     logo: '/hilook-seeklogo.png' },
  { name: 'Grandstream', logo: '/grandstream.png' },
  { name: 'Alfama',      logo: '/LOGO ALFAMA-bsl-rvb.png' },
]

// Listed twice so the strip can loop without a seam.
const items = [...brands, ...brands]

/** A slow, pausable strip of the brands we carry, under the navbar. */
export default function BrandsTicker() {
  return (
    <div className="relative mt-3 overflow-hidden py-2"
      style={{ maskImage: 'linear-gradient(90deg, transparent, #000 8%, #000 92%, transparent)', WebkitMaskImage: 'linear-gradient(90deg, transparent, #000 8%, #000 92%, transparent)' }}>
      <style>{`
        @keyframes brandScroll { from { transform: translateX(0); } to { transform: translateX(-50%); } }
        .brands-track { display: flex; gap: 10px; width: max-content; animation: brandScroll 40s linear infinite; }
        .brands-track:hover, .brands-track:focus-within { animation-play-state: paused; }
        @media (prefers-reduced-motion: reduce) { .brands-track { animation: none; } }
      `}</style>
      <div className="brands-track">
        {items.map((brand, i) => (
          <Link key={i} href={`/products?brand=${encodeURIComponent(brand.name)}`} aria-hidden={i >= brands.length || undefined}
            tabIndex={i >= brands.length ? -1 : undefined}
            className="flex shrink-0 items-center gap-2.5 rounded-full border border-qb-border bg-qb-card py-1.5 pl-1.5 pr-4 text-[15px] font-medium text-qb-text transition-colors hover:border-qb-accent">
            <span className="flex h-7 w-7 items-center justify-center overflow-hidden rounded-full bg-white p-1 ring-1 ring-black/5">
              <Image src={brand.logo} alt="" width={22} height={22} className="h-full w-full object-contain" />
            </span>
            {brand.name}
          </Link>
        ))}
      </div>
    </div>
  )
}
