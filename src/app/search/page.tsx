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
    <div className="px-5 pb-24 pt-12">
      <div className="mx-auto max-w-6xl">
        <h1 className="section-title text-[2rem] sm:text-[2.5rem]">
          {query ? <>Results for &ldquo;{query}&rdquo;</> : 'Search products'}
        </h1>
        {query && (
          <p className="mt-2 text-[17px] text-qb-sub">{results.length} result{results.length !== 1 ? 's' : ''}</p>
        )}

        <div className="mt-10">
          {!query && (
            <div className="glass p-12 text-center text-[17px] text-qb-sub">
              Search by product name or model number with the search button at the top of the page.
            </div>
          )}

          {query && results.length === 0 && (
            <div className="glass p-12 text-center">
              <h2 className="text-[20px] font-semibold text-qb-text">Nothing matches &ldquo;{query}&rdquo;</h2>
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
