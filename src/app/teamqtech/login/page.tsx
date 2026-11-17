import { redirect } from 'next/navigation'

// /teamqtech/login is consolidated into /teamqtech — the inline sign-in form
// on /teamqtech handles both boss and staff (cashier) credentials.
export default function AdminLoginRedirect() {
  redirect('/teamqtech')
}
