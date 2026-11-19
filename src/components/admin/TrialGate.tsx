'use client'

import { Hourglass, Lock, LogOut } from 'lucide-react'
import { formatLeft, TRIAL_DAYS, useTrial, type TrialState } from '@/lib/trial'
import QbnetLogo from '@/components/admin/QbnetLogo'

/**
 * The trial countdown, as a pill for a top bar. Calm for most of the
 * trial, amber in the last three days, red on the final one.
 */
export function TrialBadge({ trial, compact = false }: { trial: TrialState; compact?: boolean }) {
  if (trial.paid || trial.expired) return null
  const daysLeft = trial.msLeft / (24 * 60 * 60 * 1000)
  const tone = daysLeft <= 1 ? 'red' : daysLeft <= 3 ? 'amber' : 'accent'
  const fg = `var(--qb-${tone})`
  const bg = `var(--qb-${tone}-soft)`
  return (
    <div title={`Trial day ${trial.day} of ${TRIAL_DAYS}. Locks ${trial.end.toLocaleString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}.`}
      style={{ display: 'inline-flex', alignItems: 'center', gap: 7, padding: compact ? '5px 10px' : '6px 12px', borderRadius: 999,
        background: bg, color: fg, fontSize: compact ? 12 : 13, fontWeight: 650, whiteSpace: 'nowrap', flexShrink: 0 }}>
      <Hourglass size={compact ? 13 : 14} strokeWidth={2.2} />
      {!compact && <span>Trial ends in</span>}
      <span style={{ fontVariantNumeric: 'tabular-nums' }}>{formatLeft(trial.msLeft)}</span>
    </div>
  )
}

/** Full-screen lock shown once the trial is over. */
export function TrialLock({ onSignOut }: { onSignOut?: () => void }) {
  return (
    <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '24px 16px', background: 'var(--qb-bg)' }}>
      <div style={{ width: '100%', maxWidth: 440, textAlign: 'center', padding: '36px 28px 30px', borderRadius: 28,
        background: 'var(--qb-card)', border: '1px solid var(--qb-border)' }}>
        <div style={{ display: 'flex', justifyContent: 'center', marginBottom: 18 }}><QbnetLogo size={64} radius={18} /></div>
        <div style={{ width: 52, height: 52, borderRadius: 16, margin: '0 auto 16px', display: 'grid', placeItems: 'center',
          background: 'var(--qb-red-soft)', color: 'var(--qb-red)' }}>
          <Lock size={24} strokeWidth={2.2} />
        </div>
        <h1 style={{ margin: 0, fontSize: 22, fontWeight: 750, letterSpacing: '-0.02em', color: 'var(--qb-text)' }}>Your free trial has ended</h1>
        <p style={{ margin: '10px 0 0', fontSize: 15, lineHeight: 1.5, color: 'var(--qb-sub)' }}>
          The {TRIAL_DAYS}-day trial of the QBNET TECH system is over. Your invoices, stock and records are kept
          safe — complete payment to unlock the full version and carry on where you left off.
        </p>
        {onSignOut && (
          <button onClick={onSignOut} className="qb-icon-btn"
            style={{ marginTop: 22, width: 'auto', height: 'auto', padding: '10px 16px', borderRadius: 12, display: 'inline-flex', alignItems: 'center', gap: 8, fontWeight: 600, fontSize: 14 }}>
            <LogOut size={16} /> Sign out
          </button>
        )}
      </div>
    </div>
  )
}

export { useTrial }
