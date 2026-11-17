'use client'

import { useEffect, useRef, useState } from 'react'
import { type IScannerControls } from '@zxing/browser'
import { ArrowLeft, Flashlight, FlashlightOff } from 'lucide-react'

// ─────────────────────────────────────────────────────────────
// CameraScanner — phone/webcam barcode scanning for stock taking.
//
// Uses ZXing (works on iOS Safari, where the native BarcodeDetector API is
// absent). Every decode is handed to onDetect, which routes through the exact
// same handleCode pipeline as the USB-wedge input, so filtering / linking /
// deduction behave identically. A per-code cooldown means holding one barcode
// in frame counts once; swapping to the next item counts again immediately.
// ─────────────────────────────────────────────────────────────

const TEAL = '#4f7cff'

type Tone = 'ok' | 'warn' | 'err'

export default function CameraScanner({ active, banner, onDetect, onClose }: {
  active: boolean                                   // false while a link/qty modal is open → pause counting
  banner: { tone: Tone; title: string; sub?: string } | null
  onDetect: (text: string) => void
  onClose: () => void
}) {
  const videoRef    = useRef<HTMLVideoElement>(null)
  const controlsRef = useRef<IScannerControls | null>(null)
  const lastRef     = useRef<{ code: string; t: number }>({ code: '', t: 0 })
  const activeRef   = useRef(active)
  const detectRef   = useRef(onDetect)
  activeRef.current = active
  detectRef.current = onDetect

  const [error,     setError]     = useState<string | null>(null)
  const [torchOn,   setTorchOn]   = useState(false)
  const [torchable, setTorchable] = useState(false)

  useEffect(() => {
    let cancelled = false
    // The camera API only exists in a secure context (HTTPS or localhost).
    // Over plain http:// on a LAN IP, navigator.mediaDevices is undefined —
    // guard so we show guidance instead of a raw "undefined is not an object".
    if (typeof navigator === 'undefined' || !navigator.mediaDevices?.getUserMedia) {
      setError('Camera needs a secure (HTTPS) connection. This page is on http://, so the browser blocks the camera. Use the USB scanner here, or open the site over https:// to scan with the camera.')
      return
    }
    ;(async () => {
      try {
        // Lazy-load ZXing so it never evaluates during server render and is
        // only fetched when the camera is actually opened.
        const { BrowserMultiFormatReader } = await import('@zxing/browser')
        const reader = new BrowserMultiFormatReader()
        const controls = await reader.decodeFromConstraints(
          { video: { facingMode: { ideal: 'environment' } } },
          videoRef.current!,
          (result) => {
            if (!result || !activeRef.current) return
            const text = result.getText()
            const now = Date.now()
            if (lastRef.current.code === text && now - lastRef.current.t < 1500) return
            lastRef.current = { code: text, t: now }
            detectRef.current(text)
          },
        )
        if (cancelled) { controls.stop(); return }
        controlsRef.current = controls
        const track = (videoRef.current?.srcObject as MediaStream | null)?.getVideoTracks?.()[0]
        const caps = track?.getCapabilities?.() as { torch?: boolean } | undefined
        if (caps && 'torch' in caps) setTorchable(true)
      } catch (e) {
        setError(e instanceof Error ? e.message : 'Cannot access camera — grant permission and use HTTPS.')
      }
    })()
    return () => { cancelled = true; controlsRef.current?.stop() }
  }, [])

  const toggleTorch = async () => {
    const track = (videoRef.current?.srcObject as MediaStream | null)?.getVideoTracks?.()[0]
    if (!track) return
    try {
      const next = !torchOn
      await track.applyConstraints({ advanced: [{ torch: next }] } as unknown as MediaTrackConstraints)
      setTorchOn(next)
    } catch { /* torch not controllable */ }
  }

  const bc = banner?.tone === 'ok' ? TEAL : banner?.tone === 'warn' ? '#f59e0b' : '#ef4444'

  return (
    // z-index sits BELOW the link/qty modals (9998+) so those render on top.
    <div style={{ position: 'fixed', inset: 0, zIndex: 9000, background: '#000', display: 'flex', flexDirection: 'column' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '12px 16px', color: '#fff' }}>
        <button onClick={onClose} style={{ display: 'flex', alignItems: 'center', gap: 8, background: 'rgba(255,255,255,0.12)', border: 'none', color: '#fff', borderRadius: 10, padding: '9px 16px 9px 12px', fontWeight: 800, fontSize: 14, cursor: 'pointer' }}>
          <ArrowLeft size={20} /> Back
        </button>
        <span style={{ fontWeight: 800, letterSpacing: '0.08em', fontSize: 13, opacity: 0.9 }}>CAMERA SCAN</span>
        <button onClick={onClose} style={{ background: TEAL, border: 'none', color: '#04130f', borderRadius: 10, padding: '9px 20px', fontWeight: 800, fontSize: 14, cursor: 'pointer' }}>Done</button>
      </div>

      <div style={{ position: 'relative', flex: 1, overflow: 'hidden' }}>
        <video ref={videoRef} autoPlay muted playsInline style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
        {/* Aiming reticle */}
        <div style={{ position: 'absolute', top: '50%', left: '50%', transform: 'translate(-50%,-50%)', width: '72%', maxWidth: 340, aspectRatio: '3 / 2', border: `3px solid ${TEAL}`, borderRadius: 16, boxShadow: '0 0 0 4000px rgba(0,0,0,0.35)' }} />
        {error && <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff', textAlign: 'center', padding: 24, fontSize: 14 }}>{error}</div>}

        {/* Last-scan banner (beep/vibrate come from the parent's report()) */}
        {banner && (
          <div style={{ position: 'absolute', left: 16, right: 16, bottom: 16, borderRadius: 12, background: `${bc}`, color: banner.tone === 'ok' ? '#060d1a' : '#fff', padding: '12px 16px', fontWeight: 800, boxShadow: '0 8px 24px rgba(0,0,0,0.4)' }}>
            <div style={{ fontFamily: 'monospace', fontSize: 15 }}>{banner.title}</div>
            {banner.sub && <div style={{ fontSize: 12, opacity: 0.85, marginTop: 2 }}>{banner.sub}</div>}
          </div>
        )}
      </div>

      <div style={{ padding: '14px 18px', textAlign: 'center', color: '#94a3b8', fontSize: 12 }}>
        {torchable
          ? <button onClick={toggleTorch} style={{ display: 'inline-flex', alignItems: 'center', gap: 8, background: torchOn ? TEAL : 'rgba(255,255,255,0.15)', border: 'none', color: torchOn ? '#04130f' : '#fff', borderRadius: 9, padding: '10px 22px', fontWeight: 800, cursor: 'pointer' }}>
              {torchOn ? <Flashlight size={18} /> : <FlashlightOff size={18} />} {torchOn ? 'Torch on' : 'Torch'}
            </button>
          : <span>Aim the box barcode inside the frame</span>}
      </div>
    </div>
  )
}
