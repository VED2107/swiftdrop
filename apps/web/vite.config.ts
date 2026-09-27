import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// Dev server is localhost-only on purpose: behind the proxy every request would look
// like it came from the PC itself. Test the phone against `pnpm start` (port 8787).
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    host: "localhost",
    port: 5173,
    proxy: { "/api": { target: "http://localhost:8787", ws: true } },
  },
  build: { target: "es2022", sourcemap: false, assetsInlineLimit: 0 },
});
