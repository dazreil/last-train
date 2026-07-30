import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  // Pinned because there is another lockfile higher up the home directory, which
  // Turbopack would otherwise pick as the workspace root.
  turbopack: { root: __dirname },

  async headers() {
    return [
      {
        // The service worker must be allowed to control the whole origin, and
        // must not be cached by the browser or it can never be replaced.
        source: '/sw.js',
        headers: [
          { key: 'Cache-Control', value: 'no-cache, no-store, must-revalidate' },
          { key: 'Service-Worker-Allowed', value: '/' },
        ],
      },
      {
        source: '/:path*',
        headers: [
          { key: 'X-Content-Type-Options', value: 'nosniff' },
          { key: 'Referrer-Policy', value: 'no-referrer' },
          // Single-user personal tool; nothing here should be framed.
          { key: 'X-Frame-Options', value: 'DENY' },
        ],
      },
    ];
  },
};

export default nextConfig;
