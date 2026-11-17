import Link from 'next/link'
import Image from 'next/image'
import { ArrowUpRight, ChevronDown, MessageCircle, Phone, Mail, Truck, Wrench, Tag } from 'lucide-react'
import HeroSection from '@/components/HeroSection'
import BrandsTicker from '@/components/BrandsTicker'
import ScrollReveal from '@/components/ScrollReveal'
import { CONTACT, whatsappLink } from '@/lib/constants'

// Each tile searches the shop for that kind of kit. `span` sets the tile's
// footprint in the bento grid on large screens.
const needs = [
  { img: '/cctvsys.png', title: 'Watch the premises', kit: 'Cameras, NVRs and DVRs', search: 'camera', span: 'lg:col-span-2 lg:row-span-2' },
  { img: '/network.png', title: 'Get everyone online', kit: 'Switches, routers and PoE', search: 'switch', span: '' },
  { img: '/access.jpg',  title: 'Control who comes in', kit: 'Readers, barriers and locks', search: 'access', span: '' },
  { img: '/fire.jpg',    title: 'Catch a fire early', kit: 'Detectors and panels', search: 'fire', span: '' },
  { img: '/itequip.png', title: 'Equip the office', kit: 'Computers and accessories', search: 'computer', span: '' },
]

const steps = [
  { title: 'Send us the job', body: 'A floor plan, a photo of the site or just a list of what you want covered. WhatsApp is fastest.' },
  { title: 'Get a written quote', body: 'We match equipment to the site and your budget, and list every item and price on a proforma.' },
  { title: 'Delivery or fitting', body: 'Collect from the shop, have it delivered anywhere in Ghana, or let our technicians install it.' },
]

const audiences = [
  {
    label: 'Trade',
    title: 'Installers and contractors',
    points: ['Wholesale pricing on volume', 'Stock checked before you quote', 'Proformas for your clients'],
    cta: 'Ask for trade prices',
    message: 'Hello, I am an installer and would like your trade prices.',
  },
  {
    label: 'Retail',
    title: 'Homes and businesses',
    points: ['Help choosing the right kit', 'Installation by our technicians', 'Support after the job is done'],
    cta: 'Plan my setup',
    message: 'Hello, I would like help planning a security setup.',
  },
]

const faqs = [
  { q: 'Do you deliver outside Accra?', a: 'Yes. We deliver to every region in Ghana. Tell us the town and we will confirm the timing when you order.' },
  { q: 'Can I buy without installation?', a: 'Of course. Most of our customers are installers who only need the equipment. Installation is there if you want it.' },
  { q: 'Is the equipment genuine?', a: 'Everything comes through authorised channels for the brands we carry, with the manufacturer warranty.' },
  { q: 'How do I get a quote?', a: 'Message us on WhatsApp with what you need. We reply with a written proforma you can share or pay against.' },
]

function Eyebrow({ children }: { children: React.ReactNode }) {
  return <p className="text-[13px] font-semibold uppercase tracking-[0.14em] text-qb-accent">{children}</p>
}

export default function HomePage() {
  return (
    <>
      <HeroSection />

      {/* The brands we carry, scrolling. Each one opens the shop filtered to it. */}
      <section aria-labelledby="brands-heading" className="mx-auto max-w-6xl px-5">
        <p id="brands-heading" className="text-center text-[13px] font-semibold uppercase tracking-[0.14em] text-qb-muted">
          Authorised brands we carry
        </p>
        <BrandsTicker />
      </section>

      {/* Shop by need: a bento of what the customer is trying to do. */}
      <section className="px-5 py-20">
        <div className="mx-auto max-w-6xl">
          <ScrollReveal direction="up" duration={600}>
            <Eyebrow>Shop by need</Eyebrow>
            <h2 className="section-title mt-2 max-w-2xl text-[2rem] sm:text-[2.5rem]">What are you setting up?</h2>
          </ScrollReveal>
          <div className="mt-10 grid auto-rows-[220px] grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
            {needs.map(({ img, title, kit, search, span }, i) => (
              <ScrollReveal key={title} delay={i * 60} direction="up" duration={600} distance={20} className={span}>
                <Link href={`/products?search=${encodeURIComponent(search)}`}
                  className="group relative block h-full overflow-hidden rounded-[24px] bg-qb-fill">
                  <Image src={img} alt="" fill sizes="(max-width: 640px) 100vw, (max-width: 1024px) 50vw, 50vw"
                    className="object-cover transition-transform duration-700 group-hover:scale-105" />
                  <div aria-hidden className="absolute inset-0 bg-gradient-to-t from-black/75 via-black/20 to-transparent" />
                  <div className="absolute inset-x-0 bottom-0 flex items-end justify-between gap-3 p-5">
                    <div>
                      <h3 className="text-[20px] font-semibold tracking-tight text-white">{title}</h3>
                      <p className="mt-0.5 text-[14px] text-white/80">{kit}</p>
                    </div>
                    <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-white/20 text-white backdrop-blur transition-colors group-hover:bg-white group-hover:text-black">
                      <ArrowUpRight size={18} />
                    </span>
                  </div>
                </Link>
              </ScrollReveal>
            ))}
            <ScrollReveal delay={needs.length * 60} direction="up" duration={600} distance={20}>
              <Link href="/products"
                className="flex h-full flex-col justify-between rounded-[24px] bg-qb-accent p-5 text-white transition-opacity hover:opacity-90">
                <Tag size={22} />
                <div>
                  <h3 className="text-[20px] font-semibold tracking-tight">Something else?</h3>
                  <p className="mt-0.5 text-[14px] text-white/85">Browse the full catalogue</p>
                </div>
              </Link>
            </ScrollReveal>
          </div>
        </div>
      </section>

      {/* How ordering works */}
      <section className="px-5 pb-20">
        <div className="mx-auto grid max-w-6xl gap-10 lg:grid-cols-[0.8fr_1.2fr]">
          <div>
            <Eyebrow>How it works</Eyebrow>
            <h2 className="section-title mt-2 text-[2rem] sm:text-[2.5rem]">From a message to a working system</h2>
            <div className="mt-6 flex flex-wrap gap-2 text-[14px] text-qb-sub">
              <span className="inline-flex items-center gap-1.5 rounded-full bg-qb-fill px-3 py-1.5"><Truck size={15} /> Delivery nationwide</span>
              <span className="inline-flex items-center gap-1.5 rounded-full bg-qb-fill px-3 py-1.5"><Wrench size={15} /> Optional installation</span>
            </div>
          </div>
          <ol className="relative space-y-4">
            {steps.map(({ title, body }, i) => (
              <ScrollReveal key={title} delay={i * 100} direction="up" duration={600} distance={16}>
                <li className="glass flex gap-5 p-5 sm:p-6">
                  <span className="qb-display text-[2.25rem] leading-none text-qb-accent">{String(i + 1).padStart(2, '0')}</span>
                  <div>
                    <h3 className="text-[18px] font-semibold text-qb-text">{title}</h3>
                    <p className="mt-1 text-[15px] leading-relaxed text-qb-sub">{body}</p>
                  </div>
                </li>
              </ScrollReveal>
            ))}
          </ol>
        </div>
      </section>

      {/* Who we serve: trade and retail side by side. */}
      <section className="px-5 pb-20">
        <div className="mx-auto grid max-w-6xl gap-4 md:grid-cols-2">
          {audiences.map(({ label, title, points, cta, message }, i) => (
            <div key={label}
              className={`flex flex-col rounded-[28px] p-7 sm:p-9 ${i === 0 ? 'bg-[#0b1f3a] text-white' : 'glass'}`}>
              <span className={`w-fit rounded-full px-3 py-1 text-[13px] font-semibold ${i === 0 ? 'bg-white/15' : 'bg-qb-fill text-qb-accent'}`}>{label}</span>
              <h3 className={`mt-4 text-[26px] font-semibold tracking-tight ${i === 0 ? '' : 'text-qb-text'}`}>{title}</h3>
              <ul className={`mt-5 flex-1 space-y-2.5 text-[16px] ${i === 0 ? 'text-white/80' : 'text-qb-sub'}`}>
                {points.map(p => (
                  <li key={p} className={`border-b pb-2.5 last:border-0 ${i === 0 ? 'border-white/15' : 'border-qb-separator'}`}>{p}</li>
                ))}
              </ul>
              <a href={whatsappLink(message)} target="_blank" rel="noopener noreferrer"
                className={`mt-7 inline-flex w-fit items-center gap-2 rounded-full px-5 py-3 text-[16px] font-medium transition-opacity hover:opacity-90 ${i === 0 ? 'bg-white text-[#0b1f3a]' : 'bg-qb-accent text-white'}`}>
                <MessageCircle size={17} /> {cta}
              </a>
            </div>
          ))}
        </div>
      </section>

      {/* Questions and contact */}
      <section className="px-5 pb-24">
        <div className="mx-auto grid max-w-6xl gap-10 lg:grid-cols-[1.2fr_0.8fr]">
          <div>
            <Eyebrow>Questions</Eyebrow>
            <h2 className="section-title mt-2 text-[2rem] sm:text-[2.5rem]">Before you order</h2>
            <div className="mt-8 divide-y divide-qb-separator border-y border-qb-separator">
              {faqs.map(({ q, a }) => (
                <details key={q} className="group py-5">
                  <summary className="flex cursor-pointer list-none items-center justify-between gap-4 text-[17px] font-medium text-qb-text [&::-webkit-details-marker]:hidden">
                    {q}
                    <ChevronDown size={18} className="shrink-0 text-qb-muted transition-transform group-open:rotate-180" />
                  </summary>
                  <p className="mt-3 max-w-xl text-[15px] leading-relaxed text-qb-sub">{a}</p>
                </details>
              ))}
            </div>
          </div>

          <aside className="glass h-fit p-6 sm:p-8">
            <h3 className="text-[20px] font-semibold tracking-tight text-qb-text">Talk to the shop</h3>
            <p className="mt-1 text-[15px] text-qb-sub">{CONTACT.city}</p>
            <div className="mt-6 space-y-2">
              <a href={whatsappLink('Hello QBNET TECH.')} target="_blank" rel="noopener noreferrer"
                className="flex items-center gap-3 rounded-2xl bg-qb-accent px-4 py-3.5 text-[16px] font-medium text-white transition-opacity hover:opacity-90">
                <MessageCircle size={18} /> WhatsApp {CONTACT.whatsapp.display}
              </a>
              <a href={`tel:${CONTACT.phones[0].tel}`}
                className="flex items-center gap-3 rounded-2xl bg-qb-fill px-4 py-3.5 text-[16px] text-qb-text transition-colors hover:bg-qb-card">
                <Phone size={18} className="text-qb-muted" /> {CONTACT.phones[0].display}
              </a>
              <a href={`mailto:${CONTACT.email}`}
                className="flex items-center gap-3 rounded-2xl bg-qb-fill px-4 py-3.5 text-[16px] text-qb-text transition-colors hover:bg-qb-card">
                <Mail size={18} className="text-qb-muted" /> {CONTACT.email}
              </a>
            </div>
            <Link href="/contact" className="mt-5 inline-flex items-center gap-1 text-[15px] font-medium text-qb-accent hover:underline">
              All contact details <ArrowUpRight size={15} />
            </Link>
          </aside>
        </div>
      </section>
    </>
  )
}
