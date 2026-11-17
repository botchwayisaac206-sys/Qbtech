import type { Metadata } from 'next'
import { notFound } from 'next/navigation'
import Image from 'next/image'
import Link from 'next/link'
import { supabase } from '@/lib/supabase'
import { ChevronRight, Phone, Check } from 'lucide-react'
import ProductImageGallery from '@/components/ProductImageGallery'
import ProductCard from '@/components/ProductCard'
import { CONTACT, whatsappLink } from '@/lib/constants'

export async function generateMetadata(
  { params }: { params: Promise<{ brand: string; id: string }> }
): Promise<Metadata> {
  const { brand: rawBrand, id } = await params
  const brand = decodeURIComponent(rawBrand)
  const { data } = await supabase.from('products').select('title, description, model_number, images, price').eq('id', id).limit(1)
  const p = data?.[0]
  if (!p) return { title: 'Product not found' }

  const title = `${p.title}, ${brand}`
  const description = p.description
    ? `${p.description.slice(0, 150)}... Buy ${p.title} (${p.model_number}) from QBNET TECH. ${p.price ? `GH₵ ${p.price.toLocaleString()}.` : ''} Nationwide delivery.`
    : `Buy ${p.title} (${p.model_number}) from QBNET TECH. Genuine ${brand} products with nationwide delivery.`
  const image = p.images?.[0]

  return {
    title,
    description,
    keywords: [p.title, p.model_number, brand, 'Ghana', 'buy', 'price', 'QBNET TECH'],
    openGraph: {
      title,
      description,
      url: `https://www.qbnettech.com/products/${encodeURIComponent(brand)}/${id}`,
      images: image ? [{ url: image, alt: p.title }] : [{ url: '/preview.jpg' }],
      type: 'website',
    },
    twitter: { card: 'summary_large_image', title, description, images: image ? [image] : ['/preview.jpg'] },
    alternates: { canonical: `https://www.qbnettech.com/products/${encodeURIComponent(brand)}/${id}` },
  }
}

const brandLogos: Record<string, string> = {
  'Hikvision': '/hik.png', 'Dahua': '/dahu.jpg', 'TP-Link': '/ti.png',
  'Hi-Look': '/hi-look.png', 'Grandstream': '/grandstream.png', 'Alfama': '/LOGO ALFAMA-bsl-rvb.png',
  'D-Link': '/dlink.png', 'Panasonic': '/pana.png',
}

const PROMISES = ['Free delivery in Ghana', 'Warranty included', 'Installation available']

export default async function ProductPage({
  params,
}: {
  params: Promise<{ brand: string; id: string }>
}) {
  // Next.js 15+: params is a Promise and must be awaited.
  const { id } = await params

  const { data: rows, error } = await supabase
    .from('products')
    .select('*')
    .eq('id', id)
    .limit(1)

  if (error?.message) console.error('Supabase error:', error.message)

  const product = rows?.[0] ?? null
  if (!product) notFound()

  const { data: related } = await supabase
    .from('products')
    .select('*')
    .eq('brand', product.brand)
    .eq('in_stock', true)
    .neq('id', id)
    .limit(4)

  const waUrl  = whatsappLink(`Hello, I'm interested in the ${product.title} (${product.model_number}). Please send pricing and availability.`)
  const logo   = brandLogos[product.brand]
  const images = (product.images || []).filter(Boolean)
  const specs  = product.specifications && Object.keys(product.specifications).length > 0
    ? product.specifications as Record<string, string> : null

  return (
    <div className="px-5 pb-24 pt-8">
      <div className="mx-auto max-w-6xl">
        <nav aria-label="Breadcrumb" className="mb-6 flex flex-wrap items-center gap-1 text-[14px] text-qb-sub">
          <Link href="/" className="hover:text-qb-text">Home</Link>
          <ChevronRight size={14} className="text-qb-faint" />
          <Link href="/products" className="hover:text-qb-text">Products</Link>
          <ChevronRight size={14} className="text-qb-faint" />
          <Link href={`/products?brand=${encodeURIComponent(product.brand)}`} className="hover:text-qb-text">{product.brand}</Link>
          <ChevronRight size={14} className="text-qb-faint" />
          <span className="max-w-[220px] truncate text-qb-text" aria-current="page">{product.title}</span>
        </nav>

        <div className="mb-16 grid gap-10 lg:grid-cols-2 lg:gap-14">
          <ProductImageGallery images={images} title={product.title} />

          <div className="flex flex-col">
            <div className="mb-4 flex items-center gap-3">
              <span className="flex h-11 w-11 shrink-0 items-center justify-center overflow-hidden rounded-xl bg-white p-1.5 ring-1 ring-black/5">
                {logo
                  ? <Image src={logo} alt="" width={32} height={32} className="h-full w-full object-contain" />
                  : <span className="text-center text-[9px] font-bold leading-tight text-neutral-600">{product.brand}</span>}
              </span>
              <div className="text-[15px]">
                <div className="font-semibold text-qb-text">{product.brand}</div>
                <div className="text-qb-sub">{product.model_number}</div>
              </div>
            </div>

            <h1 className="qb-display text-[2rem] sm:text-[2.5rem]">{product.title}</h1>

            <div className="mt-4 flex flex-wrap items-center gap-2 text-[14px]">
              <span className={`inline-flex items-center gap-1.5 rounded-full px-3 py-1 font-medium ${product.in_stock ? 'bg-qb-fill text-qb-green' : 'bg-qb-fill text-qb-red'}`}>
                <span className="h-1.5 w-1.5 rounded-full bg-current" aria-hidden />
                {product.in_stock ? 'In stock' : 'Out of stock'}
              </span>
              {product.category && <span className="rounded-full bg-qb-fill px-3 py-1 text-qb-sub">{product.category}</span>}
            </div>

            <div className="mt-6 border-b border-qb-separator pb-6">
              {product.price
                ? <p className="text-[2.2rem] font-semibold leading-none tracking-tight text-qb-text">GH₵ {product.price.toLocaleString()}</p>
                : <p className="text-[18px] text-qb-sub">Price on request. Message us for a quote.</p>}
            </div>

            {product.description && (
              <p className="mt-6 text-[16px] leading-relaxed text-qb-sub">{product.description}</p>
            )}

            {specs && (
              <dl className="mt-6 grid grid-cols-2 gap-2">
                {Object.entries(specs).slice(0, 4).map(([k, v]) => (
                  <div key={k} className="rounded-2xl bg-qb-fill p-3">
                    <dt className="text-[13px] text-qb-muted">{k}</dt>
                    <dd className="text-[15px] font-medium text-qb-text">{v}</dd>
                  </div>
                ))}
              </dl>
            )}

            <div className="mt-8 flex flex-col gap-3 sm:flex-row">
              <a href={waUrl} target="_blank" rel="noopener noreferrer" className="btn-whatsapp flex-1 !py-3.5 !text-[17px]">Order on WhatsApp</a>
              <a href={`tel:${CONTACT.phones[0].tel}`} className="btn-glass !py-3.5 !text-[17px]"><Phone size={17} /> Call us</a>
            </div>

            <ul className="mt-5 flex flex-wrap gap-x-5 gap-y-2">
              {PROMISES.map(item => (
                <li key={item} className="flex items-center gap-2 text-[14px] text-qb-sub">
                  <span className="flex h-5 w-5 items-center justify-center rounded-full bg-qb-accent text-white"><Check size={12} strokeWidth={3} /></span>
                  {item}
                </li>
              ))}
            </ul>
          </div>
        </div>

        {specs && (
          <section className="glass mb-16 p-6 sm:p-8">
            <h2 className="text-[22px] font-semibold tracking-tight text-qb-text">Specifications</h2>
            <dl className="mt-5 divide-y divide-[var(--qb-separator)]">
              {Object.entries(specs).map(([k, v]) => (
                <div key={k} className="grid grid-cols-[minmax(0,1fr)_minmax(0,1.6fr)] gap-4 py-3 text-[15px]">
                  <dt className="text-qb-sub">{k}</dt>
                  <dd className="text-qb-text">{v}</dd>
                </div>
              ))}
            </dl>
          </section>
        )}

        {related && related.length > 0 && (
          <section>
            <div className="mb-6 flex items-end justify-between gap-4">
              <h2 className="section-title text-[1.75rem]">More from {product.brand}</h2>
              <Link href={`/products?brand=${encodeURIComponent(product.brand)}`} className="flex items-center gap-1 text-[16px] font-medium text-qb-accent">
                See all <ChevronRight size={17} />
              </Link>
            </div>
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
              {related.map((p: any) => <ProductCard key={p.id} product={p} />)}
            </div>
          </section>
        )}
      </div>
    </div>
  )
}
