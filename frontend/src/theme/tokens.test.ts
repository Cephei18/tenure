// One source of truth: src/index.css and docs/design-tokens.json must equal tokens.ts, and every text colour must
// meet WCAG AA (4.5:1) on every surface it is used on.
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { tokens } from "./tokens";

const css = readFileSync(new URL("../index.css", import.meta.url), "utf8");
const json = JSON.parse(readFileSync(new URL("../../../docs/design-tokens.json", import.meta.url), "utf8"));

function luminance(hex: string) {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
export const contrast = (a: string, b: string) => {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
};

describe("design tokens", () => {
  it("index.css declares every colour token with the same value", () => {
    for (const [name, value] of Object.entries(tokens.color)) {
      expect(css, name).toContain(`--color-${name}: ${value};`);
    }
    expect(css).toContain(`--font-sans: ${tokens.font.sans};`);
  });

  it("docs/design-tokens.json is the current export (npm run tokens)", () => {
    const { $comment, ...rest } = json;
    expect($comment).toMatch(/Generated from frontend\/src\/theme\/tokens.ts/);
    expect(rest).toEqual(JSON.parse(JSON.stringify(tokens)));
  });

  it("text colours meet WCAG AA (4.5:1) on every surface", () => {
    const { bg, surface, surface2, text, soft, muted, accent, full, restricted } = tokens.color;
    for (const surf of [bg, surface, surface2]) {
      for (const fg of [text, soft, muted, accent, full, restricted]) {
        expect(contrast(fg, surf), `${fg} on ${surf}`).toBeGreaterThanOrEqual(4.5);
      }
    }
  });

  it("FROZEN rose is used for badges/large text: >= 3:1 (WCAG AA large / UI components)", () => {
    for (const surf of [tokens.color.bg, tokens.color.surface, tokens.color.surface2]) {
      expect(contrast(tokens.color.frozen, surf)).toBeGreaterThanOrEqual(3);
    }
  });
});
