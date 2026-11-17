/**
 * The QBNET TECH SOLUTIONS mark: the satellite dish from the company logo,
 * on a white tile so it reads on light and dark backgrounds.
 * public/qbnet-logo.jpg is the full logo as supplied; public/logo.jpg (with
 * the name) and public/logo-mark.png / fav.jpg (dish only) are cut from it.
 */
export default function QbnetLogo({ size = 36, radius }: { size?: number; radius?: number }) {
  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img src="/logo-mark.png" alt="QBNET TECH SOLUTIONS" width={size} height={size}
      style={{ display: 'block', flexShrink: 0, width: size, height: size, borderRadius: radius ?? Math.round(size * 0.25),
        background: '#fff', objectFit: 'contain', boxShadow: '0 0 0 1px rgba(0,0,0,0.06)' }} />
  )
}
