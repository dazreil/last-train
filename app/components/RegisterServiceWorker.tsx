'use client';

import { useEffect } from 'react';

/**
 * Registers the service worker so the app opens from the home screen without
 * waiting on the network. Deliberately silent: a registration failure (private
 * browsing, an unsupported browser, plain HTTP in development) must not affect
 * the app, which works perfectly well without it.
 */
export default function RegisterServiceWorker() {
  useEffect(() => {
    if (!('serviceWorker' in navigator)) return;
    if (process.env.NODE_ENV !== 'production') return;

    const register = () => {
      navigator.serviceWorker.register('/sw.js').catch(() => {});
    };

    // After load, so registration never competes with the first paint.
    if (document.readyState === 'complete') register();
    else window.addEventListener('load', register, { once: true });

    return () => window.removeEventListener('load', register);
  }, []);

  return null;
}
