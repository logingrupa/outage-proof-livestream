import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// "type": "module" in package.json means __dirname is undefined here --
// derive it from import.meta.url instead (see RESEARCH.md Q1 / D-15).
const currentDirectory = path.dirname(fileURLToPath(import.meta.url))

// https://vite.dev/config/
export default defineConfig({
  base: '/outage-proof-livestream/',
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      '@': path.resolve(currentDirectory, './src'),
    },
  },
})
