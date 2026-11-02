import assert from "node:assert/strict";
import { test } from "node:test";
import {
  createBoardIntentStorageKey,
  readCreateBoardIntent,
  saveCreateBoardIntent,
} from "../../src/lib/private-board-intent.ts";

class MemoryStorage {
  values = new Map();

  getItem(key) {
    return this.values.get(key) ?? null;
  }

  setItem(key, value) {
    this.values.set(key, value);
  }

  removeItem(key) {
    this.values.delete(key);
  }
}

const firstPrincipal = "40000000-0000-4000-8000-000000000001";
const secondPrincipal = "40000000-0000-4000-8000-000000000002";
const savedIntent = {
  name: "Tablero privado de A",
  timeZone: "America/Argentina/Buenos_Aires",
  operationId: "aaaaaaaa-0000-4000-8000-000000000001",
  uncertain: true,
};

test("a pending board intent is isolated to its Auth principal", () => {
  const storage = new MemoryStorage();
  saveCreateBoardIntent(storage, firstPrincipal, savedIntent);

  assert.deepEqual(readCreateBoardIntent(storage, firstPrincipal), savedIntent);
  assert.equal(readCreateBoardIntent(storage, secondPrincipal), null);
  assert.notEqual(
    createBoardIntentStorageKey(firstPrincipal),
    createBoardIntentStorageKey(secondPrincipal),
  );
});

test("no creation intent is available without an authenticated principal id", () => {
  const storage = new MemoryStorage();
  saveCreateBoardIntent(storage, null, savedIntent);

  assert.equal(createBoardIntentStorageKey(null), null);
  assert.equal(createBoardIntentStorageKey("user@example.test"), null);
  saveCreateBoardIntent(storage, "user@example.test", savedIntent);
  assert.equal(readCreateBoardIntent(storage, undefined), null);
  assert.equal(storage.values.size, 0);
});
