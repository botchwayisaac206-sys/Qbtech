'use client'

/**
 * Lets a cashier work on up to 3 invoices at once. Each draft is its own
 * InvoiceForm instance with fully independent state. We keep all drafts
 * mounted (the inactive ones are hidden with `display:none`) so switching
 * tabs never loses typed data.
 */

import { useState } from 'react'
import InvoiceForm from './InvoiceForm'

const TEAL = '#0a7cff'
const MAX_DRAFTS = 3

interface Draft { id: number; label: string }
let draftCounter = 0
const makeDraft = (n: number): Draft => ({ id: ++draftCounter, label: `Draft ${n}` })

export default function InvoiceWorkspace({ onSaved, userId }: { onSaved?: () => void; userId: string | null }) {
  const [drafts, setDrafts] = useState<Draft[]>(() => [makeDraft(1)])
  const [activeId, setActiveId] = useState<number>(() => drafts[0]?.id ?? 0)
  // Where each draft draws its controls in the bar above.
  const [slots, setSlots] = useState<Record<number, HTMLDivElement>>({})
  const setSlot = (id: number, el: HTMLDivElement | null) => {
    if (el) setSlots(s => (s[id] === el ? s : { ...s, [id]: el }))
  }

  function addDraft() {
    if (drafts.length >= MAX_DRAFTS) return
    const next = makeDraft(drafts.length + 1)
    setDrafts(ds => [...ds, next])
    setActiveId(next.id)
  }

  function closeDraft(id: number) {
    if (drafts.length <= 1) return
    setDrafts(ds => {
      const idx = ds.findIndex(d => d.id === id)
      const next = ds.filter(d => d.id !== id)
      if (activeId === id) {
        const fallback = next[idx] || next[idx - 1] || next[0]
        setActiveId(fallback.id)
      }
      return next
    })
  }

  return (
    <div>
      {/* Draft tab bar */}
      <div style={{
        display: 'flex', gap: 6, marginBottom: 14, flexWrap: 'wrap', alignItems: 'center',
      }}>
        {drafts.map(d => {
          const active = d.id === activeId
          return (
            <div key={d.id} style={{ display: 'flex', alignItems: 'center' }}>
              <button
                onClick={() => setActiveId(d.id)}
                style={{
                  padding: '8px 14px',
                  borderTopLeftRadius: 10, borderBottomLeftRadius: 10,
                  borderTopRightRadius: drafts.length > 1 ? 0 : 10,
                  borderBottomRightRadius: drafts.length > 1 ? 0 : 10,
                  border: `1px solid ${active ? TEAL : 'rgba(10,124,255,0.2)'}`,
                  background: active ? TEAL : 'var(--qb-card)',
                  color: active ? '#ffffff' : 'var(--qb-text)',
                  fontWeight: 800, fontSize: 12, letterSpacing: '0.1em',
                  cursor: 'pointer',
                }}
              >
                {d.label}
              </button>
              {drafts.length > 1 && (
                <button
                  onClick={() => closeDraft(d.id)}
                  title="Close draft"
                  style={{
                    padding: '8px 10px',
                    borderTopRightRadius: 10, borderBottomRightRadius: 10,
                    borderTop: `1px solid ${active ? TEAL : 'rgba(10,124,255,0.2)'}`,
                    borderRight: `1px solid ${active ? TEAL : 'rgba(10,124,255,0.2)'}`,
                    borderBottom: `1px solid ${active ? TEAL : 'rgba(10,124,255,0.2)'}`,
                    borderLeft: 'none',
                    background: active ? 'rgba(10,124,255,0.85)' : 'var(--qb-card)',
                    color: active ? '#ffffff' : 'var(--qb-sub)',
                    fontWeight: 900, fontSize: 14, cursor: 'pointer',
                  }}
                >
                  ×
                </button>
              )}
            </div>
          )
        })}
        {drafts.length < MAX_DRAFTS && (
          <button
            onClick={addDraft}
            title="New draft invoice"
            style={{
              padding: '8px 14px', borderRadius: 10,
              border: '1px dashed rgba(10,124,255,0.4)',
              background: 'transparent', color: TEAL,
              fontWeight: 800, fontSize: 12, letterSpacing: '0.1em', cursor: 'pointer',
            }}
          >
            + NEW DRAFT
          </button>
        )}
        <span style={{ color: 'var(--qb-muted)', fontSize: 11, fontVariantNumeric: 'tabular-nums', marginLeft: 6 }} title="Each draft keeps what was typed when you switch">
          {drafts.length}/{MAX_DRAFTS} drafts
        </span>
        {/* Each draft's own date and scan controls are drawn here, on this row,
            to leave the form below its full height for the item lines. */}
        {drafts.map(d => (
          <div key={d.id} ref={el => setSlot(d.id, el)}
            style={{ display: d.id === activeId ? 'flex' : 'none', flex: 1, minWidth: 0, justifyContent: 'flex-end', alignItems: 'center', gap: 8 }} />
        ))}
      </div>

      {/* All drafts are mounted; only the active one is visible. This preserves
          every InvoiceForm's internal state across tab switches. */}
      {drafts.map(d => (
        <div key={d.id} style={{ display: d.id === activeId ? 'block' : 'none' }}>
          <InvoiceForm onSaved={onSaved} userId={userId} toolbarSlot={slots[d.id] ?? null} />
        </div>
      ))}
    </div>
  )
}
