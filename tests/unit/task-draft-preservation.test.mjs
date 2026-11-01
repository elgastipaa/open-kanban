import assert from "node:assert/strict";
import { test } from "node:test";
import {
  captureTaskDraftForAuthorizationRefresh,
  resolveTaskDraftAfterAuthorizationRefresh,
} from "../../src/lib/task-draft-preservation.ts";

const draft = {
  title: "Borrador privado",
  description: "Texto sin guardar",
  priority: "high",
  due_on: "2026-11-01",
};

function capture(overrides = {}) {
  return captureTaskDraftForAuthorizationRefresh({
    actorId: "actor-a",
    taskId: "task-a",
    authEpoch: "9",
    draft,
    isDirty: true,
    ...overrides,
  });
}

test("only a dirty task draft is kept in transient memory during a pending refetch", () => {
  const preserved = capture();

  assert.deepEqual(
    resolveTaskDraftAfterAuthorizationRefresh({
      preserved,
      currentActorId: "actor-a",
      currentAuthEpoch: 9,
      outcome: { status: "pending" },
    }),
    { status: "pending" },
  );
  assert.equal(capture({ isDirty: false }), null);
});

test("a draft returns only after an authorized snapshot has the same actor, epoch and task", () => {
  assert.deepEqual(
    resolveTaskDraftAfterAuthorizationRefresh({
      preserved: capture(),
      currentActorId: "actor-a",
      currentAuthEpoch: 9,
      outcome: {
        status: "authorized",
        authEpoch: "9",
        taskIds: ["task-a", "task-b"],
      },
    }),
    { status: "restore", draft },
  );
});

test("denial, unavailable, stale authorization, account change and missing task discard the draft", () => {
  const preserved = capture();
  const resolve = (overrides = {}) =>
    resolveTaskDraftAfterAuthorizationRefresh({
      preserved,
      currentActorId: "actor-a",
      currentAuthEpoch: 9,
      outcome: { status: "authorized", authEpoch: 9, taskIds: ["task-a"] },
      ...overrides,
    });

  assert.deepEqual(resolve({ outcome: { status: "denied" } }), { status: "discard" });
  assert.deepEqual(resolve({ outcome: { status: "unavailable" } }), { status: "discard" });
  assert.deepEqual(resolve({ outcome: { status: "discarded" } }), { status: "discard" });
  assert.deepEqual(resolve({ currentActorId: "actor-b" }), { status: "discard" });
  assert.deepEqual(resolve({ currentAuthEpoch: 10 }), { status: "discard" });
  assert.deepEqual(
    resolve({ outcome: { status: "authorized", authEpoch: 10, taskIds: ["task-a"] } }),
    { status: "discard" },
  );
  assert.deepEqual(
    resolve({ outcome: { status: "authorized", authEpoch: 9, taskIds: ["task-b"] } }),
    { status: "discard" },
  );
});
