'use client'

import { useState, useEffect, Suspense } from 'react'
import { useSearchParams, useRouter } from 'next/navigation'
import ProductCard from '@/components/ProductCard'
import CategorySidebar from '@/components/CategorySidebar'
import { supabase } from '@/lib/supabase'
import { Search, X, SlidersHorizontal } from 'lucide-react'

// All slugs and their children — used to match parent-category filter
// e.g. clicking "Hikvision" shows products with category_id of hikvision, hikvision-nvr, hikvision-dvr-2mp, etc.
const SLUG_CHILDREN: Record<string, string[]> = {
  'hikvision':     ['hikvision', 'hikvision-nvr', 'hikvision-evr', 'hikvision-dvr', 'hikvision-dvr-2mp', 'hikvision-dvr-5mp', 'hikvision-ip', 'hikvision-analogue-cameras', 'hikvision-ip-speakers', 'hikvision-analogue-speakers'],
  'hikvision-dvr': ['hikvision-dvr', 'hikvision-dvr-2mp', 'hikvision-dvr-5mp'],
  'dahua':         ['dahua', 'dahua-nvr', 'dahua-dvr', 'dahua-dvr-4mp', 'dahua-dvr-8mp', 'dahua-ip', 'dahua-analogue-cameras', 'dahua-ip-speakers', 'dahua-analogue-speakers'],
  'dahua-dvr':     ['dahua-dvr', 'dahua-dvr-4mp', 'dahua-dvr-8mp'],
}
function getSlugsToMatch(slug: string): string[] {
  return SLUG_CHILDREN[slug] || [slug]
}

// Brand → category_id slug mapping (so brand filter also matches category_id)
const BRAND_SLUGS: Record<string, string[]> = {
  'Hikvision':  ['hikvision', 'hikvision-nvr', 'hikvision-evr', 'hikvision-dvr', 'hikvision-dvr-2mp', 'hikvision-dvr-5mp', 'hikvision-ip', 'hikvision-analogue-cameras', 'hikvision-ip-speakers', 'hikvision-analogue-speakers'],
  'Dahua':      ['dahua', 'dahua-nvr', 'dahua-dvr', 'dahua-dvr-4mp', 'dahua-dvr-8mp', 'dahua-ip', 'dahua-analogue-cameras', 'dahua-ip-speakers', 'dahua-analogue-speakers'],
  'TP-Link':    ['tp-link'],
  'D-Link':     ['d-link'],
  'Panasonic':  ['panasonic'],
}


function ProductsContent() {
  const searchParams = useSearchParams()
  const router       = useRouter()

  const [products,    setProducts]    = useState<any[]>([])
  const [filtered,    setFiltered]    = useState<any[]>([])
  const [loading,     setLoading]     = useState(true)
  const [search,      setSearch]      = useState(searchParams.get('search') || '')
  const [brand,       setBrand]       = useState(searchParams.get('brand') || '')
  const [inStockOnly, setInStockOnly] = useState(false)
  const [sidebarOpen, setSidebarOpen] = useState(false)

  const categoryId = searchParams.get('category_id') || ''

  // Load all products once
  useEffect(() => {
    supabase.from('products').select('*').order('created_at', { ascending: false })
      .then(({ data }) => { setProducts(data || []); setLoading(false) })
  }, [])

  // Sync search + brand from URL
  useEffect(() => {
    setSearch(searchParams.get('search') || '')
    setBrand(searchParams.get('brand') || '')
  }, [searchParams])

  // Filter logic
  useEffect(() => {
    let r = [...products]

    // Text search — matches title, model, description, brand, category_id
    if (search) {
      const q = search.toLowerCase()
      r = r.filter(p =>
        [p.title, p.model_number, p.description, p.brand, p.category_id]
          .filter(Boolean).join(' ').toLowerCase().includes(q)
      )
    }

    // Brand filter — also matches category_id slugs for brand-named categories
    if (brand) {
      const brandSlugs = BRAND_SLUGS[brand] || []
      r = r.filter(p =>
        p.brand === brand ||
        (p.category_id && brandSlugs.includes(p.category_id))
      )
    }

    // Category filter — matches selected slug AND all its children slugs
    if (categoryId) {
      const slugsToMatch = getSlugsToMatch(categoryId)
      r = r.filter(p => p.category_id && slugsToMatch.includes(p.category_id))
    }

    if (inStockOnly) r = r.filter(p => p.in_stock)

    setFiltered(r)
  }, [search, brand, categoryId, inStockOnly, products])

  const applyFilter = (key: string, val: string) => {
    const p = new URLSearchParams(searchParams.toString())
    val ? p.set(key, val) : p.delete(key)
    router.push(`/products?${p.toString()}`, { scroll: false })
  }

  const clearAll = () => { setInStockOnly(false); router.push('/products', { scroll: false }) }

  const hasFilters = search || brand || categoryId || inStockOnly

  // Page title based on active filters
  const pageTitle = (() => {
    if (brand) return brand
    if (categoryId) {
      // Find name from slug
      const allCats = [
        { name:'Hikvision',slug:'hikvision'},{name:'NVR',slug:'hikvision-nvr'},{name:'EVR/EDVR',slug:'hikvision-evr'},
        {name:'DVR',slug:'hikvision-dvr'},{name:'2MP DVR',slug:'hikvision-dvr-2mp'},{name:'5MP DVR',slug:'hikvision-dvr-5mp'},
        {name:'IP Cameras',slug:'hikvision-ip'},{name:'Analogue Cameras',slug:'hikvision-analogue-cameras'},
        {name:'IP Speakers',slug:'hikvision-ip-speakers'},{name:'Analogue Speakers',slug:'hikvision-analogue-speakers'},
        {name:'Dahua',slug:'dahua'},{name:'NVR',slug:'dahua-nvr'},
        {name:'DVR',slug:'dahua-dvr'},{name:'4MP DVR',slug:'dahua-dvr-4mp'},{name:'8MP DVR',slug:'dahua-dvr-8mp'},
        {name:'IP Cameras',slug:'dahua-ip'},{name:'Analogue Cameras',slug:'dahua-analogue-cameras'},
        {name:'IP Speakers',slug:'dahua-ip-speakers'},{name:'Analogue Speakers',slug:'dahua-analogue-speakers'},
        {name:'TP-Link',slug:'tp-link'},{name:'D-Link',slug:'d-link'},{name:'Panasonic',slug:'panasonic'},
        {name:'Hi-Look',slug:'hi-look'},{name:'Grandstream',slug:'grandstream'},{name:'Alfama',slug:'alfama'},
        {name:'Addressable Fire Alarm',slug:'addressable-fire-alarm'},{name:'Conventional Fire Alarm',slug:'conventional-fire-alarm'},
        {name:'Solar 4G PTZ',slug:'solar-4g-ptz'},{name:'WiFi Cameras',slug:'wifi-cameras'},
        {name:'Networking Accessories',slug:'networking-accessories'},{name:'CCTV Accessories',slug:'cctv-accessories'},
      ]
      return allCats.find(c => c.slug === categoryId)?.name || 'Products'
    }
    return 'All products'
  })()

  const chips = [
    brand && { key: 'brand', label: brand, clear: () => { setBrand(''); applyFilter('brand', '') } },
    search && { key: 'search', label: `“${search}”`, clear: () => { setSearch(''); applyFilter('search', '') } },
    categoryId && { key: 'cat', label: pageTitle, clear: () => applyFilter('category_id', '') },
    inStockOnly && { key: 'stock', label: 'In stock only', clear: () => setInStockOnly(false) },
  ].filter(Boolean) as { key: string; label: string; clear: () => void }[]

  return (
    <div className="px-5 pb-24 pt-10">
      <div className="mx-auto max-w-6xl">
        <h1 className="section-title text-[2rem] sm:text-[2.6rem]">{pageTitle}</h1>
        <p className="mt-1 text-[15px] text-qb-sub">
          {loading ? 'Loading products…' : `${filtered.length} product${filtered.length !== 1 ? 's' : ''}`}
        </p>

        {/* Filter bar */}
        <div className="mt-6 flex flex-wrap gap-2">
          <label className="relative min-w-[200px] flex-1">
            <span className="sr-only">Search products</span>
            <Search size={16} className="pointer-events-none absolute left-3.5 top-1/2 -translate-y-1/2 text-qb-faint" />
            <input type="search" placeholder="Search products, models or brands" value={search}
              onChange={e => { setSearch(e.target.value); applyFilter('search', e.target.value) }}
              className="qb-field !rounded-full !pl-10" />
          </label>
          <button type="button" onClick={() => setInStockOnly(!inStockOnly)} aria-pressed={inStockOnly}
            className={`rounded-full px-4 py-2.5 text-[15px] font-medium transition-colors ${inStockOnly ? 'bg-qb-accent text-white' : 'border border-qb-border bg-qb-card text-qb-text'}`}>
            In stock
          </button>
          <button type="button" onClick={() => setSidebarOpen(!sidebarOpen)} aria-expanded={sidebarOpen}
            className="flex items-center gap-2 rounded-full border border-qb-border bg-qb-card px-4 py-2.5 text-[15px] font-medium text-qb-text lg:hidden">
            <SlidersHorizontal size={16} /> Categories
          </button>
        </div>

        {chips.length > 0 && (
          <div className="mt-3 flex flex-wrap items-center gap-2">
            {chips.map(c => (
              <span key={c.key} className="flex items-center gap-1 rounded-full bg-qb-fill py-1 pl-3 pr-1.5 text-[14px] text-qb-text">
                {c.label}
                <button type="button" onClick={c.clear} aria-label={`Remove filter ${c.label}`} className="rounded-full p-1 text-qb-sub hover:bg-qb-fill"><X size={13} /></button>
              </span>
            ))}
            <button type="button" onClick={clearAll} className="px-2 text-[14px] font-medium text-qb-accent">Clear all</button>
          </div>
        )}

        {/* Sidebar + grid */}
        <div className="mt-6 flex items-start gap-6">
          <div className={`w-56 shrink-0 ${sidebarOpen ? 'block' : 'hidden'} lg:sticky lg:top-24 lg:block`}>
            <Suspense fallback={null}>
              <CategorySidebar />
            </Suspense>
          </div>

          <div className="min-w-0 flex-1">
            {loading ? (
              <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3">
                {[...Array(6)].map((_, i) => <div key={i} className="glass h-72 animate-pulse" />)}
              </div>
            ) : filtered.length === 0 ? (
              <div className="glass px-6 py-16 text-center">
                <h2 className="text-[20px] font-semibold text-qb-text">No products match</h2>
                <p className="mt-1 text-[16px] text-qb-sub">Try another category, brand or search term.</p>
                <button type="button" onClick={clearAll} className="btn-primary mt-6">Clear filters</button>
              </div>
            ) : (
              <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3">
                {filtered.map(p => <ProductCard key={p.id} product={p} />)}
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}

export default function ProductsClientContent() {
  return (
    <Suspense fallback={
      <div className="px-5 py-10">
        <div className="mx-auto grid max-w-6xl grid-cols-2 gap-4 lg:grid-cols-3">
          {[...Array(6)].map((_, i) => <div key={i} className="glass h-72 animate-pulse" />)}
        </div>
      </div>
    }>
      <ProductsContent />
    </Suspense>
  )
}
