import { supabase } from '@/lib/supabase'
import ProductCard from '@/components/ProductCard'
import { CONTACT } from '@/lib/constants'
import type { Metadata } from 'next'

// Next.js 15: searchParams arrives as a Promise and must be awaited.
interface PageProps {
  searchParams: Promise<{ q?: string }>
}

export async function generateMetadata({ searchParams }: PageProps): Promise<Metadata> {
  const { q } = await searchParams
  return { title: q ? `Search: "${q}"` : 'Search products' }
}

async function searchProducts(query: string) {
  // Commas, parentheses and quotes are PostgREST filter syntax inside .or();
  // left in, a search could add conditions of its own to the query.
  const term = query.replace(/[,()"'\\]/g, ' ').trim()
  if (!term) return []

  const { data } = await supabase
    .from('products')
    .select('*')
    .or(`title.ilike.%${term}%,model_number.ilike.%${term}%,description.ilike.%${term}%`)
    .order('created_at', { ascending: false })
    .limit(24)

  return data || []
}

export default async function SearchPage({ searchParams }: PageProps) {
  const query = (await searchParams).q || ''
  const results = query ? await searchProducts(query) : []

  return (
    <div className="px-4 pb-24 pt-8 sm:px-5 sm:pt-12">
      <div className="mx-auto max-w-6xl">
        <h1 className="section-title break-words text-[2rem] sm:text-[2.5rem]">
          {query ? <>Results for &ldquo;{query}&rdquo;</> : 'Search products'}
        </h1>
        {query && (
          <p className="mt-2 text-[17px] text-qb-sub">{results.length} result{results.length !== 1 ? 's' : ''}</p>
        )}

        {/* A plain form, so it works before any script loads. Full width on a phone. */}
        <form action="/search" method="get" role="search" className="mt-6 flex max-w-xl gap-2">
          <label className="relative min-w-0 flex-1">
            <span className="sr-only">Search products</span>
            <input type="search" name="q" defaultValue={query} enterKeyHint="search"
              placeholder="Product name or model number" className="qb-field !w-full !rounded-full" />
          </label>
          <button type="submit" className="btn-primary shrink-0 !px-5 !py-2.5 !text-[15px]">Search</button>
        </form>

        <div className="mt-8 sm:mt-10">
          {!query && (
            <div className="glass p-8 text-center text-[17px] text-qb-sub sm:p-12">
              Search by product name or model number.
            </div>
          )}

          {query && results.length === 0 && (
            <div className="glass p-8 text-center sm:p-12">
              <h2 className="break-words text-[20px] font-semibold text-qb-text">Nothing matches &ldquo;{query}&rdquo;</h2>
              <p className="mx-auto mt-2 max-w-md text-[16px] text-qb-sub">
                Try a model number, such as DS-2CD2143G2-I, or a shorter name. We may also have it in the shop, so give us a call.
              </p>
              <a href={`tel:${CONTACT.phones[0].tel}`} className="btn-primary mt-6">Call {CONTACT.phones[0].display}</a>
            </div>
          )}

          {results.length > 0 && (
            <div className="grid grid-cols-1 gap-5 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
              {results.map(product => <ProductCard key={product.id} product={product} />)}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
