/// <reference types="vitest/config" />
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// Static build. Hosted at the domain root ("/", e.g. Vercel) by default; GITHUB_PAGES=true builds for a GitHub
// Pages project site under /tenure/ (.github/workflows/pages.yml sets it).
// Data files (docs/results/*.csv, deployments/*.json) are imported straight from the repo root, so the
// frontend never holds a second, drifting copy: `server.fs.allow` lets the dev server read them.
export default defineConfig({
  base: process.env.GITHUB_PAGES === "true" ? "/tenure/" : "/",
  plugins: [react(), tailwindcss()],
  server: { fs: { allow: [".."] } },
  build: {
    rollupOptions: {
      output: {
        // vendor chunks cache across deploys and keep the app chunk small (recharts pulls in react + d3)
        manualChunks: { vendor: ["react", "react-dom", "recharts"], viem: ["viem"] },
      },
    },
    chunkSizeWarningLimit: 600, // the vendor chunk is ~550 kB minified (~160 kB gzip); nothing app-side is large
  },
  test: { environment: "node", include: ["src/**/*.test.ts"] },
});
