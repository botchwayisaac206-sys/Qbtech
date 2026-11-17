import { Plus_Jakarta_Sans } from 'next/font/google'

// The back office has its own typeface, apart from the public site's.
const jakarta = Plus_Jakarta_Sans({ subsets: ['latin'], weight: ['400', '500', '600', '700', '800'], display: 'swap' })

export default function AdminLayout({ children }: { children: React.ReactNode }) {
  return <div className={jakarta.className}>{children}</div>
}
