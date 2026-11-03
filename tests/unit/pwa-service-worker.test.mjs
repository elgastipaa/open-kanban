import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { runInNewContext } from "node:vm";

const workerSource = await readFile(
  new URL("../../public/sw.js", import.meta.url),
  "utf8",
);
const offlineDocument = await readFile(
  new URL("../../public/offline.v1.html", import.meta.url),
  "utf8",
);

const origin = "https://openkanban.example";

function requestUrl(request) {
  return typeof request === "string" ? request : request.url;
}

function createWorker({ fetchFails = false } = {}) {
  const listeners = new Map();
  const openedCaches = [];
  const deletedCaches = [];
  const cacheEntries = new Map();
  const cacheMatches = [];
  const cacheWrites = [];
  const fetchCalls = [];
  const oldCaches = ["openkanban-public-v0", "unrelated-cache"];
  let didClaimClients = false;
  let didSkipWaiting = false;
  let networkIsAvailable = !fetchFails;

  const cache = {
    added: [],
    async addAll(urls) {
      this.added = [...urls];
      for (const path of urls) {
        const body =
          path === "/offline.v1.html" ? offlineDocument : `static:${path}`;
        cacheEntries.set(new URL(path, origin).href, new Response(body));
      }
    },
    async match(request) {
      const url = new URL(requestUrl(request), origin);
      cacheMatches.push(`${url.pathname}${url.search}`);
      return cacheEntries.get(url.href) ?? null;
    },
    async put(request, response) {
      cacheWrites.push(requestUrl(request));
      cacheEntries.set(new URL(requestUrl(request), origin).href, response);
    },
  };

  const caches = {
    async open(name) {
      openedCaches.push(name);
      return cache;
    },
    async keys() {
      return [...oldCaches, ...new Set(openedCaches)];
    },
    async delete(name) {
      deletedCaches.push(name);
      return true;
    },
  };

  const self = {
    location: { origin },
    addEventListener(name, callback) {
      listeners.set(name, callback);
    },
    skipWaiting() {
      didSkipWaiting = true;
      return Promise.resolve();
    },
    clients: {
      claim() {
        didClaimClients = true;
        return Promise.resolve();
      },
    },
  };

  runInNewContext(workerSource, {
    caches,
    fetch: async (request) => {
      const url = new URL(requestUrl(request), origin);
      fetchCalls.push(url.href);
      if (!networkIsAvailable) throw new Error("offline fixture");
      if (url.pathname === "/offline.v1.html") {
        return new Response(offlineDocument, {
          headers: { "Content-Type": "text/html; charset=utf-8" },
        });
      }
      return new Response(`network:${url.pathname}${url.search}`);
    },
    Response,
    URL,
    self,
  });

  async function dispatchLifecycle(name, props = {}) {
    const pending = [];
    const event = {
      ...props,
      waitUntil(promise) {
        pending.push(Promise.resolve(promise));
      },
    };
    listeners.get(name)(event);
    await Promise.all(pending);
  }

  function dispatchFetch(request) {
    let responsePromise = null;
    listeners.get("fetch")({
      request,
      respondWith(promise) {
        responsePromise = Promise.resolve(promise);
      },
    });
    return { intercepted: responsePromise !== null, responsePromise };
  }

  return {
    cache,
    cacheEntries,
    cacheMatches,
    cacheWrites,
    deletedCaches,
    dispatchFetch,
    dispatchLifecycle,
    fetchCalls,
    get didClaimClients() {
      return didClaimClients;
    },
    get didSkipWaiting() {
      return didSkipWaiting;
    },
    get hasMessageHandler() {
      return listeners.has("message");
    },
    openedCaches,
    set networkIsAvailable(value) {
      networkIsAvailable = value;
    },
  };
}

test("install caches only explicitly versioned public PWA resources", async () => {
  const worker = createWorker();
  await worker.dispatchLifecycle("install");

  assert.deepEqual(worker.openedCaches, ["openkanban-public-v1"]);
  assert.deepEqual(worker.cache.added, [
    "/offline.v1.html",
    "/icons/open-kanban-192.v1.svg",
    "/icons/open-kanban-512.v1.svg",
  ]);
});

test("private navigation and login return URLs stay network-only and unchanged", async () => {
  const worker = createWorker();
  await worker.dispatchLifecycle("install");
  const privateUrl = `${origin}/planning-board?filter=assigned`;
  const callbackUrl = `${origin}/auth/callback?code=synthetic&next=%2Fplanning-board%3Ffilter%3Dassigned`;

  const privateNavigation = worker.dispatchFetch({
    method: "GET",
    mode: "navigate",
    url: privateUrl,
  });
  const privateResponse = await privateNavigation.responsePromise;
  assert.equal(
    await privateResponse.text(),
    "network:/planning-board?filter=assigned",
  );

  const callbackNavigation = worker.dispatchFetch({
    method: "GET",
    mode: "navigate",
    url: callbackUrl,
  });
  const callbackResponse = await callbackNavigation.responsePromise;
  assert.equal(
    await callbackResponse.text(),
    "network:/auth/callback?code=synthetic&next=%2Fplanning-board%3Ffilter%3Dassigned",
  );
  assert.equal(worker.fetchCalls.at(-1), callbackUrl);
  assert.deepEqual(worker.cacheWrites, []);
  assert.ok(
    !worker.cacheMatches.some((path) => path.includes("planning-board")),
  );
});

test("logout and account change never reuse prior session content from CacheStorage", async () => {
  const worker = createWorker();
  await worker.dispatchLifecycle("install");

  const firstAccount = worker.dispatchFetch({
    method: "GET",
    mode: "navigate",
    url: `${origin}/planning-board?fixture=account-a`,
  });
  const firstResponse = await firstAccount.responsePromise;
  assert.match(await firstResponse.text(), /fixture=account-a/);

  const logout = worker.dispatchFetch({
    method: "GET",
    mode: "navigate",
    url: `${origin}/`,
  });
  assert.equal(await (await logout.responsePromise).text(), "network:/");

  const secondAccount = worker.dispatchFetch({
    method: "GET",
    mode: "navigate",
    url: `${origin}/planning-board?fixture=account-b`,
  });
  const secondResponse = await secondAccount.responsePromise;
  assert.match(await secondResponse.text(), /fixture=account-b/);

  assert.deepEqual(worker.cacheWrites, []);
  assert.ok(
    !worker.cacheMatches.some((path) => path.includes("planning-board")),
  );
});

test("offline private navigation shows only the generic public fallback", async () => {
  const worker = createWorker();
  await worker.dispatchLifecycle("install");
  worker.networkIsAvailable = false;

  const navigation = worker.dispatchFetch({
    method: "GET",
    mode: "navigate",
    url: `${origin}/private-board-title?tab=secret`,
  });
  const response = await navigation.responsePromise;
  const body = await response.text();

  assert.match(body, /Sin conexión/);
  assert.doesNotMatch(body, /private-board-title|secret/);
  assert.deepEqual(worker.cacheMatches, ["/offline.v1.html"]);
  assert.deepEqual(worker.cacheWrites, []);
});

test("API requests and unversioned assets are not intercepted or queued", async () => {
  const worker = createWorker();
  await worker.dispatchLifecycle("install");

  const apiRequest = worker.dispatchFetch({
    method: "POST",
    mode: "cors",
    url: `${origin}/api/search`,
  });
  const unversionedAsset = worker.dispatchFetch({
    method: "GET",
    mode: "no-cors",
    url: `${origin}/icons/open-kanban-192.svg`,
  });

  assert.equal(apiRequest.intercepted, false);
  assert.equal(unversionedAsset.intercepted, false);
  assert.deepEqual(worker.cacheWrites, []);
});

test("service worker never forces activation when a new version is installed", async () => {
  const worker = createWorker();
  await worker.dispatchLifecycle("install");
  assert.equal(worker.didSkipWaiting, false);

  await worker.dispatchLifecycle("activate");
  assert.equal(worker.didClaimClients, true);
  assert.deepEqual(worker.deletedCaches, ["openkanban-public-v0"]);
  assert.equal(worker.hasMessageHandler, false);
  assert.equal(worker.didSkipWaiting, false);
});
