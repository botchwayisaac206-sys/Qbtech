import type { Metadata } from 'next'
import ContactForm from '@/components/ContactForm'

export const metadata: Metadata = {
  title: 'Contact Us',
  description: 'Get in touch with QBNET TECH by phone, WhatsApp or email. Based in Accra, Ghana. Free consultation available.',
  keywords: ['contact QBNET TECH', 'IT company Accra Ghana', 'CCTV supplier contact Ghana', 'security solutions consultation Ghana'],
  openGraph: {
    title: 'Contact QBNET TECH',
    description: 'Reach us by phone, WhatsApp, or email for IT equipment, CCTV, security and networking solutions in Ghana.',
    url: 'https://www.qbnettech.com/contact',
    images: [{ url: '/preview.jpg', width: 1200, height: 630 }],
  },
  alternates: { canonical: 'https://www.qbnettech.com/contact' },
}

export default function ContactPage() {
  return <ContactForm />
}
