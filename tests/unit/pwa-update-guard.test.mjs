import assert from "node:assert/strict";
import { test } from "node:test";
import {
  createPwaUpdateGuardRegistry,
  registerPwaUpdateGuard,
  requestPwaUpdate,
  resolvePwaUpdateChoice,
} from "../../src/lib/pwa-update-guard.ts";

test("an update guard can defer activation and unregister without changing editor state", () => {
  const registry = createPwaUpdateGuardRegistry();
  let activationCount = 0;
  let requestedContinuation = null;
  const unregister = registerPwaUpdateGuard(registry, (continueUpdate) => {
    requestedContinuation = continueUpdate;
    return true;
  });

  assert.equal(requestPwaUpdate(registry, () => activationCount++), "deferred");
  assert.equal(activationCount, 0);

  requestedContinuation();
  assert.equal(activationCount, 1);
  unregister();
  assert.equal(requestPwaUpdate(registry, () => activationCount++), "activated");
  assert.equal(activationCount, 2);
});

test("stale unregister functions cannot remove a newer open editor's guard", () => {
  const registry = createPwaUpdateGuardRegistry();
  const unregisterOld = registerPwaUpdateGuard(registry, () => true);
  let activated = 0;
  let deferred = 0;
  registerPwaUpdateGuard(registry, () => {
    deferred++;
    return true;
  });

  unregisterOld();

  assert.equal(requestPwaUpdate(registry, () => activated++), "deferred");
  assert.equal(deferred, 1);
  assert.equal(activated, 0);
});

test("save activates only after confirmation; discard activates and continuing cancels", () => {
  assert.equal(resolvePwaUpdateChoice("save", "confirmed"), "activate");
  assert.equal(resolvePwaUpdateChoice("save", "error"), "wait");
  assert.equal(resolvePwaUpdateChoice("save", "conflict"), "wait");
  assert.equal(resolvePwaUpdateChoice("save", "reconciliation"), "wait");
  assert.equal(resolvePwaUpdateChoice("discard"), "activate");
  assert.equal(resolvePwaUpdateChoice("continue"), "cancel");
});

test("a save without a server response leaves update activation deferred", () => {
  const registry = createPwaUpdateGuardRegistry();
  let continueUpdate = null;
  let activationCount = 0;
  registerPwaUpdateGuard(registry, (resume) => {
    continueUpdate = resume;
    return true;
  });

  assert.equal(
    requestPwaUpdate(registry, () => activationCount++),
    "deferred",
  );
  assert.equal(resolvePwaUpdateChoice("save"), "wait");
  assert.equal(activationCount, 0);
  assert.equal(typeof continueUpdate, "function");
});
