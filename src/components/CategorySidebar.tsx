'use client'

import { useState, useEffect } from 'react'
import Image from 'next/image'
import { useRouter, useSearchParams } from 'next/navigation'
import { ChevronRight } from 'lucide-react'

type SubSub = { name: string; slug: string }
type Sub    = { name: string; slug: string; subsubs?: SubSub[] }
type Cat    = { name: string; slug: string; icon: string | null; subs: Sub[] }

const CATEGORIES: Cat[] = [
  { name: 'Hikvision',  slug: 'hikvision',  icon: '/hik.png',
    subs: [
      { name: 'NVR',              slug: 'hikvision-nvr' },
      { name: 'EVR/EDVR',         slug: 'hikvision-evr' },
      { name: 'DVR',              slug: 'hikvision-dvr', subsubs: [{ name: '2MP', slug: 'hikvision-dvr-2mp' }, { name: '5MP', slug: 'hikvision-dvr-5mp' }] },
      { name: 'IP cameras',       slug: 'hikvision-ip' },
      { name: 'Analogue cameras', slug: 'hikvision-analogue-cameras' },
      { name: 'IP speakers',      slug: 'hikvision-ip-speakers' },
      { name: 'Analogue speakers',slug: 'hikvision-analogue-speakers' },
    ],
  },
  { name: 'Dahua',      slug: 'dahua',      icon: '/dahu.jpg',
    subs: [
      { name: 'NVR',              slug: 'dahua-nvr' },
      { name: 'DVR',              slug: 'dahua-dvr', subsubs: [{ name: '4MP', slug: 'dahua-dvr-4mp' }, { name: '8MP', slug: 'dahua-dvr-8mp' }] },
      { name: 'IP cameras',       slug: 'dahua-ip' },
      { name: 'Analogue cameras', slug: 'dahua-analogue-cameras' },
      { name: 'IP speakers',      slug: 'dahua-ip-speakers' },
      { name: 'Analogue speakers',slug: 'dahua-analogue-speakers' },
    ],
  },
  { name: 'TP-Link',    slug: 'tp-link',    icon: '/ti.png',   subs: [] },
  { name: 'D-Link',     slug: 'd-link',     icon: '/dlink.png',subs: [] },
  { name: 'Panasonic',  slug: 'panasonic',  icon: '/pana.png', subs: [] },
  { name: 'Hi-Look',    slug: 'hi-look',    icon: '/hilook-seeklogo.png',    subs: [] },
  { name: 'Grandstream',slug: 'grandstream',icon: '/grandstream.png', subs: [] },
  { name: 'Alfama',     slug: 'alfama',     icon: '/LOGO ALFAMA-bsl-rvb.png', subs: [] },
  { name: 'Addressable Fire Alarm',  slug: 'addressable-fire-alarm',  icon: null, subs: [] },
  { name: 'Conventional Fire Alarm', slug: 'conventional-fire-alarm', icon: null, subs: [] },
  { name: 'Solar 4G PTZ Cameras',    slug: 'solar-4g-ptz',            icon: null, subs: [] },
  { name: 'WiFi Cameras',            slug: 'wifi-cameras',            icon: null, subs: [] },
  { name: 'Networking Accessories',  slug: 'networking-accessories',  icon: null, subs: [] },
  { name: 'CCTV Accessories',        slug: 'cctv-accessories',        icon: null, subs: [] },
]



// Helper: get all child slugs of a category (for parent-match filtering)
function getDescendantSlugs(cat: Cat): string[] {
  const slugs: string[] = [cat.slug]
  for (const sub of cat.subs) {
    slugs.push(sub.slug)
    for (const ss of sub.subsubs || []) slugs.push(ss.slug)
  }
  return slugs
}

export default function CategorySidebar() {
  const params   = useSearchParams()
  const router   = useRouter()
  const selected = params.get('category_id') || ''
  const [expanded, setExpanded] = useState<string[]>([])

  // Auto-expand tree to show selected item
  useEffect(() => {
    if (!selected) return
    for (const cat of CATEGORIES) {
      if (cat.slug === selected) {
        setExpanded(e => e.includes(cat.slug) ? e : [...e, cat.slug])
        return
      }
      for (const sub of cat.subs) {
        if (sub.slug === selected || sub.subsubs?.some(ss => ss.slug === selected)) {
          setExpanded(e => {
            const next = [...e]
            if (!next.includes(cat.slug)) next.push(cat.slug)
            if (!next.includes(sub.slug)) next.push(sub.slug)
            return next
          })
          return
        }
      }
    }
  }, [selected])

  const navigate = (slug: string) => {
    const p = new URLSearchParams(params.toString())
    selected === slug ? p.delete('category_id') : p.set('category_id', slug)
    router.push(`/products?${p.toString()}`, { scroll: false })
  }

  const toggle = (slug: string, e: React.MouseEvent) => {
    e.stopPropagation()
    setExpanded(prev => prev.includes(slug) ? prev.filter(s => s !== slug) : [...prev, slug])
  }

  const clearCategory = () => {
    const p = new URLSearchParams(params.toString())
    p.delete('category_id')
    router.push(`/products?${p.toString()}`, { scroll: false })
  }

  /** One row: the name navigates; the chevron (when there are children) expands. */
  const Row = ({ slug, label, depth, hasKids, icon }: { slug: string; label: string; depth: number; hasKids?: boolean; icon?: Cat }) => {
    const active = selected === slug
    return (
      <div className={`flex items-center rounded-xl transition-colors ${active ? 'bg-qb-accent text-white' : 'text-qb-text hover:bg-qb-fill'}`}
        style={{ paddingLeft: 4 + depth * 14 }}>
        <button type="button" onClick={() => navigate(slug)} aria-current={active ? 'true' : undefined}
          className={`flex min-w-0 flex-1 items-center gap-2.5 py-2 pl-1.5 text-left ${depth === 0 ? 'text-[15px] font-medium' : 'text-[14px]'}`}>
          {icon && (
            <span className="flex h-6 w-6 shrink-0 items-center justify-center overflow-hidden rounded-[7px] bg-white p-0.5 ring-1 ring-black/5">
              {icon.icon
                ? <Image src={icon.icon} alt="" width={20} height={20} className="h-full w-full object-contain" />
                : <span className="text-[8px] font-bold text-neutral-500">{icon.name.split(' ').map(w => w[0]).join('').slice(0, 2)}</span>}
            </span>
          )}
          <span className="truncate">{label}</span>
        </button>
        {hasKids && (
          <button type="button" onClick={e => toggle(slug, e)} aria-expanded={expanded.includes(slug)} aria-label={`Show ${label} ranges`}
            className={`mr-1 rounded-lg p-1.5 ${active ? 'text-white' : 'text-qb-faint'}`}>
            <ChevronRight size={14} className={`transition-transform ${expanded.includes(slug) ? 'rotate-90' : ''}`} />
          </button>
        )}
      </div>
    )
  }

  return (
    <nav aria-label="Categories" className="glass p-2.5">
      <button type="button" onClick={clearCategory} aria-current={!selected ? 'true' : undefined}
        className={`mb-1 w-full rounded-xl px-3 py-2 text-left text-[15px] font-medium transition-colors ${!selected ? 'bg-qb-accent text-white' : 'text-qb-text hover:bg-qb-fill'}`}>
        All products
      </button>
      {CATEGORIES.map(cat => (
        <div key={cat.slug}>
          <Row slug={cat.slug} label={cat.name} depth={0} hasKids={cat.subs.length > 0} icon={cat} />
          {expanded.includes(cat.slug) && cat.subs.map(sub => (
            <div key={sub.slug}>
              <Row slug={sub.slug} label={sub.name} depth={1} hasKids={!!sub.subsubs?.length} />
              {expanded.includes(sub.slug) && sub.subsubs?.map(ss => (
                <Row key={ss.slug} slug={ss.slug} label={ss.name} depth={2} />
              ))}
            </div>
          ))}
        </div>
      ))}
    </nav>
  )
}
