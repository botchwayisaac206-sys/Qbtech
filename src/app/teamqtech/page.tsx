'use client'

import { useState, useEffect, useRef, useCallback } from 'react'
import { supabase } from '@/lib/supabase'
import StockTab from '@/components/StockTab'
import Transfers from '@/components/admin/Transfers'
import Debtors from '@/components/admin/Debtors'
import StockApprovals from '@/components/admin/StockApprovals'
import { usePendingCount } from '@/lib/stockApproval'
import { useAutoAcceptMenu, useNoStockMenu } from '@/components/admin/AutoAcceptMenu'
import { HandCoins } from 'lucide-react'
import ProductNames from '@/components/admin/ProductNames'
import ItemHistory from '@/components/admin/ItemHistory'
import QbnetLogo from '@/components/admin/QbnetLogo'
import SalesDashboard from '@/components/admin/SalesDashboard'
import InvoiceWorkspace from '@/components/admin/InvoiceWorkspace'
import InvoiceList from '@/components/admin/InvoiceList'
import { prefetchAdminData } from '@/lib/adminCache'
import Expenses from '@/components/admin/Expenses'
import Deliveries from '@/components/admin/Deliveries'
import StaffManager from '@/components/admin/StaffManager'
import AuditLog from '@/components/admin/AuditLog'
import Suppliers from '@/components/admin/Suppliers'
import ReadOnlyGuard from '@/components/admin/ReadOnlyGuard'
import { useRole } from '@/lib/sales'
import {
  BarChart3, FilePlus2, Files, Wallet, Truck, Users,
  Boxes, ArrowLeftRight, History, Search, PackageCheck,
  Moon, Sun, LogOut, Menu, X, PanelLeftClose, PanelLeftOpen, type LucideIcon,
} from 'lucide-react'
import { useIsMobile } from '@/lib/useIsMobile'
import { useQbTheme, V } from '@/lib/qbTheme'

// The panel's action blue, from the admin palette in qb-ios.css. (Still called
// TEAL so the rest of this file reads as before.) Every colour is a --qb-* token.
const TEAL = 'var(--qb-accent)'

// Icon for each admin tab (lucide).
const TAB_ICON: Record<string, LucideIcon> = {
  sales: BarChart3, invoice: FilePlus2, invoices: Files, expenses: Wallet,
  deliveries: Truck, debtors: HandCoins, staff: Users,
  stock: Boxes, transfers: ArrowLeftRight,
  history: Search, log: History, suppliers: PackageCheck,
}

/**
 * The tabs a cashier may open — used both to filter the nav and to push a
 * cashier off any other tab.
 */
const CASHIER_TABS = new Set([
  // Transfers is staff work — restocking the shop floor from the back
  // warehouses is a daily job, and transfer_stock() already limits writes to
  // the Big Boss and cashiers.
  'invoice', 'expenses', 'deliveries', 'transfers',
  // A customer settling a debt pays whoever is at the counter.
  'debtors',
])

// ── Toast helper ─────────────────────────────────────────────
function useToast() {
  const [msg, setMsg] = useState<{ text:string; type:'ok'|'err' }|null>(null)
  const show = useCallback((text:string, type:'ok'|'err'='ok') => {
    setMsg({ text, type })
    setTimeout(() => setMsg(null), 3000)
  }, [])
  const Toast = msg ? (
    <div role="status" style={{ position:'fixed', top:16, left:'50%', transform:'translateX(-50%)', zIndex:9999, display:'flex', alignItems:'center', gap:10,
      padding:'11px 18px 11px 14px', borderRadius:999, background: V.cardStrong, border:`1px solid ${V.border}`, color: V.text,
      fontWeight:600, fontSize:14, boxShadow: V.shadow, maxWidth:'calc(100vw - 32px)' }}>
      <span aria-hidden style={{ width:9, height:9, borderRadius:9, flexShrink:0, background: msg.type==='ok' ? V.green : V.red }} />
      {msg.text}
    </div>
  ) : null
  return { show, Toast }
}

// ── Admin Page ───────────────────────────────────────────────
export default function AdminPage() {
  const { show, Toast } = useToast()
  const [authed,      setAuthed]      = useState(false)
  const [checkingSession, setCheckingSession] = useState(true)
  const [email,       setEmail]       = useState('')
  const [password,    setPassword]    = useState('')
  const [signingIn,   setSigningIn]   = useState(false)
  // Light/dark lives on <html data-qb-theme>, remembered per browser and
  // defaulting to the system setting. `darkMode` is still passed to tabs that ask.
  const { dark: darkMode, toggle: toggleDark } = useQbTheme()
  const [tab,         setTab]         = useState<'stock'|'transfers'|'sales'|'invoice'|'invoices'|'history'|'expenses'|'deliveries'|'debtors'|'staff'|'log'|'suppliers'>('sales')
  // Set of tab keys that have been visited at least once. A visited tab is
  // kept mounted (hidden via display:none when inactive) so its data and
  // in-progress state survive across tab switches. Never cleared during a
  // session — that's the whole point.
  const [visited,     setVisited]     = useState<Set<string>>(() => new Set(['sales']))

  const { role, isBoss, isSuperBoss, userId, isRestrictedBoss, windowed } = useRole()
  // Restricted boss keeps the full boss layout but may not change anything.
  const readOnly = isRestrictedBoss
  // The signed-in staff member's name, for the greeting ("Good Morning, Ama!").
  // Only the name they were given — never their role standing in for it.
  const [staffName, setStaffName] = useState('')
  useEffect(() => {
    if (!userId) { setStaffName(''); return }
    let cancelled = false
    supabase.from('user_roles').select('full_name').eq('user_id', userId).maybeSingle()
      .then(({ data }) => { if (!cancelled) setStaffName(((data as { full_name: string | null } | null)?.full_name || '').trim()) })
    return () => { cancelled = true }
  }, [userId])
  // Stock requests waiting for the Big Boss — shown on the Transfers tab.
  const pendingApprovals = usePendingCount(isSuperBoss)
  // Right-click the Transfers tab: the auto-accept switch.
  const autoMenu = useAutoAcceptMenu(isSuperBoss, darkMode)
  // Right-click the New Invoice tab: may staff invoice what is not in stock?
  const noStockMenu = useNoStockMenu(isSuperBoss, darkMode)
  const menuFor = (t: string) => t === 'transfers' ? autoMenu.open : t === 'invoice' ? noStockMenu.open : undefined
  const countBadge = (t: string) => t === 'transfers' && pendingApprovals > 0 && (
    <span title={`${pendingApprovals} stock request${pendingApprovals === 1 ? '' : 's'} waiting for your approval`}
      style={{ minWidth:18, height:18, padding:'0 5px', borderRadius:999, background:'#f59e0b', color:'#1f1300', fontSize:11, fontWeight:900, display:'inline-flex', alignItems:'center', justifyContent:'center', lineHeight:1 }}>
      {pendingApprovals}
    </span>
  )
  // No idle sign-out: the shop asked to stay signed in until someone signs
  // out. The session is kept by Supabase and renewed in the background.
  const isMobile = useIsMobile(820)
  // Mobile: the sidebar slides in over the page.
  const [navMenu, setNavMenu] = useState(false)
  // Desktop: the sidebar can shrink to an icon rail. Remembered per browser.
  const [collapsed, setCollapsed] = useState(false)
  useEffect(() => {
    try { setCollapsed(localStorage.getItem('qbnet.navCollapsed') === '1') } catch {}
  }, [])
  const toggleCollapsed = () => setCollapsed(c => {
    try { localStorage.setItem('qbnet.navCollapsed', c ? '0' : '1') } catch {}
    return !c
  })

  useEffect(() => {
    let mounted = true
    // Layout preview for development only: /teamqtech?preview opens the
    // dashboard without signing in, so the design can be seen before a
    // database exists. `next build` sets NODE_ENV to production, so this
    // branch never exists in the live site.
    if (process.env.NODE_ENV === 'development' && new URLSearchParams(window.location.search).has('preview')) {
      setAuthed(true)
      setCheckingSession(false)
      return () => { mounted = false }
    }
    // Read any stored session synchronously from localStorage — this is the
    // reliable path for "stay logged in on reload". INITIAL_SESSION can arrive
    // AFTER a background token-refresh network round-trip, which is too slow.
    supabase.auth.getSession().then(({ data: { session } }) => {
      if (!mounted) return
      setAuthed(!!session)
      setCheckingSession(false)
    }).catch(() => { if (mounted) setCheckingSession(false) })

    const { data: listener } = supabase.auth.onAuthStateChange((event, _session) => {
      if (!mounted) return
      if (event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED') {
        setAuthed(true)
        setCheckingSession(false)
      } else if (event === 'SIGNED_OUT') {
        setAuthed(false)
        setCheckingSession(false)
      }
    })
    return () => { mounted = false; listener.subscription.unsubscribe() }
  }, [])

  useEffect(() => {
    if (!authed) return
    // Fire-and-forget prefetch every dataset the admin panel uses so that the
    // user's first click on ANY tab hits warm cache — no "Loading…" spinner.
    prefetchAdminData()
  }, [authed])

  // Cashiers only get the tabs they're allowed to use — force the default
  // away from a hidden tab (which would otherwise render silently even though
  // the tab button is hidden by the role filter).
  useEffect(() => {
    if (!authed) return
    if (!isBoss && role === 'cashier' && !CASHIER_TABS.has(tab)) {
      setTab('invoice')
    }
  }, [authed, role, isBoss, tab])

  // The back office has its own solid palette (qb-ios.css, data-qb-area="admin").
  // Set on <html> so dialogs and dropdowns rendered in portals pick it up too.
  useEffect(() => {
    const el = document.documentElement
    el.setAttribute('data-qb-area', 'admin')
    return () => el.removeAttribute('data-qb-area')
  }, [])

  // Mark every tab the user visits so it stays mounted for the rest of the session.
  useEffect(() => {
    setVisited(prev => prev.has(tab) ? prev : new Set(prev).add(tab))
  }, [tab])

  const inputStyle: React.CSSProperties = {
    width:'100%', padding:'13px 15px', borderRadius:12, fontSize:16, outline:'none', fontFamily:'inherit',
    border:`1px solid ${V.inputBorder}`, background: V.input, color: V.text,
  }
  const labelStyle: React.CSSProperties = {
    fontSize:13, fontWeight:600, color: V.sub, display:'block', margin:'0 0 7px 4px',
  }


  // ── Session check (prevents login-screen flash on reload) ──
  if (checkingSession) return (
    <div style={{ minHeight:'100vh', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <style>{`@keyframes spin { to { transform: rotate(360deg) } }`}</style>
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 16 }}>
        <QbnetLogo size={44} />
        <div style={{ width: 26, height: 26, border: `3px solid ${V.fill}`, borderTopColor: TEAL, borderRadius: '50%', animation: 'spin 0.7s linear infinite' }} />
      </div>
    </div>
  )

  // ── Login screen ─────────────────────────────────────────
  // Split screen: the brand on an ink panel to the left, the form to the right.
  // On a phone the brand panel shrinks to a strip above the form.
  if (!authed) return (
    <div style={{ minHeight:'100vh', display:'flex', alignItems:'center', justifyContent:'center', padding: isMobile ? '24px 16px' : 40 }}>
      {Toast}
      <button onClick={() => toggleDark()} title={darkMode ? 'Switch to light' : 'Switch to dark'} aria-label={darkMode ? 'Switch to light' : 'Switch to dark'}
        className="qb-icon-btn" style={{ position:'absolute', top:18, right:18 }}>
        {darkMode ? <Moon size={17} /> : <Sun size={17} />}
      </button>
      <div style={{ width:'100%', maxWidth:400, display:'flex', flexDirection:'column', alignItems:'center', gap:18 }}>
        <form
          onSubmit={async e => {
            e.preventDefault()
            if (!email || !password) return show('Email or staff ID and password required', 'err')
            // Allow staff to type just their login handle (e.g. "isha") instead of
            // the full isha@qbnettech.com staff ID. Presence of '@' = real email.
            const raw = email.trim()
            const loginEmail = raw.includes('@')
              ? raw
              : `${raw.toLowerCase()}@qbnettech.com`
            setSigningIn(true)
            const { error } = await supabase.auth.signInWithPassword({ email: loginEmail, password })
            setSigningIn(false)
            if (error) {
              show(error.message || 'Sign in failed', 'err')
            } else {
              // onAuthStateChange will fire SIGNED_IN and flip authed=true.
              setPassword('')
            }
          }}
          style={{ width:'100%', padding: isMobile ? '28px 22px 24px' : '36px 34px 30px', borderRadius:28,
            background: V.card, border:`1px solid ${V.border}` }}
        >
          <div style={{ display:'flex', flexDirection:'column', alignItems:'center', textAlign:'center', marginBottom:26 }}>
            <div style={{ marginBottom:14 }}><QbnetLogo size={72} radius={20} /></div>
            <h1 style={{ color: V.text, fontWeight:700, fontSize:26, letterSpacing:'-0.02em', margin:0 }}>QBNET TECH SOLUTIONS</h1>
            <p style={{ color: V.sub, fontSize:15, margin:'6px 0 0' }}>Sign in with your staff ID or email.</p>
          </div>
          <label style={labelStyle}>Staff ID or email</label>
          <input type="text" value={email} onChange={e => setEmail(e.target.value)} placeholder="e.g. ama" autoComplete="username"
            style={{ ...inputStyle, marginBottom:16 }} />
          <label style={labelStyle}>Password</label>
          <input type="password" value={password} onChange={e => setPassword(e.target.value)} placeholder="••••••••" autoComplete="current-password"
            style={{ ...inputStyle, marginBottom:24 }} />
          <button type="submit" disabled={signingIn} style={{ width:'100%', padding:'15px', borderRadius:14,
            background: signingIn ? V.fill : TEAL, color: signingIn ? V.sub : '#fff',
            fontWeight:600, fontSize:17, border:'none', cursor: signingIn ? 'not-allowed' : 'pointer' }}>
            {signingIn ? 'Signing in…' : 'Sign in'}
          </button>
        </form>
        <div style={{ color: V.muted, fontSize:12.5 }}>Stock and invoicing for the QBNET team</div>
      </div>
    </div>
  )

  // ── Navigation ───────────────────────────────────────────
  // Grouped by the kind of work, top to bottom: the counter, the stock, then
  // the back office. Change NAV_GROUPS to reorder — nothing else depends on it.
  // Selling prices are set on the Stock tab (Big Boss only).
  type TabKey = typeof tab
  const NAV_GROUPS: { title: string; tabs: TabKey[] }[] = [
    { title: 'Counter',   tabs: ['invoice', 'invoices', 'debtors', 'deliveries', 'expenses'] },
    { title: 'Inventory', tabs: ['stock', 'transfers', 'suppliers', 'history'] },
    { title: 'Business',  tabs: ['sales', 'staff', 'log'] },
  ]
  const canSee = (t: TabKey) => {
    if (!isBoss && role === 'cashier') return CASHIER_TABS.has(t)
    if (t === 'staff' || t === 'log' || t === 'suppliers') return isBoss
    return true
  }
  const labelOf = (t: TabKey) => ({
    stock: 'Stock', transfers: 'Transfers', sales: 'Sales', invoice: 'New Invoice', invoices: 'Invoices',
    expenses: 'Expenses', deliveries: 'Deliveries', debtors: 'Debtors', staff: 'Staff', history: 'History', log: 'Log', suppliers: 'Suppliers & costs',
  } as Record<TabKey, string>)[t] || String(t)
  const groupOf = (t: TabKey) => NAV_GROUPS.find(g => g.tabs.includes(t))?.title || ''
  const pick = (t: TabKey) => { setTab(t); setNavMenu(false) }
  const rail = collapsed && !isMobile
  const initials = (staffName || (isSuperBoss ? 'Big Boss' : isBoss ? 'Boss' : 'Staff'))
    .split(/\s+/).map(w => w[0]).join('').slice(0, 2).toUpperCase()
  const h = new Date().getHours()
  const greeting = h < 12 ? 'Good morning' : h < 17 ? 'Good afternoon' : 'Good evening'
  const ActiveIcon = TAB_ICON[tab]

  const sidebar = (
    // An ink panel fixed to the left edge, so the page always has the same
    // frame: menu on the left, where-you-are along the top. On a phone it slides in.
    <aside className="qb-side" style={{
      // alignSelf keeps the panel from stretching to the page height, which
      // would leave sticky nothing to stick within.
      width: rail ? 76 : 248, flexShrink:0, alignSelf:'flex-start', position: isMobile ? 'fixed' : 'sticky', zIndex:60,
      top: 0, left: isMobile ? 0 : undefined, bottom: isMobile ? 0 : undefined,
      height: isMobile ? undefined : '100vh', margin: 0,
      transform: isMobile && !navMenu ? 'translateX(calc(-100% - 20px))' : 'none',
      borderRadius: isMobile ? '0 18px 18px 0' : 0, boxShadow: isMobile ? '0 20px 50px rgba(0,0,0,0.35)' : 'none',
      display:'flex', flexDirection:'column', overflow:'hidden', transition:'width 0.25s cubic-bezier(0.32,0.72,0,1), transform 0.35s cubic-bezier(0.32,0.72,0,1)',
    }}>
      {/* Brand */}
      <div style={{ display:'flex', alignItems:'center', gap:11, padding: rail ? '18px 0 16px' : '18px 16px 16px', justifyContent: rail ? 'center' : 'flex-start', borderBottom:'1px solid var(--qb-side-line)', marginBottom:10 }}>
        <QbnetLogo size={rail ? 40 : 38} radius={11} />
        {!rail && (
          <div style={{ minWidth:0, flex:1 }}>
            <div style={{ color:'#fff', fontWeight:800, fontSize:14.5, letterSpacing:'0.01em', lineHeight:1.2 }}>QBNET TECH</div>
            <div style={{ color:'var(--qb-side-muted)', fontSize:12 }}>Back office</div>
          </div>
        )}
        {isMobile && (
          <button onClick={() => setNavMenu(false)} aria-label="Close menu" className="qb-icon-btn"><X size={17} /></button>
        )}
      </div>

      {/* Groups */}
      <nav style={{ flex:1, overflowY:'auto', padding:'4px 10px 10px', display:'flex', flexDirection:'column', gap:16 }}>
        {NAV_GROUPS.map(g => {
          const items = g.tabs.filter(canSee)
          if (!items.length) return null
          return (
            <div key={g.title}>
              {rail
                ? <div style={{ height:1, background:'var(--qb-side-line)', margin:'0 10px 10px' }} />
                : <div style={{ color:'var(--qb-side-muted)', fontSize:11, fontWeight:700, letterSpacing:'0.08em', textTransform:'uppercase', padding:'0 11px 6px' }}>{g.title}</div>}
              <div style={{ display:'flex', flexDirection:'column', gap:2 }}>
                {items.map(t => {
                  const Icon = TAB_ICON[t]
                  const active = tab === t
                  return (
                    <button key={t} onClick={() => pick(t)} data-active={active} aria-current={active ? 'page' : undefined}
                      onContextMenu={menuFor(t)}
                      title={rail ? labelOf(t) : isSuperBoss ? (t === 'transfers' ? 'Right-click for auto-accept' : t === 'invoice' ? 'Right-click to allow invoicing items not in stock' : undefined) : undefined}
                      className="qb-nav-item"
                      style={{
                        position:'relative', display:'flex', alignItems:'center', gap:11, width:'100%',
                        justifyContent: rail ? 'center' : 'flex-start',
                        padding: rail ? '10px 0' : '9px 11px', borderRadius:12, border:'none', cursor:'pointer', textAlign:'left',
                        fontFamily:'inherit', fontWeight: active ? 650 : 500, fontSize:14.5,
                      }}>
                      {Icon && <Icon size={18} strokeWidth={active ? 2.2 : 1.9} style={{ color: active ? 'inherit' : 'var(--qb-side-muted)', flexShrink:0 }} />}
                      {!rail && <span style={{ flex:1 }}>{labelOf(t)}</span>}
                      {rail
                        ? (t === 'transfers' && pendingApprovals > 0 && <span style={{ position:'absolute', top:6, right:12, width:8, height:8, borderRadius:8, background:'#f59e0b' }} />)
                        : countBadge(t)}
                    </button>
                  )
                })}
              </div>
            </div>
          )
        })}
      </nav>

      {/* Who is signed in, and the session controls */}
      <div style={{ padding:12, borderTop:'1px solid var(--qb-side-line)' }}>
        <div style={{ display:'flex', alignItems:'center', gap:10, flexDirection: rail ? 'column' : 'row' }}>
          <div style={{ width:36, height:36, borderRadius:'50%', flexShrink:0, display:'grid', placeItems:'center', fontWeight:600, fontSize:14, color:'#fff',
            background: TEAL }}>{initials}</div>
          {!rail && (
            <div style={{ flex:1, minWidth:0 }}>
              <div style={{ color:'#fff', fontWeight:600, fontSize:14, whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis' }}>{staffName || (isBoss ? 'Boss' : 'Staff')}</div>
              <div style={{ color:'var(--qb-side-muted)', fontSize:12.5 }}>{isSuperBoss ? 'Big Boss' : isBoss ? (readOnly ? 'Boss, view only' : 'Boss') : 'Cashier'}</div>
            </div>
          )}
          <div style={{ display:'flex', gap:6, flexDirection: rail ? 'column' : 'row' }}>
            <button onClick={() => toggleDark()} title={darkMode ? 'Switch to light' : 'Switch to dark'} aria-label={darkMode ? 'Switch to light' : 'Switch to dark'} className="qb-icon-btn">
              {darkMode ? <Sun size={16} /> : <Moon size={16} />}
            </button>
            <button onClick={() => { supabase.auth.signOut(); setAuthed(false) }} title="Sign out" aria-label="Sign out" className="qb-icon-btn">
              <LogOut size={16} />
            </button>
          </div>
        </div>
        {!isMobile && (
          <button onClick={toggleCollapsed} className="qb-nav-item" title={rail ? 'Expand menu' : 'Collapse menu'}
            style={{ marginTop:10, width:'100%', display:'flex', alignItems:'center', justifyContent: rail ? 'center' : 'flex-start', gap:8,
              padding:'8px 10px', borderRadius:10, border:'none', background:'transparent', fontFamily:'inherit', fontWeight:500, fontSize:13, cursor:'pointer' }}>
            {rail ? <PanelLeftOpen size={16} /> : <><PanelLeftClose size={16} /> Collapse sidebar</>}
          </button>
        )}
      </div>
    </aside>
  )

  // ── Dashboard ────────────────────────────────────────────
  return (
    <div style={{ minHeight:'100vh', display:'flex' }}>
      {Toast}
      <style>{`
        @keyframes greet-in { from { opacity: 0; transform: translateY(-6px); } to { opacity: 1; transform: none; } }
        .greet-banner { animation: greet-in 0.45s ease both; }
      `}</style>

      {sidebar}
      {isMobile && navMenu && <div onClick={() => setNavMenu(false)} style={{ position:'fixed', inset:0, zIndex:55, background:'var(--qb-scrim)' }} />}
      {autoMenu.element}
      {noStockMenu.element}

      <main style={{ flex:1, minWidth:0, display:'flex', flexDirection:'column' }}>
        {/* ── Top bar: where you are (section › page), the date and who is signed in ── */}
        <header style={{
          position:'sticky', top:0, zIndex:40, display:'flex', alignItems:'center', gap:12,
          padding: isMobile ? '10px 14px' : '14px 28px',
          background: V.card, borderBottom:`1px solid ${V.border}`, boxShadow:'none',
        }}>
          {isMobile && (
            <button onClick={() => setNavMenu(true)} aria-label="Open menu" className="qb-icon-btn" style={{ position:'relative', width:38, height:38 }}>
              <Menu size={19} />
              {pendingApprovals > 0 && <span style={{ position:'absolute', top:-1, right:-1, width:10, height:10, borderRadius:10, background:'#f59e0b' }} />}
            </button>
          )}
          {!isMobile && ActiveIcon && (
            <span aria-hidden style={{ width:40, height:40, borderRadius:12, display:'grid', placeItems:'center', background: V.accentSoft, color: TEAL, flexShrink:0 }}>
              <ActiveIcon size={20} strokeWidth={2.2} />
            </span>
          )}
          <div style={{ minWidth:0, flex:1 }}>
            <div style={{ color: V.muted, fontSize:12, fontWeight:600, whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis' }}>
              {groupOf(tab)}{groupOf(tab) && <span style={{ margin:'0 6px', color: V.faint }}>›</span>}{labelOf(tab)}
            </div>
            <h1 style={{ color: V.text, fontWeight:750, fontSize: isMobile ? 20 : 24, letterSpacing:'-0.02em', lineHeight:1.15, margin:'1px 0 0' }}>
              {labelOf(tab)}
            </h1>
          </div>
          {!isMobile && (
            <div className="greet-banner" style={{ textAlign:'right', lineHeight:1.3 }}>
              <div style={{ color: V.text, fontSize:14, fontWeight:600, whiteSpace:'nowrap' }}>
                {greeting}{staffName ? `, ${staffName}` : ''}
              </div>
              <div style={{ color: V.muted, fontSize:12.5, whiteSpace:'nowrap' }}>
                {new Date().toLocaleDateString('en-GB', { weekday:'long', day:'numeric', month:'long', year:'numeric' })}
              </div>
            </div>
          )}
        </header>

        <div style={{ width:'100%', maxWidth:1280, margin:'0 auto', padding: isMobile ? '16px 12px 40px' : '24px 28px 56px' }}>

        {/* ── Child-component tabs ───────────────────────────────
            Each tab is mounted on first visit and kept mounted for the rest
            of the session (hidden via display:none when inactive). This means
            data fetches run exactly ONCE per session — tab switches have zero
            network cost and never wipe scroll, filters, or typed input. */}

        {/* Sales dashboard (boss/admin only) */}
        {visited.has('sales') && (
          <div style={{ display: tab === 'sales' ? 'block' : 'none' }}>
            {isBoss
              ? <SalesDashboard isBoss={isBoss} windowed={windowed} />
              : <div style={{ padding:48, textAlign:'center', color:'var(--qb-sub)' }}>Only a Boss can open this tab.</div>}
          </div>
        )}

        {/* New invoice workspace — up to 3 drafts side-by-side */}
        {visited.has('invoice') && (
          <div style={{ display: tab === 'invoice' ? 'block' : 'none' }}>
            <ReadOnlyGuard active={readOnly}>
              <InvoiceWorkspace onSaved={() => show('Invoice saved · print dialog opened')} userId={userId} />
            </ReadOnlyGuard>
          </div>
        )}

        {/* Invoice list */}
        {visited.has('invoices') && (
          <div style={{ display: tab === 'invoices' ? 'block' : 'none' }}>
            <InvoiceList />
          </div>
        )}


        {/* Expenses (boss + cashier; amounts blurred for staff) */}
        {visited.has('expenses') && (
          <div style={{ display: tab === 'expenses' ? 'block' : 'none' }}>
            <ReadOnlyGuard active={readOnly}>
              <Expenses canSeeAmounts={isBoss} userId={userId} windowed={windowed} />
            </ReadOnlyGuard>
          </div>
        )}

        {/* Deliveries (boss + cashier; staff log, boss sees all) */}
        {visited.has('deliveries') && (
          <div style={{ display: tab === 'deliveries' ? 'block' : 'none' }}>
            <ReadOnlyGuard active={readOnly}>
              <Deliveries isBoss={isBoss} userId={userId} windowed={windowed} />
            </ReadOnlyGuard>
          </div>
        )}

        {/* Debtors — sales on credit and the payments made against them */}
        {visited.has('debtors') && (
          <div style={{ display: tab === 'debtors' ? 'block' : 'none' }}>
            <ReadOnlyGuard active={readOnly}>
              <Debtors userId={userId} isSuperBoss={isSuperBoss} />
            </ReadOnlyGuard>
          </div>
        )}

        {/* Staff manager (boss only) */}
        {visited.has('staff') && (
          <div style={{ display: tab === 'staff' ? 'block' : 'none' }}>
            {isBoss
              ? <StaffManager />
              : <div style={{ padding:48, textAlign:'center', color:'var(--qb-sub)' }}>Only a Boss can open this tab.</div>}
          </div>
        )}

        {/* Stock tab */}
        {visited.has('stock') && (
          <div style={{ display: tab === 'stock' ? 'block' : 'none' }}>
            <ReadOnlyGuard active={readOnly}>
              <StockTab darkMode={darkMode} onToggleDark={() => toggleDark()} isSuperBoss={isSuperBoss} />
            </ReadOnlyGuard>
          </div>
        )}

        {/* History tab — search any invoiced item and see how many went out,
            when, and to whom. Read-only, so no guard is needed. */}
        {visited.has('history') && (
          <div style={{ display: tab === 'history' ? 'block' : 'none' }}>
            <ItemHistory dark={darkMode} />
          </div>
        )}

        {/* Transfers tab — moving units between locations, and the record of
            it. This is the only way units reach STORE STOCK, which is what
            main-shop invoices are deducted from. */}
        {visited.has('transfers') && (
          <div style={{ display: tab === 'transfers' ? 'block' : 'none' }}>
            {/* Every staff movement waits here for the Big Boss; staff see their own. */}
            {!readOnly || isBoss ? <StockApprovals isSuperBoss={isSuperBoss} isBoss={isBoss} dark={darkMode} /> : null}
            <ReadOnlyGuard active={readOnly}>
              <Transfers dark={darkMode} canWrite={!readOnly} isBoss={isBoss} isSuperBoss={isSuperBoss} />
            </ReadOnlyGuard>
            {/* Merging two names for one product rewrites stock rows — Big Boss only. */}
            {isSuperBoss && <ProductNames dark={darkMode} />}
          </div>
        )}

        {/* Suppliers & costs — goods received at cost, payments, spoilt returns,
            and cost prices. Bosses read; only the Big Boss records anything. */}
        {visited.has('suppliers') && (
          <div style={{ display: tab === 'suppliers' ? 'block' : 'none' }}>
            {isBoss
              ? <Suppliers canWrite={isSuperBoss} notify={show} />
              : <div style={{ padding:48, textAlign:'center', color:'var(--qb-sub)' }}>Only a Boss can open this tab.</div>}
          </div>
        )}

        {/* Log tab — audit trail for every insert/update/delete on money-moving tables */}
        {visited.has('log') && (
          <div style={{ display: tab === 'log' ? 'block' : 'none' }}>
            {isBoss
              ? <AuditLog darkMode={darkMode} />
              : <div style={{ padding:48, textAlign:'center', color:'var(--qb-sub)' }}>Only a Boss can open this tab.</div>}
          </div>
        )}

        </div>
      </main>
    </div>
  )
}
