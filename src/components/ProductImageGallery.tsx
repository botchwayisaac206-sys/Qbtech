'use client'

import { useEffect, useState } from 'react'
import Image from 'next/image'
import { ChevronLeft, ChevronRight, Package, X } from 'lucide-react'

interface Props { images: string[]; title: string }

/** Main photo, thumbnails, and a full-screen view with keyboard support. */
export default function ProductImageGallery({ images, title }: Props) {
  const [active, setActive] = useState(0)
  const [zoomed, setZoomed] = useState(false)
  const step = (d: number) => setActive(i => (i + d + images.length) % images.length)

  useEffect(() => {
    if (!zoomed) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setZoomed(false)
      if (e.key === 'ArrowLeft') step(-1)
      if (e.key === 'ArrowRight') step(1)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  })

  if (!images.length) {
    return (
      <div className="glass flex aspect-[4/3] items-center justify-center text-qb-faint">
        <Package size={56} strokeWidth={1.3} />
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-3 lg:sticky lg:top-24 lg:self-start">
      <button type="button" onClick={() => setZoomed(true)} aria-label="View photo full screen"
        className="glass relative aspect-[4/3] cursor-zoom-in overflow-hidden !bg-white">
        <Image key={active} src={images[active]} alt={title} fill className="object-contain p-6"
          sizes="(max-width: 1024px) 100vw, 50vw" priority />
        {images.length > 1 && (
          <span className="absolute bottom-3 right-3 rounded-full bg-black/55 px-2.5 py-1 text-[13px] font-medium text-white backdrop-blur" style={{ fontVariantNumeric: 'tabular-nums' }}>
            {active + 1} of {images.length}
          </span>
        )}
      </button>

      {images.length > 1 && (
        <div className="flex gap-2 overflow-x-auto pb-1">
          {images.map((img, i) => (
            <button key={i} type="button" onClick={() => setActive(i)} aria-label={`Photo ${i + 1}`} aria-current={i === active}
              className={`relative h-16 w-16 shrink-0 overflow-hidden rounded-xl bg-white transition-all ${i === active ? 'ring-2 ring-qb-accent' : 'opacity-70 ring-1 ring-black/5 hover:opacity-100'}`}>
              <Image src={img} alt="" fill className="object-contain p-1" sizes="64px" />
            </button>
          ))}
        </div>
      )}

      {zoomed && (
        <div role="dialog" aria-modal="true" aria-label={title}
          className="fixed inset-0 z-[60] flex items-center justify-center bg-black/85 p-4 backdrop-blur-md"
          onClick={() => setZoomed(false)}>
          <div className="relative aspect-[4/3] w-full max-w-4xl" onClick={e => e.stopPropagation()}>
            <Image src={images[active]} alt={title} fill className="object-contain" sizes="90vw" />
          </div>
          <button type="button" onClick={() => setZoomed(false)} aria-label="Close"
            className="absolute right-5 top-5 flex h-10 w-10 items-center justify-center rounded-full bg-white/15 text-white hover:bg-white/25"><X size={20} /></button>
          {images.length > 1 && (
            <>
              <button type="button" aria-label="Previous photo" onClick={e => { e.stopPropagation(); step(-1) }}
                className="absolute left-4 top-1/2 flex h-11 w-11 -translate-y-1/2 items-center justify-center rounded-full bg-white/15 text-white hover:bg-white/25"><ChevronLeft size={22} /></button>
              <button type="button" aria-label="Next photo" onClick={e => { e.stopPropagation(); step(1) }}
                className="absolute right-4 top-1/2 flex h-11 w-11 -translate-y-1/2 items-center justify-center rounded-full bg-white/15 text-white hover:bg-white/25"><ChevronRight size={22} /></button>
            </>
          )}
        </div>
      )}
    </div>
  )
}
