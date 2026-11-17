import type { Config } from "tailwindcss";

// Colours and type map onto the --qb-* design tokens (src/app/qb-ios.css), so
// a class like `text-qb-sub` or `bg-qb-card` follows light/dark automatically.
const config: Config = {
  content: [
    "./src/pages/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/components/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/app/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      colors: {
        qb: {
          bg: "var(--qb-bg)",
          card: "var(--qb-card)",
          "card-strong": "var(--qb-card-strong)",
          text: "var(--qb-text)",
          sub: "var(--qb-sub)",
          muted: "var(--qb-muted)",
          faint: "var(--qb-faint)",
          border: "var(--qb-border)",
          separator: "var(--qb-separator)",
          fill: "var(--qb-fill)",
          accent: "var(--qb-accent)",
          red: "var(--qb-red)",
          green: "var(--qb-green)",
          orange: "var(--qb-orange)",
        },
      },
      fontFamily: {
        // Apple's pairing: SF Pro Text (sans/body) and SF Pro Display (headings).
        // `font-mono` was the old cyber look; it now resolves to the text face.
        sans: "var(--qb-font)",
        heading: "var(--qb-font-display)",
        display: "var(--qb-font-display)",
        body: "var(--qb-font)",
        mono: "var(--qb-font)",
      },
      borderRadius: {
        qb: "var(--qb-radius)",
      },
    },
  },
  plugins: [],
};
export default config;
