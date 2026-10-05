// Guarda las páginas y librerías en el teléfono para que Agenda, Club y Staff abran sin internet.
const CACHE = "bg-v1";
const PRE = [
  "agenda.html", "club.html", "staff.html",
  "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2",
  "https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js",
  "https://unpkg.com/html5-qrcode@2.3.8/html5-qrcode.min.js"
];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => Promise.allSettled(PRE.map(u =>
    fetch(u, { mode: u.startsWith("http") ? "cors" : "same-origin" }).then(r => r.ok && c.put(u, r))))));
  self.skipWaiting();
});

self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

self.addEventListener("fetch", e => {
  const req = e.request, url = new URL(req.url);
  if (req.method !== "GET" || url.hostname.endsWith("supabase.co")) return;
  if (url.origin === location.origin) {
    // Páginas propias: primero internet (para tener siempre la última versión), si no hay, lo guardado
    e.respondWith(fetch(req).then(r => {
      if (r.ok) { const cp = r.clone(); caches.open(CACHE).then(c => c.put(url.pathname.endsWith("/") ? req : url.origin + url.pathname, cp)); }
      return r;
    }).catch(() => caches.match(req, { ignoreSearch: true }).then(m => m || caches.match(url.origin + url.pathname))));
    return;
  }
  // Librerías y fuentes: lo guardado primero
  e.respondWith(caches.match(req).then(m => m || fetch(req).then(r => {
    if (r.ok || r.type === "opaque") { const cp = r.clone(); caches.open(CACHE).then(c => c.put(req, cp)); }
    return r;
  })));
});
