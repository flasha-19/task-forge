import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// For GitHub Pages the workflow sets VITE_BASE=/<repository-name>/ ; locally it is "/".
export default defineConfig({
  base: process.env.VITE_BASE ?? "/",
  plugins: [react()],
});
