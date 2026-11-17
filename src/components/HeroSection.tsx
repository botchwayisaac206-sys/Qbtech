'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import Image from 'next/image'
import { whatsappLink } from '@/lib/constants'

// Product cut-outs shown in the lens, in order.
const SLIDES = [
  '/heroproducts/1_0_01_04_40077_399911328-Black_crop_thumb.png',
  '/heroproducts/1_0_01_07_15908_729347164_crop_thumb.png',
  '/heroproducts/1_0_01_07_15908_729347579_crop_thumb.png',
  '/heroproducts/1_0_01_21_10315_528077270_crop_thumb.png',
  '/heroproducts/1_0_01_21_10315_528077271_crop_thumb.png',
  '/heroproducts/DS-2CD2T47G2-L_image_1.png',
  '/heroproducts/DS-2CD2T47G2-L_image_3.png',
  '/heroproducts/b1.jpg',
  '/heroproducts/OII (2).png',
  '/heroproducts/OIO (2).png',
]

export default function HeroSection() {
  const [current, setCurrent] = useState(0)
  const [paused, setPaused] = useState(false)

  // Advance every few seconds, unless the visitor prefers reduced motion or
  // has picked a slide themselves.
  useEffect(() => {
    if (paused || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
    const t = setInterval(() => setCurrent(c => (c + 1) % SLIDES.length), 4000)
    return () => clearInterval(t)
  }, [paused])

  return (
    <section className="relative overflow-hidden">
      <div className="mx-auto grid max-w-6xl items-center gap-12 px-5 pb-16 pt-12 sm:pt-20 lg:grid-cols-[1.05fr_1fr] lg:gap-8 lg:pb-24">

        <div style={{ animation: 'qb-rise 0.7s cubic-bezier(0.22,1,0.36,1) both' }}>
          <h1 className="qb-display text-[2.6rem] sm:text-[3.6rem] lg:text-[4.1rem]">
            Security and networking gear, ready to install.
          </h1>
          <p className="mt-5 max-w-[34rem] text-[18px] leading-relaxed text-qb-sub">
            Cameras, recorders, access control, fire alarms and network equipment from
            Hikvision, Dahua, TP-Link and more. Wholesale or retail, with installation when you need it.
          </p>
          <div className="mt-8 flex flex-col gap-3 sm:flex-row">
            <Link href="/products" className="btn-primary !px-7 !py-3.5 !text-[17px]">Browse products</Link>
            <a href={whatsappLink('Hello, I would like a free consultation.')} target="_blank" rel="noopener noreferrer"
              className="btn-glass !px-7 !py-3.5 !text-[17px]">
              Get a free consultation
            </a>
          </div>
        </div>

        {/* The lens: products fade through a frosted disc, a nod to the cameras we sell. */}
        <div className="relative mx-auto w-full max-w-[460px]" onMouseEnter={() => setPaused(true)} onMouseLeave={() => setPaused(false)}>
          <div aria-hidden className="absolute inset-[-12%] rounded-full opacity-80 blur-3xl"
            style={{ background: 'radial-gradient(circle at 50% 45%, color-mix(in srgb, var(--qb-accent) 32%, transparent), transparent 65%)' }} />
          <div className="glass relative aspect-square !rounded-full"
            style={{ boxShadow: 'var(--qb-shadow), inset 0 1px 0 var(--qb-glass-edge), inset 0 0 0 10px color-mix(in srgb, var(--qb-text) 4%, transparent)' }}>
            <div aria-hidden className="absolute inset-[9%] rounded-full border border-qb-separator" />
            {SLIDES.map((src, i) => (
              <div key={src} className="absolute inset-[16%]"
                style={{
                  opacity: i === current ? 1 : 0,
                  transform: i === current ? 'scale(1)' : 'scale(0.94)',
                  transition: 'opacity 0.8s ease, transform 0.8s cubic-bezier(0.22,1,0.36,1)',
                }}>
                <Image src={src} alt={i === current ? 'Featured product' : ''} fill sizes="(max-width: 1024px) 70vw, 340px"
                  className="object-contain drop-shadow-[0_18px_30px_rgba(0,0,0,0.25)]" priority={i === 0} />
              </div>
            ))}
          </div>
          <div className="mt-6 flex justify-center gap-1.5" role="tablist" aria-label="Featured products">
            {SLIDES.map((_, i) => (
              <button key={i} type="button" role="tab" aria-selected={i === current} aria-label={`Show product ${i + 1}`}
                onClick={() => { setCurrent(i); setPaused(true) }}
                className="h-2 rounded-full transition-all duration-300"
                style={{ width: i === current ? 22 : 8, background: i === current ? 'var(--qb-accent)' : 'var(--qb-fill)' }} />
            ))}
          </div>
        </div>
      </div>
    </section>
  )
}
