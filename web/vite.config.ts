import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Minimal SPA build. `base: "./"` keeps asset paths relative so the dist can be
// served from any sub-path (IPFS, a CDN folder) without extra config.
export default defineConfig({
  base: "./",
  plugins: [react()],
});
