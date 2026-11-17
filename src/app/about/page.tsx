import type { Metadata } from 'next'
import Link from 'next/link'
import { ShieldCheck, Zap, Truck, Headphones, BadgeCheck, Users } from 'lucide-react'
import { whatsappLink } from '@/lib/constants'

export const metadata: Metadata = {
  title: 'About us',
  description: 'QBNET TECH supplies quality IT equipment, CCTV, access control and security systems across Ghana.',
  keywords: ['about QBNET TECH', 'IT company Ghana', 'security solutions company Accra', 'Hikvision Ghana'],
  openGraph: {
    title: 'About QBNET TECH',
    description: 'Quality IT equipment and security systems across Ghana.',
    url: 'https://www.qbnettech.com/about',
    images: [{ url: '/preview.jpg', width: 1200, height: 630 }],
  },
  alternates: { canonical: 'https://www.qbnettech.com/about' },
}

const values = [
  { icon: ShieldCheck, title: 'Genuine products', desc: 'Only authorised stock from brands we trust.' },
  { icon: Zap,         title: 'Quick quotes', desc: 'Tell us about the site and get a price the same day.' },
  { icon: Truck,       title: 'Delivery across Ghana', desc: 'We get orders to you wherever you are.' },
  { icon: Headphones,  title: 'Support that answers', desc: 'Reach the team on WhatsApp when something needs fixing.' },
  { icon: BadgeCheck,  title: 'Authorised dealer', desc: 'Hikvision, Dahua, CISCO and more.' },
  { icon: Users,       title: 'Trusted locally', desc: 'Businesses, schools and homes across the country.' },
]

export default function AboutPage() {
  return (
    <div className="px-5 pb-24 pt-12">
      <div className="mx-auto max-w-6xl">
        <div className="max-w-3xl">
          <h1 className="qb-display text-[2.4rem] sm:text-[3.4rem]">IT and security, done properly.</h1>
          <p className="mt-5 text-[19px] leading-relaxed text-qb-sub">
            QBNET TECH is a one-stop shop for information technology and security in Ghana. We supply quality
            equipment at fair prices, deliver it, and help install it.
          </p>
        </div>

        <div className="mt-14 grid gap-5 lg:grid-cols-2">
          <section className="glass p-7 sm:p-8">
            <h2 className="text-[22px] font-semibold tracking-tight text-qb-text">What we set out to do</h2>
            <p className="mt-3 text-[16px] leading-relaxed text-qb-sub">
              Provide quality IT products and services at the lowest fair price, with delivery that arrives
              when promised, throughout Ghana and beyond.
            </p>
          </section>
          <section className="glass p-7 sm:p-8">
            <h2 className="text-[22px] font-semibold tracking-tight text-qb-text">Security is our speciality</h2>
            <p className="mt-3 text-[16px] leading-relaxed text-qb-sub">
              Homes, offices, shops and public venues. We design systems for commercial, education,
              healthcare and hospitality clients, and many more.
            </p>
          </section>
        </div>

        <section className="mt-20">
          <h2 className="section-title text-[2rem] sm:text-[2.5rem]">Why customers choose us</h2>
          <div className="mt-8 grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
            {values.map(({ icon: Icon, title, desc }) => (
              <div key={title} className="glass p-6">
                <span className="flex h-11 w-11 items-center justify-center rounded-2xl bg-qb-accent text-white"><Icon size={21} /></span>
                <h3 className="mt-4 text-[18px] font-semibold tracking-tight text-qb-text">{title}</h3>
                <p className="mt-1.5 text-[15px] leading-relaxed text-qb-sub">{desc}</p>
              </div>
            ))}
          </div>
        </section>

        <section className="glass mt-20 !rounded-[32px] px-6 py-14 text-center sm:px-12">
          <h2 className="section-title text-[2rem] sm:text-[2.5rem]">Planning a project?</h2>
          <p className="mx-auto mt-3 max-w-xl text-[17px] text-qb-sub">
            Tell us about the site and we will suggest a setup and a price. The consultation is free.
          </p>
          <div className="mt-8 flex flex-col justify-center gap-3 sm:flex-row">
            <a href={whatsappLink('Hello, I am planning a project and would like advice.')} target="_blank" rel="noopener noreferrer" className="btn-primary !px-7 !py-3.5">
              Message us on WhatsApp
            </a>
            <Link href="/products" className="btn-glass !px-7 !py-3.5">Browse products</Link>
          </div>
        </section>
      </div>
    </div>
  )
}
