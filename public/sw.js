/*
 * Service worker.
 *
 * Purpose is speed and reachability, not offline browsing: the app should open
 * from the home screen and paint immediately, even on a platform with one bar of
 * signal or none at all.
 *
 * Strategy:
 *   - App shell: network-first, falling back to cache, so a bad connection never
 *     leaves a blank screen.
 *   - Hashed build assets: cache-first. They are immutable by construction.
 *   - /api/trains: network-first, falling back to the last answer for that exact
 *     from:to:date. A stale copy is tagged so the page can say so -- a timetable
 *     answer that might be out of date is worth having, but only if it is
 *     labelled honestly.
 */

const VERSION = 'v1';
const SHELL_CACHE = `last-train-shell-${VERSION}`;
const ASSET_CACHE = `last-train-assets-${VERSION}`;
const API_CACHE = `last-train-api-${VERSION}`;

const SHELL_URLS = ['/', '/manifest.webmanifest', '/icons/icon-192.png', '/icons/icon-512.png'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(SHELL_CACHE);
      // Individually, so one 404 cannot fail the whole install.
      await Promise.all(
        SHELL_URLS.map((url) => cache.add(new Request(url, { cache: 'reload' })).catch(() => {}))
      );
      await self.skipWaiting();
    })()
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const keep = new Set([SHELL_CACHE, ASSET_CACHE, API_CACHE]);
      for (const name of await caches.keys()) {
        if (!keep.has(name)) await caches.delete(name);
      }
      await self.clients.claim();
    })()
  );
});

/** Copy a cached response, tagging it so the page knows it is not fresh. */
async function tagAsStale(response) {
  const headers = new Headers(response.headers);
  headers.set('x-from-cache', '1');
  return new Response(await response.blob(), {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

async function networkFirst(request, cacheName, { tag = false } = {}) {
  const cache = await caches.open(cacheName);
  try {
    const response = await fetch(request);
    if (response.ok) cache.put(request, response.clone());
    return response;
  } catch (error) {
    const cached = await cache.match(request);
    if (cached) return tag ? tagAsStale(cached) : cached;
    throw error;
  }
}

async function cacheFirst(request, cacheName) {
  const cache = await caches.open(cacheName);
  const cached = await cache.match(request);
  if (cached) return cached;
  const response = await fetch(request);
  if (response.ok) cache.put(request, response.clone());
  return response;
}

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  // Timetable lookups. Keyed by the full URL, which already contains the service
  // date, so a stale hit can never be a different day's timetable.
  if (url.pathname === '/api/trains') {
    event.respondWith(networkFirst(request, API_CACHE, { tag: true }));
    return;
  }

  // Immutable hashed assets.
  if (url.pathname.startsWith('/_next/static/') || url.pathname.startsWith('/icons/')) {
    event.respondWith(cacheFirst(request, ASSET_CACHE));
    return;
  }

  // Navigations and everything else in the shell.
  if (request.mode === 'navigate') {
    event.respondWith(
      networkFirst(request, SHELL_CACHE).catch(async () => {
        const cache = await caches.open(SHELL_CACHE);
        return (await cache.match('/')) ?? Response.error();
      })
    );
    return;
  }

  if (url.pathname === '/manifest.webmanifest') {
    event.respondWith(networkFirst(request, SHELL_CACHE));
  }
});
