import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { resolve } from 'path'
import { viteStaticCopy } from 'vite-plugin-static-copy'

const uiComponentsSrc = resolve(__dirname, '../../libs/ui-components/src')

export default defineConfig({
  plugins: [
    react(),
    viteStaticCopy({
      targets: [
        {
          src: resolve(__dirname, '../../libs/i18n/locales'),
          dest: '.',
        },
      ],
    }),
  ],
  resolve: {
    alias: [
      {
        find: /^@osac\/ui-components\/(.+)$/,
        replacement: `${uiComponentsSrc}/$1`,
      },
    ],
  },
  server: {
    port: 5173,
    // Fail fast instead of silently moving to another port: the proxy's dev
    // config (BASE_UI_URL in package.json's dev:proxy script) hardcodes this
    // port for console WebSocket Origin validation.
    strictPort: true,
    proxy: {
      '/api': {
        target: 'http://localhost:8080',
        changeOrigin: true,
        ws: true,
      },
      '/health': {
        target: 'http://localhost:8080',
        changeOrigin: true,
      },
      '/ready': {
        target: 'http://localhost:8080',
        changeOrigin: true,
      },
    },
  },
  optimizeDeps: {
    include: ['@patternfly/react-charts > victory-core'],
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
  },
})
