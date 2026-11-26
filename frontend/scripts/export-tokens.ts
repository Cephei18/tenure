// Writes docs/design-tokens.json from src/theme/tokens.ts so the slide deck reuses the exact values.
// Run: npm run tokens   (tokens.test.ts fails if the JSON or src/index.css drifts from tokens.ts)
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { tokens } from "../src/theme/tokens";

const out = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "docs", "design-tokens.json");
const doc = { $comment: "Generated from frontend/src/theme/tokens.ts by `npm run tokens`. Do not edit.", ...tokens };
writeFileSync(out, JSON.stringify(doc, null, 2) + "\n");
console.log(`wrote ${out}`);
