'use client'

import { useState } from 'react'
import { Phone, Mail, MapPin, MessageCircle } from 'lucide-react'
import { CONTACT, whatsappLink } from '@/lib/constants'

const HOURS = [
  { days: 'Monday to Friday', time: '8:00 to 18:00' },
  { days: 'Saturday', time: '9:00 to 16:00' },
  { days: 'Sunday', time: 'Closed' },
]

/**
 * Contact details plus a message form. The site has no mail server, so the
 * form hands the message to WhatsApp, filled in and ready to send, instead of
 * pretending to have sent it.
 */
export default function ContactForm() {
  const [form, setForm] = useState({ name: '', phone: '', message: '' })
  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    setForm(p => ({ ...p, [k]: e.target.value }))

  const submit = (e: React.FormEvent) => {
    e.preventDefault()
    const text = [`Hello QBNET TECH, my name is ${form.name.trim()}.`, form.message.trim(), form.phone.trim() && `You can reach me on ${form.phone.trim()}.`]
      .filter(Boolean).join('\n\n')
    window.open(whatsappLink(text), '_blank', 'noopener,noreferrer')
  }

  const channels = [
    ...CONTACT.phones.map((p, i) => ({ icon: Phone, label: i === 0 ? 'Call' : 'Call (second line)', value: p.display, href: `tel:${p.tel}` })),
    { icon: MessageCircle, label: 'WhatsApp', value: CONTACT.whatsapp.display, href: whatsappLink() },
    { icon: Mail, label: 'Email', value: CONTACT.email, href: `mailto:${CONTACT.email}` },
    { icon: MapPin, label: 'Location', value: CONTACT.city, href: null },
  ]

  return (
    <div className="px-5 pb-24 pt-12">
      <div className="mx-auto max-w-6xl">
        <div className="max-w-2xl">
          <h1 className="qb-display text-[2.4rem] sm:text-[3.2rem]">Talk to us</h1>
          <p className="mt-4 text-[18px] leading-relaxed text-qb-sub">
            Questions about a product, a quote for a site, or help after installation. Pick whatever is easiest.
          </p>
        </div>

        <div className="mt-12 grid gap-6 lg:grid-cols-[1fr_1.15fr]">
          <div className="space-y-6">
            <ul className="glass divide-y divide-[var(--qb-separator)] overflow-hidden">
              {channels.map(({ icon: Icon, label, value, href }) => {
                const body = (
                  <>
                    <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-qb-accent text-white"><Icon size={18} /></span>
                    <span className="min-w-0">
                      <span className="block text-[13px] text-qb-muted">{label}</span>
                      <span className="block break-all text-[17px] text-qb-text">{value}</span>
                    </span>
                  </>
                )
                return (
                  <li key={label}>
                    {href
                      ? <a href={href} target={href.startsWith('http') ? '_blank' : undefined} rel="noopener noreferrer" className="flex items-center gap-4 px-5 py-4 hover:bg-qb-fill">{body}</a>
                      : <div className="flex items-center gap-4 px-5 py-4">{body}</div>}
                  </li>
                )
              })}
            </ul>

            <div className="glass p-5">
              <h2 className="text-[17px] font-semibold text-qb-text">Opening hours</h2>
              <dl className="mt-3 space-y-2 text-[15px]">
                {HOURS.map(h => (
                  <div key={h.days} className="flex justify-between gap-4">
                    <dt className="text-qb-sub">{h.days}</dt>
                    <dd className="text-qb-text" style={{ fontVariantNumeric: 'tabular-nums' }}>{h.time}</dd>
                  </div>
                ))}
              </dl>
            </div>
          </div>

          <form onSubmit={submit} className="glass space-y-5 p-6 sm:p-8">
            <div>
              <h2 className="text-[20px] font-semibold text-qb-text">Send a message</h2>
              <p className="mt-1 text-[15px] text-qb-sub">This opens WhatsApp with your message written out. Press send there.</p>
            </div>
            <label className="block">
              <span className="mb-1.5 block text-[14px] font-medium text-qb-sub">Your name</span>
              <input required value={form.name} onChange={set('name')} autoComplete="name" className="qb-field" />
            </label>
            <label className="block">
              <span className="mb-1.5 block text-[14px] font-medium text-qb-sub">Phone number (optional)</span>
              <input type="tel" value={form.phone} onChange={set('phone')} autoComplete="tel" placeholder="+233" className="qb-field" />
            </label>
            <label className="block">
              <span className="mb-1.5 block text-[14px] font-medium text-qb-sub">Message</span>
              <textarea required rows={5} value={form.message} onChange={set('message')}
                placeholder="Tell us about your site or the product you need" className="qb-field resize-none" />
            </label>
            <button type="submit" className="btn-whatsapp w-full !py-3.5">Continue in WhatsApp</button>
          </form>
        </div>
      </div>
    </div>
  )
}
