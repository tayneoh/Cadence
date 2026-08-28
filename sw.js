/* Cadence service worker — enables offline use.
   Bump CACHE_VERSION whenever index.html or assets change so clients
   pick up the new files instead of a stale cache. */
const CACHE_VERSION = 'cadence-v4';

/* The app shell: local files that make up the installable app. */
const APP_SHELL = [
  './',
  './index.html',
  './manifest.json',
  './icon-180.png',
  './icon-192.png',
  './icon-512.png',
];

/* On install: pre-cache the app shell, then activate immediately. */
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION)
      .then((cache) => cache.addAll(APP_SHELL))
      .then(() => self.skipWaiting())
  );
});

/* On activate: drop any old caches from previous versions and take control. */
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys.filter((k) => k !== CACHE_VERSION).map((k) => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

/* Fetch strategy:
   - The HTML entry point (`index.html` or the app root) uses
     NETWORK-FIRST. This is essential — cache-first for HTML means users
     can be stuck on a broken build indefinitely even after we ship a
     fix, because the SW keeps serving the cached HTML and never notices
     the update. Network-first fetches fresh HTML when there's any
     connection at all, and falls back to cache only when offline.
   - Other local assets (icons, manifest) use cache-first; they change
     rarely and don't need to block on the network.
   - CDN assets (Tailwind, Lucide, fonts) use network-first with cache
     fallback so they update naturally but still work offline. */
self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);
  const isLocal = url.origin === self.location.origin;
  const isHtml = request.mode === 'navigate' ||
                 url.pathname === '/' ||
                 url.pathname.endsWith('/') ||
                 url.pathname.endsWith('.html');

  if (isLocal && isHtml) {
    // network-first: always try to get the fresh page, cache on success
    event.respondWith(
      fetch(request)
        .then((response) => {
          const copy = response.clone();
          caches.open(CACHE_VERSION).then((c) => c.put(request, copy));
          return response;
        })
        .catch(() => caches.match(request).then((c) => c || caches.match('./index.html')))
    );
  } else if (isLocal) {
    // cache-first for non-HTML local assets (icons, manifest)
    event.respondWith(
      caches.match(request).then((cached) => cached || fetch(request))
    );
  } else {
    // network-first for CDN assets
    event.respondWith(
      fetch(request)
        .then((response) => {
          const copy = response.clone();
          caches.open(CACHE_VERSION).then((cache) => cache.put(request, copy));
          return response;
        })
        .catch(() => caches.match(request))
    );
  }
});
