/*
 * The old web app's service worker, replaced by one that removes itself.
 *
 * The web board is gone (25 September 2026). A phone that added it to the home screen
 * still has the old worker, which served a cached copy of the board whatever the server
 * said. A browser checks this file for updates, so this version is what it finds: it
 * clears every cache the old worker made, unregisters, and reloads open pages so they
 * show the site as it is now. Keep it for a few months, then delete it.
 */
self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      for (const key of await caches.keys()) await caches.delete(key);
      await self.registration.unregister();
      for (const client of await self.clients.matchAll({ type: 'window' })) client.navigate(client.url);
    })()
  );
});
