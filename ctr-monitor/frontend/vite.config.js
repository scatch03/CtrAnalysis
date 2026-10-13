import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// dev: `npm run dev` with the Flask backend on :5000 (python wsgi.py)
export default defineConfig({
  plugins: [react()],
  server: { port: 5173, proxy: { "/api": "http://127.0.0.1:5000" } },
  build: { outDir: "dist", sourcemap: false, chunkSizeWarningLimit: 800 },
});
