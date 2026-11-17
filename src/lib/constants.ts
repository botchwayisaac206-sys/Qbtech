// ─────────────────────────────────────────────────────────────
// CONTACT — the one place the shop's details live.
// Every page, the footer, the navbar and the search-engine data read from
// here. Replace the placeholder numbers below with the real ones.
// ─────────────────────────────────────────────────────────────
export const CONTACT = {
  /** Shown as written; `tel` is the dialable form (country code, no spaces). */
  phones: [
    { display: '054 505 0008', tel: '+233545050008' },
  ],
  /** WhatsApp number in international form without "+", as wa.me expects. */
  whatsapp: { display: '054 505 0008', number: '233545050008' },
  email: 'info@qbnettech.com',
  instagram: 'qbnettech',
  city: 'Accra, Ghana',
} as const

/** A wa.me link, optionally with a pre-filled message. */
export const whatsappLink = (text?: string) =>
  `https://wa.me/${CONTACT.whatsapp.number}${text ? `?text=${encodeURIComponent(text)}` : ''}`
