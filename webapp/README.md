# Web app (to be built)

The app is a Next.js + Supabase application that installs on a phone or laptop (PWA) and opens offline.

Already written here, **untested** (no build environment or browser was available):
- `public/manifest.webmanifest`: install on phone and laptop (icons still to be drawn: 192, 512, maskable 512)
- `public/sw.js` and `public/offline.html`: app shell and visited pages work offline; API data is never presented from a cache as current
- `lib/outbox.ts`: offline writes are queued on the device and sent when online. Notices, sign-offs and issuing never queue offline, because the server must record the true time.

To do: register the service worker, add `p_client_id` (idempotency) to the write functions that may be queued, language switch (profiles.language, English/French dictionary), pages for report, trackers and sign-off, and the email/WhatsApp sender service. Offline use must be tested on a real phone on a poor connection before anyone relies on it.
