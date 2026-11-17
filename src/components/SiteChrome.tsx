'use client'

import { usePathname } from 'next/navigation'
import Navbar from '@/components/Navbar'
import Footer from '@/components/Footer'

/** Staff screens carry no shop navigation: the admin panel and the phone stock app. */
const isStaffRoute = (pathname: string) =>
  ['/teamqtech', '/s-quxf5u4k84'].some(p => pathname.startsWith(p))

export function SiteHeader() {
  const pathname = usePathname() || ''
  if (isStaffRoute(pathname)) return null
  return <Navbar />
}

export function SiteFooter() {
  const pathname = usePathname() || ''
  if (isStaffRoute(pathname)) return null
  return <Footer />
}
