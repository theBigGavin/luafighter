import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    port: 3000,
    proxy: {
      '/api/streams': {
        target: 'http://localhost:9005',
        changeOrigin: true,
      },
      '/api': {
        target: 'http://localhost:9003',
        changeOrigin: true,
      },
      '/socket.io': {
        target: 'http://localhost:9003',
        ws: true,
      },
    },
  },
  build: {
    outDir: 'dist',
  },
});
