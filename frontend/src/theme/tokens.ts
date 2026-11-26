// The design tokens: ONE source of truth for the site and the slide deck.
// - CSS: src/index.css declares the same values as Tailwind theme variables (checked by tokens.test.ts).
// - Deck: `npm run tokens` writes docs/design-tokens.json from this file (also checked by tokens.test.ts).
export const tokens = {
  color: {
    bg: "#14070c", // dark wine page background
    surface: "#1f0a12", // cards
    surface2: "#2a0f19", // raised elements, inputs, tracks
    border: "#3d1724", // subtle card borders
    primary: "#e11d48", // rose: primary actions, Tenure
    accent: "#f472b6", // pink: highlights, links
    soft: "#fbcfe8", // soft pink: secondary text
    text: "#ffffff", // primary text
    muted: "#c99aae", // tertiary text (axis labels, captions)
    // semantic tiers, used everywhere
    full: "#4ade80",
    restricted: "#fbbf24",
    frozen: "#e11d48",
    // scenario lines (same in every chart)
    runA: "#4ade80", // honest curator
    runB: "#fbbf24", // poisoned + static caps
    runC: "#f472b6", // poisoned + Tenure
  },
  font: {
    sans: 'Inter, ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
    mono: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
  },
  // spacing scale in px (Tailwind's 4 px grid; the deck uses the same steps)
  space: [0, 4, 8, 12, 16, 24, 32, 48, 64, 96],
  radius: { sm: 8, md: 12, lg: 16, full: 9999 },
  motion: { fast: 150, base: 300, slow: 700, easing: "cubic-bezier(0.2, 0.8, 0.2, 1)" },
} as const;

export const TIER_COLORS = [tokens.color.full, tokens.color.restricted, tokens.color.frozen] as const;
export const RUN_COLORS = { A: tokens.color.runA, B: tokens.color.runB, C: tokens.color.runC } as const;
