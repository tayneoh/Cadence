/* Cadence service worker — enables offline use.
   Bump CACHE_VERSION whenever index.html or assets change so clients
   pick up the new files instead of a stale cache. */
const CACHE_VERSION = 'cadence-v2';

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

/* On activate: drop any old caches from previous versions. */
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
   - Local app-shell requests  -> cache-first (instant, works offline).
   - CDN assets (Tailwind, Lucide, fonts) -> network-first, fall back to
     cache so the app still loads when the user is offline.
   Only GET requests are handled; everything else passes straight through. */
self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);
  const isLocal = url.origin === self.location.origin;

  if (isLocal) {
    event.respondWith(
      caches.match(request).then((cached) => cached || fetch(request))
    );
  } else {
    event.respondWith(
      fetch(request)
        .then((response) => {
          // cache a copy of successful CDN responses for offline use
          const copy = response.clone();
          caches.open(CACHE_VERSION).then((cache) => cache.put(request, copy));
          return response;
        })
        .catch(() => caches.match(request))
    );
  }
});
