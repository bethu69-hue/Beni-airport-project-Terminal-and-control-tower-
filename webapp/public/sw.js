// Service worker: makes the app installable and lets it open offline.
// Rules: (1) the app shell and pages already visited are cached; (2) API data is NEVER served from a cache as if it were current;
// (3) writes made offline go to the outbox (lib/outbox.ts) and are sent when the connection returns.
// UNTESTED: written without a browser or build environment. Test on a real phone before relying on it.
const VERSION = 'beni-shell-v1';
const SHELL = ['/', '/offline.html', '/manifest.webmanifest'];

self.addEventListener('install', (e) => { e.waitUntil(caches.open(VERSION).then((c) => c.addAll(SHELL))); self.skipWaiting(); });
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== VERSION).map((k) => caches.delete(k)))));
  self.clients.claim();
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== location.origin) return;           // Supabase and other APIs are never cached here
  if (url.pathname.startsWith('/api/')) return;
  if (req.mode === 'navigate') {                         // pages: network first, fall back to the last copy, then the offline page
    e.respondWith(fetch(req).then((r) => { const c = r.clone(); caches.open(VERSION).then((k) => k.put(req, c)); return r; })
      .catch(() => caches.match(req).then((m) => m || caches.match('/offline.html'))));
    return;
  }
  e.respondWith(caches.match(req).then((m) => m || fetch(req).then((r) => { const c = r.clone(); caches.open(VERSION).then((k) => k.put(req, c)); return r; })));
});

// Background sync: ask open pages to flush the outbox
self.addEventListener('sync', (e) => {
  if (e.tag === 'beni-outbox') e.waitUntil(self.clients.matchAll().then((cs) => cs.forEach((c) => c.postMessage({ type: 'flush-outbox' }))));
});
