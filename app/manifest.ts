import type { MetadataRoute } from 'next';

/**
 * PWA manifest.
 *
 * The whole point is opening in one tap at 23:40 and answering in under two
 * seconds, so this is installed to the home screen rather than visited.
 * `display: standalone` drops the browser chrome; `start_url` restores the last
 * searched pair from localStorage on load.
 */
export default function manifest(): MetadataRoute.Manifest {
  return {
    name: 'Last Train',
    short_name: 'Last Train',
    description: 'First and last direct train between two stations.',
    start_url: '/',
    display: 'standalone',
    orientation: 'portrait',
    background_color: '#0b0d10',
    theme_color: '#0b0d10',
    icons: [
      {
        src: '/icons/icon-192.png',
        sizes: '192x192',
        type: 'image/png',
        purpose: 'any',
      },
      {
        src: '/icons/icon-512.png',
        sizes: '512x512',
        type: 'image/png',
        purpose: 'any',
      },
      {
        src: '/icons/icon-maskable-512.png',
        sizes: '512x512',
        type: 'image/png',
        purpose: 'maskable',
      },
    ],
  };
}
