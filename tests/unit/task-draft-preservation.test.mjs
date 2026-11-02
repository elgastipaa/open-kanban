import assert from "node:assert/strict";
import { test } from "node:test";
import {
  captureTaskDraftForAuthorizationRefresh,
  rebasePreservedTaskDraft,
  resolveTaskDraftAfterAuthorizationRefresh,
  shouldRetryTaskDraftAuthorizationRefresh,
} from "../../src/lib/task-draft-preservation.ts";

const draft = {
  title: "Borrador privado",
  description: "Texto sin guardar",
  priority: "high",
  due_on: "2026-11-01",
};
const versions = { title: 4, description: 2, priority: 1, due_on: 3 };
const currentTask = {
  title: "Título actual",
  description: "Descripción actualizada por otra persona",
  priority: "medium",
  due_on: null,
  field_versions: { title: 4, description: 3, priority: 1, due_on: 3 },
};

function capture(overrides = {}) {
  return captureTaskDraftForAuthorizationRefresh({
    actorId: "actor-a",
    taskId: "task-a",
    authEpoch: "9",
    draft,
    dirtyFields: ["title"],
    baseVersions: versions,
    ...overrides,
  });
}

test("only dirty field values and their original versions stay in transient memory", () => {
  assert.deepEqual(capture(), {
    actorId: "actor-a",
    taskId: "task-a",
    authEpoch: "9",
    draft: { title: "Borrador privado" },
    dirtyFields: ["title"],
    baseVersions: { title: 4 },
  });
  assert.equal(capture({ dirtyFields: [] }), null);
});

test("a draft stays pending and restores only for the same actor, epoch and authorized task", () => {
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
  assert.deepEqual(
    resolveTaskDraftAfterAuthorizationRefresh({
      preserved,
      currentActorId: "actor-a",
      currentAuthEpoch: 9,
      outcome: { status: "retryable" },
    }),
    { status: "pending" },
  );
  assert.deepEqual(
    resolveTaskDraftAfterAuthorizationRefresh({
      preserved,
      currentActorId: "actor-a",
      currentAuthEpoch: 9,
      outcome: {
        status: "authorized",
        authEpoch: "9",
        taskIds: ["task-a", "task-b"],
      },
    }),
    { status: "restore", preserved },
  );
});

test("a rebase takes untouched fields from the authorized snapshot", () => {
  const preserved = capture();

  assert.deepEqual(
    rebasePreservedTaskDraft(currentTask, preserved),
    {
      draft: {
        title: "Borrador privado",
        description: currentTask.description,
        priority: currentTask.priority,
        due_on: "",
      },
      conflicts: {},
    },
  );
});

test("a dirty field changed since its captured version returns an explicit conflict", () => {
  const preserved = capture();
  const snapshot = {
    ...currentTask,
    title: "Título guardado por otra persona",
    field_versions: { ...currentTask.field_versions, title: 5 },
  };

  assert.deepEqual(rebasePreservedTaskDraft(snapshot, preserved), {
    draft: {
      title: "Borrador privado",
      description: snapshot.description,
      priority: snapshot.priority,
      due_on: "",
    },
    conflicts: {
      title: {
        current: "Título guardado por otra persona",
        draft: "Borrador privado",
        current_version: 5,
      },
    },
  });
});

test("denial, unavailable, stale response, account change and missing task discard the draft", () => {
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

test("discarded refreshes retry only while actor, board epoch, session and generation remain current", () => {
  const preserved = capture();
  const discarded = { status: "discarded" };
  const currentContext = {
    requestActorId: "actor-a",
    currentActorId: "actor-a",
    requestAuthEpoch: 9,
    currentAuthEpoch: 9,
    requestSessionEpoch: 4,
    currentSessionEpoch: 4,
    requestSignal: new AbortController().signal,
    isMounted: true,
    isCurrentGeneration: true,
  };
  let retries = 0;
  for (const outcome of [discarded, discarded, { status: "retryable" }]) {
    assert.equal(
      shouldRetryTaskDraftAuthorizationRefresh({
        preserved,
        ...currentContext,
        outcome,
      }),
      true,
    );
    retries += 1;
  }
  assert.equal(retries, 3);
  assert.equal(
    shouldRetryTaskDraftAuthorizationRefresh({
      preserved,
      ...currentContext,
      currentActorId: "actor-b",
      outcome: discarded,
    }),
    false,
  );
  assert.equal(
    shouldRetryTaskDraftAuthorizationRefresh({
      preserved,
      ...currentContext,
      currentAuthEpoch: 10,
      outcome: discarded,
    }),
    false,
  );
  assert.equal(
    shouldRetryTaskDraftAuthorizationRefresh({
      preserved,
      ...currentContext,
      currentSessionEpoch: 5,
      outcome: discarded,
    }),
    false,
  );
  assert.equal(
    shouldRetryTaskDraftAuthorizationRefresh({
      preserved,
      ...currentContext,
      isMounted: false,
      outcome: discarded,
    }),
    false,
  );
  assert.equal(
    shouldRetryTaskDraftAuthorizationRefresh({
      preserved,
      ...currentContext,
      isCurrentGeneration: false,
      outcome: discarded,
    }),
    false,
  );
  assert.equal(
    shouldRetryTaskDraftAuthorizationRefresh({
      preserved,
      ...currentContext,
      outcome: { status: "unavailable" },
    }),
    false,
  );
});

test("a session abort after a discarded response stops retries and does not restore the draft", () => {
  const preserved = capture();
  const controller = new AbortController();
  const context = {
    requestActorId: "actor-a",
    currentActorId: "actor-a",
    requestAuthEpoch: 9,
    currentAuthEpoch: 9,
    requestSessionEpoch: 4,
    currentSessionEpoch: 4,
    requestSignal: controller.signal,
    isMounted: true,
    isCurrentGeneration: true,
  };

  assert.equal(
    shouldRetryTaskDraftAuthorizationRefresh({
      preserved,
      ...context,
      outcome: { status: "discarded" },
    }),
    true,
  );

  controller.abort();
  assert.equal(
    shouldRetryTaskDraftAuthorizationRefresh({
      preserved,
      ...context,
      outcome: { status: "discarded" },
    }),
    false,
  );
  assert.equal(
    shouldRetryTaskDraftAuthorizationRefresh({
      preserved,
      ...context,
      currentSessionEpoch: 5,
      outcome: { status: "discarded" },
    }),
    false,
  );
  assert.deepEqual(
    resolveTaskDraftAfterAuthorizationRefresh({
      preserved,
      currentActorId: "actor-a",
      currentAuthEpoch: 9,
      outcome: { status: "discarded" },
    }),
    { status: "discard" },
  );
});

test("unmount during a discarded response stops retries and leaves no restorable draft", () => {
  const preserved = capture();
  const context = {
    requestActorId: "actor-a",
    currentActorId: "actor-a",
    requestAuthEpoch: 9,
    currentAuthEpoch: 9,
    requestSessionEpoch: 4,
    currentSessionEpoch: 4,
    requestSignal: new AbortController().signal,
    isMounted: false,
    isCurrentGeneration: false,
  };

  assert.equal(
    shouldRetryTaskDraftAuthorizationRefresh({
      preserved,
      ...context,
      outcome: { status: "discarded" },
    }),
    false,
  );
  assert.deepEqual(
    resolveTaskDraftAfterAuthorizationRefresh({
      preserved,
      currentActorId: "actor-a",
      currentAuthEpoch: 9,
      outcome: { status: "discarded" },
    }),
    { status: "discard" },
  );
});
