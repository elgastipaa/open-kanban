const CACHE_PREFIX = "openkanban-public-";
// Give each worker release a separate cache so a failed install cannot delete the active worker's shell.
const CACHE_NAME = `${CACHE_PREFIX}v2`;
const OFFLINE_URL = "/offline.v1.html";
// Bump the cache and asset versions together when this public shell changes.
const PUBLIC_ASSETS = [
  OFFLINE_URL,
  "/icons/open-kanban-192.v1.svg",
  "/icons/open-kanban-512.v1.svg",
];
const PUBLIC_ASSET_PATHS = new Set(PUBLIC_ASSETS);

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(CACHE_NAME)
      .then((cache) => cache.addAll(PUBLIC_ASSETS))
      .catch(async (error) => {
        await caches.delete(CACHE_NAME);
        throw error;
      }),
  );
});

self.addEventListener("message", (event) => {
  if (event.data?.type === "ACTIVATE_UPDATE") {
    event.waitUntil(self.skipWaiting());
  }
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((names) =>
        Promise.all(
          names
            .filter(
              (name) => name.startsWith(CACHE_PREFIX) && name !== CACHE_NAME,
            )
            .map((name) => caches.delete(name)),
        ),
      )
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  if (url.search === "" && PUBLIC_ASSET_PATHS.has(url.pathname)) {
    event.respondWith(
      caches.open(CACHE_NAME).then(async (cache) => {
        const cached = await cache.match(request);
        return cached ?? fetch(request);
      }),
    );
    return;
  }

  if (request.mode === "navigate") {
    event.respondWith(
      fetch(request).catch(async () => {
        const cache = await caches.open(CACHE_NAME);
        const offlinePage = await cache.match(OFFLINE_URL);
        return (
          offlinePage ??
          new Response(
            '<!doctype html><html lang="es"><meta charset="utf-8"><title>Sin conexión</title><h1>Sin conexión</h1><p>Volvé a conectarte para cargar OpenKanban.</p>',
            { headers: { "Content-Type": "text/html; charset=utf-8" } },
          )
        );
      }),
    );
  }
});
