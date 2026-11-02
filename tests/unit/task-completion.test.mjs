import assert from "node:assert/strict";
import { test } from "node:test";
import {
  orderTasksByCompletion,
  pendingTaskMoveIndices,
  taskCompletionFollowUp,
} from "../../src/lib/task-completion.ts";

function task(id, is_completed, completed_at = null) {
  return { id, is_completed, completed_at, position: 0 };
}

test("pending tasks retain manual order while completed tasks are most recent first", () => {
  const tasks = [
    task("pending-later-position", false),
    task("completed-old", true, "2026-01-02T00:00:00.000Z"),
    task("pending-first-position", false),
    task("completed-new", true, "2026-01-03T00:00:00.000Z"),
  ];

  assert.deepEqual(orderTasksByCompletion(tasks), {
    pending: [tasks[0], tasks[2]],
    completed: [tasks[3], tasks[1]],
  });
  assert.deepEqual(
    tasks.map(({ id }) => id),
    [
      "pending-later-position",
      "completed-old",
      "pending-first-position",
      "completed-new",
    ],
  );
});

test("completion timestamp ties use a stable identity order", () => {
  const tasks = [
    task("task-b", true, "2026-01-02T00:00:00.000Z"),
    task("task-a", true, "2026-01-02T00:00:00.000Z"),
  ];

  assert.deepEqual(
    orderTasksByCompletion(tasks).completed.map(({ id }) => id),
    ["task-a", "task-b"],
  );
});

test("pending reorders insert before completed tasks without moving their order", () => {
  const tasks = [
    task("pending-a", false),
    task("completed-old", true, "2026-01-02T00:00:00.000Z"),
    task("pending-b", false),
    task("completed-new", true, "2026-01-03T00:00:00.000Z"),
  ];

  assert.deepEqual(pendingTaskMoveIndices(tasks, "pending-a", 1), {
    sourceIndex: 0,
    destinationIndex: 2,
  });
  assert.deepEqual(pendingTaskMoveIndices(tasks, "pending-b", 0), {
    sourceIndex: 2,
    destinationIndex: 0,
  });
  assert.equal(pendingTaskMoveIndices(tasks, "completed-old", 0), null);
});

test("dirty-draft completion follows only explicit discard or confirmed save", () => {
  assert.equal(taskCompletionFollowUp("discard"), "complete");
  assert.equal(taskCompletionFollowUp("save", "confirmed"), "complete");
  assert.equal(taskCompletionFollowUp("save", "conflict"), "none");
  assert.equal(taskCompletionFollowUp("save", "error"), "none");
  assert.equal(taskCompletionFollowUp("save", "reconciliation"), "none");
  assert.equal(taskCompletionFollowUp("cancel"), "none");
});
