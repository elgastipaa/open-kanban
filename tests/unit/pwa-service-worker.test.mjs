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

function createWorker({
  fetchFails = false,
  cacheInstallFails = false,
  cacheVersion = "v2",
} = {}) {
  const listeners = new Map();
  const openedCaches = [];
  const deletedCaches = [];
  const cacheEntries = new Map();
  const cacheMatches = [];
  const cacheWrites = [];
  const fetchCalls = [];
  let currentCacheName = null;
  const oldCaches = [
    "openkanban-public-v1",
    "auth-session-cache",
    "unrelated-cache",
  ];
  const cacheNames = new Set(oldCaches);
  let didClaimClients = false;
  let didSkipWaiting = false;
  let networkIsAvailable = !fetchFails;
  let networkAccount = null;

  const cache = {
    added: [],
    async addAll(urls) {
      this.added = [...urls];
      for (const path of urls) {
        const body =
          path === "/offline.v1.html" ? offlineDocument : `static:${path}`;
        cacheEntries.set(new URL(path, origin).href, new Response(body));
      }
      if (cacheInstallFails) throw new Error("intermittent network fixture");
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
      cacheNames.add(name);
      currentCacheName = name;
      return cache;
    },
    async keys() {
      return [...cacheNames];
    },
    async delete(name) {
      deletedCaches.push(name);
      const deleted = cacheNames.delete(name);
      if (deleted && name === currentCacheName) cacheEntries.clear();
      return deleted;
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

  const source = workerSource.replace(
    /const CACHE_NAME = .+;/,
    `const CACHE_NAME = "openkanban-public-${cacheVersion}";`,
  );
  runInNewContext(source, {
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
      if (networkAccount) {
        return new Response(
          `network:${networkAccount}:${url.pathname}${url.search}`,
        );
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

  async function dispatchMessage(data) {
    const pending = [];
    listeners.get("message")?.({
      data,
      waitUntil(promise) {
        pending.push(Promise.resolve(promise));
      },
    });
    await Promise.all(pending);
  }

  return {
    cache,
    cacheEntries,
    cacheNames,
    cacheMatches,
    cacheWrites,
    deletedCaches,
    dispatchFetch,
    dispatchLifecycle,
    dispatchMessage,
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
    set networkAccount(value) {
      networkAccount = value;
    },
  };
}

test("install caches only explicitly versioned public PWA resources", async () => {
  const worker = createWorker();
  await worker.dispatchLifecycle("install");

  assert.deepEqual(worker.openedCaches, ["openkanban-public-v2"]);
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
  const privateUrl = `${origin}/planning-board?filter=assigned`;

  worker.networkAccount = "account-a";
  const firstAccount = worker.dispatchFetch({
    method: "GET",
    mode: "navigate",
    url: privateUrl,
  });
  const firstResponse = await firstAccount.responsePromise;
  assert.equal(
    await firstResponse.text(),
    "network:account-a:/planning-board?filter=assigned",
  );

  worker.networkAccount = null;
  const logout = worker.dispatchFetch({
    method: "GET",
    mode: "navigate",
    url: `${origin}/`,
  });
  assert.equal(await (await logout.responsePromise).text(), "network:/");

  worker.networkAccount = "account-b";
  const secondAccount = worker.dispatchFetch({
    method: "GET",
    mode: "navigate",
    url: privateUrl,
  });
  const secondResponse = await secondAccount.responsePromise;
  assert.equal(
    await secondResponse.text(),
    "network:account-b:/planning-board?filter=assigned",
  );

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

test("a new service worker waits for an explicit update choice", async () => {
  const worker = createWorker();
  await worker.dispatchLifecycle("install");
  assert.equal(worker.didSkipWaiting, false);
  assert.equal(worker.hasMessageHandler, true);

  await worker.dispatchMessage({ type: "UNRELATED" });
  assert.equal(worker.didSkipWaiting, false);

  await worker.dispatchMessage({ type: "ACTIVATE_UPDATE" });
  assert.equal(worker.didSkipWaiting, true);

  const installed = createWorker();
  await installed.dispatchLifecycle("install");
  assert.equal(installed.didSkipWaiting, false);
});

test("activation removes stale public caches and preserves Auth or unrelated caches", async () => {
  const worker = createWorker();
  await worker.dispatchLifecycle("install");
  await worker.dispatchLifecycle("activate");
  assert.equal(worker.didClaimClients, true);
  assert.deepEqual(worker.deletedCaches, ["openkanban-public-v1"]);
  assert.ok(!worker.cacheNames.has("openkanban-public-v1"));
  assert.ok(worker.cacheNames.has("auth-session-cache"));
  assert.ok(worker.cacheNames.has("unrelated-cache"));
  assert.ok(!worker.deletedCaches.includes("auth-session-cache"));
  assert.ok(!worker.deletedCaches.includes("unrelated-cache"));
});

test("intermittent network leaves the current installed and web versions usable", async () => {
  for (const launchMode of ["web", "installed"]) {
    const currentVersion = createWorker({ cacheVersion: "v1" });
    await currentVersion.dispatchLifecycle("install");
    await currentVersion.dispatchLifecycle("activate");

    const update = createWorker({ cacheInstallFails: true, cacheVersion: "v2" });

    await assert.rejects(update.dispatchLifecycle("install"));
    assert.equal(update.didSkipWaiting, false, `${launchMode} skipped waiting`);
    assert.deepEqual(update.deletedCaches, ["openkanban-public-v2"]);
    assert.ok(!update.cacheNames.has("openkanban-public-v2"));
    assert.ok(
      currentVersion.cacheNames.has("openkanban-public-v1"),
      `${launchMode} removed its active public cache`,
    );

    currentVersion.networkIsAvailable = false;
    const navigation = currentVersion.dispatchFetch({
      method: "GET",
      mode: "navigate",
      url: `${origin}/private-board?mode=${launchMode}`,
    });
    const response = await navigation.responsePromise;
    assert.match(await response.text(), /Sin conexión/);
    assert.deepEqual(currentVersion.cacheWrites, []);
  }
});
