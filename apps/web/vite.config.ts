import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { resolve } from "node:path";
import { defineConfig } from "vite";

// Two pages from one codebase:
//   index.html  the PC app, served by the SwiftDrop server on the PC (plain http on the LAN)
//   p2p.html    phone <-> phone, fully standalone; needs https (OPFS, camera), so
//               `--mode p2p` builds only it into dist-p2p for any static https host.
// Dev server is localhost-only on purpose: behind the proxy every request would look
// like it came from the PC itself. Test the phone against `pnpm start` (port 8787).
export default defineConfig(({ mode }) => ({
  plugins: [react(), tailwindcss()],
  server: {
    host: "localhost",
    port: 5173,
    proxy: { "/api": { target: "http://localhost:8787", ws: true } },
  },
  worker: { format: "es" },
  build: {
    target: "es2022",
    sourcemap: false,
    assetsInlineLimit: 0,
    outDir: mode === "p2p" ? "dist-p2p" : "dist",
    rollupOptions: {
      input: mode === "p2p" ? { p2p: resolve(__dirname, "p2p.html") } : { main: resolve(__dirname, "index.html"), p2p: resolve(__dirname, "p2p.html") },
    },
  },
}));
