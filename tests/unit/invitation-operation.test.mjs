import assert from "node:assert/strict";
import { test } from "node:test";
import {
  completeInvitationOperation,
  getOrCreateInvitationOperation,
} from "../../src/lib/invitation-operation.ts";

function createStorage() {
  const values = new Map();
  return {
    getItem(key) {
      return values.get(key) ?? null;
    },
    setItem(key, value) {
      values.set(key, value);
    },
    removeItem(key) {
      values.delete(key);
    },
  };
}

test("an uncertain generic link command reuses its operation and token", () => {
  const storage = createStorage();
  const first = getOrCreateInvitationOperation(
    "create:board-id",
    true,
    storage,
  );
  const replay = getOrCreateInvitationOperation(
    "create:board-id",
    true,
    storage,
  );

  assert.deepEqual(replay, first);
  assert.match(first.operationId, /^[0-9a-f-]{36}$/);
  assert.match(first.token ?? "", /^[0-9a-f]{64}$/);
});

test("a confirmed invitation command clears its key for a new intent", () => {
  const storage = createStorage();
  const first = getOrCreateInvitationOperation("accept:token", false, storage);
  completeInvitationOperation("accept:token", storage);
  const second = getOrCreateInvitationOperation("accept:token", false, storage);

  assert.notEqual(second.operationId, first.operationId);
  assert.equal(second.token, null);
});
