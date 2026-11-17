'use client'

import { useState, useEffect, useCallback, useRef } from 'react'
import Image from 'next/image'
import Link from 'next/link'
import { Package } from 'lucide-react'
import { whatsappLink } from '@/lib/constants'

interface Product {
  id: string
  title: string
  model_number: string
  description?: string
  price?: number
  brand: string
  images?: string[]
  in_stock: boolean
  [key: string]: any
}

/** A product tile: photo (cycling through extra photos on hover), name, price, and two actions. */
export default function ProductCard({ product }: { product: Product }) {
  const images   = (product.images || []).filter(Boolean)
  const hasMulti = images.length > 1

  const [mounted,  setMounted]  = useState(false)
  const [imgIdx,   setImgIdx]   = useState(0)
  const [imgError, setImgError] = useState(false)
  const timer = useRef<ReturnType<typeof setInterval> | null>(null)

  useEffect(() => { setMounted(true) }, [])

  const stop = useCallback(() => {
    if (timer.current) { clearInterval(timer.current); timer.current = null }
  }, [])

  const start = useCallback(() => {
    if (!hasMulti) return
    stop()
    timer.current = setInterval(() => {
      setImgIdx(i => (i + 1) % images.length)
      setImgError(false)
    }, 2400)
  }, [hasMulti, images.length, stop])

  useEffect(() => () => stop(), [stop])

  const goTo = (i: number, e: React.MouseEvent) => {
    e.preventDefault(); e.stopPropagation()
    setImgIdx(i); setImgError(false); stop()
  }

  const href    = `/products/${encodeURIComponent(product.brand)}/${product.id}`
  const waUrl   = whatsappLink(`Hello, I'm interested in the ${product.title} (${product.model_number}). Can you tell me more?`)
  const src     = mounted ? (images[imgIdx] || '') : (images[0] || '')
  const showImg = !!src && !imgError

  return (
    <article className="glass group flex h-full flex-col overflow-hidden transition-transform duration-300 hover:-translate-y-1"
      onMouseEnter={() => { if (mounted && hasMulti) start() }}
      onMouseLeave={() => { if (mounted) stop() }}>

      <Link href={href} className="relative block aspect-[4/3] overflow-hidden bg-white" tabIndex={-1} aria-hidden>
        {showImg ? (
          <Image key={mounted ? imgIdx : 0} src={src} alt="" fill
            className="object-contain p-4 transition-transform duration-500 group-hover:scale-[1.03]"
            sizes="(max-width: 640px) 100vw, (max-width: 1024px) 50vw, 25vw"
            onError={() => setImgError(true)} />
        ) : (
          <span className="flex h-full items-center justify-center text-neutral-300"><Package size={40} strokeWidth={1.4} /></span>
        )}
        {!product.in_stock && (
          <span className="absolute left-3 top-3 rounded-full bg-black/70 px-2.5 py-1 text-[12px] font-semibold text-white">Out of stock</span>
        )}
        {mounted && hasMulti && (
          <span className="absolute bottom-3 left-1/2 flex -translate-x-1/2 gap-1">
            {images.map((_, i) => (
              <button key={i} type="button" onClick={e => goTo(i, e)} aria-label={`Photo ${i + 1}`}
                className="h-1.5 rounded-full transition-all duration-300"
                style={{ width: i === imgIdx ? 16 : 6, background: i === imgIdx ? 'var(--qb-accent)' : 'rgba(0,0,0,0.2)' }} />
            ))}
          </span>
        )}
      </Link>

      <div className="flex flex-1 flex-col p-4">
        <div className="text-[13px] text-qb-muted">{product.brand}{product.model_number ? ` · ${product.model_number}` : ''}</div>
        <h3 className="mt-1 line-clamp-2 text-[16px] font-semibold leading-snug tracking-tight text-qb-text">
          <Link href={href} className="hover:text-qb-accent">{product.title}</Link>
        </h3>
        {product.description && (
          <p className="mt-1.5 line-clamp-2 text-[14px] leading-relaxed text-qb-sub">{product.description}</p>
        )}
        <div className="mt-auto pt-4">
          {product.price ? (
            <div className="mb-3 text-[19px] font-semibold tracking-tight text-qb-text">GH₵ {product.price.toLocaleString()}</div>
          ) : (
            <div className="mb-3 text-[15px] text-qb-sub">Price on request</div>
          )}
          <div className="flex gap-2">
            <Link href={href} className="btn-glass flex-1 !px-3 !py-2 !text-[15px]">Details</Link>
            <a href={waUrl} target="_blank" rel="noopener noreferrer" className="btn-whatsapp flex-1 !px-3 !py-2 !text-[15px]">Order</a>
          </div>
        </div>
      </div>
    </article>
  )
}
