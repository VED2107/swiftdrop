import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";

// Static marketing/download page for Vercel. The app itself runs on the user's PC.
export default defineConfig({
  plugins: [tailwindcss()],
  build: { target: "es2022", assetsInlineLimit: 0 },
});
